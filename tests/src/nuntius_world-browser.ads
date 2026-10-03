with Ada.Strings.Unbounded;

with GNAT.Sockets;

with Nuntius.Codings;

with Nuntius.Rfc6455;
with Nuntius.Ws.Peer;

--  The browser end of a websocket over a loopback pair: a connected
--  client socket and the served socket a peer adopts, with the MASKED
--  frames a browser sends and a reader for the UNMASKED ones a server
--  writes back.  No task: connect and accept on one thread, with 2 s IO
--  timeouts so a wrong answer fails in seconds.

package Nuntius_World.Browser is

   use Nuntius.Rfc6455;

   Max_Inbound : constant := 512;

   package Peers is new Nuntius.Ws.Peer (Max_Inbound_Bytes => Max_Inbound);

   Mask : constant Mask_Key := [16#01#, 16#02#, 16#03#, 16#04#];

   Io_Timeout : constant Duration := 2.0;

   --  A connected loopback pair: Browser dials, Served is accepted.
   procedure Pair (Browser, Served : out GNAT.Sockets.Socket_Type);

   --  One masked client text frame on the wire.
   procedure Browser_Text (Sock : GNAT.Sockets.Socket_Type; Text : String);

   --  One masked client control frame.
   procedure Browser_Control
     (Sock : GNAT.Sockets.Socket_Type; Op : Opcode; Payload : Octets);

   --  Read up to N bytes; Got says how many actually arrived.
   procedure Read_Some
     (Sock : GNAT.Sockets.Socket_Type;
      N    : Positive;
      Into : out Octets;
      Got  : out Natural);

   --  Exactly N bytes, or none when fewer arrived.
   function Read_Frame
     (Sock : GNAT.Sockets.Socket_Type; N : Positive) return Octets;

   --  One masked client frame, Lead its first byte, with an octet
   --  payload under 126 bytes: what a browser sends for a packed
   --  message (Lead 16#C1#).
   procedure Browser_Frame
     (Sock : GNAT.Sockets.Socket_Type; Lead : Octet; Payload : Octets);

   --  Text's characters as octets.
   function Bytes_Of (Text : String) return Octets;

   --  The scenario's pair: the browser socket, and the peer that adopted
   --  the served end with Coding.  Open_Pair drops any pair before it.
   Browser_Sock : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   The_Peer     : Peers.Peer;

   procedure Open_Pair (Coding : Nuntius.Codings.Message_Coding);

   --  Close both ends, whatever state they are in.
   procedure Close_Pair;

   --  One server frame off Sock, of any length form: its first byte,
   --  whether its mask bit was set, and its payload.  Ok False when the
   --  socket closed or ran out before the frame did.
   procedure Read_Server_Frame
     (Sock    : GNAT.Sockets.Socket_Type;
      Lead    : out Octet;
      Masked  : out Boolean;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Ok      : out Boolean);

end Nuntius_World.Browser;
