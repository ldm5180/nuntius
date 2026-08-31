with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with AWS.Net.SSL;

package body Nuntius.Ws.Aws_Client is

   --  CLIENT TLS DEFAULTS, ARMED BY THE ADAPTER THAT NEEDS THEM.
   --
   --  AWS builds a client's SSL config from its own defaults, and
   --  AWS.Default.Client_Certificate is "cert.pem" -- a file that
   --  belongs to a SERVER and does not exist beside a client.  Left
   --  alone, every wss:// dial dies locally with
   --
   --    AWS.NET.SOCKET_ERROR : Key file "cert.pem" error.
   --
   --  before a byte reaches the wire.  Every consumer of this adapter
   --  had to discover that and make the Initialize_Default_Config call
   --  itself, in its own boot code, from a diagnosis that cost a
   --  throwaway main -- so the dial's owner now makes it.  Subsequent
   --  calls are documented no-ops, so a consumer that must supply a
   --  REAL client certificate simply initializes its config before the
   --  first dial here, and this call changes nothing.
   --
   --  Guarded per instance (the call itself is process-wide and
   --  idempotent), and only on the way to a wss dial: a plain ws://
   --  consumer on an SSL-less AWS build (SOCKET=std) must not pay an
   --  SSL elaboration it will never use.  Failures fall through to the
   --  dial, whose own error then says what is actually wrong.
   Tls_Defaults_Armed : Boolean := False;

   procedure Ensure_Tls_Defaults is
   begin
      if Tls_Defaults_Armed then
         return;
      end if;
      Tls_Defaults_Armed := True;
      AWS.Net.SSL.Initialize_Default_Config
        (Server_Certificate => "", Server_Key => "", Client_Certificate => "");
   exception
      when others =>
         null;  --  an SSL-less build: the dial will say so, readably
   end Ensure_Tls_Defaults;

   procedure Note_Error
     (Self : in out Client; E : Ada.Exceptions.Exception_Occurrence)
   is
      Text : constant String :=
        Ada.Exceptions.Exception_Name (E)
        & ": "
        & Ada.Exceptions.Exception_Message (E);
      Keep : constant Natural := Natural'Min (Text'Length, Max_Error);
   begin
      Self.Err (1 .. Keep) := Text (Text'First .. Text'First + Keep - 1);
      Self.Err_Last := Keep;
   end Note_Error;

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
         begin
            Dispose (Self.Sock);
         exception
            when others =>
               --  A dial that failed mid-TLS-handshake leaves AWS's
               --  state half-built, and its Finalize then raises out of
               --  Dispose as PROGRAM_ERROR (finalize/adjust) -- which
               --  must not escape: the caller is a reconnect loop, and
               --  this exception killed a whole consumer task in
               --  production.  The pointer is left non-null on a raise,
               --  so null it by hand; leaking one dead socket beats
               --  crashing the lane that owns the redial.
               Self.Sock := null;
         end;
      end if;
   end Free_Socket;

   overriding
   procedure On_Message (Socket : in out Socket_Type; Message : String) is
      Ok : Boolean;
   begin
      --  EVERY message goes through Push, refusals included, so the
      --  fifo's own tally is the one place either loss is counted --
      --  and Nuntius.Ws.Losses is how a consumer reads it back.  Push
      --  refuses an overlong frame without copying it, so routing the
      --  oversized case through here costs nothing.
      Frames.Push (Socket.Inbound, Message, Ok);

      --  The two refusals are not the same event.  An oversized frame is
      --  a BOUND that is wrong: it could never be delivered whole, so
      --  the port contract makes it reconnect-worthy.  A full ring is
      --  the consumer falling behind on a burst, and that must NOT
      --  reconnect -- a redial would lose the whole backlog and add a
      --  gap where a moment's patience loses nothing.
      if Message'Length > Max_Frame_Bytes then
         Socket.Dead := True;
      end if;
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
      Self.Err_Last := 0;
      if URL'Length >= 3
        and then URL (URL'First .. URL'First + 2) in "wss" | "WSS"
      then
         Ensure_Tls_Defaults;
      end if;
      Self.Sock := new Socket_Type;
      AWS.Net.WebSocket.Connect (Self.Sock.all, URL);
      Self.Connected := True;
      Self.Idle := 0.0;
      Ok := True;
   exception
      when E : others =>
         --  A refused dial allocated on the way in; drop the whole object
         --  now so a reconnect storm cannot leak and the next dial starts
         --  clean.  The exception is absorbed (the port contract: a
         --  reconnect loop must not die) but its MESSAGE is kept --
         --  Last_Error -- because absorbing the reason once cost a total
         --  TLS failure its diagnosis.
         Note_Error (Self, E);
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

   --  The one wait loop under both receives.  Bounded False waits until
   --  a frame, death, or the idle limit; Bounded True additionally
   --  returns a healthy Timed_Out once Patience has elapsed.  The idle
   --  clock is Self.Idle -- persisted across calls, reset by traffic --
   --  so a run of patient calls still detects a silent partition.
   procedure Wait_Frame
     (Self      : in out Client;
      Into      : out String;
      Last      : out Natural;
      Bounded   : Boolean;
      Patience  : Duration;
      Ok        : out Boolean;
      Timed_Out : out Boolean)
   is
      Waited : Duration := 0.0;
   begin
      Last := 0;
      Ok := False;
      Timed_Out := False;

      if Self.Sock = null then
         return;  --  no dial in flight; nothing to receive

      end if;

      loop
         if Frames.Count (Self.Sock.Inbound) > 0 then
            --  Ok stays False for a frame too big for this caller:
            --  consumed by Pop and reconnect-worthy here.
            Frames.Pop (Self.Sock.Inbound, Into, Last, Ok);
            Self.Idle := 0.0;
            return;
         end if;

         if not Self.Connected or else Self.Sock.Dead then
            return;
         end if;

         if Self.Idle >= Idle_Limit then
            --  Nothing at all -- no data, no control traffic -- for
            --  the whole limit: assume a silent partition.
            Self.Sock.Dead := True;
            return;
         end if;

         if Bounded and then Waited >= Patience then
            Ok := True;
            Timed_Out := True;
            return;
         end if;

         --  Pump the socket; a False result is just "nothing yet".
         declare
            Got : Boolean := False;
         begin
            Got := AWS.Net.WebSocket.Poll (Self.Sock.all, Poll_Slice);
            if Got then
               Self.Idle := 0.0;
            else
               Self.Idle := Self.Idle + Poll_Slice;
               Waited := Waited + Poll_Slice;
            end if;
         exception
            when others =>
               Self.Sock.Dead := True;
         end;
      end loop;
   end Wait_Frame;

   overriding
   procedure Receive
     (Self : in out Client;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean)
   is
      Unused : Boolean;
   begin
      Wait_Frame
        (Self,
         Into,
         Last,
         Bounded   => False,
         Patience  => 0.0,
         Ok        => Ok,
         Timed_Out => Unused);
   end Receive;

   overriding
   procedure Receive_For
     (Self      : in out Client;
      Into      : out String;
      Last      : out Natural;
      Patience  : Duration;
      Ok        : out Boolean;
      Timed_Out : out Boolean) is
   begin
      Wait_Frame (Self, Into, Last, True, Patience, Ok, Timed_Out);
   end Receive_For;

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

   ------------
   -- Losses --
   ------------

   --  Straight off the fifo: On_Message routes every refusal through
   --  Push, so there is no second tally to reconcile.  An unconnected
   --  client has no socket and has therefore lost nothing.
   overriding
   function Losses (Self : Client) return Nuntius.Ws.Loss_Report is
   begin
      if Self.Sock = null then
         return (others => <>);
      end if;
      return
        (Dropped   => Frames.Refused_Full (Self.Sock.Inbound),
         Oversized => Frames.Refused_Long (Self.Sock.Inbound),
         Largest   => Frames.Longest_Refused (Self.Sock.Inbound));
   end Losses;

end Nuntius.Ws.Aws_Client;
