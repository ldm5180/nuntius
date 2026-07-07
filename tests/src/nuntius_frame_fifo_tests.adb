with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Frame_Fifo;

--  Only arrival order lives here: the refusal semantics (full,
--  oversized, empty, consumed-when-undeliverable) and every Count move
--  are fully specified by the proved Posts in nuntius-frame_fifo.ads --
--  gnatprove checks them for all inputs, so re-testing them by example
--  would be redundant.

package body Nuntius_Frame_Fifo_Tests is

   use AUnit.Test_Cases.Registration;

   --  Tiny bounds so wraparound is cheap to reach; a production
   --  instance only changes the numbers.
   package Fifos is new Nuntius.Frame_Fifo (Depth => 3, Max_Frame_Bytes => 8);
   use Fifos;

   --  Pop into a roomy buffer and hand back the text.
   function Popped (Q : in out Fifo) return String is
      Buf  : String (1 .. 16) := [others => ' '];
      Last : Natural;
      Ok   : Boolean;
   begin
      Pop (Q, Buf, Last, Ok);
      Assert (Ok, "pop from a non-empty fifo succeeds");
      return Buf (1 .. Last);
   end Popped;

   procedure Test_Fifo_Order (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Q  : Fifo;
      Ok : Boolean;
   begin
      Assert (Count (Q) = 0, "starts empty");

      Push (Q, "one", Ok);
      Assert (Ok, "first push lands");
      Push (Q, "two", Ok);
      Assert (Ok and then Count (Q) = 2, "second push lands");

      Assert (Popped (Q) = "one", "frames come out in arrival order");

      --  Wrap the ring: order survives the index reset.
      Push (Q, "three", Ok);
      Push (Q, "four", Ok);
      Assert (Ok and then Count (Q) = 3, "refilled to capacity");
      Assert (Popped (Q) = "two", "wraparound preserves order (1)");
      Assert (Popped (Q) = "three", "wraparound preserves order (2)");
      Assert (Popped (Q) = "four", "wraparound preserves order (3)");
      Assert (Count (Q) = 0, "drained");
   end Test_Fifo_Order;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Fifo_Order'Access, "frames pop in arrival order, wrapping");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Frame_Fifo (bounded frame buffering)");
   end Name;

end Nuntius_Frame_Fifo_Tests;
