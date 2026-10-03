with Ada.Characters.Handling;
with Ada.Streams;

with GNAT.Sockets;

with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius_World.Ws_Client;
with Nuntius_World.Ws_Script; use Nuntius_World.Ws_Script;

package body Nuntius_Steps.Ws_Client is

   use type Nuntius.Ws.Receive_Outcome;

   package Clients renames Nuntius_World.Ws_Client;

   subtype Number is Fabula.Numbers.Integer_Reads.Read;

   First_Capture  : constant := 1;
   Second_Capture : constant := 2;

   --  The frame table's two columns.
   Kind_Column : constant String := "kind";
   Text_Column : constant String := "text";

   --  Every receive reads into a buffer this long: past every frame
   --  bound the world's clients are instantiated with.
   Buffer_Bytes : constant := 512;

   --  The first byte of the two raw frames the table names: a text
   --  frame, and a text frame with RSV1 set.
   Text_Lead  : constant Ada.Streams.Stream_Element := 16#81#;
   Rsv1_Lead  : constant Ada.Streams.Stream_Element := 16#C1#;
   Rsv1_Bytes : constant := 5;

   --  How many patient receives a run until the loss may take.
   Max_Patient_Calls : constant := 10;

   Ms_Per_Second : constant := 1_000;

   Refused_Url : constant String := "ws://127.0.0.1:9/";

   ---------------------------------------------------------------------
   --  The frame table, as a script.
   ---------------------------------------------------------------------

   --  The steps one row adds; a ping also waits for its pong.
   procedure Add_Row
     (Plan  : in out Script;
      Count : in out Natural;
      Kind  : String;
      Text  : String;
      Ok    : out Boolean)
   is
      N : constant Number := Fabula.Numbers.Parse_Integer (Text);

      procedure Add (S : Nuntius_World.Ws_Script.Step) is
      begin
         Count := Count + 1;
         Plan (Count) := S;
      end Add;

      Value : constant Natural := (if N.Ok then N.Value else 0);
   begin
      Ok := True;
      if Kind = "text" then
         Add (Text_Of (Text));
      elsif Kind = "text-start" then
         Add (Start_Of (Text));
      elsif Kind = "continuation" then
         Add (Continued (Text));
      elsif Kind = "ping" then
         Add (Pinged);
         Add (Pong_Awaited);
      elsif Kind = "close" then
         Add (Closed);
      elsif Kind = "burst" and then N.Ok then
         Add (Burst_Of (Value));
      elsif Kind = "oversize" and then N.Ok then
         Add (Raw_Of (Text_Lead, Value));
      elsif Kind = "rsv1" then
         Add (Raw_Of (Rsv1_Lead, Rsv1_Bytes));
      elsif Kind = "hold" and then N.Ok then
         Add (Held (Duration (Value) / Ms_Per_Second));
      else
         Ok := False;
      end if;
   end Add_Row;

   --  The peer the table scripts, started; its port is where the
   --  client connects.
   procedure Start_From_Table
     (A    : Fabula.Args.List;
      Port : out Natural;
      R    : in out Fabula.Check.Outcome)
   is
      Plan  : Script (1 .. Max_Steps);
      Count : Natural := 1;
      Ok    : Boolean := True;
      Bound : GNAT.Sockets.Port_Type;
   begin
      Port := 0;
      Plan (1) := Upgraded;
      if not Fabula.Args.Has_Table (A)
        or else not Fabula.Args.Has_Column (A, Kind_Column)
        or else not Fabula.Args.Has_Column (A, Text_Column)
      then
         Fabula.Check.Fail_Step (R, "the step needs a kind | text table");
         return;
      end if;
      for Row in 1 .. Fabula.Args.Row_Count (A) - 1 loop
         Add_Row
           (Plan,
            Count,
            Fabula.Args.Hash_Value (A, Row, Kind_Column),
            Fabula.Args.Hash_Value (A, Row, Text_Column),
            Ok);
         if not Ok then
            Fabula.Check.Fail_Step
              (R,
               "no frame row "
               & Fabula.Args.Hash_Value (A, Row, Kind_Column)
               & " | "
               & Fabula.Args.Hash_Value (A, Row, Text_Column));
            return;
         end if;
      end loop;
      Start_Scripted (Plan (1 .. Count), Bound);
      Port := Natural (Bound);
   end Start_From_Table;

   ---------------------------------------------------------------------
   --  Receiving.
   ---------------------------------------------------------------------

   procedure Keep
     (Ctx : in out World; Buf : String; Got : Nuntius.Ws.Reception) is
   begin
      Ctx.Ws.Got := Got;
      Ctx.Ws.Message :=
        To_Unbounded_String
          (if Got.Outcome = Nuntius.Ws.Delivered
           then Buf (Buf'First .. Got.Last)
           else "");
   end Keep;

   procedure Receive (Ctx : in out World) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Clients.Client.Receive (Buf, Got);
      Keep (Ctx, Buf, Got);
   end Receive;

   procedure Receive_For (Ctx : in out World; Ms : Natural) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Clients.Client.Receive_For (Buf, Duration (Ms) / Ms_Per_Second, Got);
      Keep (Ctx, Buf, Got);
   end Receive_For;

   --  N receives of a burst, whose frame I carries the byte I.
   procedure Receive_Burst (Ctx : in out World; N : Natural) is
      Buf : String (1 .. Buffer_Bytes);
      Got : Nuntius.Ws.Reception;
   begin
      Ctx.Ws.Wanted := N;
      for I in 0 .. N - 1 loop
         Clients.Client.Receive (Buf, Got);
         if Got.Outcome = Nuntius.Ws.Delivered then
            Ctx.Ws.Received := Ctx.Ws.Received + 1;
            Ctx.Ws.In_Order :=
              Ctx.Ws.In_Order
              and then Got.Last = 1
              and then Character'Pos (Buf (1)) = I mod 256;
         end if;
      end loop;
   end Receive_Burst;

   procedure Receive_Until_Lost (Ctx : in out World; Ms : Natural) is
   begin
      for K in 1 .. Max_Patient_Calls loop
         Receive_For (Ctx, Ms);
         Ctx.Ws.Calls := K;
         exit when Ctx.Ws.Got.Outcome = Nuntius.Ws.Lost;
         if Ctx.Ws.Got.Outcome = Nuntius.Ws.Expired then
            Ctx.Ws.Timeouts := Ctx.Ws.Timeouts + 1;
         end if;
      end loop;
   end Receive_Until_Lost;

   --  Run Act with the step's integer capture N, or fail the read.
   generic
      with procedure Act (Ctx : in out World; Value : Natural);
   procedure With_Int
     (Ctx : in out World; N : Number; R : in out Fabula.Check.Outcome);

   procedure With_Int
     (Ctx : in out World; N : Number; R : in out Fabula.Check.Outcome) is
   begin
      if N.Ok and then N.Value >= 0 then
         Act (Ctx, N.Value);
      elsif N.Ok then
         Fabula.Check.Fail_Step (R, "a count cannot be negative");
      else
         Fabula.Check.Ints.Fail_Read (R, N.Error);
      end if;
   end With_Int;

   procedure Patient is new With_Int (Receive_For);
   procedure Burst is new With_Int (Receive_Burst);
   procedure Until_Lost is new With_Int (Receive_Until_Lost);

   ---------------------------------------------------------------------
   --  Setting up and checking.
   ---------------------------------------------------------------------

   procedure Choose_Shape
     (A : Fabula.Args.List; R : in out Fabula.Check.Outcome)
   is
      Depth : constant Number := Fabula.Args.Int (A, First_Capture);
      Bytes : constant Number := Fabula.Args.Int (A, Second_Capture);
      Found : Boolean := False;
   begin
      if Depth.Ok
        and then Bytes.Ok
        and then Depth.Value >= 0
        and then Bytes.Value >= 0
      then
         Clients.Choose (Depth.Value, Bytes.Value, Found);
      end if;
      if not Found then
         Fabula.Check.Fail
           (R, "the world has no client instance of that ring and bound");
      end if;
   end Choose_Shape;

   procedure Connect
     (Ctx : in out World; Port : Natural; R : in out Fabula.Check.Outcome) is
   begin
      Clients.Client.Connect
        (Url (GNAT.Sockets.Port_Type (Port), "/v1"), Ctx.Ws.Dialed);
      Fabula.Check.Is_True (R, Ctx.Ws.Dialed, "the handshake completed");
   end Connect;

   procedure Check_Outcome_Named
     (Ctx : World; Word : String; R : in out Fabula.Check.Outcome)
   is
      Wanted : Nuntius.Ws.Receive_Outcome;
   begin
      Wanted := Nuntius.Ws.Receive_Outcome'Value (Word);
      Fabula.Check.Is_True
        (R,
         Ctx.Ws.Got.Outcome = Wanted,
         "the reception was "
         & Ada.Characters.Handling.To_Lower (Ctx.Ws.Got.Outcome'Image));
   exception
      when Constraint_Error =>
         Fabula.Check.Fail_Step (R, "no reception named " & Word);
   end Check_Outcome_Named;

   procedure Check_Oversize_Tally
     (A : Fabula.Args.List; R : in out Fabula.Check.Outcome)
   is
      L : constant Nuntius.Ws.Loss_Report := Clients.Client.Losses;
   begin
      Fabula.Check.Ints.Equal
        (R, L.Oversized, Fabula.Args.Int (A, First_Capture), "oversized");
      Fabula.Check.Ints.Equal
        (R, L.Largest, Fabula.Args.Int (A, Second_Capture), "largest");
   end Check_Oversize_Tally;

   procedure Check_Lost_In
     (Ctx : World; A : Fabula.Args.List; R : in out Fabula.Check.Outcome)
   is
      Calls    : constant Number := Fabula.Args.Int (A, First_Capture);
      Timeouts : constant Number := Fabula.Args.Int (A, Second_Capture);
   begin
      Fabula.Check.Is_True
        (R, Ctx.Ws.Got.Outcome = Nuntius.Ws.Lost, "the connection was lost");
      Fabula.Check.Ints.Less_Or_Equal (R, Ctx.Ws.Calls, Calls, "receives");
      Fabula.Check.Ints.Greater_Or_Equal
        (R, Ctx.Ws.Timeouts, Timeouts, "healthy timeouts");
   end Check_Lost_In;

   Peer_Port : Natural := 0;

   procedure Execute
     (S   : Ws_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome) is
   begin
      case S is
         when E_Ws_Default         =>
            Clients.Choose_Default;

         when E_Ws_Shaped          =>
            Choose_Shape (A, R);

         when E_Ws_Impatient       =>
            Clients.Choose_Impatient;

         when E_Start_Peer         =>
            Start_From_Table (A, Peer_Port, R);

         when E_Ws_Dial_Refused    =>
            Clients.Client.Connect (Refused_Url, Ctx.Ws.Dialed);

         when E_Ws_Connect         =>
            Connect (Ctx, Peer_Port, R);

         when E_Ws_Until_Lost      =>
            Until_Lost (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Ws_Receive_For     =>
            Patient (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Ws_Receive_Many    =>
            Burst (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Ws_Receive         =>
            Receive (Ctx);

         when E_Check_Dial_Failed  =>
            Fabula.Check.Is_False (R, Ctx.Ws.Dialed, "the dial succeeded");

         when E_Check_Reception    =>
            Check_Outcome_Named (Ctx, Fabula.Args.Word (A, First_Capture), R);

         when E_Check_Message      =>
            Fabula.Check.Text_Equal
              (R,
               To_String (Ctx.Ws.Message),
               Fabula.Args.Text (A, First_Capture));

         when E_Check_Pong         =>
            Fabula.Check.Is_True (R, Result.Pong_Seen, "the peer read a pong");

         when E_Check_In_Order     =>
            Fabula.Check.Ints.Equal
              (R, Ctx.Ws.Received, Ctx.Ws.Wanted, "delivered");
            Fabula.Check.Is_True (R, Ctx.Ws.In_Order, "in order");

         when E_Check_Dropped      =>
            Fabula.Check.Ints.Greater
              (R, Clients.Client.Losses.Dropped, 0, "dropped");
            Fabula.Check.Ints.Equal
              (R, Clients.Client.Losses.Oversized, 0, "oversized");

         when E_Check_Oversized    =>
            Check_Oversize_Tally (A, R);

         when E_Check_No_Oversized =>
            Fabula.Check.Ints.Equal
              (R, Clients.Client.Losses.Oversized, 0, "oversized");

         when E_Check_Lost_Within  =>
            Check_Lost_In (Ctx, A, R);
      end case;
   end Execute;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Handled := Evt in Ws_Step;
      if Handled then
         Execute (Evt, Ctx.W, Ctx.A, Ctx.R);
      end if;
   end Offer;

   procedure Reset is null;

   function Phase return String
   is ("-");

end Nuntius_Steps.Ws_Client;
