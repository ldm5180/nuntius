with Ada.Strings.Fixed;

package body Nuntius_World is

   function Has (Haystack, Needle : String) return Boolean
   is (Ada.Strings.Fixed.Index (Haystack, Needle) > 0);

end Nuntius_World;
