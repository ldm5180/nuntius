with Ada.Real_Time;

with Fabula.Check.Ints;

with Nuntius.Http.Fetch.Curl;

with Loopback_Capture;

with Nuntius_Steps.Flows;
with Nuntius_World;      use Nuntius_World;
with Nuntius_World.Http; use Nuntius_World.Http;

package body Nuntius_Steps.Http is

   use Nuntius.Http.Fetch;

   --  Ready until something is sent; then a sync response, an async
   --  transfer in flight, a pumped completion, or a full table.
   type State is (Ready, Responded, Started, Completed, Filled);

   type Guard_Kind is (Always, Verb_Known, Method_Known, Limit_Read);

   type Action_Kind is
     (A_Nothing,
      A_Set_Agent,
      A_Send_Refused,
      A_Refuse_Verb,
      A_Recorded_Get,
      A_Recorded_Fetch,
      A_Pump,
      A_Start_Refused,
      A_Refuse_Method,
      A_Cancel,
      A_Wait,
      A_Fill,
      A_Check_Response_Failure,
      A_Check_Response_Status,
      A_Check_Wire,
      A_Check_Completion_Status,
      A_Check_No_Completion,
      A_Check_In_Flight,
      A_Check_Completion_Failure,
      A_Check_Within,
      A_Refuse_Limit,
      A_Check_Start_Refused,
      A_Check_All_Complete,
      A_Check_Response_Empty,
      A_Check_Slots_Taken);

   First_Capture : constant := 1;

   function Word (Ctx : Step_Context) return String
   is (Fabula.Args.Word (Ctx.A, First_Capture));

   function Is_Verb (Word : String) return Boolean is
      V     : Nuntius_World.Http.Verb;
      Found : Boolean;
   begin
      Verb_Named (Word, V, Found);
      return Found;
   end Is_Verb;

   function Is_Method (Word : String) return Boolean
   is (for some M in Method => M'Image = Word);

   function Evaluate
     (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean
   is
      pragma Unreferenced (Evt);
   begin
      return
        (case G is
           when Always       => True,
           when Verb_Known   => Is_Verb (Word (Ctx)),
           when Method_Known => Is_Method (Word (Ctx)),
           when Limit_Read   => Count_Read (Ctx));
   end Evaluate;

   ---------------------------------------------------------------------
   --  Actions.
   ---------------------------------------------------------------------

   function Since (T0 : Ada.Real_Time.Time) return Duration
   is (Ada.Real_Time.To_Duration
         (Ada.Real_Time."-" (Ada.Real_Time.Clock, T0)));

   --  Whether R is what a transport failure must be: Ok False, Status 0.
   function Failed (Result : Nuntius.Http.Response) return Boolean
   is (not Result.Ok and then Result.Status = 0);

   function Status_Text (Result : Nuntius.Http.Response) return String
   is ("Ok " & Result.Ok'Image & ", Status" & Result.Status'Image);

   procedure Send_Refused (Ctx : in out Step_Context)
   with Pre => Is_Verb (Word (Ctx))
   is
      V     : Nuntius_World.Http.Verb;
      Found : Boolean;
   begin
      Verb_Named (Word (Ctx), V, Found);
      Ctx.W.Client.Response := Send (V, Refused_URL);
   end Send_Refused;

   procedure Wait_For_Completion (Ctx : in out Step_Context) is
      T0 : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Pump_Until_Done (Ctx.W.Client.Done, Ctx.W.Client.Got);
      Ctx.W.Client.Elapsed := Since (T0);
   end Wait_For_Completion;

   --  Start transfers until the table is full, then one more.
   procedure Fill (Ctx : in out Step_Context) is
      Id : Request_Id;
   begin
      for K in 1 .. Nuntius.Http.Fetch.Curl.Max_In_Flight loop
         Async.Start (Request_For (Get, Refused_URL), Id);
         Ctx.W.Client.Started :=
           Ctx.W.Client.Started + (if Id = No_Request then 0 else 1);
      end loop;
      Async.Start (Request_For (Get, Refused_URL), Id);
      Ctx.W.Client.Refused := Id = No_Request;
   end Fill;

   --  Every started transfer completed, and the table drained.
   procedure Check_Drained (Ctx : in out Step_Context) is
      Done : Completion;
      Got  : Boolean;
      Seen : Natural := 0;
   begin
      while Async.In_Flight > 0 loop
         Pump_Until_Done (Done, Got);
         exit when not Got;
         Seen := Seen + 1;
      end loop;
      Fabula.Check.Ints.Equal
        (Ctx.R, Seen, Ctx.W.Client.Started, "completions");
      Fabula.Check.Ints.Equal (Ctx.R, Async.In_Flight, 0, "in flight after");
   end Check_Drained;

   procedure Check_Status_Of
     (Ctx : in out Step_Context; Result : Nuntius.Http.Response) is
   begin
      Fabula.Check.Ints.Equal
        (Ctx.R,
         Nuntius.Http.Reported_Status (Result),
         Fabula.Args.Int (Ctx.A, First_Capture),
         "status");
   end Check_Status_Of;

   procedure Execute
     (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind)
   is
      pragma Unreferenced (Evt);
   begin
      case A is
         when A_Nothing                  =>
            null;

         when A_Set_Agent                =>
            Nuntius.Http.Set_User_Agent
              (Fabula.Args.Text (Ctx.A, First_Capture));

         when A_Send_Refused             =>
            Send_Refused (Ctx);

         when A_Refuse_Verb              =>
            Fabula.Check.Fail_Step (Ctx.R, "no curl verb named " & Word (Ctx));

         when A_Recorded_Get             =>
            Ctx.W.Client.Response := Recorded_Get;

         when A_Recorded_Fetch           =>
            Recorded_Fetch (Ctx.W.Client.Done, Ctx.W.Client.Got);

         when A_Pump                     =>
            Async.Pump (Ctx.W.Client.Done, Ctx.W.Client.Got);

         when A_Start_Refused            =>
            Async.Start
              (Request_For (Method'Value (Word (Ctx)), Refused_URL),
               Ctx.W.Client.Id);

         when A_Refuse_Method            =>
            Fabula.Check.Fail_Step
              (Ctx.R, "no async method named " & Word (Ctx));

         when A_Cancel                   =>
            Async.Cancel (Ctx.W.Client.Id);

         when A_Wait                     =>
            Wait_For_Completion (Ctx);

         when A_Fill                     =>
            Fill (Ctx);

         when A_Check_Response_Failure   =>
            Fabula.Check.Is_True
              (Ctx.R,
               Failed (Ctx.W.Client.Response),
               Status_Text (Ctx.W.Client.Response));

         when A_Check_Response_Status    =>
            Check_Status_Of (Ctx, Ctx.W.Client.Response);

         when A_Check_Wire               =>
            Fabula.Check.Is_True
              (Ctx.R,
               Has
                 (Loopback_Capture.Head,
                  Fabula.Args.Text (Ctx.A, First_Capture)),
               "the head was: " & Head_Line (Loopback_Capture.Head));

         when A_Check_Completion_Status  =>
            Fabula.Check.Is_True
              (Ctx.R, Ctx.W.Client.Got, "a completion surfaced");
            Check_Status_Of (Ctx, Ctx.W.Client.Done.Result);

         when A_Check_No_Completion      =>
            Fabula.Check.Is_False
              (Ctx.R, Ctx.W.Client.Got, "a completion surfaced");

         when A_Check_In_Flight          =>
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Async.In_Flight,
               Fabula.Args.Int (Ctx.A, First_Capture),
               "in flight");

         when A_Check_Completion_Failure =>
            Fabula.Check.Is_True
              (Ctx.R, Ctx.W.Client.Got, "a completion surfaced");
            Fabula.Check.Is_True
              (Ctx.R,
               Failed (Ctx.W.Client.Done.Result),
               Status_Text (Ctx.W.Client.Done.Result));

         when A_Check_Within             =>
            Fabula.Check.Is_True
              (Ctx.R,
               Ctx.W.Client.Elapsed < Duration (Count (Ctx)),
               "took" & Ctx.W.Client.Elapsed'Image & " s");

         when A_Refuse_Limit             =>
            Refuse_Count (Ctx);

         when A_Check_Start_Refused      =>
            Fabula.Check.Is_True
              (Ctx.R,
               Ctx.W.Client.Refused,
               "the start past the table's bound");

         when A_Check_All_Complete       =>
            Check_Drained (Ctx);

         when A_Check_Response_Empty     =>
            Fabula.Check.Ints.Equal
              (Ctx.R, Length (Ctx.W.Client.Response.Reply), 0, "reply bytes");
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Length (Ctx.W.Client.Response.Location),
               0,
               "location bytes");

         when A_Check_Slots_Taken        =>
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Ctx.W.Client.Started,
               Nuntius.Http.Fetch.Curl.Max_In_Flight,
               "slots started");
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Async.In_Flight,
               Nuntius.Http.Fetch.Curl.Max_In_Flight,
               "in flight");
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

   Set_Agent                : constant Ev := (Kind => E_Set_Agent);
   Curl_Refused             : constant Ev := (Kind => E_Curl_Refused);
   Curl_Recorded            : constant Ev := (Kind => E_Curl_Recorded);
   Fetch_Recorded           : constant Ev := (Kind => E_Fetch_Recorded);
   Fetch_Pump               : constant Ev := (Kind => E_Fetch_Pump);
   Fetch_Start              : constant Ev := (Kind => E_Fetch_Start);
   Fetch_Cancel             : constant Ev := (Kind => E_Fetch_Cancel);
   Fetch_Until_Done         : constant Ev := (Kind => E_Fetch_Until_Done);
   Fetch_Fill               : constant Ev := (Kind => E_Fetch_Fill);
   Check_Response_Failure   : constant Ev :=
     (Kind => E_Check_Response_Failure);
   Check_Response_Status    : constant Ev := (Kind => E_Check_Response_Status);
   Check_Wire               : constant Ev := (Kind => E_Check_Wire);
   Check_Completion_Status  : constant Ev :=
     (Kind => E_Check_Completion_Status);
   Check_No_Completion      : constant Ev := (Kind => E_Check_No_Completion);
   Check_In_Flight          : constant Ev := (Kind => E_Check_In_Flight);
   Check_Completion_Failure : constant Ev :=
     (Kind => E_Check_Completion_Failure);
   Check_Within             : constant Ev := (Kind => E_Check_Within);
   Check_Start_Refused      : constant Ev := (Kind => E_Check_Start_Refused);
   Check_All_Complete       : constant Ev := (Kind => E_Check_All_Complete);
   Check_Response_Empty     : constant Ev := (Kind => E_Check_Response_Empty);
   Check_Slots_Taken        : constant Ev := (Kind => E_Check_Slots_Taken);

   --!format off
   Table : constant Transition_Table :=
     [Ready     + Set_Agent                  / A_Set_Agent                >= Ready,
      Ready     + Curl_Refused (Verb_Known)  / A_Send_Refused             >= Responded,
      Ready     + Curl_Refused               / A_Refuse_Verb              >= Ready,
      Ready     + Curl_Recorded              / A_Recorded_Get             >= Responded,
      Ready     + Fetch_Recorded             / A_Recorded_Fetch           >= Completed,
      Ready     + Fetch_Pump                 / A_Pump                     >= Completed,
      Ready     + Fetch_Start (Method_Known) / A_Start_Refused            >= Started,
      Ready     + Fetch_Start                / A_Refuse_Method            >= Ready,
      Ready     + Fetch_Fill                 / A_Fill                     >= Filled,
      Responded + Check_Response_Failure     / A_Check_Response_Failure   >= Responded,
      Responded + Check_Response_Status      / A_Check_Response_Status    >= Responded,
      Responded + Check_Wire                 / A_Check_Wire               >= Responded,
      Responded + Check_Response_Empty       / A_Check_Response_Empty     >= Responded,
      Started   + Fetch_Cancel               / A_Cancel                   >= Started,
      Started   + Fetch_Pump                 / A_Pump                     >= Completed,
      Started   + Fetch_Until_Done           / A_Wait                     >= Completed,
      Started   + Check_In_Flight            / A_Check_In_Flight          >= Started,
      Completed + Check_Completion_Status    / A_Check_Completion_Status  >= Completed,
      Completed + Check_Completion_Failure   / A_Check_Completion_Failure >= Completed,
      Completed + Check_No_Completion        / A_Check_No_Completion      >= Completed,
      Completed + Check_In_Flight            / A_Check_In_Flight          >= Completed,
      Completed + Check_Wire                 / A_Check_Wire               >= Completed,
      Completed + Check_Within (Limit_Read)  / A_Check_Within             >= Completed,
      Completed + Check_Within               / A_Refuse_Limit             >= Completed,
      Filled    + Check_Start_Refused        / A_Check_Start_Refused      >= Filled,
      Filled    + Check_Slots_Taken          / A_Check_Slots_Taken        >= Filled,
      Filled    + Check_All_Complete         / A_Check_All_Complete       >= Filled];
   --!format on

   Current : State := Ready;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Flow.Take (Table, Current, Ctx, Evt, Handled);
   end Offer;

   procedure Reset is
   begin
      Current := Ready;
   end Reset;

   function Phase return String
   is (Current'Image);

end Nuntius_Steps.Http;
