with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Fd_Poll;
with Nuntius.Fd_Wake;

package body Nuntius_Fd_Wake_Tests is

   use AUnit.Test_Cases.Registration;

   --  The eventfd wake token end to end.  The drain pin is the one that
   --  matters most: a readable-but-undrained wake fd would turn every
   --  poll into an instant return -- a busy spin.
   procedure Test_Lifecycle (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Fd : constant Integer := Nuntius.Fd_Wake.Create;
   begin
      Assert (Fd >= 0, "the wake fd was created");
      Assert (not Nuntius.Fd_Poll.Readable (Fd), "a fresh wake fd is quiet");

      Nuntius.Fd_Wake.Signal (Fd);
      Assert (Nuntius.Fd_Poll.Readable (Fd), "a signal makes it readable");
      Nuntius.Fd_Wake.Signal (Fd);  --  back-to-back signals coalesce

      Nuntius.Fd_Wake.Drain (Fd);
      Assert
        (not Nuntius.Fd_Poll.Readable (Fd),
         "one drain empties it completely (the busy-spin guard)");

      Nuntius.Fd_Wake.Close (Fd);
   end Test_Lifecycle;

   --  Every operation shrugs at -1 (an unarmed consumer's value), so
   --  callers never need their own guards.
   procedure Test_Negative_Fd_Is_A_No_Op
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Nuntius.Fd_Wake.Signal (-1);
      Nuntius.Fd_Wake.Drain (-1);
      Nuntius.Fd_Wake.Close (-1);
      Assert (True, "no crash on the unarmed value");
   end Test_Negative_Fd_Is_A_No_Op;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Lifecycle'Access,
         "create/signal/drain/close; drained means quiet");
      Register_Routine
        (T,
         Test_Negative_Fd_Is_A_No_Op'Access,
         "every operation is a no-op on -1");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Fd_Wake (the eventfd wake token)"));

end Nuntius_Fd_Wake_Tests;
