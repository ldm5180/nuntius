with Ada.Streams;  use Ada.Streams;
with GNAT.Sockets; use GNAT.Sockets;

with Nuntius.Socket_Io;

package body Nuntius_World.Browser is

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

   procedure Open_Pair (Coding : Nuntius.Codings.Message_Coding) is
      Served : Socket_Type;
   begin
      Close_Pair;
      Pair (Browser_Sock, Served);
      Peers.Adopt (The_Peer, Served, Coding);
   end Open_Pair;

   Normal_Closure : constant Close_Code := 1_000;

   procedure Close_Pair is
   begin
      if Peers.Is_Open (The_Peer) then
         Peers.Close (The_Peer, Normal_Closure);
      end if;
      if Browser_Sock /= No_Socket then
         begin
            Close_Socket (Browser_Sock);
         exception
            when Socket_Error =>
               null;  --  already gone: the scenario hung it up
         end;
         Browser_Sock := No_Socket;
      end if;
   end Close_Pair;

   --  The length forms of RFC 6455 5.2: a 7-bit length, or 126 then 16
   --  bits, or 127 then 64 bits, big-endian.
   Short_Limit   : constant := 125;
   Medium_Marker : constant := 126;
   Medium_Bytes  : constant := 2;
   Long_Bytes    : constant := 8;
   Mask_Bit      : constant Octet := 16#80#;
   Length_Bits   : constant Octet := 16#7F#;
   Octet_Base    : constant := 256;

   function Big_Endian (B : Octets) return Natural is
      N : Natural := 0;
   begin
      for X of B loop
         N := N * Octet_Base + Natural (X);
      end loop;
      return N;
   end Big_Endian;

   procedure Read_Server_Frame
     (Sock    : GNAT.Sockets.Socket_Type;
      Lead    : out Octet;
      Masked  : out Boolean;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Ok      : out Boolean)
   is
      Head   : constant Octets := Read_Frame (Sock, 2);
      Marker : Natural;
      Length : Natural;
   begin
      Lead := 0;
      Masked := False;
      Payload := Ada.Strings.Unbounded.Null_Unbounded_String;
      Ok := Head'Length = 2;
      if not Ok then
         return;
      end if;
      Lead := Head (1);
      Masked := (Head (2) and Mask_Bit) /= 0;
      Marker := Natural (Head (2) and Length_Bits);
      Length :=
        (if Marker <= Short_Limit
         then Marker
         elsif Marker = Medium_Marker
         then Big_Endian (Read_Frame (Sock, Medium_Bytes))
         else Big_Endian (Read_Frame (Sock, Long_Bytes)));
      if Length > 0 then
         declare
            Body_Bytes : Octets (1 .. Length);
            Got        : Natural;
         begin
            Read_Some (Sock, Length, Body_Bytes, Got);
            Ok := Got = Length;
            for B of Body_Bytes (1 .. Got) loop
               Ada.Strings.Unbounded.Append (Payload, Character'Val (B));
            end loop;
         end;
      end if;
   end Read_Server_Frame;

end Nuntius_World.Browser;
