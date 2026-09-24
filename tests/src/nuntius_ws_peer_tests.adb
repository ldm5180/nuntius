with AUnit.Assertions; use AUnit.Assertions;

with Ada.Streams;  use Ada.Streams;
with GNAT.Sockets; use GNAT.Sockets;

with Nuntius.Codings;
with Nuntius.Deflate;
with Nuntius.Rfc6455; use Nuntius.Rfc6455;
with Nuntius.Socket_Io;
with Nuntius.Ws.Peer;

with Test_Payloads; use Test_Payloads;

--  The server side of a websocket, over a real loopback pair: the
--  client end speaks through the existing MASKED encoders, which is
--  exactly what a browser sends, and reads back the UNMASKED frames a
--  server must write.  No task and no network: connect and accept on
--  one thread, with 2 s IO timeouts so a wrong answer fails in seconds.

package body Nuntius_Ws_Peer_Tests is

   use AUnit.Test_Cases.Registration;

   Max_Inbound : constant := 512;

   package Peers is new Nuntius.Ws.Peer (Max_Inbound_Bytes => Max_Inbound);

   use type Peers.Pump_Outcome;

   Mask : constant Mask_Key := [16#01#, 16#02#, 16#03#, 16#04#];

   Io_Timeout : constant Duration := 2.0;

   procedure Pair (Browser, Served : out Socket_Type) is
      Listen : Socket_Type;
      From   : Sock_Addr_Type;
      Addr   : Sock_Addr_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Addr := Get_Socket_Name (Listen);
      Create_Socket (Browser);
      Connect_Socket (Browser, (Family_Inet, Loopback_Inet_Addr, Addr.Port));
      Accept_Socket (Listen, Served, From);
      Close_Socket (Listen);
      Set_Socket_Option
        (Browser, Socket_Level, (Receive_Timeout, Timeout => Io_Timeout));
      Set_Socket_Option
        (Browser, Socket_Level, (Send_Timeout, Timeout => Io_Timeout));
      Set_Socket_Option
        (Served, Socket_Level, (Receive_Timeout, Timeout => Io_Timeout));
      Set_Socket_Option
        (Served, Socket_Level, (Send_Timeout, Timeout => Io_Timeout));
   end Pair;

   --  One masked client text frame on the wire.
   procedure Browser_Text (Sock : Socket_Type; Text : String) is
      Buf  : Octets (1 .. Text'Length + 8);
      Last : Natural;
   begin
      Encode_Text (Text, Mask, Buf, Last);
      Nuntius.Socket_Io.Send_All (Sock, Buf (1 .. Last));
   end Browser_Text;

   procedure Browser_Control
     (Sock : Socket_Type; Op : Opcode; Payload : Octets)
   is
      Buf  : Octets (1 .. Payload'Length + 6);
      Last : Natural;
   begin
      Encode_Control (Op, Payload, Mask, Buf, Last);
      Nuntius.Socket_Io.Send_All (Sock, Buf (1 .. Last));
   end Browser_Control;

   --  Read up to N bytes; Got says how many actually arrived.
   procedure Read_Some
     (Sock : Socket_Type; N : Positive; Into : out Octets; Got : out Natural)
   is
      Buf  : Stream_Element_Array (1 .. Stream_Element_Offset (N));
      Have : Stream_Element_Offset := 0;
      Last : Stream_Element_Offset;
   begin
      Into := [others => 0];
      Got := 0;
      while Have < Buf'Last loop
         begin
            Receive_Socket (Sock, Buf (Have + 1 .. Buf'Last), Last);
         exception
            when Socket_Error =>
               exit;
         end;
         exit when Last < Have + 1;
         Have := Last;
      end loop;
      Got := Natural (Have);
      for K in 1 .. Got loop
         Into (Into'First + K - 1) := Octet (Buf (Stream_Element_Offset (K)));
      end loop;
   end Read_Some;

   function Read_Frame (Sock : Socket_Type; N : Positive) return Octets is
      Buf : Octets (1 .. N);
      Got : Natural;
   begin
      Read_Some (Sock, N, Buf, Got);
      return (if Got = N then Buf else Buf (1 .. 0));
   end Read_Frame;

   procedure Test_Pump_Delivers_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Text            : constant String := "{""token"":""x""}";
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Assert (Peers.Is_Open (P), "an adopted peer is open");
      Assert (Peers.Fd (P) >= 0, "and has an fd to poll");
      Browser_Text (Browser, Text);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Message,
         "a whole text frame is a message");
      Assert (Into (1 .. Last) = Text, "the payload is unmasked verbatim");
      Peers.Close (P, 1_000);
      Close_Socket (Browser);
   end Test_Pump_Delivers_Text;

   procedure Test_Pump_Nothing_When_Partial
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Buf             : Octets (1 .. 16);
      N               : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Encode_Text ("hello", Mask, Buf, N);
      Nuntius.Socket_Io.Send_All (Browser, Buf (1 .. 3));
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Nothing,
         "three bytes are not a frame");
      Nuntius.Socket_Io.Send_All (Browser, Buf (4 .. N));
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Message,
         "the rest completes it");
      Assert (Into (1 .. Last) = "hello", "and it says hello");
      Peers.Close (P, 1_000);
      Close_Socket (Browser);
   end Test_Pump_Nothing_When_Partial;

   procedure Test_Two_Frames_Two_Pumps
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      A               : Octets (1 .. 16);
      B               : Octets (1 .. 16);
      Na, Nb          : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Encode_Text ("one", Mask, A, Na);
      Encode_Text ("two", Mask, B, Nb);
      Nuntius.Socket_Io.Send_All (Browser, A (1 .. Na) & B (1 .. Nb));
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Message
         and then Into (1 .. Last) = "one",
         "the first frame of the read");
      Assert
        (Peers.Pump (P, False, Into, Last) = Peers.Message
         and then Into (1 .. Last) = "two",
         "the second comes out of the buffer, with no read");
      Assert
        (Peers.Pump (P, False, Into, Last) = Peers.Nothing,
         "an empty buffer and no read is Nothing at once");
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Nothing,
         "a lying poll costs the receive timeout, never a hang");
      Assert (Peers.Is_Open (P), "and leaves the peer open");
      Peers.Close (P, 1_000);
      Close_Socket (Browser);
   end Test_Two_Frames_Two_Pumps;

   procedure Test_Ping_Is_Ponged (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Browser_Control
        (Browser, Op_Ping, [Character'Pos ('a'), Character'Pos ('b')]);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Nothing,
         "a ping is not a message");
      Assert
        (Read_Frame (Browser, 4)
         = [16#8A#, 2, Character'Pos ('a'), Character'Pos ('b')],
         "the pong comes back unmasked, payload and all");
      Peers.Close (P, 1_000);
      Close_Socket (Browser);
   end Test_Ping_Is_Ponged;

   procedure Test_Close_Is_Echoed (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Tail            : Octets (1 .. 1);
      Got             : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Browser_Control (Browser, Op_Close, Close_Payload (1_000));
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Closed,
         "a close frame closes the peer");
      Assert (not Peers.Is_Open (P), "and leaves it shut");
      Assert
        (Read_Frame (Browser, 4) = [16#88#, 2, 16#03#, 16#E8#],
         "the close is echoed with its payload verbatim");
      Read_Some (Browser, 1, Tail, Got);
      Assert (Got = 0, "and then the socket is gone");
      Close_Socket (Browser);
   end Test_Close_Is_Echoed;

   procedure Test_Oversize_Faults (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Big             : constant String (1 .. Max_Inbound + 1) :=
        [others => 'x'];
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Browser_Text (Browser, Big);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Faulted,
         "one byte past the cap is a fault");
      Assert
        (Read_Frame (Browser, 4) = [16#88#, 2, 16#03#, 16#F1#],
         "answered 1009, too big");
      Close_Socket (Browser);
   end Test_Oversize_Faults;

   procedure Test_Binary_Faults (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      --  FIN + binary, MASK + len 1, mask, one byte.
      Wire            : constant Octets :=
        [16#82#, 16#81#, 1, 2, 3, 4, 16#61# xor 1];
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Nuntius.Socket_Io.Send_All (Browser, Wire);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Faulted,
         "a binary frame is a fault");
      Assert
        (Read_Frame (Browser, 4) = [16#88#, 2, 16#03#, 16#EB#],
         "answered 1003, unacceptable data");
      Close_Socket (Browser);
   end Test_Binary_Faults;

   --  RSV1 set on a text frame: no extension was agreed on this peer.
   procedure Test_Rsv1_Faults (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      --  FIN + RSV1 + text, MASK + len 1, mask, one byte.
      Wire            : constant Octets :=
        [16#C1#, 16#81#, 1, 2, 3, 4, 16#61# xor 1];
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Nuntius.Socket_Io.Send_All (Browser, Wire);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Faulted,
         "an RSV1 frame is a fault");
      Assert
        (Read_Frame (Browser, 4) = [16#88#, 2, 16#03#, 16#EA#],
         "answered 1002, a protocol error: nothing was agreed");
      Close_Socket (Browser);
   end Test_Rsv1_Faults;

   --  One masked client frame, Lead its first byte, with an octet
   --  payload under 126 bytes: what a browser sends for a packed
   --  message (Lead 16#C1#).
   procedure Browser_Frame (Sock : Socket_Type; Lead : Octet; Payload : Octets)
   is
      Wire : Octets (1 .. Payload'Length + 6);
   begin
      Wire (1) := Lead;
      Wire (2) := 16#80# or Octet (Payload'Length);
      for K in 0 .. 3 loop
         Wire (3 + K) := Mask (K);
      end loop;
      for K in Payload'Range loop
         Wire (6 + K - Payload'First + 1) :=
           Payload (K) xor Mask ((K - Payload'First) mod 4);
      end loop;
      Nuntius.Socket_Io.Send_All (Sock, Wire);
   end Browser_Frame;

   function Bytes_Of (Text : String) return Octets is
      B : Octets (1 .. Text'Length);
   begin
      for K in B'Range loop
         B (K) := Character'Pos (Text (Text'First + K - 1));
      end loop;
      return B;
   end Bytes_Of;

   --  D12: a deflated peer sends the packed bytes with RSV1 set.
   procedure Test_Send_Packed (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Ok              : Boolean;
      Text            : constant String := Json_Like (60);
      Packed          : constant Octets := Nuntius.Deflate.Pack (Text);
   begin
      Assert (Packed'Length in 1 .. 125, "the fixture packs short");
      Pair (Browser, Served);
      Peers.Adopt (P, Served, Nuntius.Codings.Deflated);
      Peers.Send_Packed (P, Text, Packed, Ok);
      Assert (Ok, "the send succeeds");
      Assert
        (Read_Frame (Browser, 2) = [16#C1#, Octet (Packed'Length)],
         "FIN + RSV1 + text, the packed length");
      Assert (Read_Frame (Browser, Packed'Length) = Packed, "then the bytes");
      Close_Socket (Browser);
   end Test_Send_Packed;

   --  A plain peer gets the text, whatever was packed for the others;
   --  a deflated peer gets the text when nothing was packed.
   procedure Test_Send_Packed_Falls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      Plain, Packing  : Peers.Peer;
      Ok              : Boolean;
      Text            : constant String := Json_Like (60);
   begin
      Pair (Browser, Served);
      Peers.Adopt (Plain, Served);
      Peers.Send_Packed (Plain, Text, Nuntius.Deflate.Pack (Text), Ok);
      Assert (Ok, "the plain send succeeds");
      Assert
        (Read_Frame (Browser, 4)
         = [16#81#,
            126,
            Octet (Text'Length / 256),
            Octet (Text'Length mod 256)],
         "a plain peer gets a plain frame");
      Assert (Read_Frame (Browser, Text'Length) = Bytes_Of (Text), "the text");
      Close_Socket (Browser);

      Pair (Browser, Served);
      Peers.Adopt (Packing, Served, Nuntius.Codings.Deflated);
      Peers.Send_Packed (Packing, "hi", [], Ok);
      Assert
        (Read_Frame (Browser, 4)
         = [16#81#, 2, Character'Pos ('h'), Character'Pos ('i')],
         "nothing packed goes plain, RSV1 clear");
      Close_Socket (Browser);
   end Test_Send_Packed_Falls_Back;

   --  RSV1 is per message: a deflated peer reads packed and plain text.
   procedure Test_Packed_Inbound (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Text            : constant String := Json_Like (20) (1 .. Max_Inbound);
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served, Nuntius.Codings.Deflated);
      Browser_Frame (Browser, 16#C1#, Nuntius.Deflate.Pack (Text));
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Message,
         "a packed message is a message");
      Assert (Into (1 .. Last) = Text, "inflated to exactly the cap");
      Browser_Text (Browser, "{""token"":""x""}");
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Message
         and then Into (1 .. Last) = "{""token"":""x""}",
         "a plain one still reads");
      Close_Socket (Browser);
   end Test_Packed_Inbound;

   --  D9: what a packed frame inflates to is capped, and a stream zlib
   --  refuses, or RSV1 on a control frame, closes the peer.
   procedure Test_Packed_Inbound_Faults
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Zeros           : constant String (1 .. 4_096) := [others => '0'];

      procedure Expect (Lead : Octet; Payload : Octets; Code : Octets) is
      begin
         Pair (Browser, Served);
         Peers.Adopt (P, Served, Nuntius.Codings.Deflated);
         Browser_Frame (Browser, Lead, Payload);
         Assert
           (Peers.Pump (P, True, Into, Last) = Peers.Faulted,
            "the frame is a fault");
         Assert
           (Read_Frame (Browser, 4) = [16#88#, 2] & Code,
            "answered with the expected code");
         Close_Socket (Browser);
      end Expect;
   begin
      --  1009: 4 KB of zeros packs into a small frame.
      Expect (16#C1#, Nuntius.Deflate.Pack (Zeros), [16#03#, 16#F1#]);
      --  1007: a reserved deflate block type.
      Expect (16#C1#, [16#FF#, 16#FF#], [16#03#, 16#EF#]);
      --  1002: RSV1 on a ping (RFC 7692 6.1: data frames only).
      Expect (16#C9#, [], [16#03#, 16#EA#]);
   end Test_Packed_Inbound_Faults;

   procedure Test_Eof_Is_Closed (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Close_Socket (Browser);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Closed,
         "the peer hanging up is a close");
      Assert (not Peers.Is_Open (P), "and shuts the peer");
   end Test_Eof_Is_Closed;

   procedure Test_Send_Text_Unmasked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Ok              : Boolean;
      Big             : constant String (1 .. 70_000) := [others => 'z'];
      Head            : Octets (1 .. 10);
      Got             : Natural;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Peers.Send_Text (P, "hi", Ok);
      Assert (Ok, "a short send succeeds");
      Assert
        (Read_Frame (Browser, 4)
         = [16#81#, 2, Character'Pos ('h'), Character'Pos ('i')],
         "a server frame is never masked");

      Peers.Send_Text (P, Big, Ok);
      Assert (Ok, "a 70_000-byte document goes out whole");
      Read_Some (Browser, 10, Head, Got);
      Assert (Got = 10, "the 64-bit length form");
      Assert
        (Head = [16#81#, 16#7F#, 0, 0, 0, 0, 0, 1, 16#11#, 16#70#],
         "127 then 70_000 big-endian");
      declare
         Body_Bytes : Octets (1 .. Big'Length);
         Have       : Natural;
      begin
         Read_Some (Browser, Big'Length, Body_Bytes, Have);
         Assert (Have = Big'Length, "every payload byte arrives");
         Assert
           ((for all B of Body_Bytes => B = Character'Pos ('z')),
            "and arrives verbatim");
      end;
      Peers.Close (P, 1_000);
      Close_Socket (Browser);
   end Test_Send_Text_Unmasked;

   procedure Test_Send_After_Closed_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Browser, Served : Socket_Type;
      P               : Peers.Peer;
      Into            : String (1 .. Max_Inbound);
      Last            : Natural;
      Ok              : Boolean;
   begin
      Pair (Browser, Served);
      Peers.Adopt (P, Served);
      Close_Socket (Browser);
      Assert
        (Peers.Pump (P, True, Into, Last) = Peers.Closed, "the peer is gone");
      Peers.Send_Text (P, "anyone there", Ok);
      Assert (not Ok, "a send to a peer known closed fails");
   end Test_Send_After_Closed_Fails;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Pump_Delivers_Text'Access,
         "Pump delivers a whole text frame");
      Register_Routine
        (T,
         Test_Pump_Nothing_When_Partial'Access,
         "Pump waits for a partial frame");
      Register_Routine
        (T,
         Test_Two_Frames_Two_Pumps'Access,
         "Pump drains its buffer before it reads");
      Register_Routine
        (T, Test_Ping_Is_Ponged'Access, "a ping is answered with a pong");
      Register_Routine
        (T,
         Test_Close_Is_Echoed'Access,
         "a close is echoed and the peer shut");
      Register_Routine
        (T, Test_Oversize_Faults'Access, "an oversize frame is answered 1009");
      Register_Routine
        (T, Test_Binary_Faults'Access, "a binary frame is answered 1003");
      Register_Routine (T, Test_Eof_Is_Closed'Access, "EOF closes the peer");
      Register_Routine
        (T, Test_Rsv1_Faults'Access, "an RSV1 frame on a plain peer faults");
      Register_Routine
        (T, Test_Send_Packed'Access, "a deflated peer sends RSV1 frames");
      Register_Routine
        (T,
         Test_Send_Packed_Falls_Back'Access,
         "Send_Packed goes plain on a plain peer or with nothing packed");
      Register_Routine
        (T,
         Test_Packed_Inbound'Access,
         "a deflated peer reads packed and plain messages");
      Register_Routine
        (T,
         Test_Packed_Inbound_Faults'Access,
         "a deflated peer caps, refuses corrupt, and 1002s control RSV1");
      Register_Routine
        (T, Test_Send_Text_Unmasked'Access, "server frames go out unmasked");
      Register_Routine
        (T,
         Test_Send_After_Closed_Fails'Access,
         "a send to a closed peer answers Ok False");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Ws.Peer (the server side of a socket)");
   end Name;

end Nuntius_Ws_Peer_Tests;
