--  A bounded FIFO of text frames -- the buffering half of a websocket
--  adapter, in the SPARK core so its ring arithmetic and refusal
--  semantics are *proved* rather than unit-tested: the Posts below
--  fully specify when Push/Pop succeed and how Count moves, so the
--  only behavior left to tests is arrival order.  No heap: frames are
--  copied into fixed slots; refusals never disturb the frames already
--  queued.

generic
   Depth : Positive;
   Max_Frame_Bytes : Positive;
package Nuntius.Frame_Fifo with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);
   --  The Push/Pop postconditions capture only the old Count and
   --  Next_Length (small Naturals) via 'Old -- never Self'Old, which
   --  would snapshot the whole ring.  At production bounds the ring
   --  runs to megabytes, and assertions may stay on in release, so a
   --  Self'Old copy would memcpy megabytes on every frame of a
   --  streaming hot path (and could overflow the consumer task's
   --  stack).  Allow lets the scalar 'Old sit in the guarded
   --  (potentially unevaluated) arms of the contracts; Next_Length is
   --  total so its entry evaluation is always defined.

   --  Nonlimited: adapters embed the fifo in nonlimited socket objects.
   type Fifo is private;

   function Count (Self : Fifo) return Natural
   with Post => Count'Result <= Depth;

   --  Length of the oldest queued frame -- the one Pop will deliver -- or
   --  0 when the fifo is empty.  Total (no Pre) so a postcondition can
   --  capture Next_Length (Self)'Old without copying the whole ring.
   function Next_Length (Self : Fifo) return Natural
   with Post => Next_Length'Result <= Max_Frame_Bytes;

   --  Fresh state for a new connection -- the one place the indices are
   --  (re)initialized, so redials cannot miss one.
   procedure Clear (Self : in out Fifo)
   with Post => Count (Self) = 0;

   --  Refused (Ok False, fifo untouched) exactly when full or when
   --  Frame is longer than Max_Frame_Bytes.
   procedure Push (Self : in out Fifo; Frame : String; Ok : out Boolean)
   with
     Post =>
       Ok = (Count (Self)'Old < Depth and then Frame'Length <= Max_Frame_Bytes)
       and then Count (Self)
                = (if Ok then Count (Self)'Old + 1 else Count (Self)'Old);

   --  The oldest frame, delivered in Into (1 .. Last).  A non-empty
   --  fifo is always consumed by one -- even when the frame does not
   --  fit Into (Ok False): the caller treats that as reconnect-worthy,
   --  and an undeliverable frame must not wedge the queue.  Into'First
   --  = 1 keeps the index arithmetic trivially in range.
   procedure Pop
     (Self : in out Fifo;
      Into : in out String;
      Last : out Natural;
      Ok   : out Boolean)
   with
     Pre  => Into'First = 1,
     Post =>
       (if Count (Self)'Old = 0
        then not Ok and then Last = 0 and then Count (Self) = 0
        else
          Count (Self) = Count (Self)'Old - 1
          and then Ok = (Next_Length (Self)'Old <= Into'Length)
          and then Last = (if Ok then Next_Length (Self)'Old else 0));

private

   subtype Frame_Length is Natural range 0 .. Max_Frame_Bytes;
   subtype Slot_Index is Positive range 1 .. Depth;
   subtype Slot_Count is Natural range 0 .. Depth;

   type Frame_Slot is record
      Text : String (1 .. Max_Frame_Bytes) := [others => ' '];
      Len  : Frame_Length := 0;
   end record;

   type Slot_Array is array (Slot_Index) of Frame_Slot;

   type Fifo is record
      Slots : Slot_Array;
      Head  : Slot_Index := 1;   --  next frame to hand out
      Tail  : Slot_Index := 1;   --  next free slot
      Used  : Slot_Count := 0;
   end record;

   function Count (Self : Fifo) return Natural
   is (Self.Used);

   function Next_Length (Self : Fifo) return Natural
   is (if Self.Used = 0 then 0 else Self.Slots (Self.Head).Len);

end Nuntius.Frame_Fifo;
