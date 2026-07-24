with Ada.Unchecked_Deallocation;

package body Nuntius.Ws.Aws_Client is

   procedure Dispose is new
     Ada.Unchecked_Deallocation (Socket_Type, Socket_Access);

   procedure Free_Socket (Self : in out Client) is
   begin
      --  Deallocation is the whole cleanup: the AWS socket is Controlled,
      --  and its inherited Finalize dispatches to WebSocket.Free (which
      --  releases the dial's HTTP connection, socket, and protocol state).
      --  This is exactly how AWS.Net.Free frees a heap socket -- plain
      --  Unchecked_Deallocation.  Calling WebSocket.Free *as well* would
      --  free everything twice, since Finalize still runs on Dispose.
      --  Safe on a live, a failed, or a never-dialed object.
      if Self.Sock /= null then
         Dispose (Self.Sock);
      end if;
   end Free_Socket;

   overriding
   procedure On_Message (Socket : in out Socket_Type; Message : String) is
      Ok : Boolean;
   begin
      if Message'Length > Max_Frame_Bytes then
         --  Oversized frame: the port contract makes this reconnect-
         --  worthy (a frame we could never deliver whole).
         Socket.Dead := True;
         return;
      end if;

      --  A full ring returns Ok False and drops the newest frame while
      --  KEEPING the connection: the consumer fell behind on a burst, and
      --  a transient burst must not trigger a reconnect (which would lose
      --  the whole backlog and add a gap).  With the ring at Ring_Depth
      --  this is rare; a sustained overrun degrades to dropped frames,
      --  not a reconnect storm.  Nothing to do on the drop, so Ok is
      --  deliberately not acted on.
      Frames.Push (Socket.Inbound, Message, Ok);
   end On_Message;

   overriding
   procedure On_Close (Socket : in out Socket_Type; Message : String) is
      pragma Unreferenced (Message);
   begin
      Socket.Dead := True;
   end On_Close;

   overriding
   procedure On_Error (Socket : in out Socket_Type; Message : String) is
      pragma Unreferenced (Message);
   begin
      Socket.Dead := True;
   end On_Error;

   overriding
   procedure Connect (Self : in out Client; URL : String; Ok : out Boolean) is
   begin
      --  The port contract makes close-then-dial the adapter's job: hang
      --  up a still-open socket, release the previous dial's object
      --  entirely, then dial on a pristine one.  AWS's Connect
      --  heap-allocates a fresh HTTP connection and protocol state every
      --  call, so a reconnect loop that reused one object would grow the
      --  heap forever -- and, worse, WebSocket.Free leaves the object's
      --  aliased socket field dangling, so freeing a reused object twice
      --  (as a failed redial forces) double-frees.  A fresh object per
      --  dial sidesteps both: Free_Socket runs once per object.
      Close (Self);
      Free_Socket (Self);
      Self.Sock := new Socket_Type;
      AWS.Net.WebSocket.Connect (Self.Sock.all, URL);
      Self.Connected := True;
      Ok := True;
   exception
      when others =>
         --  A refused dial allocated on the way in; drop the whole object
         --  now so a reconnect storm cannot leak and the next dial starts
         --  clean.
         Free_Socket (Self);
         Self.Connected := False;
         Ok := False;
   end Connect;

   overriding
   procedure Send_Text
     (Self : in out Client; Payload : String; Ok : out Boolean) is
   begin
      if Self.Sock = null then
         Ok := False;
         return;
      end if;
      Self.Sock.Send (Payload);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Send_Text;

   overriding
   procedure Receive
     (Self : in out Client;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean) is
   begin
      Last := 0;
      Ok := False;

      if Self.Sock = null then
         return;  --  no dial in flight; nothing to receive

      end if;

      declare
         Idle : Duration := 0.0;
      begin
         loop
            if Frames.Count (Self.Sock.Inbound) > 0 then
               --  Ok stays False for a frame too big for this caller:
               --  consumed by Pop and reconnect-worthy here.
               Frames.Pop (Self.Sock.Inbound, Into, Last, Ok);
               return;
            end if;

            if not Self.Connected or else Self.Sock.Dead then
               return;
            end if;

            if Idle >= Idle_Limit then
               --  Nothing at all -- no data, no control traffic -- for
               --  the whole limit: assume a silent partition.
               Self.Sock.Dead := True;
               return;
            end if;

            --  Pump the socket; a False result is just "nothing yet".
            declare
               Got : Boolean := False;
            begin
               Got := AWS.Net.WebSocket.Poll (Self.Sock.all, Poll_Slice);
               Idle := (if Got then 0.0 else Idle + Poll_Slice);
            exception
               when others =>
                  Self.Sock.Dead := True;
            end;
         end loop;
      end;
   end Receive;

   overriding
   procedure Close (Self : in out Client) is
   begin
      if Self.Connected and then Self.Sock /= null then
         Self.Connected := False;
         begin
            --  A raw shutdown, not the polite close-frame API: we hang
            --  up when the link is already dead, so a queued close frame
            --  would go nowhere.  Free_Socket then reclaims the object.
            Self.Sock.Shutdown;
         exception
            when others =>
               null;  --  the peer is gone; nothing to say goodbye to
         end;
      end if;
   end Close;

end Nuntius.Ws.Aws_Client;
