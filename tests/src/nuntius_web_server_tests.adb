with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNAT.Sockets;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Web.Server;

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
   private
      Port_V       : Natural := 0;
      Short_Port_V : Natural := 0;
      Handled_V    : Natural := 0;
      Stop_V       : Boolean := False;
   end Cells;

   protected body Cells is
      procedure Reset is
      begin
         Port_V := 0;
         Short_Port_V := 0;
         Handled_V := 0;
         Stop_V := False;
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

   --  The whole routing policy a consumer would bring: echo the head
   --  the loop parsed and the body it read.
   procedure Handle
     (R       : Nuntius.Web.Request;
      Payload : String;
      Respond :
        not null access procedure
          (S : Nuntius.Web.Status; Content_Type, Payload : String)) is
   begin
      Cells.Bump_Handled;
      Respond
        (Nuntius.Web.Ok_200,
         "text/plain",
         "hi:"
         & Nuntius.Web.Method_Kind'Image (R.Method)
         & ":"
         & Nuntius.Web.Target_Of (R)
         & ":"
         & Payload);
   end Handle;

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
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web.Server (serial loopback serve loop)"));

end Nuntius_Web_Server_Tests;
