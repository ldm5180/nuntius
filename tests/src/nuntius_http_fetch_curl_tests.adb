with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Http.Fetch.Curl;

--  Offline behavior of the ASYNC (curl-multi) adapter: Start never
--  waits, Pump never blocks, and a transport-level failure (a loopback
--  connection-refusal) surfaces as a completion with Ok = False and
--  Status 0 -- the sync adapter's verdict convention.  Live exchanges
--  are the consumer's integration concern.

package body Nuntius_Http_Fetch_Curl_Tests is

   use AUnit.Test_Cases.Registration;
   use Nuntius.Http.Fetch;

   --  Port 9 (discard) on the loopback is as close to guaranteed-refused
   --  as it gets without a network.
   Refused_URL : constant String := "http://127.0.0.1:9/";

   function Req (Verb : Method) return Request
   is (Verb          => Verb,
       URL           => To_Unbounded_String (Refused_URL),
       Content       => To_Unbounded_String (if Verb = Post then "{}" else ""),
       Content_Type  =>
         To_Unbounded_String (if Verb = Post then "application/json" else ""),
       Authorization => To_Unbounded_String ("Bearer x"),
       Timeout_Ms    => 2_000);

   --  Pump is non-blocking; a refused connect still takes a few event
   --  turns to surface.  Spin with a tiny pause under a hard ceiling so
   --  a hang fails the test rather than wedging the suite.
   procedure Pump_Until
     (C : in out Curl.Curl_Client; Done : out Completion; Got : out Boolean) is
   begin
      for K in 1 .. 5_000 loop
         C.Pump (Done, Got);
         exit when Got;
         delay 0.001;
      end loop;
   end Pump_Until;

   --  A fresh client has nothing to say and says so at once.
   procedure Test_Empty_Pump (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Curl.Curl_Client;
      Done : Completion;
      Got  : Boolean;
   begin
      C.Pump (Done, Got);
      Assert (not Got, "an idle client pumps nothing");
      Assert (C.In_Flight = 0, "and reports no transfers");
   end Test_Empty_Pump;

   --  Three concurrent verbs against a refused port: three failure
   --  completions, ids intact, table drained.
   procedure Test_Refused_Completions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      C          : Curl.Curl_Client;
      Ids        : array (1 .. 3) of Request_Id;
      Done       : Completion;
      Got        : Boolean;
      Seen       : Natural := 0;
      Seen_Total : Natural := 0;  --  sum of completed ids, to match the set
      Id_Total   : Natural := 0;
   begin
      C.Start (Req (Get), Ids (1));
      C.Start (Req (Post), Ids (2));
      C.Start (Req (Delete), Ids (3));
      for K in Ids'Range loop
         Assert (Ids (K) /= No_Request, "start" & K'Image & " took a slot");
         Id_Total := Id_Total + Natural (Ids (K));
      end loop;
      Assert (C.In_Flight = 3, "three transfers in flight");

      for K in Ids'Range loop
         Pump_Until (C, Done, Got);
         Assert (Got, "completion" & K'Image & " surfaced");
         Assert
           (not Done.Ok and then Done.Status = 0,
            "a refused connect is Ok False / Status 0");
         Assert
           (Done.Location = Null_Unbounded_String, "no Location on failure");
         Seen := Seen + 1;
         Seen_Total := Seen_Total + Natural (Done.Id);
      end loop;

      Assert
        (Seen = 3 and then Seen_Total = Id_Total,
         "every started id completed exactly once");
      Assert (C.In_Flight = 0, "the table drained");
      C.Pump (Done, Got);
      Assert (not Got, "nothing left to pump");
   end Test_Refused_Completions;

   --  A cancelled transfer never surfaces.
   procedure Test_Cancel (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Curl.Curl_Client;
      Id   : Request_Id;
      Done : Completion;
      Got  : Boolean;
   begin
      C.Start (Req (Get), Id);
      Assert (Id /= No_Request and then C.In_Flight = 1, "one in flight");
      C.Cancel (Id);
      Assert (C.In_Flight = 0, "cancel freed the slot");
      C.Pump (Done, Got);
      Assert (not Got, "a cancelled transfer never completes");
   end Test_Cancel;

   --  The table is bounded: slot Max_In_Flight + 1 is refused as
   --  No_Request (the caller treats it like a transport failure), and
   --  every taken slot still completes.
   procedure Test_Table_Full (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Curl.Curl_Client;
      Id   : Request_Id;
      Done : Completion;
      Got  : Boolean;
      Seen : Natural := 0;
   begin
      for K in 1 .. Curl.Max_In_Flight loop
         C.Start (Req (Get), Id);
         Assert (Id /= No_Request, "slot" & K'Image & " taken");
      end loop;
      C.Start (Req (Get), Id);
      Assert (Id = No_Request, "a full table refuses the start");
      Assert (C.In_Flight = Curl.Max_In_Flight, "and holds its bound");

      loop
         Pump_Until (C, Done, Got);
         exit when not Got;
         Seen := Seen + 1;
      end loop;
      Assert
        (Seen = Curl.Max_In_Flight,
         "every taken slot completed; got" & Seen'Image);
      Assert (C.In_Flight = 0, "the table drained");
   end Test_Table_Full;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Empty_Pump'Access, "an idle client pumps nothing");
      Register_Routine
        (T,
         Test_Refused_Completions'Access,
         "concurrent refused transfers each complete Ok False / Status 0");
      Register_Routine
        (T, Test_Cancel'Access, "a cancelled transfer never surfaces");
      Register_Routine
        (T, Test_Table_Full'Access, "the in-flight table is bounded");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Http.Fetch.Curl (curl-multi adapter)");
   end Name;

end Nuntius_Http_Fetch_Curl_Tests;
