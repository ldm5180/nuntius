with Ada.Streams;           use Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Loopback_Capture is

   use GNAT.Sockets;

   CRLF     : constant String := ASCII.CR & ASCII.LF;
   Head_End : constant String := CRLF & CRLF;

   protected Cell is
      procedure Set (S : String);
      function Get return String;
   private
      V : Unbounded_String;
   end Cell;

   protected body Cell is
      procedure Set (S : String) is
      begin
         V := To_Unbounded_String (S);
      end Set;

      function Get return String
      is (To_String (V));
   end Cell;

   function Head return String
   is (Cell.Get);

   function Loopback_URL (Port : Natural; Path : String) return String
   is ("http://127.0.0.1:"
       & Ada.Strings.Fixed.Trim (Port'Image, Ada.Strings.Left)
       & Path);

   procedure Listen_Loopback (Listen : out Socket_Type; Port : out Natural) is
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Natural (Get_Socket_Name (Listen).Port);
   end Listen_Loopback;

   Reply : constant String :=
     "HTTP/1.1 200 OK"
     & CRLF
     & "Content-Type: text/plain"
     & CRLF
     & "Content-Length: 2"
     & CRLF
     & "Connection: close"
     & CRLF
     & CRLF
     & "ok";

   procedure Send_All (S : Socket_Type; Text : String) is
      Bytes : Stream_Element_Array (1 .. Text'Length);
      Off   : Stream_Element_Offset := Bytes'First;
      Last  : Stream_Element_Offset;
   begin
      for I in Text'Range loop
         Bytes (Stream_Element_Offset (I - Text'First + 1)) :=
           Stream_Element (Character'Pos (Text (I)));
      end loop;
      while Off <= Bytes'Last loop
         Send_Socket (S, Bytes (Off .. Bytes'Last), Last);
         exit when Last < Off;
         Off := Last + 1;
      end loop;
   end Send_All;

   --  Read until the blank line that ends the head, or the peer stops.
   function Read_Head (Peer : Socket_Type) return String is
      Acc  : Unbounded_String;
      Buf  : Stream_Element_Array (1 .. 1_024);
      Last : Stream_Element_Offset;
   begin
      loop
         Receive_Socket (Peer, Buf, Last);
         exit when Last < Buf'First;
         for K in Buf'First .. Last loop
            Append (Acc, Character'Val (Buf (K)));
         end loop;
         exit when Ada.Strings.Fixed.Index (To_String (Acc), Head_End) > 0;
      end loop;
      return To_String (Acc);
   end Read_Head;

   task body Server is
      Listen, Peer : Socket_Type;
      From         : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);
      Cell.Set (Read_Head (Peer));
      Send_All (Peer, Reply);
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         null;  --  the client side's assertions carry the verdict
   end Server;

end Loopback_Capture;
