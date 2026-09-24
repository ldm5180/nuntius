with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Codings;
with Nuntius.Rfc6455; use Nuntius.Rfc6455;

--  The pure RFC 6455 frame codec: header decode over known byte vectors
--  (the three length forms, masked and unmasked, control opcodes, short
--  buffers, protocol violations) and the client-frame encode round-trip.
--  The wire arithmetic is also carried by proof (Nuntius.Rfc6455's Posts);
--  these vectors pin the concrete byte layouts.

package body Nuntius_Rfc6455_Tests is

   use AUnit.Test_Cases.Registration;

   procedure Test_Decode_Unmasked_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  FIN + text, len 2, "hi"
      Wire : constant Octets := [16#81#, 16#02#, 16#68#, 16#69#];
      H    : constant Header := Decode (Wire);
      Buf  : String (1 .. 8);
      Last : Natural;
   begin
      Assert (H.Status = Ready, "complete unmasked frame decodes Ready");
      Assert (H.Op = Op_Text, "opcode is text");
      Assert (H.Fin, "FIN is set");
      Assert (not H.Masked, "server frame is unmasked");
      Assert (H.Header_Bytes = 2, "2-byte header");
      Assert (H.Payload_Bytes = 2, "payload length 2");
      Get_Text (Wire, H, Buf, Last);
      Assert (Buf (1 .. Last) = "hi", "payload extracts to hi");
   end Test_Decode_Unmasked_Text;

   procedure Test_Decode_Masked_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  FIN + text, MASK + len 2, mask 01 02 03 04, "hi" xored
      Wire : constant Octets :=
        [16#81#,
         16#82#,
         16#01#,
         16#02#,
         16#03#,
         16#04#,
         16#68# xor 16#01#,
         16#69# xor 16#02#];
      H    : constant Header := Decode (Wire);
      Buf  : String (1 .. 8);
      Last : Natural;
   begin
      Assert (H.Status = Ready, "masked frame decodes Ready");
      Assert (H.Masked, "mask bit set");
      Assert (H.Header_Bytes = 6, "2 + 4 mask = 6-byte header");
      Assert (H.Payload_Bytes = 2, "payload length 2");
      Get_Text (Wire, H, Buf, Last);
      Assert (Buf (1 .. Last) = "hi", "masked payload unmasks to hi");
   end Test_Decode_Masked_Text;

   procedure Test_Decode_16bit_Length
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  FIN + text, len marker 126, extended length 0x00C8 = 200
      Wire : Octets (1 .. 4 + 200) := [others => 16#41#];
   begin
      Wire (1) := 16#81#;
      Wire (2) := 126;
      Wire (3) := 16#00#;
      Wire (4) := 16#C8#;
      declare
         H : constant Header := Decode (Wire);
      begin
         Assert (H.Status = Ready, "16-bit length decodes Ready");
         Assert (H.Header_Bytes = 4, "2 + 2 extended-length = 4-byte header");
         Assert (H.Payload_Bytes = 200, "extended payload length 200");
      end;
   end Test_Decode_16bit_Length;

   procedure Test_Decode_Control_Opcodes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Ping  : constant Octets := [16#89#, 16#00#];
      Close : constant Octets := [16#88#, 16#00#];
      Pong  : constant Octets := [16#8A#, 16#00#];
      Hp    : constant Header := Decode (Ping);
      Hc    : constant Header := Decode (Close);
      Ho    : constant Header := Decode (Pong);
   begin
      Assert (Hp.Status = Ready and then Hp.Op = Op_Ping, "ping opcode");
      Assert (Hc.Status = Ready and then Hc.Op = Op_Close, "close opcode");
      Assert (Ho.Status = Ready and then Ho.Op = Op_Pong, "pong opcode");
   end Test_Decode_Control_Opcodes;

   procedure Test_Need_More (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty       : constant Octets (1 .. 0) := [others => 0];
      One_Byte    : constant Octets := [1 => 16#81#];
      Len_Missing : constant Octets :=
        [16#81#, 126, 16#00#];  -- one length byte short
   begin
      Assert (Decode (Empty).Status = Need_More, "empty buffer needs more");
      Assert (Decode (One_Byte).Status = Need_More, "one byte needs more");
      Assert
        (Decode (Len_Missing).Status = Need_More,
         "truncated extended length needs more");
   end Test_Need_More;

   --  RSV1 is permessage-deflate's bit (RFC 7692 6): Decode reports it
   --  and the adapter, which knows what was agreed, judges it.  RSV2
   --  and RSV3 belong to no extension this crate speaks.
   procedure Test_Invalid_Rsv (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Rsv1 : constant Header := Decode ([16#C1#, 16#00#]);
   begin
      Assert (Rsv1.Status = Ready, "RSV1 decodes");
      Assert (Rsv1.Rsv1, "and says so");
      Assert (Rsv1.Op = Op_Text and then Rsv1.Fin, "a final text frame");
      Assert
        (not Decode ([16#81#, 16#00#]).Rsv1, "a plain frame has RSV1 clear");
      Assert
        (Decode ([16#A1#, 16#00#]).Status = Invalid, "RSV2 set is Invalid");
      Assert
        (Decode ([16#91#, 16#00#]).Status = Invalid, "RSV3 set is Invalid");
   end Test_Invalid_Rsv;

   --  A packed message's frame carries RSV1; nothing else changes.
   procedure Test_Server_Header_Deflated
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Into : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      Server_Header (Op_Text, 10, Into, Last, Nuntius.Codings.Deflated);
      Assert (Last = 2, "a short length needs two bytes");
      Assert
        (Into (1 .. 2) = [16#C1#, 16#0A#], "FIN + RSV1 + text, length 10");
      Assert (Decode (Into (1 .. Last)).Rsv1, "and reads back as packed");
      Server_Header (Op_Text, 10, Into, Last, Nuntius.Codings.Plain);
      Assert (Into (1) = 16#81#, "plain is today's byte");
   end Test_Server_Header_Deflated;

   procedure Test_Encode_Text_Roundtrip
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Mask : constant Mask_Key := [16#DE#, 16#AD#, 16#BE#, 16#EF#];
      Wire : Octets (1 .. 64);
      Last : Natural;
   begin
      Encode_Text ("hello world", Mask, Wire, Last);
      declare
         Frame : constant Octets := Wire (1 .. Last);
         H     : constant Header := Decode (Frame);
         Buf   : String (1 .. 32);
         BLast : Natural;
      begin
         Assert (H.Status = Ready, "encoded frame decodes Ready");
         Assert (H.Op = Op_Text, "encoded opcode is text");
         Assert (H.Fin, "encoded frame is FIN");
         Assert (H.Masked, "client frame is masked");
         Assert (H.Payload_Bytes = 11, "payload length preserved");
         Get_Text (Frame, H, Buf, BLast);
         Assert (Buf (1 .. BLast) = "hello world", "round-trips the payload");
      end;
   end Test_Encode_Text_Roundtrip;

   procedure Test_Base64 (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      --  RFC 4648 vectors
      Foobar : constant Octets :=
        [Character'Pos ('f'),
         Character'Pos ('o'),
         Character'Pos ('o'),
         Character'Pos ('b'),
         Character'Pos ('a'),
         Character'Pos ('r')];
      One    : constant Octets := [1 => Character'Pos ('f')];
      Two    : constant Octets := [Character'Pos ('f'), Character'Pos ('o')];
   begin
      Assert (Base64 (Foobar) = "Zm9vYmFy", "base64 of foobar");
      Assert (Base64 (One) = "Zg==", "base64 of one byte pads ==");
      Assert (Base64 (Two) = "Zm8=", "base64 of two bytes pads =");
   end Test_Base64;

   --  A server MUST NOT mask (RFC 6455 5.1), so its frame is a header
   --  and then the payload verbatim -- these pin the three length forms.
   procedure Test_Server_Header_Short
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Into : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      Server_Header (Op_Text, 5, Into, Last);
      Assert (Last = 2, "a short length needs two bytes");
      Assert (Into (1 .. 2) = [16#81#, 16#05#], "FIN + text, length 5");
   end Test_Server_Header_Short;

   procedure Test_Server_Header_16
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Into : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      Server_Header (Op_Text, 256, Into, Last);
      Assert (Last = 4, "the 16-bit form needs four bytes");
      Assert
        (Into (1 .. 4) = [16#81#, 16#7E#, 16#01#, 16#00#],
         "126 then the length big-endian");
   end Test_Server_Header_16;

   procedure Test_Server_Header_64
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Into : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      Server_Header (Op_Text, 65_536, Into, Last);
      Assert (Last = 10, "the 64-bit form needs ten bytes");
      Assert
        (Into (1 .. 10) = [16#81#, 16#7F#, 0, 0, 0, 0, 0, 1, 0, 0],
         "127 then the length in eight big-endian bytes");
   end Test_Server_Header_64;

   --  Decode is the INBOUND reader, but the loopback tests read the
   --  server's own frames with it, so every form it writes it reads.
   procedure Test_Server_Header_Decodes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Into : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;

      procedure Round_Trip (N : Natural; Header_Bytes : Positive) is
      begin
         Server_Header (Op_Text, N, Into, Last);
         declare
            H : constant Header := Decode (Into (1 .. Last));
         begin
            Assert (H.Status = Ready, "the header decodes Ready");
            Assert (not H.Masked, "a server frame is never masked");
            Assert (H.Fin, "one frame, final");
            Assert (H.Op = Op_Text, "text");
            Assert (H.Payload_Bytes = N, "the length survives");
            Assert (H.Header_Bytes = Last, "Header_Bytes is what was written");
            Assert (Last = Header_Bytes, "the form is the expected one");
         end;
      end Round_Trip;
   begin
      Round_Trip (5, 2);
      Round_Trip (256, 4);
      Round_Trip (65_536, 10);
      --  The size WP-N5's loopback client reads back.
      Round_Trip (70_000, 10);
      Round_Trip (Natural'Last, 10);
   end Test_Server_Header_Decodes;

   --  A 64-bit length past what a Natural holds is a violation, not a
   --  number: nothing downstream could index it.
   procedure Test_Decode_Rejects_Huge_Length
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  2**31, one past Natural'Last.
      Wire  : constant Octets := [16#81#, 16#7F#, 0, 0, 0, 0, 16#80#, 0, 0, 0];
      --  2**32.
      Wider : constant Octets := [16#81#, 16#7F#, 0, 0, 0, 1, 0, 0, 0, 0];
   begin
      Assert (Decode (Wire).Status = Invalid, "2**31 is not a length");
      Assert (Decode (Wider).Status = Invalid, "2**32 even less so");
   end Test_Decode_Rejects_Huge_Length;

   procedure Test_Close_Payload (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Close_Payload (1_000) = [16#03#, 16#E8#], "1000, network order");
      Assert (Close_Payload (4_401) = [16#11#, 16#31#], "the refusal code");
      Assert (Close_Payload (1_000)'Length = 2, "always two bytes");
   end Test_Close_Payload;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Decode_Unmasked_Text'Access, "decode unmasked text frame");
      Register_Routine
        (T, Test_Decode_Masked_Text'Access, "decode masked text frame");
      Register_Routine
        (T, Test_Decode_16bit_Length'Access, "decode 16-bit extended length");
      Register_Routine
        (T, Test_Decode_Control_Opcodes'Access, "decode ping/close/pong");
      Register_Routine (T, Test_Need_More'Access, "short buffers need more");
      Register_Routine
        (T,
         Test_Invalid_Rsv'Access,
         "RSV1 is reported, RSV2 and RSV3 are invalid");
      Register_Routine
        (T,
         Test_Server_Header_Deflated'Access,
         "Server_Header sets RSV1 on a deflated message");
      Register_Routine
        (T, Test_Encode_Text_Roundtrip'Access, "encode text round-trips");
      Register_Routine (T, Test_Base64'Access, "base64 encodes per RFC 4648");
      Register_Routine
        (T, Test_Server_Header_Short'Access, "server header, short length");
      Register_Routine
        (T, Test_Server_Header_16'Access, "server header, 16-bit length");
      Register_Routine
        (T, Test_Server_Header_64'Access, "server header, 64-bit length");
      Register_Routine
        (T,
         Test_Server_Header_Decodes'Access,
         "every server header Decode reads back");
      Register_Routine
        (T,
         Test_Decode_Rejects_Huge_Length'Access,
         "a length past Natural is a violation");
      Register_Routine
        (T, Test_Close_Payload'Access, "the close code, network order");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Rfc6455 (websocket frame codec)");
   end Name;

end Nuntius_Rfc6455_Tests;
