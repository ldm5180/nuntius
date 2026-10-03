with Nuntius.Codings;

with GNAT.Sockets;

with Test_Payloads;

--  The serving loop on loopback, as the suite and the features stand it
--  up: one protected cell block every handler writes and every test
--  reads, five instances of Nuntius.Web.Server over one echo policy,
--  and the dialers that talk to them.  Every server binds port 0 and
--  reports the port it got; nothing here reaches past 127.0.0.1.

package Nuntius_World.Web is

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

   --  A body worth compressing: 2,280 bytes of repetitive JSON, which
   --  the echo policy serves on /big.
   Big_Json : constant String := Test_Payloads.Json_Like (60);

   --  The header a client sends to take any coding the loop offers.
   Accepting : constant String := "Accept-Encoding: gzip, deflate, br" & CRLF;

   --  The serving loop with the echo policy, and its variants: a
   --  one-second whole-connection budget, the /api/stream upgrade taken
   --  and adopted, and the codings applied when offered.
   procedure Serve (Bind : String; Port : Natural);
   procedure Serve_Short (Bind : String; Port : Natural);
   procedure Serve_Stream (Bind : String; Port : Natural);
   procedure Serve_Gzip (Bind : String; Port : Natural);
   procedure Serve_Deflate (Bind : String; Port : Natural);

   --  One serial exchange: connect, send Request_Text, read to the
   --  server's Connection: close.  Half_Head sends without the blank
   --  line and closes our write side instead; Tail is sent after
   --  Tail_Delay, so a body can arrive in a second write.
   function Exchange
     (Port         : Natural;
      Request_Text : String;
      Half_Head    : Boolean := False;
      Tail         : String := "";
      Tail_Delay   : Duration := 0.0) return String;

   --  A head, then Count single bytes Gap apart; answers whatever the
   --  server sent back.
   function Dribble
     (Port : Natural; Head : String; Count : Positive; Gap : Duration)
      return String;

   --  The port Get reports, once it reports one; 0 after five seconds.
   function Await_Port
     (Get : not null access function return Natural) return Natural;

   --  The bound port of each serving loop, 0 until it listens.
   function Test_Port return Natural;
   function Test_Short_Port return Natural;
   function Test_Stream_Port return Natural;
   function Test_Gzip_Port return Natural;
   function Test_Deflate_Port return Natural;

   --  What follows the head's blank line.
   function Body_Of (Reply : String) return String;

   --  A GET of Target carrying Headers (each ending in CRLF).
   function Get_With (Target, Headers : String) return String;

   --  An upgrade request to Target, with Extensions as the offer ("" for
   --  none); answers the head up to its blank line.  The socket stays
   --  with the server, which adopted it.
   function Upgrade_Reply
     (Port : Natural; Extensions : String; Target : String := "/api/stream")
      return String;

   --  Whether the loop has handed a socket to Adopt, waiting up to two
   --  seconds: the 101 can reach the client before Adopt runs.
   function Await_Adoption return Boolean;

   --  Close the socket the server handed over, if it handed one; never
   --  waits, so an After hook can call it for every scenario.
   procedure Drop_Held;

   --  Drop the socket the server handed over, so the next upgrade's
   --  adoption is its own.
   procedure Release_Held;

   --  Which serving loop a feature stands up.
   type Loop_Kind is
     (Plain_Loop, Short_Loop, Stream_Loop, Gzip_Loop, Deflate_Loop);

   --  Kind's loop on a task of its own, and the port it bound; 0 when it
   --  never listened.  Stop_Loops is what ends it.
   procedure Start_Loop (Kind : Loop_Kind; Port : out Natural);

   --  Stop every loop Start_Loop started and wait for each to end, so
   --  the next scenario's Cells.Reset finds no task still serving.
   procedure Stop_Loops;

end Nuntius_World.Web;
