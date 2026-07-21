with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Web.Files;

--  The capped whole-file read a handler serves static content with:
--  the three outcomes (read, missing, oversized) are distinct so the
--  caller owns the logging and status policy.

package body Nuntius_Web_Files_Tests is

   use AUnit.Test_Cases.Registration;
   use type Nuntius.Web.Files.Read_Result;

   Path : constant String := "nuntius_web_files_test_scratch.txt";

   --  Stream_IO, not Text_IO: Close must not append a line terminator
   --  (the content assertions are byte-exact).
   procedure Write_Scratch (Content : String) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      String'Write (Stream (F), Content);
      Close (F);
   end Write_Scratch;

   procedure Delete_Scratch is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Delete_Scratch;

   procedure Test_Read_Outcomes (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Content : Unbounded_String;
      Result  : Nuntius.Web.Files.Read_Result;
   begin
      Write_Scratch ("hello, web");
      Nuntius.Web.Files.Read_Capped (Path, 4_096, Content, Result);
      Assert (Result = Nuntius.Web.Files.Read_Ok, "a small file reads whole");
      Assert (To_String (Content) = "hello, web", "content is byte-exact");

      Nuntius.Web.Files.Read_Capped (Path, 4, Content, Result);
      Assert
        (Result = Nuntius.Web.Files.Oversized,
         "a file past the cap reads as Oversized, never truncated");
      Assert (Length (Content) = 0, "no partial content on Oversized");

      Delete_Scratch;
      Nuntius.Web.Files.Read_Capped (Path, 4_096, Content, Result);
      Assert (Result = Nuntius.Web.Files.Missing, "an absent file is Missing");
      Assert (Length (Content) = 0, "no content on Missing");
   exception
      when others =>
         Delete_Scratch;
         raise;
   end Test_Read_Outcomes;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Read_Outcomes'Access,
         "Read_Capped: whole read, oversized refusal, missing file");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web.Files (capped whole-file read)"));

end Nuntius_Web_Files_Tests;
