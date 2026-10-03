with Nuntius_Steps.Codings;
with Nuntius_Steps.Http;
with Nuntius_Steps.Web;
with Nuntius_Steps.Ws_Client;
with Nuntius_Steps.Ws_Peer;
with Nuntius_World.Http;
with Nuntius_World.Web;
with Nuntius_World.Ws_Client;
with Nuntius_World.Ws_Script;

package body Nuntius_Steps is

   procedure Execute
     (S    : Step_Kind;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome) is
   begin
      case S is
         when Web_Step    =>
            Nuntius_Steps.Web.Execute (S, Ctx, A, R);

         when Http_Step   =>
            Nuntius_Steps.Http.Execute (S, Ctx, A, R);

         when Ws_Step     =>
            Nuntius_Steps.Ws_Client.Execute (S, Ctx, A, R);

         when Peer_Step   =>
            Nuntius_Steps.Ws_Peer.Execute (S, Ctx, A, Info, R);

         when Coding_Step =>
            Nuntius_Steps.Codings.Execute (S, Ctx, A, R);
      end case;
   end Execute;

   procedure Run_Hook
     (H    : Hook_Kind;
      Ctx  : in out World;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Info, R);
   begin
      case H is
         when Fresh_World =>
            Ctx := (others => <>);
            Nuntius_World.Web.Cells.Reset;
            Nuntius_World.Http.Renew_Client;
            Nuntius_World.Ws_Client.Choose_Default;
            Nuntius_World.Ws_Script.Result.Set_Pong (False);

         when Stop_World  =>
            Nuntius_World.Web.Stop_Loops;
            Nuntius_World.Web.Drop_Held;
            Nuntius_World.Ws_Client.Drop;
            Nuntius_World.Ws_Script.Stop_Scripted;
            Nuntius_World.Browser.Close_Pair;
      end case;
   end Run_Hook;

end Nuntius_Steps;
