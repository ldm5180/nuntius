with Ada.Strings.Fixed;
with Ada.Text_IO;

with Test_Payloads;

package body Nuntius_World is

   function Has (Haystack, Needle : String) return Boolean
   is (Ada.Strings.Fixed.Index (Haystack, Needle) > 0);

   function Head_Line (Reply : String) return String is
      Ends : constant Natural := Ada.Strings.Fixed.Index (Reply, CRLF);
   begin
      if Reply'Length = 0 then
         return "(nothing)";
      end if;
      return (if Ends = 0 then Reply else Reply (Reply'First .. Ends - 1));
   end Head_Line;

   --  The value of one hex digit, or -1.
   function Hex_Value (C : Character) return Integer
   is (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others     => -1);

   Hex_Base : constant := 16;

   --  One line's hex pairs appended to Result (1 .. Last); Ok False on
   --  a stray character or an odd digit.
   procedure Add_Line
     (Line   : String;
      Result : in out Nuntius.Rfc6455.Octets;
      Last   : in out Natural;
      Ok     : in out Boolean)
   is
      Code : constant String :=
        Line
          (Line'First
           .. (if Ada.Strings.Fixed.Index (Line, "#") = 0
               then Line'Last
               else Ada.Strings.Fixed.Index (Line, "#") - 1));
      I    : Natural := Code'First;
   begin
      while Ok and then I <= Code'Last loop
         if Code (I) = ' ' or else Code (I) = ASCII.HT then
            I := I + 1;
         elsif I < Code'Last
           and then Hex_Value (Code (I)) >= 0
           and then Hex_Value (Code (I + 1)) >= 0
           and then Last < Result'Last
         then
            Last := Last + 1;
            Result (Last) :=
              Nuntius.Rfc6455.Octet
                (Hex_Value (Code (I)) * Hex_Base + Hex_Value (Code (I + 1)));
            I := I + 2;
         else
            Ok := False;
         end if;
      end loop;
   end Add_Line;

   procedure Named_Bytes
     (Dir    : String;
      Name   : String;
      Result : out Nuntius.Rfc6455.Octets;
      Last   : out Natural;
      Ok     : out Boolean)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Result := [others => 0];
      Last := 0;
      Ok := True;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Dir & "/" & Name & ".hex");
      while Ok and then not Ada.Text_IO.End_Of_File (File) loop
         Add_Line (Ada.Text_IO.Get_Line (File), Result, Last, Ok);
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when Ada.Text_IO.Name_Error | Ada.Text_IO.Use_Error =>
         Ok := False;
   end Named_Bytes;

   function Chars_Of (B : Nuntius.Rfc6455.Octets) return String is
      S : String (1 .. B'Length);
   begin
      for K in B'Range loop
         S (K - B'First + 1) := Character'Val (B (K));
      end loop;
      return S;
   end Chars_Of;

   function Octets_Of (S : String) return Nuntius.Rfc6455.Octets is
      B : Nuntius.Rfc6455.Octets (1 .. S'Length);
   begin
      for K in S'Range loop
         B (K - S'First + 1) := Character'Pos (S (K));
      end loop;
      return B;
   end Octets_Of;

   --  One row of Test_Payloads.Json_Like, measured rather than assumed.
   Json_Row_Bytes : constant Positive := Test_Payloads.Json_Like (1)'Length;

   function Json_Of (N : Natural) return String
   is (Test_Payloads.Json_Like (N / Json_Row_Bytes + 1) (1 .. N));

end Nuntius_World;
