with Ada.Strings.Fixed;
with Ada.Text_IO;

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

end Nuntius_World;
