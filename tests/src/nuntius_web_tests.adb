with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Web;

--  The pure serving primitives: the HTTP/1.1 request-LINE parser and
--  the byte-exact response head.  Routing is the consumer's policy and
--  is deliberately absent here.

package body Nuntius_Web_Tests is

   use AUnit.Test_Cases.Registration;
   use type Nuntius.Web.Method_Kind;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   procedure Test_Parse_Get_Root (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      R : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request
          ("GET / HTTP/1.1" & CRLF & "Host: x" & CRLF & CRLF);
   begin
      Assert (R.Well_Formed, "a plain GET parses");
      Assert (R.Method = Nuntius.Web.Get, "the method is Get");
      Assert (Nuntius.Web.Target_Of (R) = "/", "the target is /");
   end Test_Parse_Get_Root;

   --  POST is WELL-FORMED with Method = Other: the server answers 405
   --  (method not allowed), never 400 (bad request).
   procedure Test_Parse_Post_Is_Other
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      R : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request ("POST /api/stats HTTP/1.1" & CRLF & CRLF);
   begin
      Assert (R.Well_Formed, "POST still parses");
      Assert (R.Method = Nuntius.Web.Other, "the method is Other");
      Assert (Nuntius.Web.Target_Of (R) = "/api/stats", "the target survives");
   end Test_Parse_Post_Is_Other;

   procedure Test_Parse_Rejects_Garbage
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Long_Target : constant String (1 .. Nuntius.Web.Max_Target + 1) :=
        [1 => '/', others => 'a'];
   begin
      Assert
        (not Nuntius.Web.Parse_Request ("GET / HTTP/1.1").Well_Formed,
         "no CRLF is not a request line");
      Assert
        (not Nuntius.Web.Parse_Request ("GET /" & CRLF).Well_Formed,
         "a missing version is rejected");
      Assert
        (not Nuntius.Web.Parse_Request ("GET  HTTP/1.1" & CRLF).Well_Formed,
         "an empty target is rejected");
      Assert
        (not Nuntius.Web.Parse_Request
               ("GET " & Long_Target & " HTTP/1.1" & CRLF)
               .Well_Formed,
         "a target past Max_Target is rejected");
      Assert
        (not Nuntius.Web.Parse_Request ("GET" & CRLF).Well_Formed,
         "a lone method is rejected");
      Assert
        (not Nuntius.Web.Parse_Request ("" & CRLF).Well_Formed,
         "an empty line is rejected");
   end Test_Parse_Rejects_Garbage;

   procedure Test_Response_Head_Golden
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Head : constant String :=
        Nuntius.Web.Response_Head (Nuntius.Web.Ok_200, "application/json", 2);
   begin
      Assert
        (Head
         = "HTTP/1.1 200 OK"
           & CRLF
           & "Connection: close"
           & CRLF
           & "Cache-Control: no-store"
           & CRLF
           & "Content-Type: application/json"
           & CRLF
           & "Content-Length: 2"
           & CRLF
           & CRLF,
         "the exact 200 head, byte for byte");
      Assert
        (Nuntius.Web.Response_Head
           (Nuntius.Web.Not_Allowed_405, "text/plain", 8)
         = "HTTP/1.1 405 Method Not Allowed"
           & CRLF
           & "Connection: close"
           & CRLF
           & "Cache-Control: no-store"
           & CRLF
           & "Content-Type: text/plain"
           & CRLF
           & "Content-Length: 8"
           & CRLF
           & CRLF,
         "the exact 405 head, byte for byte");
   end Test_Response_Head_Golden;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Parse_Get_Root'Access, "Parse_Request accepts a plain GET");
      Register_Routine
        (T,
         Test_Parse_Post_Is_Other'Access,
         "Parse_Request types POST as Other (so the server can 405)");
      Register_Routine
        (T,
         Test_Parse_Rejects_Garbage'Access,
         "Parse_Request rejects malformed request lines");
      Register_Routine
        (T,
         Test_Response_Head_Golden'Access,
         "Response_Head emits the exact status head");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web (HTTP request line and response head)"));

end Nuntius_Web_Tests;
