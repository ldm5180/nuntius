with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Deflate;
with Nuntius.Rfc6455; use Nuntius.Rfc6455;

with Test_Payloads; use Test_Payloads;

--  The zlib wrapper: a gzip member a browser can read, and the
--  permessage-deflate pack and unpack of one message.  The gzip side is
--  read back with zlib's own inflate, independently of the unit under
--  test; the message side round-trips through the unit's own pair.

package body Nuntius_Deflate_Tests is

   use AUnit.Test_Cases.Registration;

   procedure Test_Gzip_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Text   : constant String := Json_Like (100);
      Member : constant String := Nuntius.Deflate.Gzip (Text);
   begin
      Assert (Member'Length > 0, "the member is not empty");
      Assert
        (Member'Length < Text'Length / 10,
         "repetitive JSON shrinks by more than ten times");
      Assert
        (Member (Member'First .. Member'First + 2)
         = Character'Val (16#1F#) & Character'Val (16#8B#) & Character'Val (8),
         "the gzip magic and deflate method");
      Assert (Gunzip (Member, Text'Length + 1) = Text, "zlib reads it back");
   end Test_Gzip_Round_Trips;

   procedure Test_Gzip_Edges (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty  : constant String := Nuntius.Deflate.Gzip ("");
      Hard   : constant String := Noise (65_536);
      Packed : constant String := Nuntius.Deflate.Gzip (Hard);
   begin
      Assert
        (Empty'Length = 20,
         "an empty member is a 10-byte header, 2 bytes of deflate and"
         & " an 8-byte footer; got"
         & Empty'Length'Image);
      Assert (Gunzip (Empty, 1) = "", "and reads back empty");
      Assert (Packed'Length > 0, "incompressible input still fits");
      Assert
        (Packed'Length <= Nuntius.Deflate.Worst_Case (Hard'Length),
         "within the worst case the scratch buffer is sized to");
      Assert (Gunzip (Packed, Hard'Length + 1) = Hard, "and reads back");
   end Test_Gzip_Edges;

   procedure Test_Pack_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Nuntius.Deflate.Unpack_Verdict;
      Text    : constant String := Json_Like (50);
      Packed  : constant Octets := Nuntius.Deflate.Pack (Text);
      Into    : String (1 .. Text'Length);
      Last    : Natural;
      Verdict : Nuntius.Deflate.Unpack_Verdict;
   begin
      Assert (Packed'Length > 0, "a 2 KB message is packed");
      Assert (Packed'Length < Text'Length / 10, "and shrinks");
      Assert
        (Packed (Packed'Last - 3 .. Packed'Last) /= [0, 0, 16#FF#, 16#FF#],
         "the sync tail is removed (RFC 7692 7.2.1)");
      Verdict := Nuntius.Deflate.Unpack (Packed, Into, Last);
      Assert (Verdict = Nuntius.Deflate.Done, "it unpacks");
      Assert (Into (1 .. Last) = Text, "to the same text");
   end Test_Pack_Round_Trips;

   --  D4 and D12: under the floor there is nothing to pack, and the
   --  caller reads the empty array as "send it plain".
   procedure Test_Pack_Floor (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Hello : constant String := "{""hello"":{""proto"":1}}";
   begin
      Assert (Nuntius.Deflate.Pack (Hello)'Length = 0, "the hello goes plain");
      Assert
        (Nuntius.Deflate.Pack (Json_Like (100) (1 .. 511))'Length = 0,
         "511 bytes go plain");
      Assert
        (Nuntius.Deflate.Pack (Json_Like (100) (1 .. 512))'Length > 0,
         "512 bytes are packed");
   end Test_Pack_Floor;

   --  D9: the cap is on what comes OUT, so a small frame cannot inflate
   --  past the caller's buffer; and garbage is a verdict, not a raise.
   procedure Test_Unpack_Bounds (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Nuntius.Deflate.Unpack_Verdict;
      Zeros : constant String (1 .. 4_096) := [others => '0'];
      Bomb  : constant Octets := Nuntius.Deflate.Pack (Zeros);
      Into  : String (1 .. 512);
      Last  : Natural;
   begin
      Assert (Bomb'Length < 64, "4 KB of one byte packs small");
      Assert
        (Nuntius.Deflate.Unpack (Bomb, Into, Last) = Nuntius.Deflate.Too_Big,
         "and inflating it into 512 bytes is refused");
      Assert (Last = 0, "with nothing claimed");
      Assert
        (Nuntius.Deflate.Unpack ([16#FF#, 16#FF#], Into, Last)
         = Nuntius.Deflate.Corrupt,
         "a reserved block type is corrupt");
      Assert (Last = 0, "with nothing claimed");
   end Test_Unpack_Bounds;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Gzip_Round_Trips'Access, "Gzip writes a member zlib reads");
      Register_Routine
        (T,
         Test_Gzip_Edges'Access,
         "Gzip handles an empty body and incompressible bytes");
      Register_Routine
        (T,
         Test_Pack_Round_Trips'Access,
         "Pack and Unpack round-trip one message without the sync tail");
      Register_Routine
        (T, Test_Pack_Floor'Access, "Pack leaves a message under 512 plain");
      Register_Routine
        (T,
         Test_Unpack_Bounds'Access,
         "Unpack caps its output and calls garbage corrupt");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Deflate (gzip and permessage-deflate)"));

end Nuntius_Deflate_Tests;
