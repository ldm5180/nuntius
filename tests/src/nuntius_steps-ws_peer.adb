with Ada.Characters.Handling;
with Ada.Directories;

with GNAT.Sockets;

with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius.Codings;
with Nuntius.Deflate;
with Nuntius.Rfc6455; use Nuntius.Rfc6455;

with Nuntius_World;         use Nuntius_World;
with Nuntius_World.Browser; use Nuntius_World.Browser;

package body Nuntius_Steps.Ws_Peer is

   use type Peers.Pump_Outcome;

   subtype Number is Fabula.Numbers.Integer_Reads.Read;

   First_Capture : constant := 1;

   --  The first byte of each frame the browser or the peer sends here:
   --  FIN, the RSV bits and the opcode.
   Text_Lead      : constant Octet := 16#81#;
   Packed_Lead    : constant Octet := 16#C1#;
   Binary_Lead    : constant Octet := 16#82#;
   Ping_Rsv1_Lead : constant Octet := 16#C9#;
   Pong_Lead      : constant Octet := 16#8A#;
   Close_Lead     : constant Octet := 16#88#;

   --  The longest named sequence a feature can send.
   Max_Named_Bytes : constant := 4_096;

   Octet_Base : constant := 256;

   ---------------------------------------------------------------------
   --  Sending.
   ---------------------------------------------------------------------

   procedure Peer_Text (Text : String; R : in out Fabula.Check.Outcome) is
      Ok : Boolean;
   begin
      Peers.Send_Text (The_Peer, Text, Ok);
      Fabula.Check.Is_True (R, Ok, "the peer's send");
   end Peer_Text;

   procedure Peer_Packed
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      Text   : constant String := Json_Of (N);
      Packed : constant Octets := Nuntius.Deflate.Pack (Text);
      Ok     : Boolean;
   begin
      Ctx.Peer.Packed := To_Unbounded_String (Chars_Of (Packed));
      Peers.Send_Packed (The_Peer, Text, Packed, Ok);
      Fabula.Check.Is_True (R, Ok, "the peer's send");
   end Peer_Packed;

   procedure Send_Named
     (Name : String;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome)
   is
      Dir  : constant String :=
        Ada.Directories.Containing_Directory (Fabula.Frames.Value (Info.File))
        & "/bytes";
      Buf  : Octets (1 .. Max_Named_Bytes);
      Last : Natural;
      Ok   : Boolean;
   begin
      Named_Bytes (Dir, Name, Buf, Last, Ok);
      if Ok then
         Browser_Frame (Browser_Sock, Packed_Lead, Buf (1 .. Last));
      else
         Fabula.Check.Fail_Step (R, "no bytes named " & Name & " in " & Dir);
      end if;
   end Send_Named;

   procedure Browser_Says (Ctx : in out World; Text : String) is
   begin
      Ctx.Peer.Sent := To_Unbounded_String (Text);
      Browser_Text (Browser_Sock, Text);
   end Browser_Says;

   procedure Browser_Packs (Ctx : in out World; Text : String) is
   begin
      Ctx.Peer.Sent := To_Unbounded_String (Text);
      Browser_Frame (Browser_Sock, Packed_Lead, Nuntius.Deflate.Pack (Text));
   end Browser_Packs;

   procedure Hang_Up is
   begin
      GNAT.Sockets.Close_Socket (Browser_Sock);
      Browser_Sock := GNAT.Sockets.No_Socket;
   end Hang_Up;

   procedure Pump (Ctx : in out World) is
      Into : String (1 .. Max_Inbound);
      Last : Natural;
   begin
      Ctx.Peer.Outcome := Peers.Pump (The_Peer, True, Into, Last);
      Ctx.Peer.Read :=
        To_Unbounded_String
          (if Ctx.Peer.Outcome = Peers.Message then Into (1 .. Last) else "");
   end Pump;

   --  Run Act with the step's integer capture, or fail the read.
   generic
      with
        procedure Act
          (Ctx   : in out World;
           Value : Natural;
           R     : in out Fabula.Check.Outcome);
   procedure With_Int
     (Ctx : in out World; N : Number; R : in out Fabula.Check.Outcome);

   procedure With_Int
     (Ctx : in out World; N : Number; R : in out Fabula.Check.Outcome) is
   begin
      if N.Ok and then N.Value >= 0 then
         Act (Ctx, N.Value, R);
      elsif N.Ok then
         Fabula.Check.Fail_Step (R, "a count cannot be negative");
      else
         Fabula.Check.Ints.Fail_Read (R, N.Error);
      end if;
   end With_Int;

   procedure Big
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Ctx);
   begin
      Peer_Text ([1 .. N => 'z'], R);
   end Big;

   procedure Long
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Ctx, R);
   begin
      Browser_Text (Browser_Sock, [1 .. N => 'x']);
   end Long;

   procedure Packed_Json
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (R);
   begin
      Browser_Packs (Ctx, Json_Of (N));
   end Packed_Json;

   procedure Zeros
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Ctx, R);
   begin
      Browser_Frame
        (Browser_Sock, Packed_Lead, Nuntius.Deflate.Pack ([1 .. N => '0']));
   end Zeros;

   ---------------------------------------------------------------------
   --  Checking what the browser reads.
   ---------------------------------------------------------------------

   --  The next server frame is Lead, unmasked, carrying Payload.
   procedure Expect_Frame
     (Lead : Octet; Payload : String; R : in out Fabula.Check.Outcome)
   is
      Got_Lead : Octet;
      Masked   : Boolean;
      Got      : Unbounded_String;
      Ok       : Boolean;
   begin
      Read_Server_Frame (Browser_Sock, Got_Lead, Masked, Got, Ok);
      Fabula.Check.Is_True (R, Ok, "a whole frame arrived");
      Fabula.Check.Ints.Equal
        (R, Integer (Got_Lead), Integer (Lead), "the first byte");
      Fabula.Check.Is_False (R, Masked, "a server frame is masked");
      Fabula.Check.Ints.Equal (R, Length (Got), Payload'Length, "the length");
      Fabula.Check.Is_True (R, To_String (Got) = Payload, "the payload");
   end Expect_Frame;

   --  The next server frame is unmasked text of exactly N bytes.
   procedure Text_Length
     (Ctx : in out World; N : Natural; R : in out Fabula.Check.Outcome)
   is
      pragma Unreferenced (Ctx);
      Got_Lead : Octet;
      Masked   : Boolean;
      Got      : Unbounded_String;
      Ok       : Boolean;
   begin
      Read_Server_Frame (Browser_Sock, Got_Lead, Masked, Got, Ok);
      Fabula.Check.Is_True (R, Ok, "a whole frame arrived");
      Fabula.Check.Ints.Equal
        (R, Integer (Got_Lead), Integer (Text_Lead), "the first byte");
      Fabula.Check.Is_False (R, Masked, "a server frame is masked");
      Fabula.Check.Ints.Equal (R, Length (Got), N, "the length");
   end Text_Length;

   --  The two payload bytes a close with Code carries.
   function Code_Bytes (Code : Natural) return String
   is ([Character'Val (Code / Octet_Base),
        Character'Val (Code mod Octet_Base)])
   with Pre => Code < Octet_Base * Octet_Base;

   procedure Expect_Close (Code : Number; R : in out Fabula.Check.Outcome) is
   begin
      if Code.Ok and then Code.Value in Close_Code then
         Expect_Frame (Close_Lead, Code_Bytes (Code.Value), R);
      else
         Fabula.Check.Fail_Step (R, "not a close code");
      end if;
   end Expect_Close;

   procedure Check_Outcome_Named
     (Ctx : World; Word : String; R : in out Fabula.Check.Outcome)
   is
      Wanted : Peers.Pump_Outcome;
   begin
      Wanted := Peers.Pump_Outcome'Value (Word);
      Fabula.Check.Is_True
        (R,
         Ctx.Peer.Outcome = Wanted,
         "the pump was "
         & Ada.Characters.Handling.To_Lower (Ctx.Peer.Outcome'Image));
   exception
      when Constraint_Error =>
         Fabula.Check.Fail_Step (R, "no pump outcome named " & Word);
   end Check_Outcome_Named;

   procedure Send_Fails (R : in out Fabula.Check.Outcome) is
      Ok : Boolean;
   begin
      Peers.Send_Text (The_Peer, "anyone there", Ok);
      Fabula.Check.Is_False (R, Ok, "the send succeeded");
   end Send_Fails;

   procedure Send_Big is new With_Int (Big);
   procedure Send_Long is new With_Int (Long);
   procedure Send_Packed_Json is new With_Int (Packed_Json);
   procedure Send_Zeros is new With_Int (Zeros);
   procedure Send_Peer_Json is new With_Int (Peer_Packed);
   procedure Expect_Length is new With_Int (Text_Length);

   procedure Execute
     (S    : Peer_Step;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome)
   is
      N : constant Number :=
        (if Fabula.Args.Count (A) >= First_Capture
         then Fabula.Args.Int (A, First_Capture)
         else Fabula.Numbers.Integer_Reads.Success (0));
   begin
      case S is
         when E_Pair_Plain           =>
            Open_Pair (Nuntius.Codings.Plain);

         when E_Pair_Deflated        =>
            Open_Pair (Nuntius.Codings.Deflated);

         when E_Peer_Send_Big        =>
            Send_Big (Ctx, N, R);

         when E_Peer_Send_Packed     =>
            Send_Peer_Json (Ctx, N, R);

         when E_Peer_Send_Text       =>
            Peer_Text (Fabula.Args.Text (A, First_Capture), R);

         when E_Browser_Ping         =>
            Browser_Control
              (Browser_Sock,
               Op_Ping,
               Bytes_Of (Fabula.Args.Text (A, First_Capture)));

         when E_Browser_Close        =>
            if N.Ok and then N.Value in Close_Code then
               Browser_Control
                 (Browser_Sock, Op_Close, Close_Payload (N.Value));
            else
               Fabula.Check.Fail_Step (R, "not a close code");
            end if;

         when E_Browser_Long         =>
            Send_Long (Ctx, N, R);

         when E_Browser_Binary       =>
            Browser_Frame (Browser_Sock, Binary_Lead, Bytes_Of ("a"));

         when E_Browser_Rsv1         =>
            Browser_Frame (Browser_Sock, Packed_Lead, Bytes_Of ("a"));

         when E_Browser_Ping_Rsv1    =>
            Browser_Frame (Browser_Sock, Ping_Rsv1_Lead, []);

         when E_Browser_Packed_Json  =>
            Send_Packed_Json (Ctx, N, R);

         when E_Browser_Packed_Zeros =>
            Send_Zeros (Ctx, N, R);

         when E_Browser_Named        =>
            Send_Named (Fabula.Args.Word (A, First_Capture), Info, R);

         when E_Browser_Json         =>
            Browser_Says (Ctx, Fabula.Args.Text (A, First_Capture));

         when E_Browser_Hangs_Up     =>
            Hang_Up;

         when E_Peer_Pump            =>
            Pump (Ctx);

         when E_Check_Pump           =>
            Check_Outcome_Named (Ctx, Fabula.Args.Word (A, First_Capture), R);

         when E_Check_Read_Sent      =>
            Fabula.Check.Is_True
              (R,
               Ctx.Peer.Read = Ctx.Peer.Sent,
               "the peer read what was sent");

         when E_Check_Text_Frame     =>
            Expect_Frame (Text_Lead, Fabula.Args.Text (A, First_Capture), R);

         when E_Check_Text_Length    =>
            Expect_Length (Ctx, N, R);

         when E_Check_Packed_Frame   =>
            Expect_Frame (Packed_Lead, To_String (Ctx.Peer.Packed), R);

         when E_Check_Pong_Frame     =>
            Expect_Frame (Pong_Lead, Fabula.Args.Text (A, First_Capture), R);

         when E_Check_Close_Frame    =>
            Expect_Close (N, R);

         when E_Check_Shut           =>
            Fabula.Check.Is_False
              (R, Peers.Is_Open (The_Peer), "the peer is open");

         when E_Check_Send_Fails     =>
            Send_Fails (R);
      end case;
   end Execute;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Handled := Evt in Peer_Step;
      if Handled then
         Execute (Evt, Ctx.W, Ctx.A, Ctx.Info, Ctx.R);
      end if;
   end Offer;

   procedure Reset is null;

   function Phase return String
   is ("-");

end Nuntius_Steps.Ws_Peer;
