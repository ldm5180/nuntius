with Fabula.Main;

with Nuntius_Steps;

--  The feature runner: Fabula.Main over the crate's step registry,
--  run over tests/features/ by `make features` and `alr test`.

procedure Nuntius_Features is new
  Fabula.Main
    (Steps     => Nuntius_Steps.Steps,
     Step_Defs => Nuntius_Steps.Step_Defs,
     Hook_Defs => Nuntius_Steps.Hook_Defs,
     Execute   => Nuntius_Steps.Execute,
     Run_Hook  => Nuntius_Steps.Run_Hook);
