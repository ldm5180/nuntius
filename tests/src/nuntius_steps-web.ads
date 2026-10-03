--  The serving loop's steps (web-server.feature): stand a loop up,
--  compose or send a request, read back what it answered.

package Nuntius_Steps.Web is

   procedure Execute
     (S   : Web_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

end Nuntius_Steps.Web;
