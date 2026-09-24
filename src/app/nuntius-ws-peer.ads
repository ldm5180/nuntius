with GNAT.Sockets;

with Nuntius.Codings;
with Nuntius.Rfc6455;

--  The SERVER side of a websocket: a socket the HTTP loop upgraded and
--  handed over.  It is not Native_Client turned around -- the client
--  dials, masks its sends and blocks in Receive, while the peer is
--  adopted, sends unmasked (RFC 6455 5.1) and reads only when the
--  caller's poll says it may.  They share Rfc6455 and Socket_Io and
--  nothing else.
--
--  Inbound is deliberately tiny: whole frames already buffered are
--  decoded FIRST, without a read, so one poll wake drains everything
--  that arrived with it, and anything past Max_Inbound_Bytes is a
--  fault rather than a buffer to grow.

generic
   Max_Inbound_Bytes : Positive;
package Nuntius.Ws.Peer is

   type Peer is limited private;

   --  Take over an upgraded socket.  Coding is what its 101 agreed:
   --  Deflated lets a text frame arrive packed, and lets Send_Packed
   --  send packed.
   procedure Adopt
     (Self   : in out Peer;
      Sock   : GNAT.Sockets.Socket_Type;
      Coding : Nuntius.Codings.Message_Coding := Nuntius.Codings.Plain);

   function Is_Open (Self : Peer) return Boolean;

   --  The fd the caller polls; negative when not open.
   function Fd (Self : Peer) return Integer;

   type Pump_Outcome is (Nothing, Message, Closed, Faulted);

   --  Readable is the caller's poll verdict: False means "decode what
   --  is buffered, read nothing".  The first TEXT frame is the
   --  Message, inflated when it arrived packed on a Deflated peer; a
   --  ping is ponged, a pong dropped, a close echoed then Closed; a
   --  binary, continuation, reserved or oversize frame is answered
   --  with a close and Faulted -- RSV1 where nothing agreed it 1002, a
   --  packed text inflating past Max_Inbound_Bytes 1009, one zlib
   --  refuses 1007.  Closed and Faulted both
   --  leave Is_Open False.  A read that times out is Nothing, not a
   --  close: a poll may lie, and a lying poll must cost time, not the
   --  connection.
   function Pump
     (Self     : in out Peer;
      Readable : Boolean;
      Into     : out String;
      Last     : out Natural) return Pump_Outcome
   with Pre => Into'First = 1 and then Into'Length >= Max_Inbound_Bytes;

   --  One unmasked text frame: the header, then Text on the wire
   --  verbatim, so a multi-megabyte document is never copied.
   procedure Send_Text (Self : in out Peer; Text : String; Ok : out Boolean);

   --  One text message: Packed, RSV1 set, when this peer agreed
   --  permessage-deflate and Packed is not empty; otherwise Text, as
   --  Send_Text sends it.  Packed is Nuntius.Deflate.Pack (Text), made
   --  once by the caller for every peer it writes to.
   procedure Send_Packed
     (Self   : in out Peer;
      Text   : String;
      Packed : Nuntius.Rfc6455.Octets;
      Ok     : out Boolean);

   --  A close frame, then the socket; a no-op when not open.
   procedure Close (Self : in out Peer; Code : Nuntius.Rfc6455.Close_Code);

private

   --  Typed, not a named number: a generic formal is not static.
   Accum_Bytes : constant Positive :=
     Max_Inbound_Bytes + Nuntius.Rfc6455.Max_Header_Bytes;

   type Peer is limited record
      Sock   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Open   : Boolean := False;
      Coding : Nuntius.Codings.Message_Coding := Nuntius.Codings.Plain;
      Accum  : Nuntius.Rfc6455.Octets (1 .. Accum_Bytes) := [others => 0];
      Len    : Natural := 0;
   end record;

end Nuntius.Ws.Peer;
