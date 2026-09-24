with Ada.Calendar;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;

with GNAT.Sockets;

with Nuntius.Deflate;
with Nuntius.Fd_Poll;
with Nuntius.Socket_Io;
with Nuntius.Web.Handshake;

procedure Nuntius.Web.Server (Bind : String; Port : Natural) is

   use GNAT.Sockets;
   use type Ada.Calendar.Time;
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

   --  One connection: read the request head, parse (pure parent), read
   --  the body a POST declared, dispatch, respond.  A receive timeout,
   --  a peer close before the bytes are all in, or a connection past
   --  its budget drops SILENTLY -- port scanners, TCP health probes,
   --  and dribbling clients never reach the outer connection-error log.
   procedure Serve_One (Sock : Socket_Type; Adopted : in out Boolean) is
      --  Whatever the peer's pacing, this is all the serial loop lends
      --  it.  Checked after every read, of the head and of the body.
      Deadline : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock + Duration (Connection_Seconds);

      Buf       : String (1 .. Max_Request_Bytes);
      Len       : Natural := 0;
      Head_Last : Natural := 0;   --  last byte of the head terminator

      type Head_Result is (Complete, Dropped, Over_Budget);

      --  Whether the request takes gzip, set once it is parsed; the
      --  answers before that are identity.
      Takes_Gzip : Boolean := False;

      procedure Send_Response
        (S            : Status;
         Content_Type : String;
         Body_Text    : String;
         Coding       : Codings.Content_Coding) is
      begin
         Nuntius.Socket_Io.Send_All
           (Sock,
            Response_Head (S, Content_Type, Body_Text'Length, Coding)
            & Body_Text);
      end Send_Response;

      --  Gzip when Response_Coding says so and zlib delivers; a member
      --  that did not come back is logged and sent identity instead.
      procedure Respond (S : Status; Content_Type, Payload : String) is
      begin
         if Response_Coding
              (Takes_Gzip, Coding_Policy, Content_Type, Payload'Length)
           = Codings.Gzip
         then
            declare
               Member : constant String := Nuntius.Deflate.Gzip (Payload);
            begin
               if Member'Length > 0 then
                  Send_Response (S, Content_Type, Member, Codings.Gzip);
                  return;
               end if;
               Log_Warn ("gzip failed; sent identity");
            end;
         end if;
         Send_Response (S, Content_Type, Payload, Codings.Identity);
      end Respond;

      function Read_Head return Head_Result is
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
                     return Dropped;
               end;
               if Last < Chunk'First then
                  --  Peer closed before the terminator: quiet drop.
                  return Dropped;
               end if;
               if Ada.Calendar.Clock > Deadline then
                  return Dropped;
               end if;
               if Len + Natural (Last) > Buf'Length then
                  return Over_Budget;
               end if;
               for K in 1 .. Last loop
                  Buf (Len + Natural (K)) := Character'Val (Chunk (K));
               end loop;
               Len := Len + Natural (Last);
            end;
            exit when Ada.Strings.Fixed.Index (Buf (1 .. Len), Terminator) > 0;
         end loop;
         return Complete;
      end Read_Head;

      --  Exactly Want bytes past the head: whatever arrived with it
      --  first, then reads bounded by the per-read timeout AND the
      --  connection budget.  A peer that declared more than it sends is
      --  a quiet drop (Ok False); one that sent MORE than it declared
      --  has the excess ignored -- Connection: close, nothing is ever
      --  pipelined.
      procedure Read_Body
        (Want : Natural; Payload : out String; Ok : out Boolean)
      is
         Have   : constant Natural := Len - Head_Last;
         Filled : Natural := Natural'Min (Have, Want);
      begin
         Payload := [others => ' '];
         Ok := False;
         Payload (Payload'First .. Payload'First + Filled - 1) :=
           Buf (Head_Last + 1 .. Head_Last + Filled);
         while Filled < Want loop
            declare
               Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
               Last  : Ada.Streams.Stream_Element_Offset;
               Take  : Natural;
            begin
               begin
                  Receive_Socket (Sock, Chunk, Last);
               exception
                  when Socket_Error =>
                     return;
               end;
               if Last < Chunk'First then
                  return;
               end if;
               if Ada.Calendar.Clock > Deadline then
                  return;
               end if;
               Take := Natural'Min (Natural (Last), Want - Filled);
               for K in 1 .. Take loop
                  Payload (Payload'First + Filled + K - 1) :=
                    Character'Val
                      (Chunk (Ada.Streams.Stream_Element_Offset (K)));
               end loop;
               Filled := Filled + Take;
            end;
         end loop;
         Ok := True;
      end Read_Body;

      --  The send comes FIRST: a raise there means nothing was handed
      --  over and the accept loop still owns the socket.  Adopt is the
      --  last call, and Adopted is set the statement after it returns.
      procedure Upgrade (R : Request) is
         Coding : constant Codings.Message_Coding :=
           Upgrade_Coding (R.Deflate_Offered, Coding_Policy);
      begin
         Nuntius.Socket_Io.Send_All
           (Sock, Upgrade_Head (Handshake.Accept_Key (Ws_Key_Of (R)), Coding));
         Adopt (R, Sock, Coding);
         Adopted := True;
      end Upgrade;

      procedure Dispatch (R : Request) is
      begin
         Takes_Gzip := R.Accepts_Gzip;
         if R.Length_Refused then
            Respond (Too_Large_413, "text/plain", "body too large");
         elsif not R.Well_Formed then
            Respond (Bad_Request_400, "text/plain", "bad request");
         elsif R.Method = Other then
            Respond (Not_Allowed_405, "text/plain", "method not allowed");
         elsif R.Method = Get and then R.Content_Length > 0 then
            --  Only a POST may spend the budget on a body.
            Respond (Bad_Request_400, "text/plain", "no body on GET");
         elsif R.Method = Post and then R.Content_Length = 0 then
            --  A chunked or lengthless POST is refused up front.
            Respond (Bad_Request_400, "text/plain", "length required");
         elsif R.Upgrade and then Accepts_Upgrade (R) then
            Upgrade (R);
         elsif R.Method = Get then
            Handle (R, "", Respond'Access);
         else
            declare
               Payload : String (1 .. R.Content_Length);
               Ok      : Boolean;
            begin
               Read_Body (R.Content_Length, Payload, Ok);
               if Ok then
                  Handle (R, Payload, Respond'Access);
               end if;
            end;
         end if;
      end Dispatch;

   begin
      case Read_Head is
         when Dropped     =>
            return;

         when Over_Budget =>
            Respond (Bad_Request_400, "text/plain", "bad request");
            return;

         when Complete    =>
            null;
      end case;

      Head_Last := Ada.Strings.Fixed.Index (Buf (1 .. Len), Terminator) + 3;
      Dispatch (Parse_Request (Buf (1 .. Len)));
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
            Sock    : Socket_Type := No_Socket;
            From    : Sock_Addr_Type;
            --  in out, not out: a raise anywhere in Serve_One has to
            --  leave this False so the loop still closes the socket.
            Adopted : Boolean := False;
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
            Serve_One (Sock, Adopted);
            if not Adopted then
               Close_Socket (Sock);
            end if;
         exception
            when E : others =>
               --  One bad client must never kill the caller's task.
               --  Sleep a lap before re-polling: if poll keeps
               --  reporting readable while accept keeps failing, an
               --  unslept retry is a hot spin.
               begin
                  if not Adopted then
                     Close_Socket (Sock);
                  end if;
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
