with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Ada.Strings.Fixed;

with AUnit.Assertions; use AUnit.Assertions;

with GNAT.Sockets;

with Loopback_Capture;
with Nuntius.Http.Curl;

--  Offline behavior of the curl adapter: a transport-level failure (here
--  a loopback connection-refusal) must come back as Ok = False with
--  Status 0 on every verb -- never an exception.  Live HTTP exchanges are
--  the consumer's integration concern.

package body Nuntius_Http_Curl_Tests is

   use AUnit.Test_Cases.Registration;

   --  Port 9 (discard) on the loopback is as close to guaranteed-refused
   --  as it gets without a network.
   Refused_URL : constant String := "http://127.0.0.1:9/";

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Has (Haystack, Needle : String) return Boolean
   is (Ada.Strings.Fixed.Index (Haystack, Needle) > 0);

   --  Out of the box the crate names itself, so no request ever goes
   --  out with no User-Agent at all -- an API edge that refuses those
   --  (with an HTML 401 the application never sees) would otherwise
   --  make the adapter look like a dead credential.
   procedure Test_Default_User_Agent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      UA : constant String := Nuntius.Http.User_Agent;
   begin
      Assert
        (UA'Length > 8 and then UA (UA'First .. UA'First + 7) = "nuntius/",
         "the default identity is nuntius/<version>: " & UA);
   end Test_Default_User_Agent;

   --  The registered identity is what the sync adapter puts on the
   --  wire -- observed at a loopback peer, since libcurl (unlike the
   --  curl CLI) sends no User-Agent unless told to.
   procedure Test_User_Agent_On_The_Wire
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Old       : constant String := Nuntius.Http.User_Agent;
      Listen    : GNAT.Sockets.Socket_Type;
      Port      : Natural;
      Transport : Nuntius.Http.Curl.Curl_Transport;
      Status    : Natural;
      Reply     : Unbounded_String;
      Ok        : Boolean;
   begin
      Nuntius.Http.Curl.Register;
      Nuntius.Http.Set_User_Agent ("probe/1.2");
      Loopback_Capture.Listen_Loopback (Listen, Port);
      declare
         Srv : Loopback_Capture.Server;
      begin
         Srv.Serve (Listen);
         Transport.Get
           (Loopback_Capture.Loopback_URL (Port, "/ua"),
            "Bearer x",
            Status,
            Reply,
            Ok);
      end;
      Nuntius.Http.Set_User_Agent (Old);

      Assert (Ok and then Status = 200, "the loopback peer answered 200");
      Assert
        (Has (Loopback_Capture.Head, "User-Agent: probe/1.2" & CRLF),
         "the registered identity is on the wire: " & Loopback_Capture.Head);
   end Test_User_Agent_On_The_Wire;

   procedure Test_Refused_Connection
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Transport : Nuntius.Http.Curl.Curl_Transport;
      Status    : Natural;
      Reply     : Unbounded_String;
      Location  : Unbounded_String;
      Ok        : Boolean;
   begin
      Nuntius.Http.Curl.Register;

      Transport.Post_Form (Refused_URL, "a=b", "Basic x", Status, Reply, Ok);
      Assert (not Ok and then Status = 0, "refused POST form: Ok False");

      Transport.Post_Json
        (Refused_URL, "{}", "Bearer x", Status, Reply, Location, Ok);
      Assert (not Ok and then Status = 0, "refused POST json: Ok False");
      Assert (Location = Null_Unbounded_String, "no Location on failure");

      Transport.Put_Json (Refused_URL, "{}", "Bearer x", Status, Reply, Ok);
      Assert (not Ok and then Status = 0, "refused PUT json: Ok False");

      Transport.Get (Refused_URL, "Bearer x", Status, Reply, Ok);
      Assert (not Ok and then Status = 0, "refused GET: Ok False");

      Transport.Delete (Refused_URL, "Bearer x", Status, Reply, Ok);
      Assert (not Ok and then Status = 0, "refused DELETE: Ok False");
   end Test_Refused_Connection;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Default_User_Agent'Access,
         "the crate names itself as the default User-Agent");
      Register_Routine
        (T,
         Test_User_Agent_On_The_Wire'Access,
         "a registered User-Agent reaches the peer on every request");
      Register_Routine
        (T,
         Test_Refused_Connection'Access,
         "transport failure is Ok = False / Status 0 on every verb");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Http.Curl (libcurl adapter)");
   end Name;

end Nuntius_Http_Curl_Tests;
