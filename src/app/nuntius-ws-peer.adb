with Ada.Streams;
use type Ada.Streams.Stream_Element_Offset;

with Nuntius.Deflate;
with Nuntius.Socket_Io;

package body Nuntius.Ws.Peer is

   use GNAT.Sockets;
   use Nuntius.Rfc6455;
   use type Nuntius.Codings.Message_Coding;

   --  The payload goes out in slices this size, so the largest local
   --  buffer a send needs is a constant however big the document is.
   Chunk_Bytes : constant := 4_096;

   procedure Adopt
     (Self   : in out Peer;
      Sock   : Socket_Type;
      Coding : Nuntius.Codings.Message_Coding := Nuntius.Codings.Plain) is
   begin
      Self.Sock := Sock;
      Self.Open := True;
      Self.Coding := Coding;
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

   --  One frame header on the wire; raises Socket_Error as Send_All
   --  does, for the caller's handler.
   procedure Send_Head
     (Self   : Peer;
      Op     : Opcode;
      Length : Natural;
      Coding : Nuntius.Codings.Message_Coding := Nuntius.Codings.Plain)
   is
      Head : Octets (1 .. Max_Server_Header);
      Last : Server_Header_Count;
   begin
      Server_Header (Op, Length, Head, Last, Coding);
      Nuntius.Socket_Io.Send_All (Self.Sock, Head (1 .. Last));
   end Send_Head;

   --  The frame header, then the payload in slices.  Any socket error
   --  anywhere in it shuts the peer.
   procedure Send_Framed
     (Self : in out Peer; Op : Opcode; Text : String; Ok : out Boolean)
   is
      Pos : Natural := Text'First;
   begin
      Ok := False;
      if not Self.Open then
         return;
      end if;
      Send_Head (Self, Op, Text'Length);
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

   --  A packed message's frame: RSV1 set, the octets verbatim.
   procedure Send_Deflated
     (Self : in out Peer; Packed : Octets; Ok : out Boolean) is
   begin
      Ok := False;
      if not Self.Open then
         return;
      end if;
      Send_Head (Self, Op_Text, Packed'Length, Nuntius.Codings.Deflated);
      Nuntius.Socket_Io.Send_All (Self.Sock, Packed);
      Ok := True;
   exception
      when Socket_Error =>
         Shut (Self);
         Ok := False;
   end Send_Deflated;

   procedure Send_Packed
     (Self : in out Peer; Text : String; Packed : Octets; Ok : out Boolean) is
   begin
      if Self.Coding = Nuntius.Codings.Deflated and then Packed'Length > 0 then
         Send_Deflated (Self, Packed, Ok);
      else
         Send_Text (Self, Text, Ok);
      end if;
   end Send_Packed;

   --  A control frame with an octet payload; control frames are at
   --  most 125 bytes, which every caller here respects.
   procedure Send_Control (Self : in out Peer; Op : Opcode; Payload : Octets)
   is
   begin
      if not Self.Open then
         return;
      end if;
      Send_Head (Self, Op, Payload'Length);
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

   --  A frame's payload as octets, unmasked: a browser masks
   --  everything it sends, control frames and packed messages included.
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

   --  A packed text frame, inflated into at most Max_Inbound_Bytes of
   --  Into: the cap is on what comes out, whatever the frame's size.
   function Inflated
     (Self : in out Peer; H : Header; Into : out String; Last : out Natural)
      return Pump_Outcome
   with Pre => Into'First = 1 and then Into'Length >= Max_Inbound_Bytes
   is
      Packed : constant Octets := Unmasked (Self, H);
   begin
      Consume (Self, H.Header_Bytes + H.Payload_Bytes);
      case Nuntius.Deflate.Unpack
             (Packed, Into (Into'First .. Max_Inbound_Bytes), Last)
      is
         when Nuntius.Deflate.Done    =>
            return Message;

         when Nuntius.Deflate.Too_Big =>
            Close (Self, 1_009);
            return Faulted;

         when Nuntius.Deflate.Corrupt =>
            Close (Self, 1_007);
            return Faulted;
      end case;
   end Inflated;

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
            if H.Rsv1 then
               return Inflated (Self, H, Into, Last);
            end if;
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
            if H.Rsv1
              and then (Self.Coding = Nuntius.Codings.Plain
                        or else H.Op /= Op_Text)
            then
               --  RSV1 is a packed data message's bit, and only where
               --  the 101 agreed it (RFC 7692 6.1).
               Close (Self, 1_002);
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
