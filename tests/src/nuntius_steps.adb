with Fabula.Check.Ints;
with Fabula.Numbers;

package body Nuntius_Steps is

   --  Where the byte count sits among a step's captures.
   Count_Capture : constant := 1;

   procedure Add_Sent
     (Ctx : in out World;
      N   : Fabula.Numbers.Integer_Reads.Read;
      R   : in out Fabula.Check.Outcome) is
   begin
      if N.Ok then
         Ctx.Sent := Ctx.Sent + N.Value;
      else
         Fabula.Check.Ints.Fail_Read (R, N.Error);
      end if;
   end Add_Sent;

   procedure Execute
     (S    : Step_Kind;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Info);
   begin
      case S is
         when Nothing_Sent =>
            Fabula.Check.Ints.Equal (R, Ctx.Sent, 0);

         when Send_Bytes   =>
            Add_Sent (Ctx, Fabula.Args.Int (A, Count_Capture), R);

         when Check_Sent   =>
            Fabula.Check.Ints.Equal
              (R, Ctx.Sent, Fabula.Args.Int (A, Count_Capture));
      end case;
   end Execute;

   procedure Run_Hook
     (H    : Hook_Kind;
      Ctx  : in out World;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Info, R);
   begin
      case H is
         when Fresh_World =>
            Ctx := (others => <>);
      end case;
   end Run_Hook;

end Nuntius_Steps;
