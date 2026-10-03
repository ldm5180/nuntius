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

end Nuntius_Steps.Ws_Peer;
