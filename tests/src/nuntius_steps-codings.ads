--  The round trips through Nuntius.Deflate (codings.feature): gzip and
--  pack a text, and read what came out back.

package Nuntius_Steps.Codings is

   procedure Execute
     (S   : Coding_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome);

end Nuntius_Steps.Codings;
