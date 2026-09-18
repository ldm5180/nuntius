with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Web.Handshake;

--  RFC 6455 4.2.2: the accept key is base64 (SHA-1 (key || GUID)), and
--  1.3 works the example through.  SHA-1 is not SPARK, which is why
--  this one step lives in the shell rather than beside the parser.

package body Nuntius_Web_Handshake_Tests is

   use AUnit.Test_Cases.Registration;

   procedure Test_Rfc_Example (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Nuntius.Web.Handshake.Accept_Key ("dGhlIHNhbXBsZSBub25jZQ==")
         = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
         "the RFC's own worked example");
   end Test_Rfc_Example;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Rfc_Example'Access, "Accept_Key matches RFC 6455 1.3");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Web.Handshake (the accept key)");
   end Name;

end Nuntius_Web_Handshake_Tests;
