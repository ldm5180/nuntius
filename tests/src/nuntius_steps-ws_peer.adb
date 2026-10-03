with Ada.Characters.Handling;
with Ada.Directories;

with GNAT.Sockets;

with Fabula.Check.Ints;

with Nuntius.Codings;
with Nuntius.Deflate;
with Nuntius.Rfc6455; use Nuntius.Rfc6455;

with Nuntius_Steps.Flows;
with Nuntius_World;         use Nuntius_World;
with Nuntius_World.Browser; use Nuntius_World.Browser;

package body Nuntius_Steps.Ws_Peer is

   use type Peers.Pump_Outcome;

   --  Unpaired until a pair opens; Paired while frames go either way;
   --  Pumped once the peer has read, which its checks need.
   type State is (Unpaired, Paired, Pumped);

   type Guard_Kind is
     (Always, Count_Given, Close_Code_Given, Bytes_Found, Outcome_Known);

   type Action_Kind is
     (A_Nothing,
      A_Again,
      --  Opening and sending.
      A_Pair_Plain,
      A_Pair_Deflated,
      A_Peer_Big,
      A_Peer_Packed,
      A_Peer_Text,
      A_Browser_Ping,
      A_Browser_Close,
      A_Browser_Long,
      A_Browser_Binary,
      A_Browser_Rsv1,
      A_Browser_Ping_Rsv1,
      A_Browser_Packed_Json,
      A_Browser_Zeros,
      A_Browser_Named,
      A_Browser_Json,
      A_Hang_Up,
      A_Pump,
      A_Refuse_Count,
      A_Refuse_Close_Code,
      A_Refuse_Bytes,
      --  Checking.
      A_Check_Pump,
      A_Refuse_Outcome,
      A_Check_Read_Sent,
      A_Check_Text_Frame,
      A_Check_Text_Length,
      A_Check_Packed_Frame,
      A_Check_Pong_Frame,
      A_Check_Close_Frame,
      A_Check_Shut,
      A_Check_Send_Fails);

   subtype Send_Action is Action_Kind range A_Pair_Plain .. A_Refuse_Bytes;
   subtype Check_Action is
     Action_Kind range A_Check_Pump .. A_Check_Send_Fails;

   First_Capture : constant := 1;

   function First (Ctx : Step_Context) return String
   is (Fabula.Args.Text (Ctx.A, First_Capture));

   --  The longest named sequence a feature can send.
   Max_Named_Bytes : constant := 4_096;

   --  Where the feature file naming a sequence keeps its bytes.
   function Bytes_Dir (Ctx : Step_Context) return String
   is (Ada.Directories.Containing_Directory
         (Fabula.Frames.Value (Ctx.Info.File))
       & "/bytes");

   function Named_Exists (Ctx : Step_Context) return Boolean is
      Buf  : Octets (1 .. Max_Named_Bytes);
      Last : Natural;
      Ok   : Boolean;
   begin
      Named_Bytes (Bytes_Dir (Ctx), First (Ctx), Buf, Last, Ok);
      return Ok;
   end Named_Exists;

   function Is_Outcome (Word : String) return Boolean
   is (for some O in Peers.Pump_Outcome =>
         O'Image = Ada.Characters.Handling.To_Upper (Word));

   function Evaluate
     (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean
   is
      pragma Unreferenced (Evt);
   begin
      return
        (case G is
           when Always           => True,
           when Count_Given      => Count_Read (Ctx),
           when Close_Code_Given =>
             Count_Read (Ctx) and then Count (Ctx) in Close_Code,
           when Bytes_Found      => Named_Exists (Ctx),
           when Outcome_Known    => Is_Outcome (First (Ctx)));
   end Evaluate;

   ---------------------------------------------------------------------
   --  Opening and sending.
   ---------------------------------------------------------------------

   --  The first byte of each frame the browser or the peer sends here:
   --  FIN, the RSV bits and the opcode.
   Text_Lead      : constant Octet := 16#81#;
   Packed_Lead    : constant Octet := 16#C1#;
   Binary_Lead    : constant Octet := 16#82#;
   Ping_Rsv1_Lead : constant Octet := 16#C9#;
   Pong_Lead      : constant Octet := 16#8A#;
   Close_Lead     : constant Octet := 16#88#;

   procedure Peer_Text (Ctx : in out Step_Context; Text : String) is
      Ok : Boolean;
   begin
      Peers.Send_Text (The_Peer, Text, Ok);
      Fabula.Check.Is_True (Ctx.R, Ok, "the peer's send");
   end Peer_Text;

   procedure Peer_Packed (Ctx : in out Step_Context) is
      Text   : constant String := Json_Of (Count (Ctx));
      Packed : constant Octets := Nuntius.Deflate.Pack (Text);
      Ok     : Boolean;
   begin
      Ctx.W.Peer.Packed := To_Unbounded_String (Chars_Of (Packed));
      Peers.Send_Packed (The_Peer, Text, Packed, Ok);
      Fabula.Check.Is_True (Ctx.R, Ok, "the peer's send");
   end Peer_Packed;

   procedure Send_Named (Ctx : in out Step_Context) is
      Buf  : Octets (1 .. Max_Named_Bytes);
      Last : Natural;
      Ok   : Boolean;
   begin
      Named_Bytes (Bytes_Dir (Ctx), First (Ctx), Buf, Last, Ok);
      Browser_Frame (Browser_Sock, Packed_Lead, Buf (1 .. Last));
   end Send_Named;

   procedure Browser_Says (Ctx : in out Step_Context; Text : String) is
   begin
      Ctx.W.Peer.Sent := To_Unbounded_String (Text);
      Browser_Text (Browser_Sock, Text);
   end Browser_Says;

   procedure Browser_Packs (Ctx : in out Step_Context; Text : String) is
   begin
      Ctx.W.Peer.Sent := To_Unbounded_String (Text);
      Browser_Frame (Browser_Sock, Packed_Lead, Nuntius.Deflate.Pack (Text));
   end Browser_Packs;

   procedure Hang_Up is
   begin
      GNAT.Sockets.Close_Socket (Browser_Sock);
      Browser_Sock := GNAT.Sockets.No_Socket;
   end Hang_Up;

   procedure Pump (Ctx : in out Step_Context) is
      Into : String (1 .. Max_Inbound);
      Last : Natural;
   begin
      Ctx.W.Peer.Outcome := Peers.Pump (The_Peer, True, Into, Last);
      Ctx.W.Peer.Read :=
        To_Unbounded_String
          (if Ctx.W.Peer.Outcome = Peers.Message
           then Into (1 .. Last)
           else "");
   end Pump;

   procedure Send_Act (A : Send_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Pair_Plain          =>
            Open_Pair (Nuntius.Codings.Plain);

         when A_Pair_Deflated       =>
            Open_Pair (Nuntius.Codings.Deflated);

         when A_Peer_Big            =>
            Peer_Text (Ctx, [1 .. Count (Ctx) => 'z']);

         when A_Peer_Packed         =>
            Peer_Packed (Ctx);

         when A_Peer_Text           =>
            Peer_Text (Ctx, First (Ctx));

         when A_Browser_Ping        =>
            Browser_Control (Browser_Sock, Op_Ping, Bytes_Of (First (Ctx)));

         when A_Browser_Close       =>
            Browser_Control
              (Browser_Sock, Op_Close, Close_Payload (Count (Ctx)));

         when A_Browser_Long        =>
            Browser_Text (Browser_Sock, [1 .. Count (Ctx) => 'x']);

         when A_Browser_Binary      =>
            Browser_Frame (Browser_Sock, Binary_Lead, Bytes_Of ("a"));

         when A_Browser_Rsv1        =>
            Browser_Frame (Browser_Sock, Packed_Lead, Bytes_Of ("a"));

         when A_Browser_Ping_Rsv1   =>
            Browser_Frame (Browser_Sock, Ping_Rsv1_Lead, []);

         when A_Browser_Packed_Json =>
            Browser_Packs (Ctx, Json_Of (Count (Ctx)));

         when A_Browser_Zeros       =>
            Browser_Frame
              (Browser_Sock,
               Packed_Lead,
               Nuntius.Deflate.Pack ([1 .. Count (Ctx) => '0']));

         when A_Browser_Named       =>
            Send_Named (Ctx);

         when A_Browser_Json        =>
            Browser_Says (Ctx, First (Ctx));

         when A_Hang_Up             =>
            Hang_Up;

         when A_Pump                =>
            Pump (Ctx);

         when A_Refuse_Count        =>
            Refuse_Count (Ctx);

         when A_Refuse_Close_Code   =>
            Fabula.Check.Fail_Step (Ctx.R, "not a close code");

         when A_Refuse_Bytes        =>
            Fabula.Check.Fail_Step
              (Ctx.R,
               "no bytes named " & First (Ctx) & " in " & Bytes_Dir (Ctx));
      end case;
   end Send_Act;

   ---------------------------------------------------------------------
   --  Checking what each end got.
   ---------------------------------------------------------------------

   Octet_Base : constant := 256;

   --  The next server frame: Lead, unmasked, and of Size bytes; its
   --  payload is Payload unless Size_Only.
   procedure Expect_Frame
     (Ctx       : in out Step_Context;
      Lead      : Octet;
      Payload   : String;
      Size_Only : Boolean := False)
   is
      Got_Lead : Octet;
      Masked   : Boolean;
      Got      : Unbounded_String;
      Ok       : Boolean;
   begin
      Read_Server_Frame (Browser_Sock, Got_Lead, Masked, Got, Ok);
      Fabula.Check.Is_True (Ctx.R, Ok, "a whole frame arrived");
      Fabula.Check.Ints.Equal
        (Ctx.R, Integer (Got_Lead), Integer (Lead), "the first byte");
      Fabula.Check.Is_False (Ctx.R, Masked, "a server frame is masked");
      Fabula.Check.Ints.Equal
        (Ctx.R, Length (Got), Payload'Length, "the length");
      Fabula.Check.Is_True
        (Ctx.R, Size_Only or else To_String (Got) = Payload, "the payload");
   end Expect_Frame;

   --  The two payload bytes a close with Code carries.
   function Code_Bytes (Code : Natural) return String
   is ([Character'Val (Code / Octet_Base),
        Character'Val (Code mod Octet_Base)])
   with Pre => Code < Octet_Base * Octet_Base;

   procedure Check_Act (A : Check_Action; Ctx : in out Step_Context) is
      Ok : Boolean;
   begin
      case A is
         when A_Check_Pump         =>
            Fabula.Check.Is_True
              (Ctx.R,
               Ctx.W.Peer.Outcome = Peers.Pump_Outcome'Value (First (Ctx)),
               "the pump was "
               & Ada.Characters.Handling.To_Lower (Ctx.W.Peer.Outcome'Image));

         when A_Refuse_Outcome     =>
            Fabula.Check.Fail_Step
              (Ctx.R, "no pump outcome named " & First (Ctx));

         when A_Check_Read_Sent    =>
            Fabula.Check.Is_True
              (Ctx.R,
               Ctx.W.Peer.Read = Ctx.W.Peer.Sent,
               "the peer read what was sent");

         when A_Check_Text_Frame   =>
            Expect_Frame (Ctx, Text_Lead, First (Ctx));

         when A_Check_Text_Length  =>
            Expect_Frame
              (Ctx, Text_Lead, [1 .. Count (Ctx) => ' '], Size_Only => True);

         when A_Check_Packed_Frame =>
            Expect_Frame (Ctx, Packed_Lead, To_String (Ctx.W.Peer.Packed));

         when A_Check_Pong_Frame   =>
            Expect_Frame (Ctx, Pong_Lead, First (Ctx));

         when A_Check_Close_Frame  =>
            Expect_Frame (Ctx, Close_Lead, Code_Bytes (Count (Ctx)));

         when A_Check_Shut         =>
            Fabula.Check.Is_False
              (Ctx.R, Peers.Is_Open (The_Peer), "the peer is open");

         when A_Check_Send_Fails   =>
            Peers.Send_Text (The_Peer, "anyone there", Ok);
            Fabula.Check.Is_False (Ctx.R, Ok, "the send succeeded");
      end case;
   end Check_Act;

   procedure Execute
     (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind) is
   begin
      case A is
         when A_Nothing    =>
            null;

         when A_Again      =>
            Then_Take (Ctx, Evt);

         when Send_Action  =>
            Send_Act (A, Ctx);

         when Check_Action =>
            Check_Act (A, Ctx);
      end case;
   end Execute;

   ---------------------------------------------------------------------
   --  The table.
   ---------------------------------------------------------------------

   package Flow is new
     Nuntius_Steps.Flows
       (State       => State,
        Guard_Kind  => Guard_Kind,
        Action_Kind => Action_Kind,
        Evaluate    => Evaluate,
        Execute     => Execute,
        Always      => Always,
        Nothing     => A_Nothing);

   use Flow.Machines;
   use Flow.Op;

   Pair_Plain           : constant Ev := (Kind => E_Pair_Plain);
   Pair_Deflated        : constant Ev := (Kind => E_Pair_Deflated);
   Peer_Send_Big        : constant Ev := (Kind => E_Peer_Send_Big);
   Peer_Send_Packed     : constant Ev := (Kind => E_Peer_Send_Packed);
   Peer_Send_Text       : constant Ev := (Kind => E_Peer_Send_Text);
   Browser_Ping         : constant Ev := (Kind => E_Browser_Ping);
   Browser_Close        : constant Ev := (Kind => E_Browser_Close);
   Browser_Long         : constant Ev := (Kind => E_Browser_Long);
   Browser_Binary       : constant Ev := (Kind => E_Browser_Binary);
   Browser_Rsv1         : constant Ev := (Kind => E_Browser_Rsv1);
   Browser_Ping_Rsv1    : constant Ev := (Kind => E_Browser_Ping_Rsv1);
   Browser_Packed_Json  : constant Ev := (Kind => E_Browser_Packed_Json);
   Browser_Packed_Zeros : constant Ev := (Kind => E_Browser_Packed_Zeros);
   Browser_Named        : constant Ev := (Kind => E_Browser_Named);
   Browser_Json         : constant Ev := (Kind => E_Browser_Json);
   Browser_Hangs_Up     : constant Ev := (Kind => E_Browser_Hangs_Up);
   Peer_Pump            : constant Ev := (Kind => E_Peer_Pump);
   Check_Pump           : constant Ev := (Kind => E_Check_Pump);
   Check_Read_Sent      : constant Ev := (Kind => E_Check_Read_Sent);
   Check_Text_Frame     : constant Ev := (Kind => E_Check_Text_Frame);
   Check_Text_Length    : constant Ev := (Kind => E_Check_Text_Length);
   Check_Packed_Frame   : constant Ev := (Kind => E_Check_Packed_Frame);
   Check_Pong_Frame     : constant Ev := (Kind => E_Check_Pong_Frame);
   Check_Close_Frame    : constant Ev := (Kind => E_Check_Close_Frame);
   Check_Shut           : constant Ev := (Kind => E_Check_Shut);
   Check_Send_Fails     : constant Ev := (Kind => E_Check_Send_Fails);

   --!format off
   Table : constant Transition_Table :=
     [Unpaired + Pair_Plain                         / A_Pair_Plain          >= Paired,
      Unpaired + Pair_Deflated                      / A_Pair_Deflated       >= Paired,

      --  Either end sends; a count, a close code or a named sequence
      --  that does not read is refused.
      Paired   + Peer_Send_Big (Count_Given)        / A_Peer_Big            >= Paired,
      Paired   + Peer_Send_Big                      / A_Refuse_Count        >= Paired,
      Paired   + Peer_Send_Packed (Count_Given)     / A_Peer_Packed         >= Paired,
      Paired   + Peer_Send_Packed                   / A_Refuse_Count        >= Paired,
      Paired   + Peer_Send_Text                     / A_Peer_Text           >= Paired,
      Paired   + Browser_Ping                       / A_Browser_Ping        >= Paired,
      Paired   + Browser_Close (Close_Code_Given)   / A_Browser_Close       >= Paired,
      Paired   + Browser_Close                      / A_Refuse_Close_Code   >= Paired,
      Paired   + Browser_Long (Count_Given)         / A_Browser_Long        >= Paired,
      Paired   + Browser_Long                       / A_Refuse_Count        >= Paired,
      Paired   + Browser_Binary                     / A_Browser_Binary      >= Paired,
      Paired   + Browser_Rsv1                       / A_Browser_Rsv1        >= Paired,
      Paired   + Browser_Ping_Rsv1                  / A_Browser_Ping_Rsv1   >= Paired,
      Paired   + Browser_Packed_Json (Count_Given)  / A_Browser_Packed_Json >= Paired,
      Paired   + Browser_Packed_Json                / A_Refuse_Count        >= Paired,
      Paired   + Browser_Packed_Zeros (Count_Given) / A_Browser_Zeros       >= Paired,
      Paired   + Browser_Packed_Zeros               / A_Refuse_Count        >= Paired,
      Paired   + Browser_Named (Bytes_Found)        / A_Browser_Named       >= Paired,
      Paired   + Browser_Named                      / A_Refuse_Bytes        >= Paired,
      Paired   + Browser_Json                       / A_Browser_Json        >= Paired,
      Paired   + Browser_Hangs_Up                   / A_Hang_Up             >= Paired,
      Paired   + Peer_Pump                          / A_Pump                >= Pumped,

      --  After a pump, a send starts the exchange over: back to Paired,
      --  where the send is taken again.
      Pumped   + Peer_Send_Big                      / A_Again               >= Paired,
      Pumped   + Peer_Send_Packed                   / A_Again               >= Paired,
      Pumped   + Peer_Send_Text                     / A_Again               >= Paired,
      Pumped   + Browser_Ping                       / A_Again               >= Paired,
      Pumped   + Browser_Close                      / A_Again               >= Paired,
      Pumped   + Browser_Long                       / A_Again               >= Paired,
      Pumped   + Browser_Binary                     / A_Again               >= Paired,
      Pumped   + Browser_Rsv1                       / A_Again               >= Paired,
      Pumped   + Browser_Ping_Rsv1                  / A_Again               >= Paired,
      Pumped   + Browser_Packed_Json                / A_Again               >= Paired,
      Pumped   + Browser_Packed_Zeros               / A_Again               >= Paired,
      Pumped   + Browser_Named                      / A_Again               >= Paired,
      Pumped   + Browser_Json                       / A_Again               >= Paired,
      Pumped   + Browser_Hangs_Up                   / A_Again               >= Paired,

      --  What the browser reads, once the peer has sent or answered.
      Paired   + Check_Text_Frame                   / A_Check_Text_Frame    >= Paired,
      Paired   + Check_Text_Length (Count_Given)    / A_Check_Text_Length   >= Paired,
      Paired   + Check_Text_Length                  / A_Refuse_Count        >= Paired,
      Paired   + Check_Packed_Frame                 / A_Check_Packed_Frame  >= Paired,
      Pumped   + Check_Pong_Frame                   / A_Check_Pong_Frame    >= Pumped,
      Pumped   + Check_Close_Frame (Close_Code_Given) / A_Check_Close_Frame >= Pumped,
      Pumped   + Check_Close_Frame                  / A_Refuse_Close_Code   >= Pumped,

      --  What the pump did.
      Pumped   + Check_Pump (Outcome_Known)         / A_Check_Pump          >= Pumped,
      Pumped   + Check_Pump                         / A_Refuse_Outcome      >= Pumped,
      Pumped   + Check_Read_Sent                    / A_Check_Read_Sent     >= Pumped,
      Pumped   + Check_Shut                         / A_Check_Shut          >= Pumped,
      Pumped   + Check_Send_Fails                   / A_Check_Send_Fails    >= Pumped];
   --!format on

   Current : State := Unpaired;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Flow.Take (Table, Current, Ctx, Evt, Handled);
   end Offer;

   procedure Reset is
   begin
      Current := Unpaired;
   end Reset;

   function Phase return String
   is (Current'Image);

end Nuntius_Steps.Ws_Peer;
