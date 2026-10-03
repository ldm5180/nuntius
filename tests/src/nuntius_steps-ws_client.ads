--  The websocket client's steps (websocket-client.feature): choose a
--  client shape, script a peer, dial and receive, and read the
--  receptions and loss tallies back.

package Nuntius_Steps.Ws_Client is

   procedure Execute
     (S   : Ws_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

end Nuntius_Steps.Ws_Client;
