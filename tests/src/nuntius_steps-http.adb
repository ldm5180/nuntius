with Ada.Real_Time;

with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius.Http.Fetch.Curl;

with Loopback_Capture;

with Nuntius_World;      use Nuntius_World;
with Nuntius_World.Http; use Nuntius_World.Http;

package body Nuntius_Steps.Http is

   use Nuntius.Http.Fetch;

   subtype Number is Fabula.Numbers.Integer_Reads.Read;

   First_Capture : constant := 1;

   function Since (T0 : Ada.Real_Time.Time) return Duration
   is (Ada.Real_Time.To_Duration
         (Ada.Real_Time."-" (Ada.Real_Time.Clock, T0)));

   --  Whether R is what a transport failure must be: Ok False, Status 0.
   function Failed (Result : Nuntius.Http.Response) return Boolean
   is (not Result.Ok and then Result.Status = 0);

   function Status_Text (Result : Nuntius.Http.Response) return String
   is ("Ok " & Result.Ok'Image & ", Status" & Result.Status'Image);

   procedure Send_Refused
     (Ctx : in out World; Word : String; R : in out Fabula.Check.Outcome)
   is
      V     : Nuntius_World.Http.Verb;
      Found : Boolean;
   begin
      Verb_Named (Word, V, Found);
      if Found then
         Ctx.Client.Response := Send (V, Refused_URL);
      else
         Fabula.Check.Fail_Step (R, "no curl verb named " & Word);
      end if;
   end Send_Refused;

   procedure Start_Refused
     (Ctx : in out World; Word : String; R : in out Fabula.Check.Outcome) is
   begin
      Async.Start
        (Request_For (Method'Value (Word), Refused_URL), Ctx.Client.Id);
   exception
      when Constraint_Error =>
         Fabula.Check.Fail_Step (R, "no async method named " & Word);
   end Start_Refused;

   procedure Wait_For_Completion (Ctx : in out World) is
      T0 : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Pump_Until_Done (Ctx.Client.Done, Ctx.Client.Got);
      Ctx.Client.Elapsed := Since (T0);
   end Wait_For_Completion;

   --  Start transfers until the table is full, then one more.
   procedure Fill (Ctx : in out World) is
      Id : Request_Id;
   begin
      for K in 1 .. Nuntius.Http.Fetch.Curl.Max_In_Flight loop
         Async.Start (Request_For (Get, Refused_URL), Id);
         if Id /= No_Request then
            Ctx.Client.Started := Ctx.Client.Started + 1;
         end if;
      end loop;
      Async.Start (Request_For (Get, Refused_URL), Id);
      Ctx.Client.Refused := Id = No_Request;
   end Fill;

   --  Every started transfer completed, and the table drained.
   procedure Check_Drained (Ctx : World; R : in out Fabula.Check.Outcome) is
      Done : Completion;
      Got  : Boolean;
      Seen : Natural := 0;
   begin
      while Async.In_Flight > 0 loop
         Pump_Until_Done (Done, Got);
         exit when not Got;
         Seen := Seen + 1;
      end loop;
      Fabula.Check.Ints.Equal (R, Seen, Ctx.Client.Started, "completions");
      Fabula.Check.Ints.Equal (R, Async.In_Flight, 0, "in flight after");
   end Check_Drained;

   procedure Check_Seconds
     (Ctx : World; Limit : Number; R : in out Fabula.Check.Outcome) is
   begin
      if Limit.Ok then
         Fabula.Check.Is_True
           (R,
            Ctx.Client.Elapsed < Duration (Limit.Value),
            "took" & Ctx.Client.Elapsed'Image & " s");
      else
         Fabula.Check.Ints.Fail_Read (R, Limit.Error);
      end if;
   end Check_Seconds;

   procedure Execute
     (S   : Http_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome) is
   begin
      case S is
         when E_Set_Agent                =>
            Nuntius.Http.Set_User_Agent (Fabula.Args.Text (A, First_Capture));

         when E_Curl_Refused             =>
            Send_Refused (Ctx, Fabula.Args.Word (A, First_Capture), R);

         when E_Curl_Recorded            =>
            Ctx.Client.Response := Recorded_Get;

         when E_Fetch_Recorded           =>
            Recorded_Fetch (Ctx.Client.Done, Ctx.Client.Got);

         when E_Fetch_Pump               =>
            Async.Pump (Ctx.Client.Done, Ctx.Client.Got);

         when E_Fetch_Start              =>
            Start_Refused (Ctx, Fabula.Args.Word (A, First_Capture), R);

         when E_Fetch_Cancel             =>
            Async.Cancel (Ctx.Client.Id);

         when E_Fetch_Until_Done         =>
            Wait_For_Completion (Ctx);

         when E_Fetch_Fill               =>
            Fill (Ctx);

         when E_Check_Response_Failure   =>
            Fabula.Check.Is_True
              (R,
               Failed (Ctx.Client.Response),
               Status_Text (Ctx.Client.Response));

         when E_Check_Response_Status    =>
            Fabula.Check.Ints.Equal
              (R,
               Nuntius.Http.Reported_Status (Ctx.Client.Response),
               Fabula.Args.Int (A, First_Capture),
               "status");

         when E_Check_Wire               =>
            Fabula.Check.Is_True
              (R,
               Has
                 (Loopback_Capture.Head, Fabula.Args.Text (A, First_Capture)),
               "the head was: " & Head_Line (Loopback_Capture.Head));

         when E_Check_Completion_Status  =>
            Fabula.Check.Is_True (R, Ctx.Client.Got, "a completion surfaced");
            Fabula.Check.Ints.Equal
              (R,
               Nuntius.Http.Reported_Status (Ctx.Client.Done.Result),
               Fabula.Args.Int (A, First_Capture),
               "status");

         when E_Check_No_Completion      =>
            Fabula.Check.Is_False (R, Ctx.Client.Got, "a completion surfaced");

         when E_Check_In_Flight          =>
            Fabula.Check.Ints.Equal
              (R,
               Async.In_Flight,
               Fabula.Args.Int (A, First_Capture),
               "in flight");

         when E_Check_Completion_Failure =>
            Fabula.Check.Is_True (R, Ctx.Client.Got, "a completion surfaced");
            Fabula.Check.Is_True
              (R,
               Failed (Ctx.Client.Done.Result),
               Status_Text (Ctx.Client.Done.Result));

         when E_Check_Within             =>
            Check_Seconds (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Check_Start_Refused      =>
            Fabula.Check.Is_True
              (R, Ctx.Client.Refused, "the start past the table's bound");

         when E_Check_All_Complete       =>
            Check_Drained (Ctx, R);
      end case;
   end Execute;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Handled := Evt in Http_Step;
      if Handled then
         Execute (Evt, Ctx.W, Ctx.A, Ctx.R);
      end if;
   end Offer;

   procedure Reset is null;

   function Phase return String
   is ("-");

end Nuntius_Steps.Http;
