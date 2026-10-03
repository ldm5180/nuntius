--  The websocket client's steps (websocket-client.feature): choose a
--  client shape, script a peer, dial and receive, and read the
--  receptions and loss tallies back.

package Nuntius_Steps.Ws_Client is

   procedure Execute
     (S   : Ws_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

   --  This feature as a region of the registry: Offer takes the step if it
   --  is this feature's, Reset starts a scenario, Phase names its state.
   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean);
   procedure Reset;
   function Phase return String;

end Nuntius_Steps.Ws_Client;
