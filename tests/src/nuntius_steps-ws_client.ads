--  The websocket client's steps (websocket-client.feature): choose a
--  client shape, script a peer, dial and receive, and read the
--  receptions and loss tallies back.  A region of the registry: Offer
--  takes this feature's steps, Reset starts a scenario, Phase names its
--  state.

package Nuntius_Steps.Ws_Client is

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);

   procedure Reset;

   function Phase return String;

end Nuntius_Steps.Ws_Client;
