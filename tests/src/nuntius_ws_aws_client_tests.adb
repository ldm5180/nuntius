with Ada.Strings;       use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;

with AUnit.Assertions; use AUnit.Assertions;

with GNAT.Sockets; use GNAT.Sockets;

with Nuntius.Ws.Aws_Client;

--  Offline behavior of the AWS adapter: everything a Client guarantees
--  before (or without) a successful dial, plus a refused dial against a
--  loopback port nothing listens on, plus a dial whose TLS handshake
--  breaks against a live peer speaking garbage.  Live frame traffic is
--  the consumer's integration concern; the buffering underneath is
--  proved (Nuntius.Frame_Fifo) and the callbacks are exercised there.

package body Nuntius_Ws_Aws_Client_Tests is

   use AUnit.Test_Cases.Registration;

   --  Small bounds: these tests never queue a frame, so only the type
   --  checking of the instantiation cares.
   package Ws_Clients is new
     Nuntius.Ws.Aws_Client (Ring_Depth => 3, Max_Frame_Bytes => 64);

   --  Port 9 (discard) on the loopback is as close to guaranteed-refused
   --  as it gets without a network; a refused dial must come back as a
   --  clean Ok = False, never an exception.
   Refused_URL : constant String := "ws://127.0.0.1:9/";

   procedure Test_Unconnected (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Ws_Clients.Client;
      Buf  : String (1 .. 64);
      Last : Natural;
      Ok   : Boolean;
   begin
      Ws_Clients.Send_Text (C, "hello", Ok);
      Assert (not Ok, "send before any dial reports Ok = False");

      Ws_Clients.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "receive before any dial reports Ok = False");
      Assert (Last = 0, "receive before any dial delivers nothing");

      --  Closing a never-dialed client is a harmless no-op.
      Ws_Clients.Close (C);
   end Test_Unconnected;

   procedure Test_Refused_Dial (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C  : Ws_Clients.Client;
      Ok : Boolean;
   begin
      Ws_Clients.Connect (C, Refused_URL, Ok);
      Assert (not Ok, "a refused dial reports Ok = False");

      --  And the client is still safe to use (close-then-dial contract):
      --  a second refused dial behaves the same, nothing dangles.
      Ws_Clients.Connect (C, Refused_URL, Ok);
      Assert (not Ok, "a refused redial reports Ok = False");
      Ws_Clients.Close (C);
   end Test_Refused_Dial;

   --  A dial that gets a TCP connection but no TLS: the peer answers the
   --  ClientHello with garbage and hangs up.  Unlike the refused dial,
   --  AWS builds real connection state on the way in, and the handshake
   --  failure then abandons it half-built -- the state whose controlled
   --  Finalize raised out of Free_Socket's Dispose on the live Schwab
   --  dial (PROGRAM_ERROR: finalize/adjust raised exception, killing the
   --  stream task).  The port contract is the same as every other failed
   --  dial: Ok = False, nothing propagates, the client redials cleanly.
   task type Garbage_Peer is
      entry Serve (Listener : Socket_Type);
   end Garbage_Peer;

   task body Garbage_Peer is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
      Status : Selector_Status;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      --  TIMED accept: the test routine is this task's master, so a
      --  forever-blocking accept would turn any exception in the routine
      --  (an Assert, or the very bug under test propagating out of
      --  Connect) into a suite-wide hang at scope exit.
      Accept_Socket (Listen, Peer, From, Timeout => 10.0, Status => Status);
      if Status = Completed then
         String'Write
           (Stream (Peer), "this is not a tls server" & ASCII.CR & ASCII.LF);
         Close_Socket (Peer);
      end if;
      Close_Socket (Listen);
   exception
      when others =>
         null;  --  the client hanging up early is this peer's success
   end Garbage_Peer;

   procedure Test_Broken_Tls_Dial (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Addr   : Sock_Addr_Type;
      Srv    : Garbage_Peer;
      C      : Ws_Clients.Client;
      Ok     : Boolean;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Addr := Get_Socket_Name (Listen);
      Srv.Serve (Listen);

      Ws_Clients.Connect
        (C,
         "wss://127.0.0.1:" & Trim (Port_Type'Image (Addr.Port), Both) & "/",
         Ok);

      --  Release the peer BEFORE any assert can raise: an AWS that fails
      --  the wss dial without ever TCP-connecting (no SSL support) would
      --  otherwise leave it counting down its accept timeout.
      declare
         Dummy : Socket_Type;
      begin
         Create_Socket (Dummy);
         Connect_Socket (Dummy, (Family_Inet, Loopback_Inet_Addr, Addr.Port));
         Close_Socket (Dummy);
      exception
         when others =>
            null;  --  the peer already served the real dial and is gone
      end;

      Assert (not Ok, "a broken-handshake dial reports Ok = False");

      --  The half-built dial must not poison the client: a follow-up
      --  refused dial still comes back clean.
      Ws_Clients.Connect (C, Refused_URL, Ok);
      Assert (not Ok, "the client redials cleanly after the broken dial");
      Ws_Clients.Close (C);
   end Test_Broken_Tls_Dial;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Unconnected'Access, "unconnected client refuses politely");
      Register_Routine
        (T, Test_Refused_Dial'Access, "refused dial is Ok = False, reusable");
      Register_Routine
        (T,
         Test_Broken_Tls_Dial'Access,
         "a broken TLS handshake never propagates");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Ws.Aws_Client (AWS websocket adapter)");
   end Name;

end Nuntius_Ws_Aws_Client_Tests;
