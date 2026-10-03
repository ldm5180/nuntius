with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius.Deflate;

with Nuntius_World; use Nuntius_World;

with Test_Payloads;

package body Nuntius_Steps.Codings is

   use type Nuntius.Deflate.Unpack_Verdict;

   subtype Number is Fabula.Numbers.Integer_Reads.Read;

   First_Capture : constant := 1;

   --  "Under a tenth": the shrink the unit tests hold repetitive JSON to.
   Tenth : constant := 10;

   --  The kinds of text a step can make, and what it does with one.
   type Source is (Json, Noise);
   type Treatment is (Gzipped, Packed);

   function Text_Of (From : Source; N : Natural) return String
   is (case From is
         when Json  => Json_Of (N),
         when Noise => Test_Payloads.Noise (N));

   function Treated (Text : String; How : Treatment) return String
   is (case How is
         when Gzipped => Nuntius.Deflate.Gzip (Text),
         when Packed  => Chars_Of (Nuntius.Deflate.Pack (Text)));

   procedure Make
     (Ctx  : in out World;
      From : Source;
      How  : Treatment;
      N    : Number;
      R    : in out Fabula.Check.Outcome) is
   begin
      if N.Ok and then N.Value >= 0 then
         Ctx.Coding.Text := To_Unbounded_String (Text_Of (From, N.Value));
         Ctx.Coding.Result :=
           To_Unbounded_String (Treated (To_String (Ctx.Coding.Text), How));
      elsif N.Ok then
         Fabula.Check.Fail_Step (R, "a length cannot be negative");
      else
         Fabula.Check.Ints.Fail_Read (R, N.Error);
      end if;
   end Make;

   procedure Check_Unpacks (Ctx : World; R : in out Fabula.Check.Outcome) is
      Text    : constant String := To_String (Ctx.Coding.Text);
      Into    : String (1 .. Text'Length);
      Last    : Natural;
      Verdict : Nuntius.Deflate.Unpack_Verdict;
   begin
      Verdict :=
        Nuntius.Deflate.Unpack
          (Octets_Of (To_String (Ctx.Coding.Result)), Into, Last);
      Fabula.Check.Is_True
        (R,
         Verdict = Nuntius.Deflate.Done and then Into (1 .. Last) = Text,
         "the unpack was " & Verdict'Image);
   end Check_Unpacks;

   procedure Check_Packed
     (Ctx : World; Word : String; R : in out Fabula.Check.Outcome)
   is
      Something : constant Boolean := Length (Ctx.Coding.Result) > 0;
   begin
      if Word = "something" then
         Fabula.Check.Is_True (R, Something, "nothing was packed");
      elsif Word = "nothing" then
         Fabula.Check.Is_False (R, Something, "something was packed");
      else
         Fabula.Check.Fail_Step (R, "say nothing or something, not " & Word);
      end if;
   end Check_Packed;

   procedure Execute
     (S   : Coding_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome) is
   begin
      case S is
         when Gzip_Json         =>
            Make (Ctx, Json, Gzipped, Fabula.Args.Int (A, First_Capture), R);

         when Gzip_Noise        =>
            Make (Ctx, Noise, Gzipped, Fabula.Args.Int (A, First_Capture), R);

         when Pack_Json         =>
            Make (Ctx, Json, Packed, Fabula.Args.Int (A, First_Capture), R);

         when Check_Tenth       =>
            Fabula.Check.Ints.Less
              (R,
               Length (Ctx.Coding.Result),
               Length (Ctx.Coding.Text) / Tenth,
               "the result's length");

         when Check_Gunzip_Back =>
            Fabula.Check.Is_True
              (R,
               Test_Payloads.Gunzip
                 (To_String (Ctx.Coding.Result), Length (Ctx.Coding.Text) + 1)
               = To_String (Ctx.Coding.Text),
               "zlib read back the text");

         when Check_Unpack_Back =>
            Check_Unpacks (Ctx, R);

         when Check_Packed_Word =>
            Check_Packed (Ctx, Fabula.Args.Word (A, First_Capture), R);
      end case;
   end Execute;

end Nuntius_Steps.Codings;
