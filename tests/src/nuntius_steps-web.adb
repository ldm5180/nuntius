with Ada.Characters.Handling;

with Fabula.Check.Ints;

with Nuntius.Codings;

with Test_Payloads;

with Nuntius_Steps.Flows;
with Nuntius_World;     use Nuntius_World;
with Nuntius_World.Web; use Nuntius_World.Web;

package body Nuntius_Steps.Web is

   use type Nuntius.Codings.Message_Coding;

   --  Idle until a loop is started; Starting until it says it listens;
   --  Serving until a request goes out, composed first if it has parts;
   --  Answered once a reply is in hand, Adopting while an adoption is
   --  awaited.
   type State is (Idle, Starting, Serving, Composing, Answered, Adopting);

   type Guard_Kind is
     (Always, Stream_Target, Listening, Count_Given, Coding_Known, Adopted);

   type Action_Kind is
     (A_Nothing,
      --  Starting a loop.
      A_Start_Plain,
      A_Start_Short,
      A_Start_Stream,
      A_Start_Deflate,
      A_Start_Gzip,
      A_Refuse_Target,
      A_No_Loop,
      --  Composing and sending.
      A_Compose,
      A_Add_Header,
      A_Add_Body,
      A_Split_Body,
      A_Send,
      A_Send_Raw,
      A_Send_Half,
      A_Dribble,
      A_Upgrade,
      A_Offer,
      A_Refuse_Count,
      --  Checking.
      A_Check_Status,
      A_Check_Carries,
      A_Check_Lacks,
      A_Check_Silent,
      A_Check_Handled,
      A_Await_Adoption,
      A_Check_Coding,
      A_No_Adoption,
      A_Refuse_Coding,
      A_Check_Not_Adopted,
      A_Check_Saw_Upgrade,
      A_Check_No_Upgrade,
      A_Check_Gunzips,
      A_Check_Big_Body,
      A_Check_Length,
      A_Check_Echoed,
      A_Check_Big_Prefix);

   subtype Start_Action is Action_Kind range A_Start_Plain .. A_No_Loop;
   subtype Send_Action is Action_Kind range A_Compose .. A_Refuse_Count;
   subtype Check_Action is
     Action_Kind range A_Check_Status .. A_Check_Big_Prefix;

   --  Where each value sits among a step's captures.
   First_Capture  : constant := 1;
   Second_Capture : constant := 2;

   function First (Ctx : Step_Context) return String
   is (Fabula.Args.Text (Ctx.A, First_Capture));

   --  The one target the world's loops take upgrades on.
   Stream_Target_Path : constant String := "/api/stream";

   function Is_Coding (Word : String) return Boolean
   is (for some C in Nuntius.Codings.Message_Coding =>
         C'Image = Ada.Characters.Handling.To_Upper (Word));

   function Evaluate
     (G : Guard_Kind; Ctx : Step_Context; Evt : Step_Kind) return Boolean
   is
      pragma Unreferenced (Evt);
   begin
      return
        (case G is
           when Always        => True,
           when Stream_Target => First (Ctx) = Stream_Target_Path,
           when Listening     => Ctx.W.Port /= 0,
           when Count_Given   => Count_Read (Ctx),
           when Coding_Known  => Is_Coding (First (Ctx)),
           when Adopted       => Cells.Adopted > 0);
   end Evaluate;

   ---------------------------------------------------------------------
   --  Starting a loop: start it, then hear whether it listens.
   ---------------------------------------------------------------------

   procedure Start (Ctx : in out Step_Context; Kind : Loop_Kind) is
   begin
      Start_Loop (Kind, Ctx.W.Port);
      Then_Take (Ctx, E_Listened);
   end Start;

   procedure Start_Act (A : Start_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Start_Plain   =>
            Start (Ctx, Plain_Loop);

         when A_Start_Short   =>
            Start (Ctx, Short_Loop);

         when A_Start_Stream  =>
            Start (Ctx, Stream_Loop);

         when A_Start_Deflate =>
            Start (Ctx, Deflate_Loop);

         when A_Start_Gzip    =>
            Start (Ctx, Gzip_Loop);

         when A_Refuse_Target =>
            Fabula.Check.Fail
              (Ctx.R,
               "the world's loops take upgrades on "
               & Stream_Target_Path
               & " only");

         when A_No_Loop       =>
            Fabula.Check.Fail (Ctx.R, "no serving loop is listening");
      end case;
   end Start_Act;

   ---------------------------------------------------------------------
   --  Composing and sending.  A composed request waits in the context
   --  until the first check sends it, so the "with ..." steps can keep
   --  adding to it.
   ---------------------------------------------------------------------

   --  The head a dribble sends before its single bytes: a body is
   --  promised, so the loop keeps reading.
   Dribble_Head : constant String :=
     "POST /x HTTP/1.1"
     & CRLF
     & "Content-Type: application/json"
     & CRLF
     & "Content-Length: 40"
     & CRLF
     & CRLF;

   --  How many single bytes a dribble sends: at the paces the features
   --  use, longer than any connection budget they stand up.
   Dribble_Bytes : constant := 8;

   Ms_Per_Second : constant := 1_000;

   function Seconds (Ms : Natural) return Duration
   is (Duration (Ms) / Ms_Per_Second);

   procedure Add_Line (Ctx : in out Step_Context; Line : String) is
   begin
      Append (Ctx.W.Request.Head, CRLF & Line);
   end Add_Line;

   procedure Set_Body (Ctx : in out Step_Context; Content : String) is
   begin
      Ctx.W.Request.Content := To_Unbounded_String (Content);
      Add_Line (Ctx, "Content-Length:" & Natural'Image (Content'Length));
   end Set_Body;

   --  The composed request on the wire and its reply kept; a body with a
   --  tail delay goes in a second write.  Then the check that sent it.
   procedure Send (Ctx : in out Step_Context; Check : Step_Kind) is
      P    : constant Pending_Request := Ctx.W.Request;
      Head : constant String := To_String (P.Head) & CRLF & CRLF;
   begin
      Ctx.W.Reply :=
        To_Unbounded_String
          (if P.Tail_Ms = 0
           then Exchange (Ctx.W.Port, Head & To_String (P.Content))
           else
             Exchange
               (Ctx.W.Port,
                Head,
                Tail       => To_String (P.Content),
                Tail_Delay => Seconds (P.Tail_Ms)));
      Then_Take (Ctx, Check);
   end Send;

   procedure Keep (Ctx : in out Step_Context; Reply : String) is
   begin
      Ctx.W.Reply := To_Unbounded_String (Reply);
   end Keep;

   procedure Send_Act
     (A : Send_Action; Ctx : in out Step_Context; Evt : Step_Kind) is
   begin
      case A is
         when A_Compose      =>
            Ctx.W.Request :=
              (Method => To_Unbounded_String (First (Ctx)),
               Target =>
                 To_Unbounded_String
                   (Fabula.Args.Word (Ctx.A, Second_Capture)),
               Head   =>
                 To_Unbounded_String
                   (First (Ctx)
                    & " "
                    & Fabula.Args.Word (Ctx.A, Second_Capture)
                    & " HTTP/1.1"),
               others => <>);

         when A_Add_Header   =>
            Add_Line (Ctx, First (Ctx));

         when A_Add_Body     =>
            Set_Body (Ctx, First (Ctx));

         when A_Split_Body   =>
            Ctx.W.Request.Tail_Ms := Count (Ctx);

         when A_Send         =>
            Send (Ctx, Evt);

         when A_Send_Raw     =>
            Keep (Ctx, Exchange (Ctx.W.Port, First (Ctx) & CRLF & CRLF));

         when A_Send_Half    =>
            Keep (Ctx, Exchange (Ctx.W.Port, "GET /x HT", Half_Head => True));

         when A_Dribble      =>
            Keep
              (Ctx,
               Dribble
                 (Ctx.W.Port,
                  Dribble_Head,
                  Dribble_Bytes,
                  Seconds (Count (Ctx))));

         when A_Upgrade      =>
            Keep (Ctx, Upgrade_Reply (Ctx.W.Port, "", First (Ctx)));

         when A_Offer        =>
            Keep
              (Ctx,
               Upgrade_Reply
                 (Ctx.W.Port,
                  Fabula.Args.Text (Ctx.A, Second_Capture),
                  First (Ctx)));

         when A_Refuse_Count =>
            Refuse_Count (Ctx);
      end case;
   end Send_Act;

   ---------------------------------------------------------------------
   --  Checking what came back.
   ---------------------------------------------------------------------

   function Reply_Text (Ctx : Step_Context) return String
   is (To_String (Ctx.W.Reply));

   function Reply_Was (Ctx : Step_Context) return String
   is ("the reply was: " & Head_Line (Reply_Text (Ctx)));

   --  The adopted socket's coding is the one the step names.
   procedure Check_Coding (Ctx : in out Step_Context) is
   begin
      Fabula.Check.Is_True
        (Ctx.R,
         Cells.Adopted = 1
         and then Cells.Kept_Coding
                  = Nuntius.Codings.Message_Coding'Value (First (Ctx)),
         "adopted"
         & Natural'Image (Cells.Adopted)
         & " time(s), "
         & Nuntius.Codings.Message_Coding'Image (Cells.Kept_Coding));
   end Check_Coding;

   --  The reply's Content-Length names its body's own length.
   procedure Check_Length (Ctx : in out Step_Context) is
      Size : constant Natural := Body_Of (Reply_Text (Ctx))'Length;
   begin
      Fabula.Check.Is_True
        (Ctx.R,
         Has
           (Reply_Text (Ctx), "Content-Length:" & Natural'Image (Size) & CRLF),
         "the body is" & Natural'Image (Size) & " bytes");
   end Check_Length;

   --  Wait for the loop's adoption, which the 101 can beat; the next
   --  event's guard reads how it came out.
   procedure Await (Ctx : in out Step_Context) is
      Came : constant Boolean := Await_Adoption;
      pragma Unreferenced (Came);
   begin
      Then_Take (Ctx, E_Adoption_Settled);
   end Await;

   procedure Check_Act (A : Check_Action; Ctx : in out Step_Context) is
   begin
      case A is
         when A_Check_Status      =>
            Fabula.Check.Is_True
              (Ctx.R,
               Has
                 (Reply_Text (Ctx),
                  "HTTP/1.1" & Natural'Image (Count (Ctx)) & " "),
               Reply_Was (Ctx));

         when A_Check_Carries     =>
            Fabula.Check.Is_True
              (Ctx.R, Has (Reply_Text (Ctx), First (Ctx)), Reply_Was (Ctx));

         when A_Check_Lacks       =>
            Fabula.Check.Is_False
              (Ctx.R, Has (Reply_Text (Ctx), First (Ctx)), Reply_Was (Ctx));

         when A_Check_Silent      =>
            Fabula.Check.Ints.Equal
              (Ctx.R, Length (Ctx.W.Reply), 0, "reply bytes");

         when A_Check_Handled     =>
            Fabula.Check.Ints.Equal
              (Ctx.R,
               Cells.Handled,
               Fabula.Args.Int (Ctx.A, First_Capture),
               "handled");

         when A_Await_Adoption    =>
            Await (Ctx);

         when A_Check_Coding      =>
            Check_Coding (Ctx);

         when A_No_Adoption       =>
            Fabula.Check.Fail (Ctx.R, "no socket was adopted");

         when A_Refuse_Coding     =>
            Fabula.Check.Fail_Step (Ctx.R, "no coding named " & First (Ctx));

         when A_Check_Not_Adopted =>
            Fabula.Check.Ints.Equal (Ctx.R, Cells.Adopted, 0, "adopted");

         when A_Check_Saw_Upgrade =>
            Fabula.Check.Is_True
              (Ctx.R, Cells.Saw_Upgrade, "typed as an upgrade");

         when A_Check_No_Upgrade  =>
            Fabula.Check.Is_False
              (Ctx.R, Cells.Saw_Upgrade, "typed as an upgrade");

         when A_Check_Gunzips     =>
            Fabula.Check.Is_True
              (Ctx.R,
               Test_Payloads.Gunzip
                 (Body_Of (Reply_Text (Ctx)), Big_Json'Length + 1)
               = Big_Json,
               "the body gunzips to the big JSON");

         when A_Check_Big_Body    =>
            Fabula.Check.Is_True
              (Ctx.R,
               Body_Of (Reply_Text (Ctx)) = Big_Json,
               "the body is the big JSON");

         when A_Check_Length      =>
            Check_Length (Ctx);

         when A_Check_Echoed      =>
            Fabula.Check.Is_True
              (Ctx.R,
               Has
                 (Reply_Text (Ctx),
                  "hi:"
                  & To_String (Ctx.W.Request.Method)
                  & ":"
                  & To_String (Ctx.W.Request.Target)
                  & ":"
                  & To_String (Ctx.W.Request.Content)),
               "the handler did not echo the request");

         when A_Check_Big_Prefix  =>
            Fabula.Check.Is_True
              (Ctx.R,
               Count (Ctx) <= Big_Json'Length
               and then Body_Of (Reply_Text (Ctx))
                        = Big_Json
                            (Big_Json'First
                             .. Big_Json'First + Count (Ctx) - 1),
               "the body is not the first"
               & Natural'Image (Count (Ctx))
               & " bytes of the big JSON");
      end case;
   end Check_Act;

   procedure Execute
     (A : Action_Kind; Ctx : in out Step_Context; Evt : Step_Kind) is
   begin
      case A is
         when A_Nothing    =>
            null;

         when Start_Action =>
            Start_Act (A, Ctx);

         when Send_Action  =>
            Send_Act (A, Ctx, Evt);

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

   Start_Server         : constant Ev := (Kind => E_Start_Server);
   Start_Short_Server   : constant Ev := (Kind => E_Start_Short_Server);
   Start_Stream_Server  : constant Ev := (Kind => E_Start_Stream_Server);
   Start_Deflate_Server : constant Ev := (Kind => E_Start_Deflate_Server);
   Start_Gzip_Server    : constant Ev := (Kind => E_Start_Gzip_Server);
   Listened             : constant Ev := (Kind => E_Listened);
   Send_Request         : constant Ev := (Kind => E_Send_Request);
   Add_Header           : constant Ev := (Kind => E_Add_Header);
   Add_Body             : constant Ev := (Kind => E_Add_Body);
   Split_Body           : constant Ev := (Kind => E_Split_Body);
   Send_Raw             : constant Ev := (Kind => E_Send_Raw);
   Send_Half            : constant Ev := (Kind => E_Send_Half);
   Send_Dribble         : constant Ev := (Kind => E_Send_Dribble);
   Send_Upgrade         : constant Ev := (Kind => E_Send_Upgrade);
   Send_Offer           : constant Ev := (Kind => E_Send_Offer);
   Check_Status         : constant Ev := (Kind => E_Check_Status);
   Check_Carries        : constant Ev := (Kind => E_Check_Carries);
   Check_Lacks          : constant Ev := (Kind => E_Check_Lacks);
   Check_Silent         : constant Ev := (Kind => E_Check_Silent);
   Check_Handled        : constant Ev := (Kind => E_Check_Handled);
   Check_Adopted        : constant Ev := (Kind => E_Check_Adopted);
   Adoption_Settled     : constant Ev := (Kind => E_Adoption_Settled);
   Check_Not_Adopted    : constant Ev := (Kind => E_Check_Not_Adopted);
   Check_Saw_Upgrade    : constant Ev := (Kind => E_Check_Saw_Upgrade);
   Check_No_Upgrade     : constant Ev := (Kind => E_Check_No_Upgrade);
   Check_Gunzips        : constant Ev := (Kind => E_Check_Gunzips);
   Check_Big_Body       : constant Ev := (Kind => E_Check_Big_Body);
   Check_Length_Matches : constant Ev := (Kind => E_Check_Length_Matches);
   Check_Echoed         : constant Ev := (Kind => E_Check_Echoed);
   Check_Big_Prefix     : constant Ev := (Kind => E_Check_Big_Prefix);

   --!format off
   Table : constant Transition_Table :=
     [--  A loop starts from Idle, or replaces the Background's.
      Idle      + Start_Server                          / A_Start_Plain     >= Starting,
      Idle      + Start_Short_Server                    / A_Start_Short     >= Starting,
      Idle      + Start_Gzip_Server                     / A_Start_Gzip      >= Starting,
      Idle      + Start_Stream_Server  (Stream_Target)  / A_Start_Stream    >= Starting,
      Idle      + Start_Stream_Server                   / A_Refuse_Target   >= Idle,
      Idle      + Start_Deflate_Server (Stream_Target)  / A_Start_Deflate   >= Starting,
      Idle      + Start_Deflate_Server                  / A_Refuse_Target   >= Idle,
      Serving   + Start_Short_Server                    / A_Start_Short     >= Starting,
      Starting  + Listened (Listening)                                      >= Serving,
      Starting  + Listened                              / A_No_Loop         >= Idle,

      --  A request goes out whole, or is composed and goes at the first
      --  check.
      Serving   + Send_Request                          / A_Compose         >= Composing,
      Serving   + Send_Raw                              / A_Send_Raw        >= Answered,
      Serving   + Send_Half                             / A_Send_Half       >= Answered,
      Serving   + Send_Dribble (Count_Given)            / A_Dribble         >= Answered,
      Serving   + Send_Dribble                          / A_Refuse_Count    >= Serving,
      Serving   + Send_Upgrade                          / A_Upgrade         >= Answered,
      Serving   + Send_Offer                            / A_Offer           >= Answered,
      Composing + Add_Header                            / A_Add_Header      >= Composing,
      Composing + Add_Body                              / A_Add_Body        >= Composing,
      Composing + Split_Body (Count_Given)              / A_Split_Body      >= Composing,
      Composing + Split_Body                            / A_Refuse_Count    >= Composing,
      Composing + Check_Status                          / A_Send            >= Answered,
      Composing + Check_Carries                         / A_Send            >= Answered,
      Composing + Check_Lacks                           / A_Send            >= Answered,
      Composing + Check_Silent                          / A_Send            >= Answered,
      Composing + Check_Handled                         / A_Send            >= Answered,
      Composing + Check_Adopted                         / A_Send            >= Answered,
      Composing + Check_Not_Adopted                     / A_Send            >= Answered,
      Composing + Check_Saw_Upgrade                     / A_Send            >= Answered,
      Composing + Check_No_Upgrade                      / A_Send            >= Answered,
      Composing + Check_Gunzips                         / A_Send            >= Answered,
      Composing + Check_Big_Body                        / A_Send            >= Answered,
      Composing + Check_Length_Matches                  / A_Send            >= Answered,
      Composing + Check_Echoed                          / A_Send            >= Answered,
      Composing + Check_Big_Prefix                      / A_Send            >= Answered,

      --  Every check reads the reply in hand.
      Answered  + Check_Status (Count_Given)            / A_Check_Status    >= Answered,
      Answered  + Check_Status                          / A_Refuse_Count    >= Answered,
      Answered  + Check_Carries                         / A_Check_Carries   >= Answered,
      Answered  + Check_Lacks                           / A_Check_Lacks     >= Answered,
      Answered  + Check_Silent                          / A_Check_Silent    >= Answered,
      Answered  + Check_Handled                         / A_Check_Handled   >= Answered,
      Answered  + Check_Adopted (Coding_Known)          / A_Await_Adoption  >= Adopting,
      Answered  + Check_Adopted                         / A_Refuse_Coding   >= Answered,
      Adopting  + Adoption_Settled (Adopted)            / A_Check_Coding    >= Answered,
      Adopting  + Adoption_Settled                      / A_No_Adoption     >= Answered,
      Answered  + Check_Not_Adopted                     / A_Check_Not_Adopted >= Answered,
      Answered  + Check_Saw_Upgrade                     / A_Check_Saw_Upgrade >= Answered,
      Answered  + Check_No_Upgrade                      / A_Check_No_Upgrade  >= Answered,
      Answered  + Check_Gunzips                         / A_Check_Gunzips   >= Answered,
      Answered  + Check_Big_Body                        / A_Check_Big_Body  >= Answered,
      Answered  + Check_Length_Matches                  / A_Check_Length    >= Answered,
      Answered  + Check_Echoed                          / A_Check_Echoed    >= Answered,
      Answered  + Check_Big_Prefix (Count_Given)        / A_Check_Big_Prefix >= Answered,
      Answered  + Check_Big_Prefix                      / A_Refuse_Count    >= Answered];
   --!format on

   Current : State := Idle;

   procedure Offer
     (Ctx : in out Step_Context; Evt : Step_Kind; Handled : out Boolean) is
   begin
      Flow.Take (Table, Current, Ctx, Evt, Handled);
   end Offer;

   procedure Reset is
   begin
      Current := Idle;
   end Reset;

   function Phase return String
   is (Current'Image);

end Nuntius_Steps.Web;
