--  The round trips through Nuntius.Deflate (codings.feature): gzip or
--  pack a text, and read what came out back.  A region of the registry:
--  Offer takes this feature's steps, Reset starts a scenario, Phase names
--  its state.

package Nuntius_Steps.Codings is

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);

   procedure Reset;

   function Phase return String;

end Nuntius_Steps.Codings;
