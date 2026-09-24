with Ada.Streams; use Ada.Streams;

with AUnit.Assertions; use AUnit.Assertions;

with ZLib;

package body Test_Payloads is

   function Json_Like (Rows : Positive) return String is
      Row : constant String := "{""sym"":""SPXW"",""bid"":1.25,""ask"":1.35},";
      S   : String (1 .. Rows * Row'Length);
   begin
      for K in 0 .. Rows - 1 loop
         S (K * Row'Length + 1 .. (K + 1) * Row'Length) := Row;
      end loop;
      return S;
   end Json_Like;

   function Noise (Length : Natural) return String is
      S     : String (1 .. Length);
      State : Natural := 12_345;
   begin
      for C of S loop
         State := (State * 1_103 + 12_345) mod 65_536;
         C := Character'Val (State / 256);
      end loop;
      return S;
   end Noise;

   function Gunzip (Member : String; Max : Positive) return String is
      Filter  : ZLib.Filter_Type;
      In_Data : Stream_Element_Array (1 .. Member'Length);
      Output  : Stream_Element_Array (1 .. Stream_Element_Offset (Max));
      In_Last : Stream_Element_Offset;
      Last    : Stream_Element_Offset;
   begin
      for K in In_Data'Range loop
         In_Data (K) :=
           Character'Pos (Member (Member'First + Natural (K) - 1));
      end loop;
      ZLib.Inflate_Init (Filter, Header => ZLib.GZip);
      ZLib.Translate (Filter, In_Data, In_Last, Output, Last, ZLib.Finish);
      Assert (ZLib.Stream_End (Filter), "the gzip member is complete");
      ZLib.Close (Filter, Ignore_Error => True);
      return S : String (1 .. Natural (Last)) do
         for K in S'Range loop
            S (K) := Character'Val (Output (Stream_Element_Offset (K)));
         end loop;
      end return;
   end Gunzip;

end Test_Payloads;
