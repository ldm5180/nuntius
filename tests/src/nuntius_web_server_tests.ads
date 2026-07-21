with AUnit.Test_Cases;

package Nuntius_Web_Server_Tests is

   type Test is new AUnit.Test_Cases.Test_Case with null record;

   overriding
   procedure Register_Tests (T : in out Test);

   overriding
   function Name (T : Test) return AUnit.Message_String;

end Nuntius_Web_Server_Tests;
