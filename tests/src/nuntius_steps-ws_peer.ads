--  The served websocket's steps (websocket-peer.feature): open a pair,
--  have the browser or the peer send, pump the peer, and read back what
--  each end got.  Named byte sequences live beside the feature file that
--  names them.  A region of the registry: Offer takes this feature's
--  steps, Reset starts a scenario, Phase names its state.

package Nuntius_Steps.Ws_Peer is

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);

   procedure Reset;

   function Phase return String;

end Nuntius_Steps.Ws_Peer;
