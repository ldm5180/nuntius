with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Ws.Aws_Client;

--  Offline behavior of the AWS adapter: everything a Client guarantees
--  before (or without) a successful dial, plus a refused dial against a
--  loopback port nothing listens on.  Live frame traffic is the
--  consumer's integration concern; the buffering underneath is proved
--  (Nuntius.Frame_Fifo) and the callbacks are exercised there.

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

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Unconnected'Access, "unconnected client refuses politely");
      Register_Routine
        (T, Test_Refused_Dial'Access, "refused dial is Ok = False, reusable");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Ws.Aws_Client (AWS websocket adapter)");
   end Name;

end Nuntius_Ws_Aws_Client_Tests;
