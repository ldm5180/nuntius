--  The serving loop's steps (web-server.feature, upgrade.feature, the
--  loop half of codings.feature): stand a loop up, compose or send a
--  request, read back what it answered.  A region of the registry: Offer
--  takes this feature's steps, Reset starts a scenario, Phase names its
--  state.

package Nuntius_Steps.Web is

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);

   procedure Reset;

   function Phase return String;

end Nuntius_Steps.Web;
