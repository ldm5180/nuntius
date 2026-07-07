with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions; use AUnit.Assertions;

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
