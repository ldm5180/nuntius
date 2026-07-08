with Nuntius;
with Nuntius.Frame_Fifo;
with Nuntius.Rfc6455;

--  Withs every core unit so the whole SPARK closure is in gnatprove's
--  tree even when a unit temporarily has no other proof-side client.
--  gnatprove analyses generics only through concrete instances -- those
--  live in the per-unit harnesses beside this file (the instances of
--  Nuntius.Frame_Fifo in Frame_Fifo_Proof).

package Core_Closure_Proof
  with SPARK_Mode
is

end Core_Closure_Proof;
