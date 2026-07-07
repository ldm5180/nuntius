with AUnit.Test_Cases;

with Nuntius_Frame_Fifo_Tests;
with Nuntius_Http_Curl_Tests;
with Nuntius_Ws_Aws_Client_Tests;

package body Nuntius_Suite is

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite :=
        AUnit.Test_Suites.New_Suite;

      procedure Add (T : AUnit.Test_Cases.Test_Case_Access) is
      begin
         AUnit.Test_Suites.Add_Test (Result, T);
      end Add;
   begin
      Add (new Nuntius_Frame_Fifo_Tests.Test);
      Add (new Nuntius_Ws_Aws_Client_Tests.Test);
      Add (new Nuntius_Http_Curl_Tests.Test);
      return Result;
   end Suite;

end Nuntius_Suite;
