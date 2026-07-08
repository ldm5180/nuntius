package body Nuntius.Rfc6455
  with SPARK_Mode
is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   Base64_Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   --  The 4-bit opcode nibble -> our enum; reserved values return False.
   procedure Classify_Opcode
     (Nibble : Octet; Op : out Opcode; Known : out Boolean) is
   begin
      Known := True;
      case Nibble is
         when 16#0#  =>
            Op := Op_Continuation;

         when 16#1#  =>
            Op := Op_Text;

         when 16#2#  =>
            Op := Op_Binary;

         when 16#8#  =>
            Op := Op_Close;

         when 16#9#  =>
            Op := Op_Ping;

         when 16#A#  =>
            Op := Op_Pong;

         when others =>
            Op := Op_Continuation;
            Known := False;
      end case;
   end Classify_Opcode;

   ----------
   -- Decode --
   ----------

   function Decode (Buffer : Octets) return Header is
      Len    : constant Natural := Buffer'Length;
      Result : Header;
   begin
      if Len < 2 then
         return Result;  --  Need_More (the default)

      end if;

      declare
         B0      : constant Octet := Buffer (Buffer'First);
         B1      : constant Octet := Buffer (Buffer'First + 1);
         Masked  : constant Boolean := (B1 and 16#80#) /= 0;
         Len7    : constant Octet := B1 and 16#7F#;
         Mask_N  : constant Natural := (if Masked then 4 else 0);
         Op      : Opcode;
         Known   : Boolean;
         Ext_N   : Natural;
         Payload : Natural := 0;
      begin
         --  RSV1..3 must be zero (we negotiate no extensions).
         if (B0 and 16#70#) /= 0 then
            Result.Status := Invalid;
            return Result;
         end if;

         Classify_Opcode (B0 and 16#0F#, Op, Known);
         if not Known then
            Result.Status := Invalid;
            return Result;
         end if;

         if Len7 < 126 then
            Ext_N := 0;
            Payload := Natural (Len7);
         elsif Len7 = 126 then
            Ext_N := 2;
         else
            Ext_N := 8;
         end if;

         --  The whole header (control byte, length field, mask) must be in.
         if Len < 2 + Ext_N + Mask_N then
            return Result;  --  Need_More

         end if;

         if Ext_N = 2 then
            Payload :=
              Natural (Buffer (Buffer'First + 2))
              * 256
              + Natural (Buffer (Buffer'First + 3));
         elsif Ext_N = 8 then
            --  We never accept a frame past 16 bits of length (the adapter
            --  caps at Max_Frame_Bytes regardless), so a larger 64-bit
            --  length is a violation rather than an overflow risk.
            for I in 2 .. 7 loop
               if Buffer (Buffer'First + I) /= 0 then
                  Result.Status := Invalid;
                  return Result;
               end if;
            end loop;
            Payload :=
              Natural (Buffer (Buffer'First + 8))
              * 256
              + Natural (Buffer (Buffer'First + 9));
         end if;

         if Masked then
            for I in 0 .. 3 loop
               Result.Mask (I) := Buffer (Buffer'First + 2 + Ext_N + I);
            end loop;
         end if;

         Result :=
           (Status        => Ready,
            Op            => Op,
            Fin           => (B0 and 16#80#) /= 0,
            Masked        => Masked,
            Header_Bytes  => 2 + Ext_N + Mask_N,
            Payload_Bytes => Payload,
            Mask          => Result.Mask);
         return Result;
      end;
   end Decode;

   ------------
   -- Get_Text --
   ------------

   procedure Get_Text
     (Buffer : Octets; H : Header; Into : out String; Last : out Natural) is
   begin
      Into := [others => ' '];
      Last := H.Payload_Bytes;
      for I in 0 .. H.Payload_Bytes - 1 loop
         pragma Loop_Invariant (H.Header_Bytes + I < Buffer'Length);
         declare
            Raw : constant Octet := Buffer (Buffer'First + H.Header_Bytes + I);
            Val : constant Octet :=
              (if H.Masked then Raw xor H.Mask (I mod 4) else Raw);
         begin
            Into (Into'First + I) := Character'Val (Natural (Val));
         end;
      end loop;
   end Get_Text;

   -----------------
   -- Encode_Text --
   -----------------

   procedure Encode_Text
     (Text : String; Mask : Mask_Key; Into : out Octets; Last : out Natural)
   is
      N   : constant Natural := Text'Length;
      Ext : constant Natural := (if N < 126 then 0 else 2);
      Hdr : constant Natural := 2 + Ext + 4;
   begin
      Into := [others => 0];
      Into (1) := 16#81#;  --  FIN + text
      if N < 126 then
         Into (2) := 16#80# or Octet (N);
      else
         Into (2) := 16#80# or 126;
         Into (3) := Octet (N / 256);
         Into (4) := Octet (N mod 256);
      end if;
      for I in 0 .. 3 loop
         Into (3 + Ext + I) := Mask (I);
      end loop;
      for I in 0 .. N - 1 loop
         Into (Hdr + 1 + I) :=
           Octet (Character'Pos (Text (Text'First + I))) xor Mask (I mod 4);
      end loop;
      Last := Hdr + N;
   end Encode_Text;

   --------------------
   -- Encode_Control --
   --------------------

   procedure Encode_Control
     (Op      : Opcode;
      Payload : Octets;
      Mask    : Mask_Key;
      Into    : out Octets;
      Last    : out Natural)
   is
      N : constant Natural := Payload'Length;
   begin
      Into := [others => 0];
      Into (1) :=
        16#80#
        or (case Op is
              when Op_Close => 16#8#,
              when Op_Ping  => 16#9#,
              when others   => 16#A#);
      Into (2) := 16#80# or Octet (N);
      for I in 0 .. 3 loop
         Into (3 + I) := Mask (I);
      end loop;
      for I in 0 .. N - 1 loop
         Into (7 + I) := Payload (Payload'First + I) xor Mask (I mod 4);
      end loop;
      Last := 6 + N;
   end Encode_Control;

   ------------
   -- Base64 --
   ------------

   function Base64 (Data : Octets) return String is
      N       : constant Natural := Data'Length;
      Out_Len : constant Natural := 4 * ((N + 2) / 3);
      R       : String (1 .. Out_Len) := [others => '='];
      Oi      : Natural := 1;
      I       : Natural := 0;
   begin
      while I < N loop
         pragma Loop_Invariant (I mod 3 = 0 and then Oi = 1 + 4 * (I / 3));
         pragma Loop_Invariant (Oi + 3 <= Out_Len);
         pragma Loop_Variant (Increases => I);
         declare
            B0     : constant Natural := Natural (Data (Data'First + I));
            B1     : constant Natural :=
              (if I + 1 < N then Natural (Data (Data'First + I + 1)) else 0);
            B2     : constant Natural :=
              (if I + 2 < N then Natural (Data (Data'First + I + 2)) else 0);
            Triple : constant Natural := B0 * 65_536 + B1 * 256 + B2;
         begin
            R (Oi) := Base64_Alphabet (1 + (Triple / 262_144) mod 64);
            R (Oi + 1) := Base64_Alphabet (1 + (Triple / 4_096) mod 64);
            if I + 1 < N then
               R (Oi + 2) := Base64_Alphabet (1 + (Triple / 64) mod 64);
            end if;
            if I + 2 < N then
               R (Oi + 3) := Base64_Alphabet (1 + Triple mod 64);
            end if;
         end;
         Oi := Oi + 4;
         I := I + 3;
      end loop;
      return R;
   end Base64;

   ----------------------
   -- Client_Handshake --
   ----------------------

   function Client_Handshake (Host, Path, Key : String) return String
   is ("GET "
       & Path
       & " HTTP/1.1"
       & CRLF
       & "Host: "
       & Host
       & CRLF
       & "Upgrade: websocket"
       & CRLF
       & "Connection: Upgrade"
       & CRLF
       & "Sec-WebSocket-Key: "
       & Key
       & CRLF
       & "Sec-WebSocket-Version: 13"
       & CRLF
       & CRLF);

end Nuntius.Rfc6455;
