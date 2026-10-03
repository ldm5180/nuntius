with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNAT.Sockets;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Codings;
with Nuntius.Web;
with Nuntius.Ws.Native_Client;
with Nuntius.Ws.Peer;

with Test_Payloads;

with Nuntius_World;     use Nuntius_World;
with Nuntius_World.Web; use Nuntius_World.Web;

--  The serial serve loop over a REAL loopback socket -- the coverage
--  the mechanics never had while they lived in a consumer: 200 through
--  the Handle seam on a GET and on a POST carrying a body, 400 on
--  garbage, on a lengthless POST and on a GET that brought a body, 405
--  on a method that is neither, 413 on an over-long body, the quiet
--  drop of a half-sent head, and the whole-connection budget that ends
--  a dribble.  Port 0 + On_Listening keeps the test free of
--  fixed-port flakes.

package body Nuntius_Web_Server_Tests is

   use type Nuntius.Ws.Receive_Outcome;

   use AUnit.Test_Cases.Registration;

   --  The loopback dialer: a SMALL idle limit and a frame cap past the
   --  16-bit length form, so a wrong answer fails in seconds instead of
   --  hanging out the adapter's 45 s default.
   package Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 8,
        Max_Frame_Bytes => 70_000,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   package Peers is new Nuntius.Ws.Peer (Max_Inbound_Bytes => 512);

   procedure Test_Loopback (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      R_Ok, R_Put, R_Bad, R_Half          : Unbounded_String;
      R_Get_Body, R_Json, R_Big, R_No_Len : Unbounded_String;
      R_Split                             : Unbounded_String;
      Port_Seen                           : Natural := 0;
   begin
      Cells.Reset;
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve ("127.0.0.1", 0);
         end Server_Task;
      begin
         Port_Seen := Await_Port (Test_Port'Access);
         if Port_Seen /= 0 then
            R_Ok :=
              To_Unbounded_String
                (Exchange (Port_Seen, "GET /x HTTP/1.1" & CRLF & CRLF));
            R_Put :=
              To_Unbounded_String
                (Exchange (Port_Seen, "PUT /x HTTP/1.1" & CRLF & CRLF));
            R_Bad :=
              To_Unbounded_String
                (Exchange (Port_Seen, "garbage" & CRLF & CRLF));
            R_Half :=
              To_Unbounded_String
                (Exchange (Port_Seen, "GET /x HT", Half_Head => True));
            R_Get_Body :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen,
                    "GET /x HTTP/1.1"
                    & CRLF
                    & "Content-Length: 5"
                    & CRLF
                    & CRLF
                    & "abcde"));
            R_Json :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen,
                    "POST /api/close HTTP/1.1"
                    & CRLF
                    & "Content-Type: application/json"
                    & CRLF
                    & "Content-Length: 15"
                    & CRLF
                    & CRLF
                    & "{""scope"":""all""}"));
            R_Big :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen,
                    "POST /api/close HTTP/1.1"
                    & CRLF
                    & "Content-Length: 5000"
                    & CRLF
                    & CRLF));
            R_No_Len :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen, "POST /api/close HTTP/1.1" & CRLF & CRLF));
            R_Split :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen,
                    "POST /api/close HTTP/1.1"
                    & CRLF
                    & "Content-Type: application/json"
                    & CRLF
                    & "Content-Length: 15"
                    & CRLF
                    & CRLF,
                    Tail       => "{""scope"":""all""}",
                    Tail_Delay => 0.2));
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the server reported its bound port");
      Assert
        (Has (To_String (R_Ok), "HTTP/1.1 200 OK")
         and then Has (To_String (R_Ok), "hi:GET:/x:"),
         "a GET reaches Handle with an empty payload: " & To_String (R_Ok));
      Assert
        (Has (To_String (R_Put), "405 Method Not Allowed")
         and then Has (To_String (R_Put), "method not allowed"),
         "a PUT answers 405, not 400: " & To_String (R_Put));
      Assert
        (Has (To_String (R_Bad), "400 Bad Request"),
         "a malformed line answers 400: " & To_String (R_Bad));
      Assert
        (Length (R_Half) = 0,
         "half a head then close drops quietly, no response bytes: "
         & To_String (R_Half));
      Assert
        (Has (To_String (R_Get_Body), "400 Bad Request")
         and then Has (To_String (R_Get_Body), "no body on GET"),
         "a GET carrying a body is refused unread: " & To_String (R_Get_Body));
      Assert
        (Has (To_String (R_Json), "HTTP/1.1 200 OK")
         and then Has
                    (To_String (R_Json),
                     "hi:POST:/api/close:{""scope"":""all""}"),
         "a JSON POST reaches Handle with its body: " & To_String (R_Json));
      Assert
        (Has (To_String (R_Big), "413 Content Too Large")
         and then Has (To_String (R_Big), "body too large"),
         "a 5000-byte body is refused before it is read: "
         & To_String (R_Big));
      Assert
        (Has (To_String (R_No_Len), "400 Bad Request")
         and then Has (To_String (R_No_Len), "length required"),
         "a lengthless POST is refused: " & To_String (R_No_Len));
      Assert
        (Has (To_String (R_Split), "hi:POST:/api/close:{""scope"":""all""}"),
         "a body that arrives in a second write still reaches Handle: "
         & To_String (R_Split));
   end Test_Loopback;

   --  The per-read timeout alone would let one byte every 300 ms hold
   --  the serial loop for as long as the peer cares to: the
   --  whole-connection budget is what ends it, with no response and
   --  without Handle ever running.
   procedure Test_Dribble_Is_Dropped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Reply     : Unbounded_String;
      After     : Unbounded_String;
      Handled   : Natural := 0;
      Port_Seen : Natural := 0;
   begin
      Cells.Reset;
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve_Short ("127.0.0.1", 0);
         end Server_Task;
      begin
         Port_Seen := Await_Port (Test_Short_Port'Access);
         if Port_Seen /= 0 then
            Reply :=
              To_Unbounded_String
                (Dribble
                   (Port_Seen,
                    "POST /x HTTP/1.1"
                    & CRLF
                    & "Content-Type: application/json"
                    & CRLF
                    & "Content-Length: 40"
                    & CRLF
                    & CRLF,
                    Count => 8,
                    Gap   => 0.3));
            Handled := Cells.Handled;
            After :=
              To_Unbounded_String
                (Exchange (Port_Seen, "GET /y HTTP/1.1" & CRLF & CRLF));
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the short-budget server reported its port");
      Assert
        (Length (Reply) = 0,
         "a dribbled body gets no response at all: " & To_String (Reply));
      Assert (Handled = 0, "Handle never ran on the dribbled connection");
      Assert
        (Has (To_String (After), "hi:GET:/y:"),
         "the loop is free again straight after: " & To_String (After));
   end Test_Dribble_Is_Dropped;

   function Ws_Url (Port : Natural; Path : String) return String
   is ("ws://127.0.0.1:"
       & Ada.Strings.Fixed.Trim (Natural'Image (Port), Ada.Strings.Both)
       & Path);

   Hello_Frame : constant String := "{""hello"":{""proto"":1}}";

   procedure Test_Upgrade_Is_Adopted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Port_Seen : Natural := 0;
      C         : Ws.Client;
      Buf       : String (1 .. 256);
      Ok        : Boolean := False;
      Rx        : Nuntius.Ws.Reception;
      Sock      : GNAT.Sockets.Socket_Type;
      Got       : Boolean := False;
      P         : Peers.Peer;
      Sent      : Boolean := False;
   begin
      Cells.Reset;
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve_Stream ("127.0.0.1", 0);
         end Server_Task;
      begin
         Port_Seen := Await_Port (Test_Stream_Port'Access);
         if Port_Seen /= 0 then
            Ws.Connect (C, Ws_Url (Port_Seen, "/api/stream"), Ok);
            if Ok then
               for K in 1 .. 200 loop
                  Cells.Take (Sock, Got);
                  exit when Got;
                  delay 0.01;
               end loop;
               if Got then
                  Peers.Adopt (P, Sock);
                  Peers.Send_Text (P, Hello_Frame, Sent);
                  Ws.Receive_For (C, Buf, 2.0, Rx);
               end if;
            end if;
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the server reported its bound port");
      Assert (Got, "the loop handed the socket to Adopt");
      Assert (Cells.Adopted = 1, "exactly once");
      Assert (Sent, "the peer wrote a frame on it");
      Assert
        (Rx.Outcome = Nuntius.Ws.Delivered
         and then Buf (1 .. Rx.Last) = Hello_Frame,
         "and the dialer read it back whole");
      Assert (Cells.Handled = 0, "Handle never saw the upgrade");
      Ws.Close (C);
      Peers.Close (P, 1_000);
   end Test_Upgrade_Is_Adopted;

   procedure Test_Upgrade_Refused_Reaches_Handle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Port_Seen : Natural := 0;
      C         : Ws.Client;
      Ok        : Boolean := True;
   begin
      Cells.Reset;
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve_Stream ("127.0.0.1", 0);
         end Server_Task;
      begin
         Port_Seen := Await_Port (Test_Stream_Port'Access);
         if Port_Seen /= 0 then
            Ws.Connect (C, Ws_Url (Port_Seen, "/elsewhere"), Ok);
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the server reported its bound port");
      Assert (not Ok, "an upgrade the consumer refuses does not connect");
      Assert (Cells.Adopted = 0, "and nothing was adopted");
      Assert (Cells.Handled = 1, "it reached Handle instead");
      Assert (Cells.Saw_Upgrade, "which saw it typed as an upgrade");
      Ws.Close (C);
   end Test_Upgrade_Refused_Reaches_Handle;

   procedure Test_Plain_Get_On_Stream_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Port_Seen : Natural := 0;
      Reply     : Unbounded_String;
   begin
      Cells.Reset;
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve_Stream ("127.0.0.1", 0);
         end Server_Task;
      begin
         Port_Seen := Await_Port (Test_Stream_Port'Access);
         if Port_Seen /= 0 then
            Reply :=
              To_Unbounded_String
                (Exchange
                   (Port_Seen, "GET /api/stream HTTP/1.1" & CRLF & CRLF));
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the server reported its bound port");
      Assert (Cells.Adopted = 0, "a plain GET adopts nothing");
      Assert (Cells.Handled = 1, "it is the GET it always was");
      Assert (not Cells.Saw_Upgrade, "and is not typed as an upgrade");
      Assert
        (Has (To_String (Reply), "426 Upgrade Required")
         and then Has (To_String (Reply), "Upgrade: websocket"),
         "the consumer answered it 426: " & To_String (Reply));
   end Test_Plain_Get_On_Stream_Path;

   --  D4: gzip when the request takes it, the type shrinks and the body
   --  is past the floor; anything else is today's identity response.
   procedure Test_Gzip_Responses (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Port_Seen                   : Natural := 0;
      Big, Plain, Small, Png, Off : Unbounded_String;
   begin
      Cells.Reset;
      declare
         task Gzip_Task;
         task Off_Task;

         task body Gzip_Task is
         begin
            Serve_Gzip ("127.0.0.1", 0);
         end Gzip_Task;

         task body Off_Task is
         begin
            Serve ("127.0.0.1", 0);
         end Off_Task;
      begin
         Port_Seen := Await_Port (Test_Gzip_Port'Access);
         if Port_Seen /= 0 and then Await_Port (Test_Port'Access) /= 0 then
            Big :=
              To_Unbounded_String
                (Exchange (Port_Seen, Get_With ("/big", Accepting)));
            Plain :=
              To_Unbounded_String
                (Exchange (Port_Seen, Get_With ("/big", "")));
            Small :=
              To_Unbounded_String
                (Exchange (Port_Seen, Get_With ("/small", Accepting)));
            Png :=
              To_Unbounded_String
                (Exchange (Port_Seen, Get_With ("/png", Accepting)));
            Off :=
              To_Unbounded_String
                (Exchange (Cells.Port, Get_With ("/big", Accepting)));
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the gzip server reported its port");
      Assert
        (Has (To_String (Big), "Content-Encoding: gzip" & CRLF)
         and then Has (To_String (Big), "Vary: Accept-Encoding" & CRLF),
         "a big JSON body to a gzip client is gzipped: " & To_String (Big));
      Assert
        (Test_Payloads.Gunzip (Body_Of (To_String (Big)), 4_096) = Big_Json,
         "and the body is the gzip of the payload");
      Assert
        (Has
           (To_String (Big),
            "Content-Length:"
            & Natural'Image (Body_Of (To_String (Big))'Length)
            & CRLF),
         "with the packed length");
      Assert
        (not Has (To_String (Plain), "Content-Encoding")
         and then Body_Of (To_String (Plain)) = Big_Json,
         "no Accept-Encoding, identity");
      Assert
        (not Has (To_String (Small), "Content-Encoding")
         and then Body_Of (To_String (Small)) = Big_Json (1 .. 100),
         "under the floor, identity");
      Assert
        (not Has (To_String (Png), "Content-Encoding"),
         "an image type, identity");
      Assert
        (not Has (To_String (Off), "Content-Encoding")
         and then Body_Of (To_String (Off)) = Big_Json,
         "the default policy is identity only");
   end Test_Gzip_Responses;

   --  D7: the 101 says what was agreed, and Adopt is told the same.
   procedure Test_Upgrade_Deflate (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use type Nuntius.Codings.Message_Coding;
      pragma Unreferenced (T);
      Port_Seen                : Natural := 0;
      Offered, Bare, Off       : Unbounded_String;
      Offered_C, Bare_C, Off_C : Nuntius.Codings.Message_Coding :=
        Nuntius.Codings.Plain;
   begin
      Cells.Reset;
      declare
         task Deflate_Task;
         task Off_Task;

         task body Deflate_Task is
         begin
            Serve_Deflate ("127.0.0.1", 0);
         end Deflate_Task;

         task body Off_Task is
         begin
            Serve_Stream ("127.0.0.1", 0);
         end Off_Task;
      begin
         Port_Seen := Await_Port (Test_Deflate_Port'Access);
         if Port_Seen /= 0 and then Await_Port (Test_Stream_Port'Access) /= 0
         then
            Offered :=
              To_Unbounded_String
                (Upgrade_Reply
                   (Port_Seen, "permessage-deflate; client_max_window_bits"));
            Release_Held;
            Offered_C := Cells.Kept_Coding;
            Bare := To_Unbounded_String (Upgrade_Reply (Port_Seen, ""));
            Release_Held;
            Bare_C := Cells.Kept_Coding;
            Off :=
              To_Unbounded_String
                (Upgrade_Reply (Cells.Stream_Port, "permessage-deflate"));
            Release_Held;
            Off_C := Cells.Kept_Coding;
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the deflate server reported its port");
      Assert
        (Has (To_String (Offered), Nuntius.Web.Deflate_Extension & CRLF),
         "an offer is answered with the extension: " & To_String (Offered));
      Assert
        (Offered_C = Nuntius.Codings.Deflated, "and Adopt is told Deflated");
      Assert
        (Length (Bare) = 129 and then Bare_C = Nuntius.Codings.Plain,
         "no offer: today's 101 and Plain: " & To_String (Bare));
      Assert
        (not Has (To_String (Off), "Sec-WebSocket-Extensions")
         and then Off_C = Nuntius.Codings.Plain,
         "the default policy never agrees one");
   end Test_Upgrade_Deflate;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Loopback'Access,
         "loopback serve: GET and POST via Handle, 400/405/413, quiet "
         & "half-head drop");
      Register_Routine
        (T,
         Test_Dribble_Is_Dropped'Access,
         "the whole-connection budget ends a dribble and frees the loop");
      Register_Routine
        (T,
         Test_Upgrade_Is_Adopted'Access,
         "an accepted upgrade is answered 101 and handed over");
      Register_Routine
        (T,
         Test_Upgrade_Refused_Reaches_Handle'Access,
         "an upgrade the consumer refuses reaches Handle");
      Register_Routine
        (T,
         Test_Plain_Get_On_Stream_Path'Access,
         "a plain GET on the stream target is still a GET");
      Register_Routine
        (T,
         Test_Gzip_Responses'Access,
         "a gzip-taking request gets a gzipped body when it pays");
      Register_Routine
        (T,
         Test_Upgrade_Deflate'Access,
         "a deflate offer is answered in the 101 and told to Adopt");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web.Server (serial loopback serve loop)"));

end Nuntius_Web_Server_Tests;
