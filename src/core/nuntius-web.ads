--  The serving side's pure primitives: the HTTP/1.1 request parser and
--  the response head -- bounded string functions with no IO, so a
--  consumer's socket loop (Nuntius.Web.Server) stays a thin transport.
--  The parser reads the request LINE and the handful of header lines a
--  serving loop has to act on (how long the body is, what it claims to
--  be, who is asking, which codings it can read); everything else in
--  the header block is skipped.
--  ROUTING is absent by design -- which targets exist is the consumer's
--  policy, applied in its Handle procedure.

with Nuntius.Codings;

package Nuntius.Web
  with SPARK_Mode
is

   use type Codings.Content_Coding;
   use type Codings.Message_Coding;
   use type Codings.Policy;

   --  One request's read budget: request line + headers.  Localhost
   --  cookies from other dev servers could inflate headers; the cap is
   --  the one constant to bump if 400s ever show up in practice.
   Max_Request_Bytes : constant := 4_096;
   --  The target cap has to hold a full OAuth redirect target
   --  (/auth?code=<escaped>&session=<uuid>), which is why it is
   --  generous: a target past the cap answers 400 BEFORE the consumer's
   --  Handle runs, so an authorization code would be lost silently.
   Max_Target        : constant := 2_048;
   --  A request body's cap, read past the head only for a POST.
   Max_Body_Bytes    : constant := 4_096;
   --  openssl rand -hex 32 is 64; twice that is room, not a target.
   Max_Bearer        : constant := 128;
   --  One IPv6 and one IPv4 hop with the comma fit; the value is a
   --  log decoration, never a decision.
   Max_Forwarded     : constant := 64;
   --  RFC 6455 4.1: 16 random bytes, base64 -- 24 bytes ending in "==".
   Ws_Key_Length     : constant := 24;
   --  base64 (SHA-1 (..)): 20 bytes become 28.
   Accept_Length     : constant := 28;

   type Method_Kind is (Get, Post, Other);

   type Request is record
      Well_Formed : Boolean := False;
      Method      : Method_Kind := Other;
      Target      : String (1 .. Max_Target) := [others => ' '];
      Target_Len  : Natural range 0 .. Max_Target := 0;

      --  From the header block, when present and sane.
      --  Content-Length: 0 when absent.  A digit run whose value
      --  exceeds Max_Body_Bytes -- including any run longer than four
      --  digits -- leaves the request NOT well-formed with
      --  Length_Refused True, so the server can answer 413 rather than
      --  400; a run that is not all digits, an empty value, or a
      --  second Content-Length is plain 400 (Well_Formed False,
      --  Length_Refused False).  A run longer than four digits is
      --  refused on its LENGTH alone and never evaluated, so nothing
      --  here can overflow.
      Content_Length  : Natural range 0 .. Max_Body_Bytes := 0;
      Length_Refused  : Boolean := False;
      --  Content-Type names application/json (the value up to the
      --  first ';', trimmed, ASCII case-insensitive).
      Json_Body       : Boolean := False;
      --  Authorization: Bearer <token> (RFC 6750 2.1): the scheme word
      --  ASCII case-insensitive, one or more SP, then the token
      --  verbatim to the end of the value.  Absent, another scheme, an
      --  empty token, or one over Max_Bearer bytes leaves Bearer_Len 0
      --  -- an over-long token can never match and never overflows.
      --  A SECRET: never logged, never echoed, never 'Image'd.
      Bearer          : String (1 .. Max_Bearer) := [others => ' '];
      Bearer_Len      : Natural range 0 .. Max_Bearer := 0;
      --  X-Forwarded-For, for the audit line only: the value verbatim
      --  when it is 1 .. Max_Forwarded bytes of visible ASCII (32 ..
      --  126); anything longer or with any other byte leaves it empty,
      --  so attacker-chosen text cannot carry a control character into
      --  the log.
      Forwarded_For   : String (1 .. Max_Forwarded) := [others => ' '];
      Forwarded_Len   : Natural range 0 .. Max_Forwarded := 0;
      --  A websocket upgrade: a GET whose Upgrade, Connection,
      --  Sec-WebSocket-Version and Sec-WebSocket-Key headers all agree
      --  (RFC 6455 4.1).  Anything short of all four leaves this False
      --  and the request is the plain GET it was -- nothing is refused
      --  at the parser.  Ws_Key means something only when Upgrade does.
      Upgrade         : Boolean := False;
      Ws_Key          : String (1 .. Ws_Key_Length) := [others => ' '];
      --  Accept-Encoding names gzip or the wildcard (RFC 9110 12.5.3):
      --  some element, cut at its first ';' and trimmed, is "gzip"
      --  (ASCII case-insensitive) or "*".  A weight is not read, so a
      --  q=0 does not refuse; no browser sends one.
      Accepts_Gzip    : Boolean := False;
      --  Sec-WebSocket-Extensions holds a permessage-deflate offer this
      --  side can answer (RFC 7692 7.1): no parameter but a bare or
      --  8 .. 15 client_max_window_bits and the two no_context_takeover
      --  flags.  An offer asking for a server window is skipped.
      Deflate_Offered : Boolean := False;
   end record;

   function Target_Of (R : Request) return String
   is (R.Target (1 .. R.Target_Len));

   function Bearer_Of (R : Request) return String
   is (R.Bearer (1 .. R.Bearer_Len));

   function Forwarded_For_Of (R : Request) return String
   is (R.Forwarded_For (1 .. R.Forwarded_Len));

   function Ws_Key_Of (R : Request) return String
   is (R.Ws_Key);

   --  The default for a consumer that takes no upgrades.
   function Never_Upgrade (Unused : Request) return Boolean
   is (False);

   --  The smallest body worth a content coding.  Below it the gzip or
   --  deflate framing costs more than it saves: a 78-byte JSON body
   --  gzips to 106.
   Min_Compress_Bytes : constant := 512;

   function Worth_Packing (Length : Natural) return Boolean
   is (Length >= Min_Compress_Bytes);

   --  Whether a body of this media type shrinks under deflate: any
   --  text/ type, JSON and SVG.  An image or font format is compressed
   --  already, and deflate only grows it.
   function Compressible (Content_Type : String) return Boolean;

   --  The coding a response goes out in: gzip when the request takes
   --  it, the policy applies codings, the type shrinks and the body is
   --  worth it; identity otherwise.
   function Response_Coding
     (Accepts_Gzip : Boolean;
      Policy       : Codings.Policy;
      Content_Type : String;
      Length       : Natural) return Codings.Content_Coding
   is (if Accepts_Gzip
         and then Policy = Codings.Compress_When_Offered
         and then Compressible (Content_Type)
         and then Worth_Packing (Length)
       then Codings.Gzip
       else Codings.Identity);

   --  The coding an upgraded socket agrees: permessage-deflate when the
   --  request offered one this side can answer and the policy applies
   --  codings; plain otherwise.
   function Upgrade_Coding
     (Deflate_Offered : Boolean; Policy : Codings.Policy)
      return Codings.Message_Coding
   is (if Deflate_Offered and then Policy = Codings.Compress_When_Offered
       then Codings.Deflated
       else Codings.Plain);

   --  Parse the request LINE and the header block up to the first EMPTY
   --  line (never to Text'Last: a body may itself contain CRLF and even
   --  a Content-Length).  Well_Formed = "<METHOD> SP <target> SP
   --  HTTP/1.<x>" with an uppercase method, a target of 1 .. Max_Target
   --  bytes with no interior SP/CTL, and a one-digit minor version --
   --  and no refused header.  An unknown method is WELL-FORMED with
   --  Method = Other -- the server answers 405, not 400.
   function Parse_Request (Text : String) return Request
   with Pre => Text'First = 1 and then Text'Length <= Max_Request_Bytes;

   --  Equality without an early exit: every byte is visited whatever
   --  the first difference.  The consumer compares two SHA-256 hex
   --  digests with it (a bearer guard), so the Pre is exact length.
   function Same_Text (A, B : String) return Boolean
   with Pre => A'Length = B'Length, Post => Same_Text'Result = (A = B);

   type Status is
     (Ok_200,
      Accepted_202,
      Bad_Request_400,
      Unauthorized_401,
      Forbidden_403,
      Not_Found_404,
      Not_Allowed_405,
      Conflict_409,
      Too_Large_413,
      Unsupported_Media_415,
      Upgrade_Required_426,
      Unavailable_503);

   --  The one header a 401 MUST carry (RFC 9110 15.5.2); the realm is
   --  cosmetic and the same for every consumer.
   Challenge : constant String :=
     "WWW-Authenticate: Bearer realm=""dashboard""";

   --  The one header a 426 MUST carry (RFC 9110 15.5.22).
   Upgrade_Offer : constant String := "Upgrade: websocket";

   function Status_Line (S : Status) return String
   is (case S is
         when Ok_200                => "200 OK",
         when Accepted_202          => "202 Accepted",
         when Bad_Request_400       => "400 Bad Request",
         when Unauthorized_401      => "401 Unauthorized",
         when Forbidden_403         => "403 Forbidden",
         when Not_Found_404         => "404 Not Found",
         when Not_Allowed_405       => "405 Method Not Allowed",
         when Conflict_409          => "409 Conflict",
         when Too_Large_413         => "413 Content Too Large",
         when Unsupported_Media_415 => "415 Unsupported Media Type",
         when Upgrade_Required_426  => "426 Upgrade Required",
         when Unavailable_503       => "503 Service Unavailable");

   --  The two lines a gzip body adds (RFC 9110 8.4, 12.5.5).  Vary goes
   --  only on the gzip variant: every response is no-store, so there is
   --  no cache to warn, and the identity head stays byte-for-byte what
   --  it was.
   Gzip_Encoding : constant String := "Content-Encoding: gzip";
   Gzip_Vary     : constant String := "Vary: Accept-Encoding";

   --  "HTTP/1.1 <code> <reason>" CRLF, then on a 401 ONLY the
   --  Challenge CRLF and on a 426 ONLY the Upgrade_Offer CRLF, then
   --  "Connection: close" CRLF "Cache-Control:
   --  no-store" CRLF "Content-Security-Policy: frame-ancestors 'none'"
   --  CRLF "X-Content-Type-Options: nosniff" CRLF, on a Gzip body the
   --  Gzip_Encoding CRLF and Gzip_Vary CRLF, then "Content-Type: <..>"
   --  CRLF "Content-Length: <n>" CRLF CRLF -- the body follows
   --  verbatim.
   function Response_Head
     (S              : Status;
      Content_Type   : String;
      Content_Length : Natural;
      Coding         : Codings.Content_Coding := Codings.Identity)
      return String
   with Pre => Content_Type'Length in 1 .. 64;

   --  The extension line of a 101 that took a deflate offer (RFC 7692
   --  7.1.1): both no_context_takeover parameters, whatever the offer
   --  said, so every message is packed and unpacked from a fresh
   --  window and one packed buffer serves every client.
   Deflate_Extension : constant String :=
     "Sec-WebSocket-Extensions: permessage-deflate;"
     & " server_no_context_takeover; client_no_context_takeover";

   --  "HTTP/1.1 101 Switching Protocols" CRLF "Upgrade: websocket"
   --  CRLF "Connection: Upgrade" CRLF "Sec-WebSocket-Accept: <a>" CRLF,
   --  on a Deflated socket the Deflate_Extension CRLF, then CRLF.  No
   --  body follows: the socket is a websocket from here.
   function Upgrade_Head
     (Accept_Key : String; Coding : Codings.Message_Coding := Codings.Plain)
      return String
   with
     Pre  => Accept_Key'Length = Accept_Length,
     Post =>
       Upgrade_Head'Result'Length
       = 101
         + Accept_Length
         + (if Coding = Codings.Deflated
            then Deflate_Extension'Length + 2
            else 0);

end Nuntius.Web;
