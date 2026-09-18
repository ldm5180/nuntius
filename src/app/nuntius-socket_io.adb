with Ada.Streams;
use type Ada.Streams.Stream_Element_Offset;

package body Nuntius.Socket_Io is

   use GNAT.Sockets;

   procedure Drain (Sock : Socket_Type; Buf : Ada.Streams.Stream_Element_Array)
   is
      First : Ada.Streams.Stream_Element_Offset := Buf'First;
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      while First <= Buf'Last loop
         Send_Socket (Sock, Buf (First .. Buf'Last), Last);
         exit when Last < First;
         First := Last + 1;
      end loop;
   end Drain;

   procedure Send_All (Sock : Socket_Type; Text : String) is
      Buf : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
   begin
      for K in Text'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (K - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (K)));
      end loop;
      Drain (Sock, Buf);
   end Send_All;

   procedure Send_All (Sock : Socket_Type; Bytes : Nuntius.Rfc6455.Octets) is
      Buf : Ada.Streams.Stream_Element_Array (1 .. Bytes'Length);
   begin
      for K in Bytes'Range loop
         Buf (Ada.Streams.Stream_Element_Offset (K - Bytes'First + 1)) :=
           Ada.Streams.Stream_Element (Bytes (K));
      end loop;
      Drain (Sock, Buf);
   end Send_All;

end Nuntius.Socket_Io;
