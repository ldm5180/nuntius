with Ada.Streams; use Ada.Streams;
with Ada.Unchecked_Deallocation;

with ZLib;

with Nuntius.Web;

package body Nuntius.Deflate is

   use type ZLib.Header_Type;

   type Scratch_Access is access Stream_Element_Array;

   procedure Free is new
     Ada.Unchecked_Deallocation (Stream_Element_Array, Scratch_Access);

   --  RFC 7692 7.2.1: what a sync flush ends with, and what the sender
   --  removes and the receiver puts back.
   Sync_Tail : constant Stream_Element_Array := [0, 0, 16#FF#, 16#FF#];

   --  An empty result, with bounds an empty aggregate cannot give it:
   --  the index type starts at its base type's first value.
   No_Bytes : constant Stream_Element_Array (1 .. 0) := [others => 0];

   --  One deflate of all of In_Data into Out_Data (1 .. Out_Last),
   --  with Header and Flush chosen by the caller.  Done is False when
   --  zlib did not take all of the input; the filter is closed either
   --  way.
   procedure Deflate_All
     (In_Data  : Stream_Element_Array;
      Out_Data : out Stream_Element_Array;
      Out_Last : out Stream_Element_Offset;
      Header   : ZLib.Header_Type;
      Done     : out Boolean)
   is
      Filter  : ZLib.Filter_Type;
      In_Last : Stream_Element_Offset;
      Flush   : constant ZLib.Flush_Mode :=
        (if Header = ZLib.GZip then ZLib.Finish else ZLib.Sync_Flush);
   begin
      ZLib.Deflate_Init (Filter, Header => Header);
      ZLib.Translate (Filter, In_Data, In_Last, Out_Data, Out_Last, Flush);
      Done :=
        In_Last = In_Data'Last
        and then (Header /= ZLib.GZip or else ZLib.Stream_End (Filter));
      ZLib.Close (Filter, Ignore_Error => True);
   exception
      when others =>
         if ZLib.Is_Open (Filter) then
            ZLib.Close (Filter, Ignore_Error => True);
         end if;
         Out_Last := Out_Data'First - 1;
         Done := False;
   end Deflate_All;

   --  The deflate of all of Payload with Header, flushed as Header
   --  wants; empty when it is over Max_Pack_Bytes or zlib fails.  The
   --  scratch is on the heap: a 2 MB body must not need a 2 MB stack.
   function Deflated
     (Payload : String; Header : ZLib.Header_Type) return Stream_Element_Array
   is
   begin
      if Payload'Length > Max_Pack_Bytes then
         return No_Bytes;
      end if;
      declare
         In_Data  : Stream_Element_Array (1 .. Payload'Length)
         with Import, Address => Payload'Address;
         Scratch  : Scratch_Access :=
           new Stream_Element_Array
                 (1 .. Stream_Element_Offset (Worst_Case (Payload'Length)));
         Out_Last : Stream_Element_Offset;
         Done     : Boolean;
      begin
         Deflate_All (In_Data, Scratch.all, Out_Last, Header, Done);
         if not Done then
            Out_Last := 0;
         end if;
         return
            Result : constant Stream_Element_Array := Scratch (1 .. Out_Last)
         do
            Free (Scratch);
         end return;
      end;
   end Deflated;

   function Gzip (Payload : String) return String is
      Member : constant Stream_Element_Array := Deflated (Payload, ZLib.GZip);
      Text   : constant String (1 .. Member'Length)
      with Import, Address => Member'Address;
   begin
      return Text;
   end Gzip;

   function Pack (Text : String) return Nuntius.Rfc6455.Octets is
   begin
      if not Nuntius.Web.Worth_Packing (Text'Length) then
         return [];
      end if;
      declare
         Raw : constant Stream_Element_Array := Deflated (Text, ZLib.None);
      begin
         if Raw'Length < Sync_Tail'Length
           or else Raw (Raw'Last - 3 .. Raw'Last) /= Sync_Tail
         then
            return [];
         end if;
         declare
            Packed :
              constant Nuntius.Rfc6455.Octets
                         (1 .. Raw'Length - Sync_Tail'Length)
            with Import, Address => Raw'Address;
         begin
            return Packed;
         end;
      end;
   end Pack;

   function Unpack
     (Packed : Nuntius.Rfc6455.Octets; Into : out String; Last : out Natural)
      return Unpack_Verdict
   is
      Filter   : ZLib.Filter_Type;
      In_Data  : Stream_Element_Array (1 .. Packed'Length + Sync_Tail'Length);
      Output   : Stream_Element_Array (1 .. Into'Length + 1);
      In_Last  : Stream_Element_Offset;
      Out_Last : Stream_Element_Offset;
   begin
      Last := 0;
      for K in Packed'Range loop
         In_Data (Stream_Element_Offset (K - Packed'First + 1)) :=
           Stream_Element (Packed (K));
      end loop;
      In_Data (In_Data'Last - 3 .. In_Data'Last) := Sync_Tail;
      ZLib.Inflate_Init (Filter, Header => ZLib.None);
      ZLib.Translate
        (Filter, In_Data, In_Last, Output, Out_Last, ZLib.Sync_Flush);
      ZLib.Close (Filter, Ignore_Error => True);
      if Out_Last > Into'Length then
         return Too_Big;
      elsif In_Last /= In_Data'Last then
         return Corrupt;
      end if;
      for K in 1 .. Natural (Out_Last) loop
         Into (K) := Character'Val (Output (Stream_Element_Offset (K)));
      end loop;
      Last := Natural (Out_Last);
      return Done;
   exception
      when others =>
         if ZLib.Is_Open (Filter) then
            ZLib.Close (Filter, Ignore_Error => True);
         end if;
         Last := 0;
         return Corrupt;
   end Unpack;

end Nuntius.Deflate;
