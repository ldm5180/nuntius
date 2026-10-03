--  The served websocket's steps (websocket-peer.feature): open a pair,
--  have the browser or the peer send, pump the peer, and read back what
--  each end got.  Info locates the feature file, beside which its named
--  byte sequences live.

package Nuntius_Steps.Ws_Peer is

   procedure Execute
     (S    : Peer_Step;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome);

   --  This feature as a region of the registry: Offer takes the step if it
   --  is this feature's, Reset starts a scenario, Phase names its state.
   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);
   procedure Reset;
   function Phase return String;

end Nuntius_Steps.Ws_Peer;
