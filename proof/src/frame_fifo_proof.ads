with Nuntius.Frame_Fifo;

--  Concrete instances so gnatprove analyses the Frame_Fifo generic: once
--  at production-scale bounds and once at tiny bounds where wraparound
--  and the full/empty edges are immediate.  Consumers are expected to
--  instantiate the generic in their own proof harness too, at the exact
--  numbers their adapter uses, so a proof can never cover a stale depth.

package Frame_Fifo_Proof
  with SPARK_Mode
is

   package Large is new
     Nuntius.Frame_Fifo (Depth => 1_024, Max_Frame_Bytes => 2_048);

   package Small is new Nuntius.Frame_Fifo (Depth => 3, Max_Frame_Bytes => 8);

end Frame_Fifo_Proof;
