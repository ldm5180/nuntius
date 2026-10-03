with Sml.Machines.Operators;
with Sml.Simple_Machines;

--  One feature's steps as a state machine: the steps are its events, the
--  conditions that chose between their bodies are its guards, the bodies
--  its actions.  Take offers one step to the table, then takes the event
--  any action asked for next, and keeps the state the table reached.

generic
   type State is (<>);
   type Guard_Kind is (<>);
   type Action_Kind is (<>);
   with
     function Evaluate
       (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean;
   with
     procedure Execute
       (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind);
   Always : Guard_Kind;
   Nothing : Action_Kind;
package Nuntius_Steps.Flows is

   package Machines is new
     Sml.Simple_Machines
       (State       => State,
        Event       => Step_Kind,
        Context     => Step_Context,
        Guard_Kind  => Guard_Kind,
        Action_Kind => Action_Kind,
        Evaluate    => Evaluate,
        Execute     => Execute);

   package Op is new Machines.Engine.Operators (Always, Nothing);

   --  Evt through Table from Current, and Current moved to where it went;
   --  Handled False when no row of this feature takes Evt there.
   procedure Take
     (Table   : Machines.Transition_Table;
      Current : in out State;
      Ctx     : in out Step_Context;
      Evt     : Step_Kind;
      Handled : out Boolean);

end Nuntius_Steps.Flows;
