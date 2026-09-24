with Ada.Streams;
use type Ada.Streams.Stream_Element_Offset;

with Nuntius.Socket_Io;

package body Nuntius.Ws.Peer is

   use GNAT.Sockets;
   use Nuntius.Rfc6455;

   --  The payload goes out in slices this size, so the largest local
   --  buffer a send needs is a constant however big the document is.
   Chunk_Bytes : constant := 4_096;

   procedure Adopt (Self : in out Peer; Sock : Socket_Type) is
   begin
      Self.Sock := Sock;
      Self.Open := True;
      Self.Len := 0;
   end Adopt;

   function Is_Open (Self : Peer) return Boolean
   is (Self.Open);

   function Fd (Self : Peer) return Integer
   is (if Self.Open then To_C (Self.Sock) else -1);

   procedure Shut (Self : in out Peer) is
   begin
      if Self.Open then
         Self.Open := False;
         begin
            Close_Socket (Self.Sock);
         exception
            when Socket_Error =>
               null;
         end;
      end if;
   end Shut;

   --  The frame header, then the payload in slices.  Any socket error
   --  anywhere in it shuts the peer.
   procedure Send_Framed
     (Self : in out Peer; Op : Opcode; Text : String; Ok : out Boolean)
   is
      Head : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
      Pos  : Natural := Text'First;
   begin
      Ok := False;
      if not Self.Open then
         return;
      end if;
      Server_Header (Op, Text'Length, Head, Last);
      Nuntius.Socket_Io.Send_All (Self.Sock, Head (1 .. Last));
      while Pos <= Text'Last loop
         declare
            Stop  : constant Natural :=
              Natural'Min (Text'Last, Pos + Chunk_Bytes - 1);
            Slice : Octets (1 .. Stop - Pos + 1);
         begin
            for K in Slice'Range loop
               Slice (K) := Octet (Character'Pos (Text (Pos + K - 1)));
            end loop;
            Nuntius.Socket_Io.Send_All (Self.Sock, Slice);
            Pos := Stop + 1;
         end;
      end loop;
      Ok := True;
   exception
      when Socket_Error =>
         Shut (Self);
         Ok := False;
   end Send_Framed;

   procedure Send_Text (Self : in out Peer; Text : String; Ok : out Boolean) is
   begin
      Send_Framed (Self, Op_Text, Text, Ok);
   end Send_Text;

   --  A control frame with an octet payload; control frames are at
   --  most 125 bytes, which every caller here respects.
   procedure Send_Control (Self : in out Peer; Op : Opcode; Payload : Octets)
   is
      Head : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      if not Self.Open then
         return;
      end if;
      Server_Header (Op, Payload'Length, Head, Last);
      Nuntius.Socket_Io.Send_All (Self.Sock, Head (1 .. Last));
      if Payload'Length > 0 then
         Nuntius.Socket_Io.Send_All (Self.Sock, Payload);
      end if;
   exception
      when Socket_Error =>
         Shut (Self);
   end Send_Control;

   procedure Close (Self : in out Peer; Code : Close_Code) is
   begin
      if not Self.Open then
         return;
      end if;
      Send_Control (Self, Op_Close, Close_Payload (Code));
      Shut (Self);
   end Close;

   procedure Consume (Self : in out Peer; N : Natural) is
   begin
      if N >= Self.Len then
         Self.Len := 0;
      else
         Self.Accum (1 .. Self.Len - N) := Self.Accum (N + 1 .. Self.Len);
         Self.Len := Self.Len - N;
      end if;
   end Consume;

   --  One receive into the accumulator's free tail.  EOF or a real
   --  socket error closes; a receive TIMEOUT is nothing at all.
   procedure Read_Some (Self : in out Peer; Grew, Alive : out Boolean) is
      Room : constant Natural := Natural'Max (Self.Accum'Length - Self.Len, 1);
      Buf  :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Room));
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Grew := False;
      Alive := True;
      if Self.Len >= Self.Accum'Length then
         return;
      end if;
      Receive_Socket (Self.Sock, Buf, Last);
      if Last < Buf'First then
         Alive := False;
         return;
      end if;
      for K in 1 .. Natural (Last) loop
         Self.Accum (Self.Len + K) :=
           Octet (Buf (Ada.Streams.Stream_Element_Offset (K)));
      end loop;
      Self.Len := Self.Len + Natural (Last);
      Grew := True;
   exception
      when E : Socket_Error =>
         --  A poll may lie, and the socket carries a Receive_Timeout:
         --  neither is the connection ending.
         Alive :=
           Resolve_Exception (E)
           in Resource_Temporarily_Unavailable | Operation_Now_In_Progress;
         Grew := False;
   end Read_Some;

   --  A control frame's payload, unmasked: a browser masks everything
   --  it sends, control frames included.
   function Unmasked (Self : Peer; H : Header) return Octets is
      Raw       : constant Octets :=
        Self.Accum (H.Header_Bytes + 1 .. H.Header_Bytes + H.Payload_Bytes);
      Out_Bytes : Octets (1 .. H.Payload_Bytes);
   begin
      for K in Out_Bytes'Range loop
         Out_Bytes (K) :=
           (if H.Masked
            then Raw (Raw'First + K - 1) xor H.Mask ((K - 1) mod 4)
            else Raw (Raw'First + K - 1));
      end loop;
      return Out_Bytes;
   end Unmasked;

   --  React to the whole frame at the accumulator's front.
   function React
     (Self : in out Peer; H : Header; Into : out String; Last : out Natural)
      return Pump_Outcome
   is
      Frame_Bytes : constant Natural := H.Header_Bytes + H.Payload_Bytes;
   begin
      Last := 0;
      case H.Op is
         when Op_Text                     =>
            Get_Text (Self.Accum (1 .. Self.Len), H, Into, Last);
            Consume (Self, Frame_Bytes);
            return Message;

         when Op_Ping                     =>
            declare
               Echo : constant Octets := Unmasked (Self, H);
            begin
               Consume (Self, Frame_Bytes);
               Send_Control (Self, Op_Pong, Echo);
            end;
            return Nothing;

         when Op_Pong                     =>
            Consume (Self, Frame_Bytes);
            return Nothing;

         when Op_Close                    =>
            declare
               Echo : constant Octets := Unmasked (Self, H);
            begin
               Consume (Self, Frame_Bytes);
               Send_Control (Self, Op_Close, Echo);
            end;
            Shut (Self);
            return Closed;

         when Op_Binary | Op_Continuation =>
            Close (Self, 1_003);
            return Faulted;
      end case;
   end React;

   --  The frame at the front, if one is whole.  Anything the codec
   --  calls invalid, and anything past the inbound cap, ends here.
   function Next_Frame
     (Self : in out Peer;
      Into : out String;
      Last : out Natural;
      Done : out Boolean) return Pump_Outcome
   is
      H : constant Header := Decode (Self.Accum (1 .. Self.Len));
   begin
      Last := 0;
      Done := True;
      case H.Status is
         when Need_More =>
            Done := False;
            return Nothing;

         when Invalid   =>
            Close (Self, 1_003);
            return Faulted;

         when Ready     =>
            if H.Rsv1 then
               --  No extension was agreed on this peer.
               Close (Self, 1_003);
               return Faulted;
            end if;
            if H.Payload_Bytes > Max_Inbound_Bytes then
               Close (Self, 1_009);
               return Faulted;
            end if;
            if Self.Len < H.Header_Bytes + H.Payload_Bytes then
               Done := False;
               return Nothing;
            end if;
            return React (Self, H, Into, Last);
      end case;
   end Next_Frame;

   function Pump
     (Self     : in out Peer;
      Readable : Boolean;
      Into     : out String;
      Last     : out Natural) return Pump_Outcome
   is
      Done       : Boolean;
      Grew       : Boolean;
      Alive      : Boolean;
      First_Pass : Pump_Outcome;
   begin
      Into := [others => ' '];
      Last := 0;
      if not Self.Open then
         return Closed;
      end if;

      First_Pass := Next_Frame (Self, Into, Last, Done);
      if Done then
         return First_Pass;
      end if;

      if not Readable then
         return Nothing;
      end if;

      Read_Some (Self, Grew, Alive);
      if not Alive then
         Shut (Self);
         return Closed;
      end if;
      if not Grew then
         return Nothing;
      end if;

      declare
         Second : constant Pump_Outcome := Next_Frame (Self, Into, Last, Done);
      begin
         return (if Done then Second else Nothing);
      end;
   end Pump;

end Nuntius.Ws.Peer;
