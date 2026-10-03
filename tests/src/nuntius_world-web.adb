with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Nuntius.Web.Server;

package body Nuntius_World.Web is

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

   procedure Serve_Loop is new
     Nuntius.Web.Server
       (Stop         => Stop,
        Sleep_Ms     => Sleep_Ms,
        Log_Info     => Log_Quiet,
        Log_Warn     => Log_Quiet,
        On_Listening => On_Listening,
        Handle       => Handle);

   --  The same loop with a one-second whole-connection budget: what a
   --  dribbling peer meets.
   procedure Serve_Short_Loop is new
     Nuntius.Web.Server
       (Stop               => Stop,
        Sleep_Ms           => Sleep_Ms,
        Log_Info           => Log_Quiet,
        Log_Warn           => Log_Quiet,
        On_Listening       => On_Listening_Short,
        Connection_Seconds => 1,
        Handle             => Handle);

   procedure Serve_Stream_Loop is new
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
   procedure Serve_Gzip_Loop is new
     Nuntius.Web.Server
       (Stop          => Stop,
        Sleep_Ms      => Sleep_Ms,
        Log_Info      => Log_Quiet,
        Log_Warn      => Log_Quiet,
        On_Listening  => On_Listening_Gzip,
        Coding_Policy => Nuntius.Codings.Compress_When_Offered,
        Handle        => Handle);

   procedure Serve_Deflate_Loop is new
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

   procedure Serve (Bind : String; Port : Natural) renames Serve_Loop;
   procedure Serve_Short (Bind : String; Port : Natural)
   renames Serve_Short_Loop;
   procedure Serve_Stream (Bind : String; Port : Natural)
   renames Serve_Stream_Loop;
   procedure Serve_Gzip (Bind : String; Port : Natural)
   renames Serve_Gzip_Loop;
   procedure Serve_Deflate (Bind : String; Port : Natural)
   renames Serve_Deflate_Loop;

   --  A client socket connected to 127.0.0.1:Port; Timeout, when not
   --  zero, bounds every read on it.
   function Dial
     (Port : Natural; Timeout : Duration := 0.0)
      return GNAT.Sockets.Socket_Type
   is
      use GNAT.Sockets;
      Sock : Socket_Type;
   begin
      Create_Socket (Sock);
      if Timeout > 0.0 then
         Set_Socket_Option
           (Sock, Socket_Level, (Name => Receive_Timeout, Timeout => Timeout));
      end if;
      Connect_Socket
        (Sock,
         (Family => Family_Inet,
          Addr   => Inet_Addr ("127.0.0.1"),
          Port   => GNAT.Sockets.Port_Type (Port)));
      return Sock;
   end Dial;

   --  Text's characters as bytes on Sock, in one send.
   procedure Send_Text (Sock : GNAT.Sockets.Socket_Type; Text : String) is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for K in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (K)));
      end loop;
      GNAT.Sockets.Send_Socket (Sock, Buf, Last);
   end Send_Text;

   --  Everything Sock delivers until the peer closes or a read fails,
   --  then the socket closed.
   function Read_To_Close (Sock : GNAT.Sockets.Socket_Type) return String is
      use type Ada.Streams.Stream_Element_Offset;
      Reply : Unbounded_String;
      Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         begin
            GNAT.Sockets.Receive_Socket (Sock, Chunk, Last);
         exception
            when GNAT.Sockets.Socket_Error =>
               exit;
         end;
         exit when Last < Chunk'First;
         for K in 1 .. Last loop
            Append (Reply, Character'Val (Chunk (K)));
         end loop;
      end loop;
      GNAT.Sockets.Close_Socket (Sock);
      return To_String (Reply);
   end Read_To_Close;

   function Exchange
     (Port         : Natural;
      Request_Text : String;
      Half_Head    : Boolean := False;
      Tail         : String := "";
      Tail_Delay   : Duration := 0.0) return String
   is
      Sock : constant GNAT.Sockets.Socket_Type := Dial (Port);
   begin
      Send_Text (Sock, Request_Text);
      if Half_Head then
         GNAT.Sockets.Shutdown_Socket (Sock, GNAT.Sockets.Shut_Write);
      end if;
      if Tail /= "" then
         delay Tail_Delay;
         Send_Text (Sock, Tail);
      end if;
      return Read_To_Close (Sock);
   end Exchange;

   --  Every READ the server makes lands well inside its per-read
   --  timeout, so only a whole-connection budget can end this.  A send
   --  that fails is the server closing on us: the budget ran out.
   function Dribble
     (Port : Natural; Head : String; Count : Positive; Gap : Duration)
      return String
   is
      Sock : constant GNAT.Sockets.Socket_Type := Dial (Port, Timeout => 5.0);
   begin
      Send_Text (Sock, Head);
      for K in 1 .. Count loop
         delay Gap;
         begin
            Send_Text (Sock, "A");
         exception
            when GNAT.Sockets.Socket_Error =>
               exit;
         end;
      end loop;
      return Read_To_Close (Sock);
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

   function Test_Stream_Port return Natural
   is (Cells.Stream_Port);

   function Test_Gzip_Port return Natural
   is (Cells.Gzip_Port);

   function Test_Deflate_Port return Natural
   is (Cells.Deflate_Port);

   --  What follows the head's blank line.
   function Body_Of (Reply : String) return String
   is (Reply (Ada.Strings.Fixed.Index (Reply, CRLF & CRLF) + 4 .. Reply'Last));

   function Get_With (Target, Headers : String) return String
   is ("GET " & Target & " HTTP/1.1" & CRLF & Headers & CRLF);

   Key_24 : constant String := "dGhlIHNhbXBsZSBub25jZQ==";

   --  An upgrade request sent raw, with Extensions as the offer ("" for
   --  none); answers the head up to its blank line.  The socket stays
   --  with the server, which adopted it.
   function Upgrade_Reply (Port : Natural; Extensions : String) return String
   is
      use type Ada.Streams.Stream_Element_Offset;

      Sock  : constant GNAT.Sockets.Socket_Type := Dial (Port, Timeout => 2.0);
      Reply : Unbounded_String;
      One   : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Send_Text
        (Sock,
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
         & CRLF);
      while not Has (To_String (Reply), CRLF & CRLF) loop
         begin
            GNAT.Sockets.Receive_Socket (Sock, One, Last);
         exception
            when GNAT.Sockets.Socket_Error =>
               exit;
         end;
         exit when Last < One'First;
         Append (Reply, Character'Val (One (1)));
      end loop;
      GNAT.Sockets.Close_Socket (Sock);
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

end Nuntius_World.Web;
