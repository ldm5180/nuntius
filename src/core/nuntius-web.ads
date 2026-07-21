--  The serving side's pure primitives: the HTTP/1.1 request-LINE
--  parser and the response head -- bounded string functions with no IO,
--  so a consumer's socket loop (Nuntius.Web.Server) stays a thin
--  transport.  Headers are never interpreted: the server reads them
--  only to find the blank line ending the request.  ROUTING is absent
--  by design -- which targets exist is the consumer's policy, applied
--  in its Handle procedure.

package Nuntius.Web
  with SPARK_Mode
is

   --  One request's read budget: request line + headers.  Localhost
   --  cookies from other dev servers could inflate headers; the cap is
   --  the one constant to bump if 400s ever show up in practice.
   Max_Request_Bytes : constant := 4_096;
   Max_Target        : constant := 256;

   type Method_Kind is (Get, Other);

   type Request is record
      Well_Formed : Boolean := False;
      Method      : Method_Kind := Other;
      Target      : String (1 .. Max_Target) := [others => ' '];
      Target_Len  : Natural range 0 .. Max_Target := 0;
   end record;

   function Target_Of (R : Request) return String
   is (R.Target (1 .. R.Target_Len));

   --  Parse the request LINE (up to the first CRLF; anything after is
   --  ignored).  Well_Formed = "<METHOD> SP <target> SP HTTP/1.<x>"
   --  with an uppercase method, a target of 1 .. Max_Target bytes with
   --  no interior SP/CTL, and a one-digit minor version.  An unknown
   --  method is WELL-FORMED with Method = Other -- the server answers
   --  405, not 400.
   function Parse_Request (Text : String) return Request
   with Pre => Text'First = 1 and then Text'Length <= Max_Request_Bytes;

   type Status is (Ok_200, Bad_Request_400, Not_Found_404, Not_Allowed_405);

   function Status_Line (S : Status) return String
   is (case S is
         when Ok_200          => "200 OK",
         when Bad_Request_400 => "400 Bad Request",
         when Not_Found_404   => "404 Not Found",
         when Not_Allowed_405 => "405 Method Not Allowed");

   --  "HTTP/1.1 <code> <reason>" CRLF "Connection: close" CRLF
   --  "Cache-Control: no-store" CRLF "Content-Type: <..>" CRLF
   --  "Content-Length: <n>" CRLF CRLF -- the body follows verbatim.
   function Response_Head
     (S : Status; Content_Type : String; Content_Length : Natural)
      return String
   with Pre => Content_Type'Length in 1 .. 64;

end Nuntius.Web;
