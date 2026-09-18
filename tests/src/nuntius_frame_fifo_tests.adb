with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Frame_Fifo;

--  Only arrival order and the loss TALLY live here: the refusal
--  semantics (full, oversized, empty, consumed-when-undeliverable) and
--  every Count move are fully specified by the proved Posts in
--  nuntius-frame_fifo.ads -- gnatprove checks them for all inputs, so
--  re-testing those by example would be redundant.  The tally is here
--  because what it is FOR is a worked example: a consumer asking "did
--  you throw anything away, and how long was it".

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

   --  A REFUSAL THAT NOBODY COUNTS IS A LOSS THAT NOBODY SEES.
   --
   --  Push's Ok is the only signal a refusal gives, and an adapter that
   --  drops it on the floor -- which is exactly what the AWS adapter's
   --  ring-full branch did, with a comment saying so -- turns a burst
   --  the consumer fell behind on into missing data with no trace.  The
   --  two reasons must also stay apart: a full ring is a consumer that
   --  is behind, an oversized frame is a BOUND that is wrong, and the
   --  second cannot be diagnosed without the length it was wrong by.
   procedure Test_Losses_Are_Counted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Q  : Fifo;
      Ok : Boolean;
   begin
      Assert
        (Refused_Full (Q) = 0
         and then Refused_Long (Q) = 0
         and then Longest_Refused (Q) = 0,
         "a fresh fifo has lost nothing");

      --  Too long for a slot, on an EMPTY fifo, so length is the only
      --  reason it can be refused.
      Push (Q, "123456789", Ok);
      Assert (not Ok, "a frame past Max_Frame_Bytes is refused");
      Assert
        (Refused_Long (Q) = 1 and then Refused_Full (Q) = 0,
         "counted as a LENGTH refusal, not a capacity one");
      Assert
        (Longest_Refused (Q) = 9,
         "and its length is kept -- that is the number the bound has to"
         & " be raised past; got"
         & Longest_Refused (Q)'Image);

      Push (Q, "123456789012", Ok);
      Assert
        (Longest_Refused (Q) = 12,
         "the LONGEST is what is kept, not the latest; got"
         & Longest_Refused (Q)'Image);

      --  Now fill it and refuse for capacity instead.
      Push (Q, "one", Ok);
      Push (Q, "two", Ok);
      Push (Q, "six", Ok);
      Assert (Ok and then Count (Q) = 3, "filled to capacity");

      Push (Q, "no", Ok);
      Assert (not Ok, "a full fifo refuses");
      Assert
        (Refused_Full (Q) = 1 and then Refused_Long (Q) = 2,
         "counted as a CAPACITY refusal, leaving the length tally alone");

      --  A new connection starts from nothing: Clear is the one place
      --  the indices reset, so it is the one place the tally must.
      Clear (Q);
      Assert
        (Refused_Full (Q) = 0
         and then Refused_Long (Q) = 0
         and then Longest_Refused (Q) = 0,
         "Clear resets the tally with the ring -- the counts describe"
         & " ONE connection");
   end Test_Losses_Are_Counted;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Fifo_Order'Access, "frames pop in arrival order, wrapping");
      Register_Routine
        (T,
         Test_Losses_Are_Counted'Access,
         "refusals are tallied by reason, with the longest refused");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Frame_Fifo (bounded frame buffering)");
   end Name;

end Nuntius_Frame_Fifo_Tests;
