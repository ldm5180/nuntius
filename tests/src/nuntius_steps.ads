with Fabula.Args;
with Fabula.Check;
with Fabula.Frames;
with Fabula.Registry;

--  The step registry the feature runner dispatches on: one Step_Kind
--  per pattern, one table that reads like the features, one Execute.

package Nuntius_Steps is

   type Step_Kind is (Nothing_Sent, Send_Bytes, Check_Sent);
   type Hook_Kind is (Fresh_World);

   --  What one scenario reads back.  fabula copies it per step, so it
   --  holds values only; the sockets and tasks live in the world.
   type World is record
      Sent : Natural := 0;
   end record;

   package Steps is new
     Fabula.Registry
       (Step_Kind => Step_Kind,
        Hook_Kind => Hook_Kind,
        Context   => World);
   use Steps;

   Step_Defs : constant Steps.Step_Table :=
     [Step ("nothing has been sent") >= Nothing_Sent,
      Step ("{int} bytes are sent") >= Send_Bytes,
      Step ("{int} bytes have been sent") >= Check_Sent];

   Hook_Defs : constant Steps.Hook_Table := [Before >= Fresh_World];

   procedure Execute
     (S    : Step_Kind;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome);

   procedure Run_Hook
     (H    : Hook_Kind;
      Ctx  : in out World;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome);

end Nuntius_Steps;
