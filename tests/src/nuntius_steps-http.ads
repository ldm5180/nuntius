--  The HTTP clients' steps (http-client.feature): send by verb, to a
--  refused port or a recording peer, and read back what was answered.

package Nuntius_Steps.Http is

   procedure Execute
     (S   : Http_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

end Nuntius_Steps.Http;
