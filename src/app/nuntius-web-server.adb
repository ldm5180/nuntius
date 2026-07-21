with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;

with GNAT.Sockets;

with Nuntius.Fd_Poll;

procedure Nuntius.Web.Server (Bind : String; Port : Natural) is

   use GNAT.Sockets;
   use type Ada.Streams.Stream_Element_Offset;

   --  Stop-notice bound between accepts.
   Poll_Ms : constant := 100;

   --  Bound on EVERY read and write on a connection (the
   --  Receive_Timeout pattern) -- a stalled peer can never park the
   --  serial loop for long.
   Io_Timeout : constant Duration := 2.0;

   Terminator : constant String := ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF;

   function Image (N : Natural) return String is
      S : constant String := N'Image;
   begin
      return S (S'First + 1 .. S'Last);
   end Image;

   --  Send the whole response; Send_Socket raises on a dead peer and
   --  the Send_Timeout bounds a stuck one.
   procedure Send_All (Sock : Socket_Type; Text : String) is
      Buf   : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      First : Ada.Streams.Stream_Element_Offset := Buf'First;
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      for K in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (K)));
      end loop;
      while First <= Buf'Last loop
         Send_Socket (Sock, Buf (First .. Buf'Last), Last);
         exit when Last < First;
         First := Last + 1;
      end loop;
   end Send_All;

   --  One connection: read the request head, parse (pure parent),
   --  dispatch, respond.  A receive timeout or a peer close before the
   --  header terminator drops SILENTLY -- port scanners, TCP health
   --  probes, and dribbling clients never reach the outer connection-
   --  error log.
   procedure Serve_One (Sock : Socket_Type) is
      Buf : String (1 .. Max_Request_Bytes);
      Len : Natural := 0;

      procedure Respond (S : Status; Content_Type, Payload : String) is
      begin
         Send_All
           (Sock, Response_Head (S, Content_Type, Payload'Length) & Payload);
      end Respond;
   begin
      loop
         declare
            Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
            Last  : Ada.Streams.Stream_Element_Offset;
         begin
            begin
               Receive_Socket (Sock, Chunk, Last);
            exception
               when Socket_Error =>
                  --  Timeout or reset before a full head: quiet drop.
                  return;
            end;
            if Last < Chunk'First then
               --  Peer closed before the terminator: quiet drop.
               return;
            end if;
            if Len + Natural (Last) > Buf'Length then
               Respond (Bad_Request_400, "text/plain", "bad request");
               return;
            end if;
            for K in 1 .. Last loop
               Buf (Len + Natural (K)) := Character'Val (Chunk (K));
            end loop;
            Len := Len + Natural (Last);
         end;
         exit when Ada.Strings.Fixed.Index (Buf (1 .. Len), Terminator) > 0;
      end loop;

      declare
         R : constant Request := Parse_Request (Buf (1 .. Len));
      begin
         if not R.Well_Formed then
            Respond (Bad_Request_400, "text/plain", "bad request");
         elsif R.Method /= Get then
            Respond (Not_Allowed_405, "text/plain", "GET only");
         else
            Handle (Target_Of (R), Respond'Access);
         end if;
      end;
   end Serve_One;

   Listener : Socket_Type;
   Addr     : Sock_Addr_Type;

begin
   --  Bind/listen; ANY failure here (bad bind string, port in use) is
   --  a warning + return, never an exception out of the caller's task.
   begin
      Addr :=
        (Family => Family_Inet,
         Addr   => Inet_Addr (Bind),
         Port   => Port_Type (Port));
      Create_Socket (Listener);
      Set_Socket_Option (Listener, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listener, Addr);
      --  Default backlog: a serial server needs no depth.
      Listen_Socket (Listener);
   exception
      when E : Socket_Error =>
         Log_Warn
           ("cannot listen on "
            & Bind
            & ":"
            & Image (Port)
            & " ("
            & Ada.Exceptions.Exception_Message (E)
            & "); serving off");
         return;
   end;

   declare
      Bound : constant Natural := Natural (Get_Socket_Name (Listener).Port);
   begin
      On_Listening (Bound);
      Log_Info ("serving http://" & Bind & ":" & Image (Bound));
   end;

   --  POLL the listening fd, never block in accept(2) (the
   --  un-abortable-foreign-call limitation).
   while not Stop loop
      if Nuntius.Fd_Poll.Readable (To_C (Listener)) then
         declare
            Sock : Socket_Type := No_Socket;
            From : Sock_Addr_Type;
         begin
            Accept_Socket (Listener, Sock, From);
            Set_Socket_Option
              (Sock,
               Socket_Level,
               (Name => Receive_Timeout, Timeout => Io_Timeout));
            Set_Socket_Option
              (Sock,
               Socket_Level,
               (Name => Send_Timeout, Timeout => Io_Timeout));
            Serve_One (Sock);
            Close_Socket (Sock);
         exception
            when E : others =>
               --  One bad client must never kill the caller's task.
               --  Sleep a lap before re-polling: if poll keeps
               --  reporting readable while accept keeps failing, an
               --  unslept retry is a hot spin.
               begin
                  Close_Socket (Sock);
               exception
                  when others =>
                     null;
               end;
               Log_Info
                 ("connection error ("
                  & Ada.Exceptions.Exception_Message (E)
                  & "); continuing");
               Sleep_Ms (Poll_Ms);
         end;
      else
         Sleep_Ms (Poll_Ms);
      end if;
   end loop;

   Close_Socket (Listener);
   Log_Info ("stopped");
end Nuntius.Web.Server;
