with AUnit.Assertions; use AUnit.Assertions;

with Ada.Streams;       use Ada.Streams;
with Ada.Strings;       use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with GNAT.Sockets;      use GNAT.Sockets;

with Nuntius.Ws.Native_Client;

--  The native RFC 6455 adapter.  Offline behavior first (unconnected /
--  refused-dial, no server), then a full loopback exchange against a tiny
--  in-process GNAT.Sockets websocket server: the upgrade handshake, a
--  single text message, a fragmented message reassembled, and an auto-pong
--  to a ping -- all over ws:// on a loopback port, no network.

package body Nuntius_Ws_Native_Client_Tests is

   use AUnit.Test_Cases.Registration;

   --  Fail fast rather than block a suite: tiny idle/poll so a hung read
   --  ends in a couple of seconds.
   package Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 8,
        Max_Frame_Bytes => 256,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   ------------------------------------------------------------------
   --  Offline cases
   ------------------------------------------------------------------

   procedure Test_Unconnected (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Ws.Client;
      Buf  : String (1 .. 64);
      Last : Natural;
      Ok   : Boolean;
   begin
      Ws.Send_Text (C, "hello", Ok);
      Assert (not Ok, "send before any dial reports Ok = False");
      Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "receive before any dial reports Ok = False");
      Assert (Last = 0, "receive before any dial delivers nothing");
      Ws.Close (C);  --  harmless no-op
   end Test_Unconnected;

   procedure Test_Refused_Dial (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C  : Ws.Client;
      Ok : Boolean;
   begin
      Ws.Connect (C, "ws://127.0.0.1:9/", Ok);
      Assert (not Ok, "a refused dial reports Ok = False");
      Ws.Connect (C, "ws://127.0.0.1:9/", Ok);
      Assert (not Ok, "a refused redial reports Ok = False, reusable");
      Ws.Close (C);
   end Test_Refused_Dial;

   ------------------------------------------------------------------
   --  Loopback server: a scripted websocket peer
   ------------------------------------------------------------------

   --  Cross-task result: did the client's auto-pong reach the server?
   protected Result is
      procedure Set_Pong (V : Boolean);
      function Pong_Seen return Boolean;
   private
      Seen : Boolean := False;
   end Result;

   protected body Result is
      procedure Set_Pong (V : Boolean) is
      begin
         Seen := V;
      end Set_Pong;
      function Pong_Seen return Boolean
      is (Seen);
   end Result;

   procedure Send_Bytes (S : Socket_Type; Bytes : Stream_Element_Array) is
      Off  : Stream_Element_Offset := Bytes'First;
      Last : Stream_Element_Offset;
   begin
      while Off <= Bytes'Last loop
         Send_Socket (S, Bytes (Off .. Bytes'Last), Last);
         exit when Last < Off;
         Off := Last + 1;
      end loop;
   end Send_Bytes;

   task type Server is
      entry Serve (Listener : Socket_Type);
   end Server;

   task body Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;

      Accept_Socket (Listen, Peer, From);

      --  Read the client's upgrade request up to the blank line.
      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;  --  enough to have crossed CRLFCRLF
         end loop;
      end;

      --  101 response, then a single message, a fragmented message, a ping.
      Send_Bytes
        (Peer,
         [Character'Pos ('H'),
          Character'Pos ('T'),
          Character'Pos ('T'),
          Character'Pos ('P'),
          Character'Pos ('/'),
          Character'Pos ('1'),
          Character'Pos ('.'),
          Character'Pos ('1'),
          Character'Pos (' '),
          Character'Pos ('1'),
          Character'Pos ('0'),
          Character'Pos ('1'),
          13,
          10,
          13,
          10]);

      --  Unmasked server frames (RFC 6455 5.1):
      --  "hello"
      Send_Bytes
        (Peer,
         [16#81#,
          16#05#,
          Character'Pos ('h'),
          Character'Pos ('e'),
          Character'Pos ('l'),
          Character'Pos ('l'),
          Character'Pos ('o')]);
      --  fragmented "foo" (text, not FIN) + "bar" (continuation, FIN)
      Send_Bytes
        (Peer,
         [16#01#,
          16#03#,
          Character'Pos ('f'),
          Character'Pos ('o'),
          Character'Pos ('o')]);
      Send_Bytes
        (Peer,
         [16#80#,
          16#03#,
          Character'Pos ('b'),
          Character'Pos ('a'),
          Character'Pos ('r')]);
      --  empty ping
      Send_Bytes (Peer, [16#89#, 16#00#]);

      --  Wait for the client's masked pong (opcode 0x8A).
      declare
         Buf  : Stream_Element_Array (1 .. 64);
         Last : Stream_Element_Offset;
      begin
         Receive_Socket (Peer, Buf, Last);
         Result.Set_Pong
           (Last >= Buf'First and then (Buf (Buf'First) and 16#0F#) = 16#0A#);
      exception
         when others =>
            Result.Set_Pong (False);
      end;

      --  Close, then hang up.
      Send_Bytes (Peer, [16#88#, 16#00#]);
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Result.Set_Pong (False);
   end Server;

   procedure Test_Loopback (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Addr   : Sock_Addr_Type;
      Srv    : Server;
      C      : Ws.Client;
      Buf    : String (1 .. 256);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Addr := Get_Socket_Name (Listen);
      Port := Addr.Port;

      Srv.Serve (Listen);

      Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/v1",
         Ok);
      Assert (Ok, "handshake completes over loopback");

      Ws.Receive (C, Buf, Last, Ok);
      Assert (Ok and then Buf (1 .. Last) = "hello", "first message is hello");

      Ws.Receive (C, Buf, Last, Ok);
      Assert
        (Ok and then Buf (1 .. Last) = "foobar",
         "fragmented message reassembles to foobar");

      --  After the ping (auto-ponged) the server closes: next receive is
      --  reconnect-worthy.
      Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "peer close reports Ok = False");

      Ws.Close (C);
      Assert (Result.Pong_Seen, "client auto-ponged the server's ping");
   end Test_Loopback;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Unconnected'Access, "unconnected client refuses politely");
      Register_Routine
        (T, Test_Refused_Dial'Access, "refused dial is Ok = False, reusable");
      Register_Routine
        (T,
         Test_Loopback'Access,
         "loopback: handshake, message, fragmentation, auto-pong");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return
        AUnit.Format ("Nuntius.Ws.Native_Client (RFC 6455 websocket adapter)");
   end Name;

end Nuntius_Ws_Native_Client_Tests;
