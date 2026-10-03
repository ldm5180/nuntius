with Ada.Characters.Handling;
with Ada.Streams;

with GNAT.Sockets;

with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius_Steps.Flows;
with Nuntius_World.Ws_Client;
with Nuntius_World.Ws_Script; use Nuntius_World.Ws_Script;

package body Nuntius_Steps.Ws_Client is

   use type Nuntius.Ws.Receive_Outcome;

   package Clients renames Nuntius_World.Ws_Client;

   --  Chosen while a client is picked and nothing is scripted; Peered
   --  once a peer waits for it; Connected once the client has dialed it.
   type State is (Chosen, Peered, Connected);

   type Guard_Kind is
     (Always, Shape_Known, Frames_Readable, Count_Given, Outcome_Known);

   type Action_Kind is
     (A_Nothing,
      A_Choose_Default,
      A_Choose_Shape,
      A_Choose_Impatient,
      A_Refuse_Shape,
      A_Start_Peer,
      A_Refuse_Frames,
      A_Dial_Refused,
      A_Connect,
      A_Receive,
      A_Receive_For,
      A_Receive_Burst,
      A_Until_Lost,
      A_Refuse_Count,
      A_Check_Dial_Failed,
      A_Check_Reception,
      A_Refuse_Outcome,
      A_Check_Message,
      A_Check_Pong,
      A_Check_In_Order,
      A_Check_Dropped,
      A_Check_Oversized,
      A_Check_No_Oversized,
      A_Check_Lost_Within);

   subtype Setup_Action is Action_Kind range A_Choose_Default .. A_Connect;
   subtype Receive_Action is Action_Kind range A_Receive .. A_Refuse_Count;
   subtype Check_Action is
     Action_Kind range A_Check_Dial_Failed .. A_Check_Lost_Within;

   First_Capture  : constant := 1;
   Second_Capture : constant := 2;

   function First (Ctx : Step_Context) return String
   is (Fabula.Args.Text (Ctx.A, First_Capture));

   ---------------------------------------------------------------------
   --  The frame table: a row's kind word, and what it scripts.
   ---------------------------------------------------------------------

   --  The frame table's two columns.
   Kind_Column : constant String := "kind";
   Text_Column : constant String := "text";

   type Row_Kind is
     (Text_Row,
      Start_Row,
      Continuation_Row,
      Ping_Row,
      Close_Row,
      Burst_Row,
      Oversize_Row,
      Rsv1_Row,
      Hold_Row);

   --  The rows whose text column is a count (frames, bytes or ms).
   subtype Counted_Row is Row_Kind range Burst_Row .. Hold_Row
   with Static_Predicate => Counted_Row /= Rsv1_Row;

   function Word_Of (K : Row_Kind) return String
   is (case K is
         when Text_Row         => "text",
         when Start_Row        => "text-start",
         when Continuation_Row => "continuation",
         when Ping_Row         => "ping",
         when Close_Row        => "close",
         when Burst_Row        => "burst",
         when Oversize_Row     => "oversize",
         when Rsv1_Row         => "rsv1",
         when Hold_Row         => "hold");

   function Is_Row (Word : String) return Boolean
   is (for some K in Row_Kind => Word_Of (K) = Word);

   function Row_Named (Word : String) return Row_Kind with Pre => Is_Row (Word)
   is
   begin
      for K in Row_Kind loop
         if Word_Of (K) = Word then
            return K;
         end if;
      end loop;
      raise Program_Error;  --  Is_Row said it is one
   end Row_Named;

   function Kind_At (Ctx : Step_Context; Row : Positive) return String
   is (Fabula.Args.Hash_Value (Ctx.A, Row, Kind_Column));

   function Text_At (Ctx : Step_Context; Row : Positive) return String
   is (Fabula.Args.Hash_Value (Ctx.A, Row, Text_Column));

   --  A row reads when its kind is known and, for a counted kind, its
   --  text is a whole number.
   function Row_Readable (Ctx : Step_Context; Row : Positive) return Boolean
   is (Is_Row (Kind_At (Ctx, Row))
       and then (Row_Named (Kind_At (Ctx, Row)) not in Counted_Row
                 or else Fabula.Numbers.Parse_Integer (Text_At (Ctx, Row))
                           .Ok));

   function Frames_Readable (Ctx : Step_Context) return Boolean
   is (Fabula.Args.Has_Table (Ctx.A)
       and then Fabula.Args.Has_Column (Ctx.A, Kind_Column)
       and then Fabula.Args.Has_Column (Ctx.A, Text_Column)
       and then (for all Row in 1 .. Fabula.Args.Row_Count (Ctx.A) - 1 =>
                   Row_Readable (Ctx, Row)));

   --  What a frame table that does not read lacks: the table, a column,
   --  or the first row that does not read, quoted.
   function Frames_Problem (Ctx : Step_Context) return String is
   begin
      if not Fabula.Args.Has_Table (Ctx.A)
        or else not Fabula.Args.Has_Column (Ctx.A, Kind_Column)
        or else not Fabula.Args.Has_Column (Ctx.A, Text_Column)
      then
         return "the step needs a kind | text table";
      end if;
      for Row in 1 .. Fabula.Args.Row_Count (Ctx.A) - 1 loop
         if not Row_Readable (Ctx, Row) then
            return
              "no frame row "
              & Kind_At (Ctx, Row)
              & " | "
              & Text_At (Ctx, Row);
         end if;
      end loop;
      return "";
   end Frames_Problem;

   function Outcome_Known (Word : String) return Boolean
   is (for some O in Nuntius.Ws.Receive_Outcome =>
         O'Image = Ada.Characters.Handling.To_Upper (Word));

   function Shape_Given (Ctx : Step_Context) return Boolean
   is (Count_Read (Ctx, First_Capture)
       and then Count_Read (Ctx, Second_Capture)
       and then Clients.Has_Shape
                  (Count (Ctx, First_Capture), Count (Ctx, Second_Capture)));

   function Evaluate
     (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean
   is
      pragma Unreferenced (Evt);
   begin
      return
        (case G is
           when Always          => True,
           when Shape_Known     => Shape_Given (Ctx),
           when Frames_Readable => Frames_Readable (Ctx),
           when Count_Given     => Count_Read (Ctx),
           when Outcome_Known   => Outcome_Known (First (Ctx)));
   end Evaluate;

   ---------------------------------------------------------------------
   --  Setting up: a client, a scripted peer, a dial.
   ---------------------------------------------------------------------

   --  The first byte of the two raw frames the table names: a text
   --  frame, and a text frame with RSV1 set.
   Text_Lead  : constant Ada.Streams.Stream_Element := 16#81#;
   Rsv1_Lead  : constant Ada.Streams.Stream_Element := 16#C1#;
   Rsv1_Bytes : constant := 5;

   Ms_Per_Second : constant := 1_000;

   Refused_Url : constant String := "ws://127.0.0.1:9/";

   --  The script steps one readable row adds; a ping also waits for its
   --  pong.
   procedure Add_Row
     (Plan  : in out Script;
      Count : in out Natural;
      Kind  : Row_Kind;
      Text  : String)
   is
      N : constant Natural :=
        Fabula.Numbers.Integer_Reads.Value_Or
          (Fabula.Numbers.Parse_Integer (Text), 0);

      procedure Add (S : Nuntius_World.Ws_Script.Step) is
      begin
         Count := Count + 1;
         Plan (Count) := S;
      end Add;
   begin
      case Kind is
         when Text_Row         =>
            Add (Text_Of (Text));

         when Start_Row        =>
            Add (Start_Of (Text));

         when Continuation_Row =>
            Add (Continued (Text));

         when Ping_Row         =>
            Add (Pinged);
            Add (Pong_Awaited);

         when Close_Row        =>
            Add (Closed);

         when Burst_Row        =>
            Add (Burst_Of (N));

         when Oversize_Row     =>
            Add (Raw_Of (Text_Lead, N));

         when Rsv1_Row         =>
            Add (Raw_Of (Rsv1_Lead, Rsv1_Bytes));

         when Hold_Row         =>
            Add (Held (Duration (N) / Ms_Per_Second));
      end case;
   end Add_Row;

   --  The peer the table scripts, started; its port is where the client
   --  connects.  Frames_Readable held, so every row reads.
   procedure Script_Peer (Ctx : in out Step_Context) is
      Plan  : Script (1 .. Max_Steps);
      Count : Natural := 1;
      Bound : GNAT.Sockets.Port_Type;
   begin
      Plan (1) := Upgraded;
      for Row in 1 .. Fabula.Args.Row_Count (Ctx.A) - 1 loop
         Add_Row
           (Plan, Count, Row_Named (Kind_At (Ctx, Row)), Text_At (Ctx, Row));
      end loop;
      Start_Scripted (Plan (1 .. Count), Bound);
      Ctx.W.Ws.Peer := Natural (Bound);
   end Script_Peer;

   procedure Choose_Shape (Ctx : in out Step_Context) is
      Found : Boolean;
   begin
      Clients.Choose
        (Count (Ctx, First_Capture), Count (Ctx, Second_Capture), Found);
   end Choose_Shape;

   procedure Setup_Act (A : Setup_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Choose_Default   =>
            Clients.Choose_Default;

         when A_Choose_Shape     =>
            Choose_Shape (Ctx);

         when A_Choose_Impatient =>
            Clients.Choose_Impatient;

         when A_Refuse_Shape     =>
            Fabula.Check.Fail
              (Ctx.R,
               "the world has no client instance of that ring and bound");

         when A_Start_Peer       =>
            Script_Peer (Ctx);

         when A_Refuse_Frames    =>
            Fabula.Check.Fail_Step (Ctx.R, Frames_Problem (Ctx));

         when A_Dial_Refused     =>
            Clients.Client.Connect (Refused_Url, Ctx.W.Ws.Dialed);

         when A_Connect          =>
            Clients.Client.Connect
              (Url (GNAT.Sockets.Port_Type (Ctx.W.Ws.Peer), "/v1"),
               Ctx.W.Ws.Dialed);
            Fabula.Check.Is_True
              (Ctx.R, Ctx.W.Ws.Dialed, "the handshake completed");
      end case;
   end Setup_Act;

   ---------------------------------------------------------------------
   --  Receiving.
   ---------------------------------------------------------------------

   --  Every receive reads into a buffer this long: past every frame
   --  bound the world's clients are instantiated with.
   Buffer_Bytes : constant := 512;

   --  How many patient receives a run until the loss may take.
   Max_Patient_Calls : constant := 10;

   --  A burst's frames carry their index modulo this.
   Byte_Values : constant := 256;

   procedure Keep
     (Ctx : in out Step_Context; Buf : String; Got : Nuntius.Ws.Reception) is
   begin
      Ctx.W.Ws.Got := Got;
      Ctx.W.Ws.Message :=
        To_Unbounded_String
          (if Got.Outcome = Nuntius.Ws.Delivered
           then Buf (Buf'First .. Got.Last)
           else "");
   end Keep;

   procedure Receive (Ctx : in out Step_Context) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Clients.Client.Receive (Buf, Got);
      Keep (Ctx, Buf, Got);
   end Receive;

   procedure Receive_For (Ctx : in out Step_Context; Ms : Natural) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Clients.Client.Receive_For (Buf, Duration (Ms) / Ms_Per_Second, Got);
      Keep (Ctx, Buf, Got);
   end Receive_For;

   --  N receives of a burst, whose frame I carries the byte I.
   procedure Receive_Burst (Ctx : in out Step_Context; N : Natural) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Ctx.W.Ws.Wanted := N;
      for I in 0 .. N - 1 loop
         Clients.Client.Receive (Buf, Got);
         if Got.Outcome = Nuntius.Ws.Delivered then
            Ctx.W.Ws.Received := Ctx.W.Ws.Received + 1;
            Ctx.W.Ws.In_Order :=
              Ctx.W.Ws.In_Order
              and then Got.Last = 1
              and then Character'Pos (Buf (1)) = I mod Byte_Values;
         end if;
      end loop;
   end Receive_Burst;

   procedure Receive_Until_Lost (Ctx : in out Step_Context; Ms : Natural) is
   begin
      for K in 1 .. Max_Patient_Calls loop
         Receive_For (Ctx, Ms);
         Ctx.W.Ws.Calls := K;
         exit when Ctx.W.Ws.Got.Outcome = Nuntius.Ws.Lost;
         if Ctx.W.Ws.Got.Outcome = Nuntius.Ws.Expired then
            Ctx.W.Ws.Timeouts := Ctx.W.Ws.Timeouts + 1;
         end if;
      end loop;
   end Receive_Until_Lost;

   procedure Receive_Act (A : Receive_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Receive       =>
            Receive (Ctx);

         when A_Receive_For   =>
            Receive_For (Ctx, Count (Ctx));

         when A_Receive_Burst =>
            Receive_Burst (Ctx, Count (Ctx));

         when A_Until_Lost    =>
            Receive_Until_Lost (Ctx, Count (Ctx));

         when A_Refuse_Count  =>
            Refuse_Count (Ctx);
      end case;
   end Receive_Act;

   ---------------------------------------------------------------------
   --  Checking.
   ---------------------------------------------------------------------

   function Losses return Nuntius.Ws.Loss_Report
   is (Clients.Client.Losses);

   procedure Check_Lost_In (Ctx : in out Step_Context) is
   begin
      Fabula.Check.Is_True
        (Ctx.R,
         Ctx.W.Ws.Got.Outcome = Nuntius.Ws.Lost,
         "the connection was lost");
      Fabula.Check.Ints.Less_Or_Equal
        (Ctx.R,
         Ctx.W.Ws.Calls,
         Fabula.Args.Int (Ctx.A, First_Capture),
         "receives");
      Fabula.Check.Ints.Greater_Or_Equal
        (Ctx.R,
         Ctx.W.Ws.Timeouts,
         Fabula.Args.Int (Ctx.A, Second_Capture),
         "healthy timeouts");
   end Check_Lost_In;

   procedure Check_Act (A : Check_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Check_Dial_Failed  =>
            Fabula.Check.Is_False
              (Ctx.R, Ctx.W.Ws.Dialed, "the dial succeeded");

         when A_Check_Reception    =>
            Fabula.Check.Is_True
              (Ctx.R,
               Ctx.W.Ws.Got.Outcome
               = Nuntius.Ws.Receive_Outcome'Value (First (Ctx)),
               "the reception was "
               & Ada.Characters.Handling.To_Lower
                   (Ctx.W.Ws.Got.Outcome'Image));

         when A_Refuse_Outcome     =>
            Fabula.Check.Fail_Step
              (Ctx.R, "no reception named " & First (Ctx));

         when A_Check_Message      =>
            Fabula.Check.Text_Equal
              (Ctx.R, To_String (Ctx.W.Ws.Message), First (Ctx));

         when A_Check_Pong         =>
            Fabula.Check.Is_True
              (Ctx.R, Result.Pong_Seen, "the peer read a pong");

         when A_Check_In_Order     =>
            Fabula.Check.Ints.Equal
              (Ctx.R, Ctx.W.Ws.Received, Ctx.W.Ws.Wanted, "delivered");
            Fabula.Check.Is_True (Ctx.R, Ctx.W.Ws.In_Order, "in order");

         when A_Check_Dropped      =>
            Fabula.Check.Ints.Greater (Ctx.R, Losses.Dropped, 0, "dropped");
            Fabula.Check.Ints.Equal (Ctx.R, Losses.Oversized, 0, "oversized");

         when A_Check_Oversized    =>
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Losses.Oversized,
               Fabula.Args.Int (Ctx.A, First_Capture),
               "oversized");
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Losses.Largest,
               Fabula.Args.Int (Ctx.A, Second_Capture),
               "largest");

         when A_Check_No_Oversized =>
            Fabula.Check.Ints.Equal (Ctx.R, Losses.Oversized, 0, "oversized");

         when A_Check_Lost_Within  =>
            Check_Lost_In (Ctx);
      end case;
   end Check_Act;

   procedure Execute
     (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind)
   is
      pragma Unreferenced (Evt);
   begin
      case A is
         when A_Nothing      =>
            null;

         when Setup_Action   =>
            Setup_Act (A, Ctx);

         when Receive_Action =>
            Receive_Act (A, Ctx);

         when Check_Action   =>
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

   Ws_Default         : constant Ev := (Kind => E_Ws_Default);
   Ws_Shaped          : constant Ev := (Kind => E_Ws_Shaped);
   Ws_Impatient       : constant Ev := (Kind => E_Ws_Impatient);
   Start_Peer         : constant Ev := (Kind => E_Start_Peer);
   Ws_Dial_Refused    : constant Ev := (Kind => E_Ws_Dial_Refused);
   Ws_Connect         : constant Ev := (Kind => E_Ws_Connect);
   Ws_Until_Lost      : constant Ev := (Kind => E_Ws_Until_Lost);
   Ws_Receive_For     : constant Ev := (Kind => E_Ws_Receive_For);
   Ws_Receive_Many    : constant Ev := (Kind => E_Ws_Receive_Many);
   Ws_Receive         : constant Ev := (Kind => E_Ws_Receive);
   Check_Dial_Failed  : constant Ev := (Kind => E_Check_Dial_Failed);
   Check_Reception    : constant Ev := (Kind => E_Check_Reception);
   Check_Message      : constant Ev := (Kind => E_Check_Message);
   Check_Pong         : constant Ev := (Kind => E_Check_Pong);
   Check_In_Order     : constant Ev := (Kind => E_Check_In_Order);
   Check_Dropped      : constant Ev := (Kind => E_Check_Dropped);
   Check_Oversized    : constant Ev := (Kind => E_Check_Oversized);
   Check_No_Oversized : constant Ev := (Kind => E_Check_No_Oversized);
   Check_Lost_Within  : constant Ev := (Kind => E_Check_Lost_Within);

   --!format off
   Table : constant Transition_Table :=
     [--  A client is chosen, a peer scripted, and the client dials it.
      Chosen    + Ws_Default                      / A_Choose_Default     >= Chosen,
      Chosen    + Ws_Shaped (Shape_Known)         / A_Choose_Shape       >= Chosen,
      Chosen    + Ws_Shaped                       / A_Refuse_Shape       >= Chosen,
      Chosen    + Ws_Impatient                    / A_Choose_Impatient   >= Chosen,
      Chosen    + Start_Peer (Frames_Readable)    / A_Start_Peer         >= Peered,
      Chosen    + Start_Peer                      / A_Refuse_Frames      >= Chosen,
      Peered    + Ws_Connect                      / A_Connect            >= Connected,

      --  An undialed client still answers, and refuses as it should.
      Chosen    + Ws_Receive                      / A_Receive            >= Chosen,
      Chosen    + Ws_Dial_Refused                 / A_Dial_Refused       >= Chosen,
      Chosen    + Check_Dial_Failed               / A_Check_Dial_Failed  >= Chosen,
      Chosen    + Check_Reception (Outcome_Known) / A_Check_Reception    >= Chosen,
      Chosen    + Check_Reception                 / A_Refuse_Outcome     >= Chosen,

      --  A connected client receives, and its receptions are checked.
      Connected + Ws_Receive                      / A_Receive            >= Connected,
      Connected + Ws_Receive_For (Count_Given)    / A_Receive_For        >= Connected,
      Connected + Ws_Receive_For                  / A_Refuse_Count       >= Connected,
      Connected + Ws_Receive_Many (Count_Given)   / A_Receive_Burst      >= Connected,
      Connected + Ws_Receive_Many                 / A_Refuse_Count       >= Connected,
      Connected + Ws_Until_Lost (Count_Given)     / A_Until_Lost         >= Connected,
      Connected + Ws_Until_Lost                   / A_Refuse_Count       >= Connected,
      Connected + Check_Reception (Outcome_Known) / A_Check_Reception    >= Connected,
      Connected + Check_Reception                 / A_Refuse_Outcome     >= Connected,
      Connected + Check_Message                   / A_Check_Message      >= Connected,
      Connected + Check_Pong                      / A_Check_Pong         >= Connected,
      Connected + Check_In_Order                  / A_Check_In_Order     >= Connected,
      Connected + Check_Dropped                   / A_Check_Dropped      >= Connected,
      Connected + Check_Oversized                 / A_Check_Oversized    >= Connected,
      Connected + Check_No_Oversized              / A_Check_No_Oversized >= Connected,
      Connected + Check_Lost_Within               / A_Check_Lost_Within  >= Connected];
   --!format on

   Current : State := Chosen;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Flow.Take (Table, Current, Ctx, Evt, Handled);
   end Offer;

   procedure Reset is
   begin
      Current := Chosen;
   end Reset;

   function Phase return String
   is (Current'Image);

end Nuntius_Steps.Ws_Client;
