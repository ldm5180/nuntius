with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNAT.Sockets;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Codings;
with Nuntius.Web.Server;
with Nuntius.Ws.Native_Client;
with Nuntius.Ws.Peer;

with Test_Payloads;

--  The serial serve loop over a REAL loopback socket -- the coverage
--  the mechanics never had while they lived in a consumer: 200 through
--  the Handle seam on a GET and on a POST carrying a body, 400 on
--  garbage, on a lengthless POST and on a GET that brought a body, 405
--  on a method that is neither, 413 on an over-long body, the quiet
--  drop of a half-sent head, and the whole-connection budget that ends
--  a dribble.  Port 0 + On_Listening keeps the test free of
--  fixed-port flakes.

package body Nuntius_Web_Server_Tests is

   use AUnit.Test_Cases.Registration;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Has (Haystack, Needle : String) return Boolean
   is (Ada.Strings.Fixed.Index (Haystack, Needle) > 0);

   protected Cells is
      procedure Reset;
      procedure Set_Port (P : Natural);
      function Port return Natural;
      procedure Set_Short_Port (P : Natural);
      function Short_Port return Natural;
      procedure Bump_Handled;
      function Handled return Natural;
      procedure Request_Stop;
      function Stopped return Boolean;
      procedure Set_Stream_Port (P : Natural);
      function Stream_Port return Natural;
      procedure Keep (Sock : GNAT.Sockets.Socket_Type);
      procedure Take (Sock : out GNAT.Sockets.Socket_Type; Got : out Boolean);
      function Adopted return Natural;
      procedure Note_Upgrade;
      function Saw_Upgrade return Boolean;
      procedure Set_Gzip_Port (P : Natural);
      function Gzip_Port return Natural;
      procedure Set_Deflate_Port (P : Natural);
      function Deflate_Port return Natural;
      procedure Keep_Coding (C : Nuntius.Codings.Message_Coding);
      function Kept_Coding return Nuntius.Codings.Message_Coding;
   private
      Port_V         : Natural := 0;
      Short_Port_V   : Natural := 0;
      Stream_Port_V  : Natural := 0;
      Handled_V      : Natural := 0;
      Stop_V         : Boolean := False;
      Adopted_V      : Natural := 0;
      Held_V         : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Has_Held_V     : Boolean := False;
      Upgrade_V      : Boolean := False;
      Gzip_Port_V    : Natural := 0;
      Deflate_Port_V : Natural := 0;
      Coding_V       : Nuntius.Codings.Message_Coding := Nuntius.Codings.Plain;
   end Cells;

   protected body Cells is
      procedure Reset is
      begin
         Port_V := 0;
         Short_Port_V := 0;
         Stream_Port_V := 0;
         Handled_V := 0;
         Stop_V := False;
         Adopted_V := 0;
         Has_Held_V := False;
         Upgrade_V := False;
         Gzip_Port_V := 0;
         Deflate_Port_V := 0;
         Coding_V := Nuntius.Codings.Plain;
      end Reset;

      procedure Set_Port (P : Natural) is
      begin
         Port_V := P;
      end Set_Port;

      function Port return Natural
      is (Port_V);

      procedure Set_Short_Port (P : Natural) is
      begin
         Short_Port_V := P;
      end Set_Short_Port;

      function Short_Port return Natural
      is (Short_Port_V);

      procedure Bump_Handled is
      begin
         Handled_V := Handled_V + 1;
      end Bump_Handled;

      function Handled return Natural
      is (Handled_V);

      procedure Request_Stop is
      begin
         Stop_V := True;
      end Request_Stop;

      function Stopped return Boolean
      is (Stop_V);

      procedure Set_Stream_Port (P : Natural) is
      begin
         Stream_Port_V := P;
      end Set_Stream_Port;

      function Stream_Port return Natural
      is (Stream_Port_V);

      procedure Keep (Sock : GNAT.Sockets.Socket_Type) is
      begin
         Held_V := Sock;
         Has_Held_V := True;
         Adopted_V := Adopted_V + 1;
      end Keep;

      procedure Take (Sock : out GNAT.Sockets.Socket_Type; Got : out Boolean)
      is
      begin
         Sock := Held_V;
         Got := Has_Held_V;
         Has_Held_V := False;
      end Take;

      function Adopted return Natural
      is (Adopted_V);

      procedure Note_Upgrade is
      begin
         Upgrade_V := True;
      end Note_Upgrade;

      function Saw_Upgrade return Boolean
      is (Upgrade_V);

      procedure Set_Gzip_Port (P : Natural) is
      begin
         Gzip_Port_V := P;
      end Set_Gzip_Port;

      function Gzip_Port return Natural
      is (Gzip_Port_V);

      procedure Set_Deflate_Port (P : Natural) is
      begin
         Deflate_Port_V := P;
      end Set_Deflate_Port;

      function Deflate_Port return Natural
      is (Deflate_Port_V);

      procedure Keep_Coding (C : Nuntius.Codings.Message_Coding) is
      begin
         Coding_V := C;
      end Keep_Coding;

      function Kept_Coding return Nuntius.Codings.Message_Coding
      is (Coding_V);
   end Cells;

   function Stop return Boolean
   is (Cells.Stopped);

   procedure Sleep_Ms (Ms : Natural) is
   begin
      delay Duration (Ms) / 1_000.0;
   end Sleep_Ms;

   procedure Log_Quiet (Line : String) is null;

   procedure On_Listening (Port : Natural) is
   begin
      Cells.Set_Port (Port);
   end On_Listening;

   procedure On_Listening_Short (Port : Natural) is
   begin
      Cells.Set_Short_Port (Port);
   end On_Listening_Short;

   --  A body worth compressing: 2,280 bytes of repetitive JSON.
   Big_Json : constant String := Test_Payloads.Json_Like (60);

   --  The whole routing policy a consumer would bring: echo the head
   --  the loop parsed and the body it read, or, on /big, /png and
   --  /small, a body the coding tests can size.
   procedure Handle
     (R       : Nuntius.Web.Request;
      Payload : String;
      Respond :
        not null access procedure
          (S : Nuntius.Web.Status; Content_Type, Payload : String))
   is
      Target : constant String := Nuntius.Web.Target_Of (R);
   begin
      Cells.Bump_Handled;
      if Target = "/big" then
         Respond (Nuntius.Web.Ok_200, "application/json", Big_Json);
      elsif Target = "/png" then
         Respond (Nuntius.Web.Ok_200, "image/png", Big_Json);
      elsif Target = "/small" then
         Respond (Nuntius.Web.Ok_200, "application/json", Big_Json (1 .. 100));
      else
         Respond
           (Nuntius.Web.Ok_200,
            "text/plain",
            "hi:"
            & Nuntius.Web.Method_Kind'Image (R.Method)
            & ":"
            & Nuntius.Web.Target_Of (R)
            & ":"
            & Payload);
      end if;
   end Handle;

   procedure On_Listening_Stream (Port : Natural) is
   begin
      Cells.Set_Stream_Port (Port);
   end On_Listening_Stream;

   --  The consumer's policy: this ONE target takes upgrades.
   function Takes_Stream (R : Nuntius.Web.Request) return Boolean
   is (R.Upgrade and then Nuntius.Web.Target_Of (R) = "/api/stream");

   procedure Keep
     (R      : Nuntius.Web.Request;
      Sock   : GNAT.Sockets.Socket_Type;
      Coding : Nuntius.Codings.Message_Coding)
   is
      pragma Unreferenced (R);
   begin
      Cells.Keep_Coding (Coding);
      Cells.Keep (Sock);
   end Keep;

   procedure On_Listening_Gzip (Port : Natural) is
   begin
      Cells.Set_Gzip_Port (Port);
   end On_Listening_Gzip;

   procedure On_Listening_Deflate (Port : Natural) is
   begin
      Cells.Set_Deflate_Port (Port);
   end On_Listening_Deflate;

   --  What an upgrade the consumer did NOT take meets.
   procedure Handle_Stream
     (R       : Nuntius.Web.Request;
      Payload : String;
      Respond :
        not null access procedure
          (S : Nuntius.Web.Status; Content_Type, Payload : String))
   is
      pragma Unreferenced (Payload);
   begin
      Cells.Bump_Handled;
      if R.Upgrade then
         Cells.Note_Upgrade;
         Respond (Nuntius.Web.Unavailable_503, "text/plain", "stream down");
      else
         Respond
           (Nuntius.Web.Upgrade_Required_426, "text/plain", "websocket only");
      end if;
   end Handle_Stream;

   procedure Serve is new
     Nuntius.Web.Server
       (Stop         => Stop,
        Sleep_Ms     => Sleep_Ms,
        Log_Info     => Log_Quiet,
        Log_Warn     => Log_Quiet,
        On_Listening => On_Listening,
        Handle       => Handle);

   --  The same loop with a one-second whole-connection budget: what a
   --  dribbling peer meets.
   procedure Serve_Short is new
     Nuntius.Web.Server
       (Stop               => Stop,
        Sleep_Ms           => Sleep_Ms,
        Log_Info           => Log_Quiet,
        Log_Warn           => Log_Quiet,
        On_Listening       => On_Listening_Short,
        Connection_Seconds => 1,
        Handle             => Handle);

   procedure Serve_Stream is new
     Nuntius.Web.Server
       (Stop            => Stop,
        Sleep_Ms        => Sleep_Ms,
        Log_Info        => Log_Quiet,
        Log_Warn        => Log_Quiet,
        On_Listening    => On_Listening_Stream,
        Handle          => Handle_Stream,
        Accepts_Upgrade => Takes_Stream,
        Adopt           => Keep);

   --  The same loops with the codings on.
   procedure Serve_Gzip is new
     Nuntius.Web.Server
       (Stop          => Stop,
        Sleep_Ms      => Sleep_Ms,
        Log_Info      => Log_Quiet,
        Log_Warn      => Log_Quiet,
        On_Listening  => On_Listening_Gzip,
        Coding_Policy => Nuntius.Codings.Compress_When_Offered,
        Handle        => Handle);

   procedure Serve_Deflate is new
     Nuntius.Web.Server
       (Stop            => Stop,
        Sleep_Ms        => Sleep_Ms,
        Log_Info        => Log_Quiet,
        Log_Warn        => Log_Quiet,
        On_Listening    => On_Listening_Deflate,
        Coding_Policy   => Nuntius.Codings.Compress_When_Offered,
        Handle          => Handle_Stream,
        Accepts_Upgrade => Takes_Stream,
        Adopt           => Keep);

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

   --  One serial exchange: connect, send Request_Text, read to the
   --  server's Connection: close.  Half_Head sends without the blank
   --  line and closes our write side instead; Tail is sent after
   --  Tail_Delay, so a body can arrive in a second write.
   function Exchange
     (Port         : Natural;
      Request_Text : String;
      Half_Head    : Boolean := False;
      Tail         : String := "";
      Tail_Delay   : Duration := 0.0) return String
   is
      use GNAT.Sockets;
      use type Ada.Streams.Stream_Element_Offset;

      Sock  : Socket_Type;
      Addr  : constant Sock_Addr_Type :=
        (Family => Family_Inet,
         Addr   => Inet_Addr ("127.0.0.1"),
         Port   => Port_Type (Port));
      Reply : Unbounded_String;

      procedure Send_Text (Text : String) is
         Buf  : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         for K in Text'Range loop
            Buf (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Text (K)));
         end loop;
         Send_Socket (Sock, Buf, Last);
      end Send_Text;
   begin
      Create_Socket (Sock);
      Connect_Socket (Sock, Addr);
      Send_Text (Request_Text);
      if Half_Head then
         Shutdown_Socket (Sock, Shut_Write);
      end if;
      if Tail /= "" then
         delay Tail_Delay;
         Send_Text (Tail);
      end if;
      loop
         declare
            Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
            Last  : Ada.Streams.Stream_Element_Offset;
         begin
            Receive_Socket (Sock, Chunk, Last);
            exit when Last < Chunk'First;
            for K in 1 .. Last loop
               Append (Reply, Character'Val (Chunk (K)));
            end loop;
         exception
            when Socket_Error =>
               exit;
         end;
      end loop;
      Close_Socket (Sock);
      return To_String (Reply);
   end Exchange;

   --  A head, then Count single bytes Gap apart: every READ lands well
   --  inside the per-read timeout, so only a whole-connection budget
   --  can end it.  Answers whatever the server sent back.
   function Dribble
     (Port : Natural; Head : String; Count : Positive; Gap : Duration)
      return String
   is
      use GNAT.Sockets;
      use type Ada.Streams.Stream_Element_Offset;

      Sock  : Socket_Type;
      Addr  : constant Sock_Addr_Type :=
        (Family => Family_Inet,
         Addr   => Inet_Addr ("127.0.0.1"),
         Port   => Port_Type (Port));
      Reply : Unbounded_String;
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Create_Socket (Sock);
      Set_Socket_Option
        (Sock, Socket_Level, (Name => Receive_Timeout, Timeout => 5.0));
      Connect_Socket (Sock, Addr);
      declare
         Buf : Ada.Streams.Stream_Element_Array (1 .. Head'Length);
      begin
         for K in Head'Range loop
            Buf (Ada.Streams.Stream_Element_Offset (K - Head'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Head (K)));
         end loop;
         Send_Socket (Sock, Buf, Last);
      end;
      for K in 1 .. Count loop
         delay Gap;
         begin
            Send_Socket (Sock, [1 => Ada.Streams.Stream_Element (65)], Last);
         exception
            when Socket_Error =>
               exit;   --  the server closed on us: the budget ran out
         end;
      end loop;
      loop
         declare
            Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
            Got   : Ada.Streams.Stream_Element_Offset;
         begin
            Receive_Socket (Sock, Chunk, Got);
            exit when Got < Chunk'First;
            for K in 1 .. Got loop
               Append (Reply, Character'Val (Chunk (K)));
            end loop;
         exception
            when Socket_Error =>
               exit;
         end;
      end loop;
      Close_Socket (Sock);
      return To_String (Reply);
   end Dribble;

   function Await_Port
     (Get : not null access function return Natural) return Natural is
   begin
      for K in 1 .. 500 loop
         exit when Get.all /= 0;
         delay 0.01;
      end loop;
      return Get.all;
   end Await_Port;

   function Test_Port return Natural
   is (Cells.Port);

   function Test_Short_Port return Natural
   is (Cells.Short_Port);

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

   function Test_Stream_Port return Natural
   is (Cells.Stream_Port);

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
      Last      : Natural := 0;
      Ok        : Boolean := False;
      Timed_Out : Boolean := False;
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
                  Ws.Receive_For (C, Buf, Last, 2.0, Ok, Timed_Out);
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
        (Ok and then not Timed_Out and then Buf (1 .. Last) = Hello_Frame,
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

   function Test_Gzip_Port return Natural
   is (Cells.Gzip_Port);

   function Test_Deflate_Port return Natural
   is (Cells.Deflate_Port);

   --  What follows the head's blank line.
   function Body_Of (Reply : String) return String
   is (Reply (Ada.Strings.Fixed.Index (Reply, CRLF & CRLF) + 4 .. Reply'Last));

   function Get_With (Target, Headers : String) return String
   is ("GET " & Target & " HTTP/1.1" & CRLF & Headers & CRLF);

   Accepting : constant String := "Accept-Encoding: gzip, deflate, br" & CRLF;

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

   Key_24 : constant String := "dGhlIHNhbXBsZSBub25jZQ==";

   --  An upgrade request sent raw, with Extensions as the offer ("" for
   --  none); answers the head up to its blank line.  The socket stays
   --  with the server, which adopted it.
   function Upgrade_Reply (Port : Natural; Extensions : String) return String
   is
      use GNAT.Sockets;
      use type Ada.Streams.Stream_Element_Offset;

      Sock  : Socket_Type;
      Reply : Unbounded_String;
      Text  : constant String :=
        "GET /api/stream HTTP/1.1"
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
        & (if Extensions = ""
           then ""
           else "Sec-WebSocket-Extensions: " & Extensions & CRLF)
        & CRLF;
      Buf   : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Create_Socket (Sock);
      Set_Socket_Option
        (Sock, Socket_Level, (Name => Receive_Timeout, Timeout => 2.0));
      Connect_Socket
        (Sock,
         (Family => Family_Inet,
          Addr   => Inet_Addr ("127.0.0.1"),
          Port   => Port_Type (Port)));
      for K in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (K)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (K)));
      end loop;
      Send_Socket (Sock, Buf, Last);
      while not Has (To_String (Reply), CRLF & CRLF) loop
         declare
            One : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Receive_Socket (Sock, One, Last);
            exit when Last < One'First;
            Append (Reply, Character'Val (One (1)));
         exception
            when Socket_Error =>
               exit;
         end;
      end loop;
      Close_Socket (Sock);
      return To_String (Reply);
   end Upgrade_Reply;

   --  Drop the socket the server handed over, so the next upgrade's
   --  adoption is its own.
   procedure Release_Held is
      Sock : GNAT.Sockets.Socket_Type;
      Got  : Boolean := False;
   begin
      for K in 1 .. 200 loop
         Cells.Take (Sock, Got);
         exit when Got;
         delay 0.01;
      end loop;
      if Got then
         GNAT.Sockets.Close_Socket (Sock);
      end if;
   end Release_Held;

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
