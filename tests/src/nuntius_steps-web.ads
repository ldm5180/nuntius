--  The serving loop's steps (web-server.feature): stand a loop up,
--  compose or send a request, read back what it answered.

package Nuntius_Steps.Web is

   procedure Execute
     (S   : Web_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

   --  This feature as a region of the registry: Offer takes the step if it
   --  is this feature's, Reset starts a scenario, Phase names its state.
   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);
   procedure Reset;
   function Phase return String;

end Nuntius_Steps.Web;
