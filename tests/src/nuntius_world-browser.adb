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

   function Bytes_Of (Text : String) return Octets is
      B : Octets (1 .. Text'Length);
   begin
      for K in B'Range loop
         B (K) := Character'Pos (Text (Text'First + K - 1));
      end loop;
      return B;
   end Bytes_Of;

end Nuntius_World.Browser;
