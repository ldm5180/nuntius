with Nuntius_Config;

package body Nuntius.Http is

   Identity : Unbounded_String :=
     To_Unbounded_String ("nuntius/" & Nuntius_Config.Crate_Version);

   function User_Agent return String
   is (To_String (Identity));

   procedure Set_User_Agent (Value : String) is
   begin
      Identity := To_Unbounded_String (Value);
   end Set_User_Agent;

end Nuntius.Http;
