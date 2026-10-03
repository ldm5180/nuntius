with Ada.Strings.Fixed;

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

end Nuntius_World;
