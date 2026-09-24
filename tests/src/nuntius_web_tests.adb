with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Codings;
with Nuntius.Web;

--  The pure serving primitives: the HTTP/1.1 request-LINE parser, the
--  header lines it interprets (length, type, bearer, forwarded-for),
--  and the byte-exact response head.  Routing is the consumer's policy
--  and is deliberately absent here.

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

   --  POST is its own method now: the server reads a body for it and
   --  hands it to Handle.  PUT is what stays Other, and what the loop
   --  answers 405.
   procedure Test_Parse_Post_Is_Post
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      R : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request ("POST /api/stats HTTP/1.1" & CRLF & CRLF);
   begin
      Assert (R.Well_Formed, "POST still parses");
      Assert (R.Method = Nuntius.Web.Post, "the method is Post");
      Assert (Nuntius.Web.Target_Of (R) = "/api/stats", "the target survives");
   end Test_Parse_Post_Is_Post;

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

   --  A real OAuth redirect target is /auth?code=<~90 escaped chars>
   --  &session=<uuid>.  A target past Max_Target answers 400 BEFORE the
   --  consumer's Handle runs, so the code would be silently lost: the
   --  cap has to carry a generous margin over the shape seen in the
   --  wild.
   procedure Test_Parse_Long_Oauth_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Code   : constant String (1 .. 300) := [others => 'c'];
      Target : constant String := "/auth?code=" & Code & "&session=abc";
      R      : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request
          ("GET " & Target & " HTTP/1.1" & CRLF & CRLF);
   begin
      Assert (R.Well_Formed, "a 300-byte OAuth target parses");
      Assert (Nuntius.Web.Target_Of (R) = Target, "the target survives whole");
   end Test_Parse_Long_Oauth_Target;

   --  The header block, which the parser now walks as far as the first
   --  empty line: the body may itself hold CRLFs and even a
   --  Content-Length, and must never be read as a header.
   procedure Test_Parse_Post_Headers
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;
      Over_Long : constant String (1 .. Max_Bearer + 1) := [others => 'a'];
      R         : Request;
   begin
      R :=
        Parse_Request
          ("POST /api/close HTTP/1.1"
           & CRLF
           & "Host: 127.0.0.1:9321"
           & CRLF
           & "content-type: Application/JSON; charset=utf-8"
           & CRLF
           & "Content-Length: 15"
           & CRLF
           & CRLF
           & "{""scope"":""all""}");
      Assert (R.Well_Formed and then R.Method = Post, "POST parses as Post");
      Assert (R.Content_Length = 15, "the length is read");
      Assert (R.Json_Body, "application/json with parameters counts");
      Assert
        (Bearer_Of (R) = "" and then Forwarded_For_Of (R) = "",
         "no token, no forwarded text");

      R :=
        Parse_Request
          ("GET / HTTP/1.1" & CRLF & "Host: LocalHost" & CRLF & CRLF);
      Assert
        (R.Content_Length = 0 and then not R.Json_Body,
         "absent headers read as none");

      R :=
        Parse_Request
          ("GET /api/positions HTTP/1.1"
           & CRLF
           & "authorization: bearer   abc.DEF-123_~+/="
           & CRLF
           & CRLF);
      Assert
        (Bearer_Of (R) = "abc.DEF-123_~+/=",
         "the scheme is case-insensitive, extra SP skipped, the token "
         & "verbatim");

      R :=
        Parse_Request
          ("GET / HTTP/1.1" & CRLF & "Authorization: Basic abc" & CRLF & CRLF);
      Assert (Bearer_Of (R) = "", "another scheme is no bearer");

      R :=
        Parse_Request
          ("GET / HTTP/1.1" & CRLF & "Authorization: Bearer" & CRLF & CRLF);
      Assert (Bearer_Of (R) = "", "a bare scheme is no bearer");

      R :=
        Parse_Request
          ("GET / HTTP/1.1"
           & CRLF
           & "Authorization: Bearer "
           & Over_Long
           & CRLF
           & CRLF);
      Assert
        (Bearer_Of (R) = "",
         "past Max_Bearer the token is absent, not truncated");

      R :=
        Parse_Request
          ("GET / HTTP/1.1"
           & CRLF
           & "X-Forwarded-For: 203.0.113.7, 100.64.0.1"
           & CRLF
           & CRLF);
      Assert
        (Forwarded_For_Of (R) = "203.0.113.7, 100.64.0.1",
         "the forwarded chain is kept verbatim");

      R :=
        Parse_Request
          ("GET / HTTP/1.1"
           & CRLF
           & "X-Forwarded-For: a"
           & ASCII.ESC
           & "b"
           & CRLF
           & CRLF);
      Assert (Forwarded_For_Of (R) = "", "a control character empties it");

      R :=
        Parse_Request
          ("POST / HTTP/1.1" & CRLF & "Content-Length: 4097" & CRLF & CRLF);
      Assert
        (not R.Well_Formed and then R.Length_Refused,
         "4097 is refused as too large");

      R :=
        Parse_Request
          ("POST / HTTP/1.1" & CRLF & "Content-Length: 99999" & CRLF & CRLF);
      Assert
        (not R.Well_Formed and then R.Length_Refused,
         "a five-digit run is too large on sight");

      R :=
        Parse_Request
          ("POST / HTTP/1.1" & CRLF & "Content-Length: 12a" & CRLF & CRLF);
      Assert
        (not R.Well_Formed and then not R.Length_Refused,
         "12a is a bad request");

      R := Parse_Request ("PUT / HTTP/1.1" & CRLF & CRLF);
      Assert (R.Well_Formed and then R.Method = Other, "PUT is still Other");

      R :=
        Parse_Request
          ("POST / HTTP/1.1"
           & CRLF
           & "Content-Length: 5"
           & CRLF
           & CRLF
           & "a"
           & CRLF
           & "Content-Length: 9999"
           & CRLF);
      Assert
        (R.Content_Length = 5,
         "the walk stops at the empty line; the body is not a header");
   end Test_Parse_Post_Headers;

   --  A browser's usual head plus what a Tailscale proxy adds: about
   --  1.2 KB, well inside the 4 KB budget, and the bearer still lands.
   procedure Test_Parse_Proxied_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;
      Token : constant String (1 .. 64) := [others => 'f'];
      Head  : constant String :=
        "GET /api/positions HTTP/1.1"
        & CRLF
        & "Host: box.tail1234.ts.net"
        & CRLF
        & "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)"
        & " AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5"
        & " Mobile/15E148 Safari/604.1"
        & CRLF
        & "Accept: application/json, text/plain, */*"
        & CRLF
        & "Accept-Language: en-US,en;q=0.9"
        & CRLF
        & "Accept-Encoding: gzip, deflate, br"
        & CRLF
        & "Referer: https://box.tail1234.ts.net/"
        & CRLF
        & "Sec-Fetch-Dest: empty"
        & CRLF
        & "Sec-Fetch-Mode: cors"
        & CRLF
        & "Sec-Fetch-Site: same-origin"
        & CRLF
        & "Sec-Fetch-User: ?1"
        & CRLF
        & "Sec-CH-UA: ""Chromium"";v=""128"", ""Not;A=Brand"";v=""24"""
        & CRLF
        & "Sec-CH-UA-Mobile: ?1"
        & CRLF
        & "Sec-CH-UA-Platform: ""iOS"""
        & CRLF
        & "Authorization: Bearer "
        & Token
        & CRLF
        & "Connection: keep-alive"
        & CRLF
        & "X-Forwarded-For: 203.0.113.7"
        & CRLF
        & "X-Forwarded-Proto: https"
        & CRLF
        & "X-Forwarded-Host: box.tail1234.ts.net"
        & CRLF
        & "Tailscale-Funnel-Request: ?1"
        & CRLF
        & CRLF;
      R     : constant Request := Parse_Request (Head);
   begin
      Assert
        (Head'Length <= Max_Request_Bytes,
         "a proxied browser head fits the read budget with room to spare:"
         & Natural'Image (Max_Request_Bytes - Head'Length)
         & " bytes free");
      Assert (R.Well_Formed and then R.Method = Get, "it parses as a GET");
      Assert (Bearer_Of (R) = Token, "the bearer survives the crowd");
      Assert
        (Forwarded_For_Of (R) = "203.0.113.7",
         "the proxy's forwarded address survives");
   end Test_Parse_Proxied_Head;

   procedure Test_New_Status_Lines
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;
   begin
      Assert (Status_Line (Accepted_202) = "202 Accepted", "202");
      Assert (Status_Line (Unauthorized_401) = "401 Unauthorized", "401");
      Assert (Status_Line (Forbidden_403) = "403 Forbidden", "403");
      Assert (Status_Line (Conflict_409) = "409 Conflict", "409");
      Assert (Status_Line (Too_Large_413) = "413 Content Too Large", "413");
      Assert
        (Status_Line (Unsupported_Media_415) = "415 Unsupported Media Type",
         "415");
   end Test_New_Status_Lines;

   --  The compare the bearer guard rests on: every byte visited,
   --  whatever the first difference.
   procedure Test_Same_Text (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      use Nuntius.Web;
      A : constant String := "0123456789abcdef";
      B : constant String := "0123456789abcdeF";
      C : constant String := "F123456789abcdef";
   begin
      Assert (Same_Text (A, A), "a string equals itself");
      Assert (not Same_Text (A, B), "a last-byte difference is a difference");
      Assert (not Same_Text (A, C), "a first-byte difference too");
      Assert (Same_Text ("", ""), "two empty strings are equal");
   end Test_Same_Text;

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
           & "Content-Security-Policy: frame-ancestors 'none'"
           & CRLF
           & "X-Content-Type-Options: nosniff"
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
           & "Content-Security-Policy: frame-ancestors 'none'"
           & CRLF
           & "X-Content-Type-Options: nosniff"
           & CRLF
           & "Content-Type: text/plain"
           & CRLF
           & "Content-Length: 8"
           & CRLF
           & CRLF,
         "the exact 405 head, byte for byte");
   end Test_Response_Head_Golden;

   --  RFC 9110 15.5.2 makes the challenge a MUST on a 401, and it is
   --  the ONLY status that carries one.
   procedure Test_Response_Head_401
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nuntius.Web.Response_Head
           (Nuntius.Web.Unauthorized_401, "text/plain", 12)
         = "HTTP/1.1 401 Unauthorized"
           & CRLF
           & "WWW-Authenticate: Bearer realm=""dashboard"""
           & CRLF
           & "Connection: close"
           & CRLF
           & "Cache-Control: no-store"
           & CRLF
           & "Content-Security-Policy: frame-ancestors 'none'"
           & CRLF
           & "X-Content-Type-Options: nosniff"
           & CRLF
           & "Content-Type: text/plain"
           & CRLF
           & "Content-Length: 12"
           & CRLF
           & CRLF,
         "the exact 401 head, challenge and all");
   end Test_Response_Head_401;

   --  The browser's upgrade (RFC 6455 4.1), as it arrives through the
   --  proxy: four headers have to agree before the request is one.
   Key_24 : constant String := "dGhlIHNhbXBsZSBub25jZQ==";

   --  A head from its parts, so one header at a time can go missing.
   function Head (Conn, Upg, Ver, Key : String) return String
   is ("GET /api/stream HTTP/1.1"
       & CRLF
       & "Host: x"
       & (if Conn = "" then "" else CRLF & "Connection: " & Conn)
       & (if Upg = "" then "" else CRLF & "Upgrade: " & Upg)
       & (if Ver = "" then "" else CRLF & "Sec-WebSocket-Version: " & Ver)
       & (if Key = "" then "" else CRLF & "Sec-WebSocket-Key: " & Key)
       & CRLF
       & CRLF);

   procedure Test_Upgrade_Request_Parsed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      R : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request
          ("GET /api/stream HTTP/1.1"
           & CRLF
           & "Host: fructus.tail1234.ts.net"
           & CRLF
           & "Connection: Upgrade"
           & CRLF
           & "Upgrade: websocket"
           & CRLF
           & "Sec-WebSocket-Version: 13"
           & CRLF
           & "Sec-WebSocket-Key: "
           & Key_24
           & CRLF
           & "Origin: https://fructus.tail1234.ts.net"
           & CRLF
           & CRLF);
   begin
      Assert (R.Well_Formed, "the upgrade request is well formed");
      Assert (R.Method = Nuntius.Web.Get, "the method is Get");
      Assert (R.Upgrade, "the four headers agree");
      Assert (Nuntius.Web.Ws_Key_Of (R) = Key_24, "the key survives verbatim");
   end Test_Upgrade_Request_Parsed;

   procedure Test_Upgrade_Needs_All_Four
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;

      Posted : constant Request :=
        Parse_Request
          ("POST /api/stream HTTP/1.1"
           & CRLF
           & "Connection: Upgrade"
           & CRLF
           & "Upgrade: websocket"
           & CRLF
           & "Sec-WebSocket-Version: 13"
           & CRLF
           & "Sec-WebSocket-Key: "
           & Key_24
           & CRLF
           & CRLF);
   begin
      Assert
        (Parse_Request (Head ("Upgrade", "websocket", "13", Key_24)).Upgrade,
         "all four agreeing is an upgrade");
      Assert
        (not Parse_Request (Head ("", "websocket", "13", Key_24)).Upgrade,
         "no Connection header");
      Assert
        (not Parse_Request (Head ("Upgrade", "", "13", Key_24)).Upgrade,
         "no Upgrade header");
      Assert
        (not Parse_Request (Head ("Upgrade", "websocket", "", Key_24)).Upgrade,
         "no version header");
      Assert
        (not Parse_Request (Head ("Upgrade", "websocket", "13", "")).Upgrade,
         "no key header");
      Assert
        (Parse_Request
           (Head ("keep-alive, Upgrade", "websocket", "13", Key_24))
           .Upgrade,
         "Connection is a token list");
      Assert
        (Parse_Request (Head ("upgrade", "WebSocket", "13", Key_24)).Upgrade,
         "both values are case-insensitive");
      Assert
        (not Parse_Request (Head ("Upgrade", "websocket", "12", Key_24))
               .Upgrade,
         "only version 13");
      Assert
        (not Parse_Request
               (Head ("Upgrade", "websocket", "13", "dGhlIHNhbXBsZSBub25jZQ="))
               .Upgrade,
         "a 23-byte key is not a key");
      Assert (not Posted.Upgrade, "a POST is never an upgrade");
      Assert
        (Parse_Request (Head ("", "", "", "")).Well_Formed,
         "a request with none of them is still a request");
   end Test_Upgrade_Needs_All_Four;

   procedure Test_Upgrade_Head_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Nuntius.Web.Upgrade_Head ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
   begin
      Assert
        (Text
         = "HTTP/1.1 101 Switching Protocols"
           & CRLF
           & "Upgrade: websocket"
           & CRLF
           & "Connection: Upgrade"
           & CRLF
           & "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
           & CRLF
           & CRLF,
         "the exact 101 head, byte for byte");
      Assert (Text'Length = 129, "129 bytes on the wire");
   end Test_Upgrade_Head_Bytes;

   procedure Test_Never_Upgrade (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      R : constant Nuntius.Web.Request :=
        Nuntius.Web.Parse_Request
          (Head ("Upgrade", "websocket", "13", Key_24));
   begin
      Assert (R.Upgrade, "the request is an upgrade");
      Assert
        (not Nuntius.Web.Never_Upgrade (R),
         "the default formal takes no upgrade at all");
   end Test_Never_Upgrade;

   --  RFC 9110 15.5.22 makes the offer a MUST on a 426, and it is the
   --  only status besides the 401 that carries a header of its own.
   procedure Test_426_Head_Carries_Upgrade
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;
      Text  : constant String :=
        Response_Head (Upgrade_Required_426, "text/plain", 14);
      Lead  : constant String :=
        "HTTP/1.1 426 Upgrade Required" & CRLF & Upgrade_Offer & CRLF;
      Plain : constant String := Response_Head (Ok_200, "text/plain", 2);
   begin
      Assert
        (Text'Length > Lead'Length
         and then Text (Text'First .. Text'First + Lead'Length - 1) = Lead,
         "the offer comes straight after the status line");
      Assert
        (Status_Line (Unavailable_503) = "503 Service Unavailable", "503");
      Assert
        (Plain'Length > Lead'Length
         and then Plain (Plain'First .. Plain'First + 20) /= "HTTP/1.1 426",
         "a 200 carries no offer");
      for K in Plain'First .. Plain'Last - Upgrade_Offer'Length + 1 loop
         Assert
           (Plain (K .. K + Upgrade_Offer'Length - 1) /= Upgrade_Offer,
            "no other status offers an upgrade");
      end loop;
   end Test_426_Head_Carries_Upgrade;

   --  A GET carrying one Accept-Encoding value, for the coding tests.
   function Accepting (Value : String) return Nuntius.Web.Request
   is (Nuntius.Web.Parse_Request
         ("GET /assets/index.js HTTP/1.1"
          & CRLF
          & "Host: x"
          & CRLF
          & "Accept-Encoding: "
          & Value
          & CRLF
          & CRLF));

   --  RFC 9110 12.5.3: a comma-separated list of codings, each with an
   --  optional weight.  gzip anywhere in it, or the wildcard, is enough.
   procedure Test_Accept_Encoding_Parsed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Accepting ("gzip, deflate, br").Accepts_Gzip,
         "a browser's list names gzip");
      Assert (not Accepting ("br").Accepts_Gzip, "brotli alone is not gzip");
      Assert
        (Accepting ("GZIP;q=0.5").Accepts_Gzip,
         "case-insensitive, and the weight is cut off");
      Assert (Accepting ("br, *").Accepts_Gzip, "the wildcard accepts gzip");
      Assert
        (not Accepting ("x-gzip-ish").Accepts_Gzip,
         "a coding that only contains gzip is not gzip");
      Assert
        (not Nuntius.Web.Parse_Request
               ("GET / HTTP/1.1" & CRLF & "Host: x" & CRLF & CRLF)
               .Accepts_Gzip,
         "no header, identity");
      Assert
        (Accepting ("gzip").Well_Formed,
         "the header never decides well-formedness");
   end Test_Accept_Encoding_Parsed;

   --  An upgrade request carrying one Sec-WebSocket-Extensions value.
   function Offering (Value : String) return Nuntius.Web.Request
   is (Nuntius.Web.Parse_Request
         ("GET /api/stream HTTP/1.1"
          & CRLF
          & "Connection: Upgrade"
          & CRLF
          & "Upgrade: websocket"
          & CRLF
          & "Sec-WebSocket-Version: 13"
          & CRLF
          & "Sec-WebSocket-Key: "
          & Key_24
          & CRLF
          & "Sec-WebSocket-Extensions: "
          & Value
          & CRLF
          & CRLF));

   Offering_None : constant Nuntius.Web.Request :=
     Nuntius.Web.Parse_Request (Head ("Upgrade", "websocket", "13", Key_24));

   --  RFC 7692 7.1: a list of offers, each a name and parameters.  The
   --  offer taken is permessage-deflate with no parameter but the three
   --  a server may answer without honouring a window of its own.
   procedure Test_Deflate_Offer_Parsed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Offering ("permessage-deflate; client_max_window_bits")
           .Deflate_Offered,
         "Chrome's offer");
      Assert (Offering ("permessage-deflate").Deflate_Offered, "Firefox's");
      Assert
        (Offering ("permessage-deflate; client_max_window_bits=10")
           .Deflate_Offered,
         "a client window with a value");
      Assert
        (Offering
           ("permessage-deflate;server_no_context_takeover;"
            & " client_no_context_takeover")
           .Deflate_Offered,
         "both no-context parameters");
      Assert
        (not Offering ("permessage-deflate; server_max_window_bits=10")
               .Deflate_Offered,
         "a server window is not honoured");
      Assert
        (Offering
           ("permessage-deflate; server_max_window_bits=10,"
            & " permessage-deflate")
           .Deflate_Offered,
         "the second offer is taken when the first is not");
      Assert
        (not Offering ("permessage-deflate; client_max_window_bits=16")
               .Deflate_Offered,
         "a client window past 15");
      Assert
        (not Offering ("permessage-deflate; client_no_context_takeover=1")
               .Deflate_Offered,
         "a no-context parameter takes no value");
      Assert
        (not Offering ("x-webkit-deflate-frame").Deflate_Offered,
         "another extension");
      Assert (not Offering_None.Deflate_Offered, "no header, no offer");
      Assert
        (Offering ("permessage-deflate").Upgrade,
         "the offer does not change the upgrade verdict");
   end Test_Deflate_Offer_Parsed;

   --  D4: a coding pays on text, never on an image format that is
   --  already compressed, and never under the floor.
   procedure Test_Compressible_And_Floor
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Web;
   begin
      Assert (Compressible ("text/javascript; charset=utf-8"), "javascript");
      Assert (Compressible ("text/plain"), "plain text");
      Assert (Compressible ("application/json"), "json");
      Assert (Compressible ("Application/JSON; charset=utf-8"), "json, cased");
      Assert (Compressible ("image/svg+xml"), "svg is text");
      Assert (not Compressible ("image/png"), "png is compressed already");
      Assert (not Compressible ("font/woff2"), "so is woff2");
      Assert (not Worth_Packing (511), "under the floor");
      Assert (Worth_Packing (512), "the floor is 512 bytes");
   end Test_Compressible_And_Floor;

   --  A gzip body adds exactly two lines after the fixed ones, and
   --  nothing else moves (the identity golden above stays byte-exact).
   procedure Test_Response_Head_Gzip_Golden
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Nuntius.Web.Response_Head
           (Nuntius.Web.Ok_200, "application/json", 965, Nuntius.Codings.Gzip)
         = "HTTP/1.1 200 OK"
           & CRLF
           & "Connection: close"
           & CRLF
           & "Cache-Control: no-store"
           & CRLF
           & "Content-Security-Policy: frame-ancestors 'none'"
           & CRLF
           & "X-Content-Type-Options: nosniff"
           & CRLF
           & "Content-Encoding: gzip"
           & CRLF
           & "Vary: Accept-Encoding"
           & CRLF
           & "Content-Type: application/json"
           & CRLF
           & "Content-Length: 965"
           & CRLF
           & CRLF,
         "the exact gzip head, byte for byte");
      Assert
        (Nuntius.Web.Response_Head
           (Nuntius.Web.Ok_200, "text/plain", 2, Nuntius.Codings.Identity)
         = Nuntius.Web.Response_Head (Nuntius.Web.Ok_200, "text/plain", 2),
         "identity is the default, and today's head");
   end Test_Response_Head_Gzip_Golden;

   --  RFC 7692 7.1.1: the answer names both no-context parameters,
   --  whatever the offer said, so no deflate state outlives a message.
   procedure Test_Upgrade_Head_Deflated
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Nuntius.Web.Upgrade_Head
          ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", Nuntius.Codings.Deflated);
   begin
      Assert
        (Text
         = "HTTP/1.1 101 Switching Protocols"
           & CRLF
           & "Upgrade: websocket"
           & CRLF
           & "Connection: Upgrade"
           & CRLF
           & "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
           & CRLF
           & "Sec-WebSocket-Extensions: permessage-deflate;"
           & " server_no_context_takeover; client_no_context_takeover"
           & CRLF
           & CRLF,
         "the exact deflate 101, byte for byte");
      Assert (Text'Length = 231, "231 bytes on the wire");
      Assert
        (Nuntius.Web.Upgrade_Head
           ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", Nuntius.Codings.Plain)'Length
         = 129,
         "plain is the default's 129 bytes");
   end Test_Upgrade_Head_Deflated;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Parse_Get_Root'Access, "Parse_Request accepts a plain GET");
      Register_Routine
        (T,
         Test_Parse_Post_Is_Post'Access,
         "Parse_Request types POST as Post (PUT is what stays Other)");
      Register_Routine
        (T,
         Test_Parse_Rejects_Garbage'Access,
         "Parse_Request rejects malformed request lines");
      Register_Routine
        (T,
         Test_Parse_Long_Oauth_Target'Access,
         "Parse_Request carries a full OAuth redirect target");
      Register_Routine
        (T,
         Test_Parse_Post_Headers'Access,
         "Parse_Request reads length, type, bearer and forwarded-for");
      Register_Routine
        (T,
         Test_Parse_Proxied_Head'Access,
         "Parse_Request handles a proxied browser head inside the budget");
      Register_Routine
        (T, Test_New_Status_Lines'Access, "Status_Line covers the new codes");
      Register_Routine
        (T, Test_Same_Text'Access, "Same_Text compares without an early exit");
      Register_Routine
        (T,
         Test_Response_Head_Golden'Access,
         "Response_Head emits the exact status head");
      Register_Routine
        (T,
         Test_Response_Head_401'Access,
         "Response_Head puts the challenge on a 401 only");
      Register_Routine
        (T,
         Test_Upgrade_Request_Parsed'Access,
         "Parse_Request types the websocket upgrade and keeps its key");
      Register_Routine
        (T,
         Test_Upgrade_Needs_All_Four'Access,
         "Parse_Request needs all four upgrade headers to agree");
      Register_Routine
        (T,
         Test_Upgrade_Head_Bytes'Access,
         "Upgrade_Head emits the exact 101 head");
      Register_Routine
        (T, Test_Never_Upgrade'Access, "Never_Upgrade refuses every upgrade");
      Register_Routine
        (T,
         Test_426_Head_Carries_Upgrade'Access,
         "Response_Head puts the upgrade offer on a 426 only");
      Register_Routine
        (T,
         Test_Accept_Encoding_Parsed'Access,
         "Parse_Request records whether gzip is accepted");
      Register_Routine
        (T,
         Test_Deflate_Offer_Parsed'Access,
         "Parse_Request records a permessage-deflate offer it can take");
      Register_Routine
        (T,
         Test_Compressible_And_Floor'Access,
         "Compressible and Worth_Packing decide when a coding pays");
      Register_Routine
        (T,
         Test_Response_Head_Gzip_Golden'Access,
         "Response_Head adds Content-Encoding and Vary for a gzip body");
      Register_Routine
        (T,
         Test_Upgrade_Head_Deflated'Access,
         "Upgrade_Head answers a deflate offer with no context takeover");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web (HTTP request line and response head)"));

end Nuntius_Web_Tests;
