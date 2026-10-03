with Fabula.Check.Ints;

with Nuntius.Deflate;

with Nuntius_Steps.Flows;
with Nuntius_World; use Nuntius_World;

with Test_Payloads;

package body Nuntius_Steps.Codings is

   use type Nuntius.Deflate.Unpack_Verdict;

   --  Empty until a step makes a text and treats it; checks read it then.
   type State is (Empty, Made);

   type Guard_Kind is (Always, Length_Read, Says_Something, Says_Nothing);

   type Action_Kind is
     (A_Nothing,
      A_Gzip_Json,
      A_Gzip_Noise,
      A_Pack_Json,
      A_Refuse_Length,
      A_Check_Tenth,
      A_Check_Gunzip_Back,
      A_Check_Unpack_Back,
      A_Expect_Something,
      A_Expect_Nothing,
      A_Refuse_Word);

   First_Capture : constant := 1;

   --  "Under a tenth": the shrink the unit tests hold repetitive JSON to.
   Tenth : constant := 10;

   function Word_Is (Ctx : Step_Context; Word : String) return Boolean
   is (Fabula.Args.Count (Ctx.A) >= First_Capture
       and then Fabula.Args.Word (Ctx.A, First_Capture) = Word);

   function Evaluate
     (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean
   is
      pragma Unreferenced (Evt);
   begin
      return
        (case G is
           when Always         => True,
           when Length_Read    => Count_Read (Ctx),
           when Says_Something => Word_Is (Ctx, "something"),
           when Says_Nothing   => Word_Is (Ctx, "nothing"));
   end Evaluate;

   ---------------------------------------------------------------------
   --  Actions.
   ---------------------------------------------------------------------

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

   procedure Make (Ctx : in out Step_Context; From : Source; How : Treatment)
   with Pre => Count_Read (Ctx)
   is
      Text : constant String := Text_Of (From, Count (Ctx));
   begin
      Ctx.W.Coding.Text := To_Unbounded_String (Text);
      Ctx.W.Coding.Result := To_Unbounded_String (Treated (Text, How));
   end Make;

   procedure Check_Unpacks (Ctx : in out Step_Context) is
      Text    : constant String := To_String (Ctx.W.Coding.Text);
      Into    : String (1 .. Text'Length);
      Last    : Natural;
      Verdict : Nuntius.Deflate.Unpack_Verdict;
   begin
      Verdict :=
        Nuntius.Deflate.Unpack
          (Octets_Of (To_String (Ctx.W.Coding.Result)), Into, Last);
      Fabula.Check.Is_True
        (Ctx.R,
         Verdict = Nuntius.Deflate.Done and then Into (1 .. Last) = Text,
         "the unpack was " & Verdict'Image);
   end Check_Unpacks;

   function Something_Packed (Ctx : Step_Context) return Boolean
   is (Length (Ctx.W.Coding.Result) > 0);

   procedure Execute
     (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind)
   is
      pragma Unreferenced (Evt);
   begin
      case A is
         when A_Nothing           =>
            null;

         when A_Gzip_Json         =>
            Make (Ctx, Json, Gzipped);

         when A_Gzip_Noise        =>
            Make (Ctx, Noise, Gzipped);

         when A_Pack_Json         =>
            Make (Ctx, Json, Packed);

         when A_Refuse_Length     =>
            Refuse_Count (Ctx);

         when A_Check_Tenth       =>
            Fabula.Check.Ints.Less
              (Ctx.R,
               Length (Ctx.W.Coding.Result),
               Length (Ctx.W.Coding.Text) / Tenth,
               "the result's length");

         when A_Check_Gunzip_Back =>
            Fabula.Check.Is_True
              (Ctx.R,
               Test_Payloads.Gunzip
                 (To_String (Ctx.W.Coding.Result),
                  Length (Ctx.W.Coding.Text) + 1)
               = To_String (Ctx.W.Coding.Text),
               "zlib read back the text");

         when A_Check_Unpack_Back =>
            Check_Unpacks (Ctx);

         when A_Expect_Something  =>
            Fabula.Check.Is_True
              (Ctx.R, Something_Packed (Ctx), "nothing was packed");

         when A_Expect_Nothing    =>
            Fabula.Check.Is_False
              (Ctx.R, Something_Packed (Ctx), "something was packed");

         when A_Refuse_Word       =>
            Fabula.Check.Fail_Step (Ctx.R, "say nothing or something");
      end case;
   end Execute;

   ---------------------------------------------------------------------
   --  The table.
   ---------------------------------------------------------------------

   package Flow is new
     Nuntius_Steps.Flows
       (State       => State,
        Guard_Kind  => Guard_Kind,
        Action_Kind => Action_Kind,
        Evaluate    => Evaluate,
        Execute     => Execute,
        Always      => Always,
        Nothing     => A_Nothing);

   use Flow.Machines;
   use Flow.Op;

   Gzip_Json         : constant Ev := (Kind => E_Gzip_Json);
   Gzip_Noise        : constant Ev := (Kind => E_Gzip_Noise);
   Pack_Json         : constant Ev := (Kind => E_Pack_Json);
   Check_Tenth       : constant Ev := (Kind => E_Check_Tenth);
   Check_Gunzip_Back : constant Ev := (Kind => E_Check_Gunzip_Back);
   Check_Unpack_Back : constant Ev := (Kind => E_Check_Unpack_Back);
   Check_Packed_Word : constant Ev := (Kind => E_Check_Packed_Word);

   --!format off
   Table : constant Transition_Table :=
     [Empty + Gzip_Json  (Length_Read)           / A_Gzip_Json         >= Made,
      Empty + Gzip_Json                          / A_Refuse_Length     >= Empty,
      Empty + Gzip_Noise (Length_Read)           / A_Gzip_Noise        >= Made,
      Empty + Gzip_Noise                         / A_Refuse_Length     >= Empty,
      Empty + Pack_Json  (Length_Read)           / A_Pack_Json         >= Made,
      Empty + Pack_Json                          / A_Refuse_Length     >= Empty,
      Made  + Check_Tenth                        / A_Check_Tenth       >= Made,
      Made  + Check_Gunzip_Back                  / A_Check_Gunzip_Back >= Made,
      Made  + Check_Unpack_Back                  / A_Check_Unpack_Back >= Made,
      Made  + Check_Packed_Word (Says_Something) / A_Expect_Something  >= Made,
      Made  + Check_Packed_Word (Says_Nothing)   / A_Expect_Nothing    >= Made,
      Made  + Check_Packed_Word                  / A_Refuse_Word       >= Made];
   --!format on

   Current : State := Empty;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Flow.Take (Table, Current, Ctx, Evt, Handled);
   end Offer;

   procedure Reset is
   begin
      Current := Empty;
   end Reset;

   function Phase return String
   is (Current'Image);

end Nuntius_Steps.Codings;
