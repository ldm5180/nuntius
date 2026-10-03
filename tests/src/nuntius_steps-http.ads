--  The HTTP clients' steps (http-client.feature): send by verb, to a
--  refused port or a recording peer, and read back what was answered.
--  A region of the registry: Offer takes this feature's steps, Reset
--  starts a scenario, Phase names its state.

package Nuntius_Steps.Http is

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);

   procedure Reset;

   function Phase return String;

end Nuntius_Steps.Http;
