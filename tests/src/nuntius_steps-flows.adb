package body Nuntius_Steps.Flows is

   --  How many follow-up events one step may chain: past any the tables
   --  ask for, so a table that loops ends instead of spinning.
   Max_Follow_Ups : constant := 4;

   procedure Take
     (Table   : Machines.Transition_Table;
      Current : in out State;
      Ctx     : in out Step_Context;
      Evt     : Step_Kind;
      Handled : out Boolean)
   is
      M         : Machines.Machine :=
        Machines.Make (Table, Initial => Current);
      Follow_Up : Step_Kind;
      Took      : Boolean;
   begin
      Machines.Engine.Process_Event (M, Ctx, Evt, Handled);
      for K in 1 .. Max_Follow_Ups loop
         exit when not Ctx.Has_Next;
         Follow_Up := Ctx.Next;
         Ctx.Has_Next := False;
         Machines.Engine.Process_Event (M, Ctx, Follow_Up, Took);
      end loop;
      Current := Machines.State_Of (M);
   end Take;

end Nuntius_Steps.Flows;
