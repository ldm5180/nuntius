--  The RFC 6455 websocket frame wire format, as pure byte arithmetic in
--  the SPARK core -- the decode/encode half of a hand-rolled websocket
--  adapter, proved free of runtime errors rather than trusted.  Decode
--  reads one frame header at the front of a buffer (the three length
--  forms, masked or not); Get_Text lifts and unmasks its payload into a
--  String; Encode_Text/Encode_Control build a client (masked) frame;
--  Base64 and Client_Handshake supply the opening HTTP upgrade.  No IO,
--  no heap, no exceptions -- every outcome is a typed status.  The socket,
--  the mask-key randomness, and the reassembly/lifecycle state all live in
--  the shell adapter (Nuntius.Ws.Native_Client).

package Nuntius.Rfc6455
  with SPARK_Mode
is

   type Octet is mod 2**8;
   type Octets is array (Positive range <>) of Octet;

   --  The frame opcodes we distinguish (RFC 6455 section 5.2).  Any other
   --  4-bit value is a reserved opcode and decodes Invalid.
   type Opcode is
     (Op_Continuation, Op_Text, Op_Binary, Op_Close, Op_Ping, Op_Pong);

   --  Ready: the header at the front of the buffer decoded; Header_Bytes
   --  and Payload_Bytes are set and the caller checks whether the whole
   --  payload is present (and within its size cap).  Need_More: fewer bytes
   --  than the header needs.  Invalid: a reserved bit or opcode -- a
   --  protocol violation, reconnect-worthy.
   type Scan_Status is (Need_More, Ready, Invalid);

   Max_Header_Bytes : constant := 14;  --  2 + 8 extended length + 4 mask

   subtype Header_Count is Natural range 0 .. Max_Header_Bytes;

   type Mask_Key is array (0 .. 3) of Octet;

   No_Mask : constant Mask_Key := [others => 0];

   type Header is record
      Status        : Scan_Status := Need_More;
      Op            : Opcode := Op_Continuation;
      Fin           : Boolean := False;
      Masked        : Boolean := False;
      Header_Bytes  : Header_Count := 0;
      Payload_Bytes : Natural := 0;
      Mask          : Mask_Key := No_Mask;
   end record;

   --  Decode the frame header at Buffer's front.  Never raises.
   function Decode (Buffer : Octets) return Header
   with
     Post =>
       (if Decode'Result.Status = Ready
        then
          Decode'Result.Header_Bytes in 2 .. Max_Header_Bytes
          and then Decode'Result.Header_Bytes <= Buffer'Length);

   --  Lift the (unmasked) payload of a Ready frame into Into (1 .. Last).
   --  The caller must have confirmed the whole frame is present.
   procedure Get_Text
     (Buffer : Octets; H : Header; Into : out String; Last : out Natural)
   with
     Pre  =>
       H.Status = Ready
       and then Into'First = 1
       and then H.Payload_Bytes <= Into'Length
       and then H.Header_Bytes <= Buffer'Length
       and then H.Payload_Bytes <= Buffer'Length - H.Header_Bytes,
     Post => Last = H.Payload_Bytes;

   --  Build a single, final, masked client text frame in Into (1 .. Last).
   procedure Encode_Text
     (Text : String; Mask : Mask_Key; Into : out Octets; Last : out Natural)
   with
     Pre  =>
       Into'First = 1
       and then Text'Length <= 65_535
       and then Into'Length >= Text'Length + 8,
     Post => Last <= Into'Length;

   --  Build a masked control frame (Ping/Pong/Close; payload <= 125 bytes).
   procedure Encode_Control
     (Op      : Opcode;
      Payload : Octets;
      Mask    : Mask_Key;
      Into    : out Octets;
      Last    : out Natural)
   with
     Pre  =>
       Into'First = 1
       and then Op in Op_Close | Op_Ping | Op_Pong
       and then Payload'Length <= 125
       and then Into'Length >= Payload'Length + 6,
     Post => Last <= Into'Length;

   --  Standard base64 (RFC 4648) -- for the 16-byte Sec-WebSocket-Key.
   function Base64 (Data : Octets) return String
   with
     Pre  => Data'Length <= 1_024,
     Post => Base64'Result'Length = 4 * ((Data'Length + 2) / 3);

   --  The opening client handshake request line + headers (CRLF-framed,
   --  terminated by a blank line).  No compression is offered.
   function Client_Handshake (Host, Path, Key : String) return String
   with
     Pre =>
       Host'Length <= 255
       and then Path'Length <= 255
       and then Key'Length <= 64;

end Nuntius.Rfc6455;
