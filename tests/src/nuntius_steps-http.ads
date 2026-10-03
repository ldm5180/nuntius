--  The HTTP clients' steps (http-client.feature): send by verb, to a
--  refused port or a recording peer, and read back what was answered.

package Nuntius_Steps.Http is

   procedure Execute
     (S   : Http_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

   --  This feature as a region of the registry: Offer takes the step if it
   --  is this feature's, Reset starts a scenario, Phase names its state.
   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);
   procedure Reset;
   function Phase return String;

end Nuntius_Steps.Http;
