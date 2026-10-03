with Fabula.Check.Ints;
with Fabula.Numbers;

with Nuntius.Codings;

with Test_Payloads;

with Nuntius_World;     use Nuntius_World;
with Nuntius_World.Web; use Nuntius_World.Web;

package body Nuntius_Steps.Web is

   subtype Number is Fabula.Numbers.Integer_Reads.Read;

   --  Where each value sits among a step's captures.
   First_Capture  : constant := 1;
   Second_Capture : constant := 2;

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

   No_Loop_Text : constant String := "no serving loop is listening";

   function Seconds (Ms : Natural) return Duration
   is (Duration (Ms) / Ms_Per_Second);

   procedure Start
     (Ctx : in out World; Kind : Loop_Kind; R : in out Fabula.Check.Outcome) is
   begin
      Start_Loop (Kind, Ctx.Port);
      if Ctx.Port = 0 then
         Fabula.Check.Fail (R, No_Loop_Text);
      end if;
   end Start;

   --  The one target the world's loops take upgrades on.
   Stream_Target : constant String := "/api/stream";

   --  Start Kind's loop, which takes upgrades on Stream_Target only: a
   --  feature naming another target asks for a loop the world lacks.
   procedure Start_Upgrading
     (Ctx    : in out World;
      Kind   : Loop_Kind;
      Target : String;
      R      : in out Fabula.Check.Outcome) is
   begin
      if Target = Stream_Target then
         Start (Ctx, Kind, R);
      else
         Fabula.Check.Fail
           (R,
            "the world's loops take upgrades on " & Stream_Target & " only");
      end if;
   end Start_Upgrading;

   ---------------------------------------------------------------------
   --  Sending.  A composed request waits in Ctx.Request until the first
   --  check sends it, so the "with ..." steps can keep adding to it.
   ---------------------------------------------------------------------

   procedure Compose (Ctx : in out World; Method, Target : String) is
   begin
      Ctx.Request :=
        (Waiting => True,
         Head    => To_Unbounded_String (Method & " " & Target & " HTTP/1.1"),
         others  => <>);
   end Compose;

   procedure Add_Line (Ctx : in out World; Line : String) is
   begin
      Append (Ctx.Request.Head, CRLF & Line);
   end Add_Line;

   procedure Set_Body (Ctx : in out World; Content : String) is
   begin
      Ctx.Request.Content := To_Unbounded_String (Content);
      Add_Line (Ctx, "Content-Length:" & Natural'Image (Content'Length));
   end Set_Body;

   procedure Set_Tail
     (Ctx : in out World; Ms : Number; R : in out Fabula.Check.Outcome) is
   begin
      if Ms.Ok then
         Ctx.Request.Tail_Ms := Ms.Value;
      else
         Fabula.Check.Ints.Fail_Read (R, Ms.Error);
      end if;
   end Set_Tail;

   --  The waiting request on the wire, and its reply kept; a body with
   --  a tail delay goes in a second write.
   procedure Flush (Ctx : in out World) is
      P    : constant Pending_Request := Ctx.Request;
      Head : constant String := To_String (P.Head) & CRLF & CRLF;
   begin
      if not P.Waiting then
         return;
      end if;
      Ctx.Request.Waiting := False;
      Ctx.Reply :=
        To_Unbounded_String
          (if P.Tail_Ms = 0
           then Exchange (Ctx.Port, Head & To_String (P.Content))
           else
             Exchange
               (Ctx.Port,
                Head,
                Tail       => To_String (P.Content),
                Tail_Delay => Seconds (P.Tail_Ms)));
   end Flush;

   procedure Send_Now (Ctx : in out World; Text : String) is
   begin
      Ctx.Reply := To_Unbounded_String (Exchange (Ctx.Port, Text));
   end Send_Now;

   procedure Dribble_At
     (Ctx : in out World; Ms : Number; R : in out Fabula.Check.Outcome) is
   begin
      if Ms.Ok then
         Ctx.Reply :=
           To_Unbounded_String
             (Dribble
                (Ctx.Port, Dribble_Head, Dribble_Bytes, Seconds (Ms.Value)));
      else
         Fabula.Check.Ints.Fail_Read (R, Ms.Error);
      end if;
   end Dribble_At;

   ---------------------------------------------------------------------
   --  Checking.
   ---------------------------------------------------------------------

   --  Whether the reply's status line carries Code.
   procedure Check_Status_Is
     (Ctx : World; Code : Number; R : in out Fabula.Check.Outcome) is
   begin
      if Code.Ok then
         Fabula.Check.Is_True
           (R,
            Has
              (To_String (Ctx.Reply),
               "HTTP/1.1" & Natural'Image (Code.Value) & " "),
            "the reply was: " & Head_Line (To_String (Ctx.Reply)));
      else
         Fabula.Check.Ints.Fail_Read (R, Code.Error);
      end if;
   end Check_Status_Is;

   procedure Check_Coding (Coding : String; R : in out Fabula.Check.Outcome) is
      use type Nuntius.Codings.Message_Coding;
      Expected : Nuntius.Codings.Message_Coding;
   begin
      if not Await_Adoption then
         Fabula.Check.Fail (R, "no socket was adopted");
         return;
      end if;
      Expected := Nuntius.Codings.Message_Coding'Value (Coding);
      Fabula.Check.Is_True
        (R,
         Cells.Adopted = 1 and then Cells.Kept_Coding = Expected,
         "adopted"
         & Natural'Image (Cells.Adopted)
         & " time(s), "
         & Nuntius.Codings.Message_Coding'Image (Cells.Kept_Coding));
   exception
      when Constraint_Error =>
         Fabula.Check.Fail_Step (R, "no coding named " & Coding);
   end Check_Coding;

   procedure Upgrade (Ctx : in out World; Target, Offer : String) is
   begin
      Ctx.Reply :=
        To_Unbounded_String (Upgrade_Reply (Ctx.Port, Offer, Target));
   end Upgrade;

   --  The body of the reply is the gzip member of Big_Json.
   procedure Check_Gunzip (Ctx : World; R : in out Fabula.Check.Outcome) is
      Got : constant String := Body_Of (To_String (Ctx.Reply));
   begin
      Fabula.Check.Is_True
        (R,
         Test_Payloads.Gunzip (Got, Big_Json'Length + 1) = Big_Json,
         "the body gunzips to the big JSON");
   end Check_Gunzip;

   --  The reply's Content-Length names its body's own length.
   procedure Check_Length (Ctx : World; R : in out Fabula.Check.Outcome) is
      Reply : constant String := To_String (Ctx.Reply);
   begin
      Fabula.Check.Is_True
        (R,
         Has
           (Reply,
            "Content-Length:" & Natural'Image (Body_Of (Reply)'Length) & CRLF),
         "the body is" & Natural'Image (Body_Of (Reply)'Length) & " bytes");
   end Check_Length;

   procedure Execute
     (S   : Web_Step;
      Ctx : in out World;
      A   : Fabula.Args.List;
      R   : in out Fabula.Check.Outcome) is
   begin
      if S in E_Check_Status .. E_Check_Length_Matches then
         Flush (Ctx);
      end if;
      case S is
         when E_Start_Server         =>
            Start (Ctx, Plain_Loop, R);

         when E_Start_Short_Server   =>
            Start (Ctx, Short_Loop, R);

         when E_Start_Stream_Server  =>
            Start_Upgrading
              (Ctx, Stream_Loop, Fabula.Args.Word (A, First_Capture), R);

         when E_Start_Deflate_Server =>
            Start_Upgrading
              (Ctx, Deflate_Loop, Fabula.Args.Word (A, First_Capture), R);

         when E_Start_Gzip_Server    =>
            Start (Ctx, Gzip_Loop, R);

         when E_Send_Request         =>
            Compose
              (Ctx,
               Fabula.Args.Word (A, First_Capture),
               Fabula.Args.Word (A, Second_Capture));

         when E_Add_Header           =>
            Add_Line (Ctx, Fabula.Args.Text (A, First_Capture));

         when E_Add_Body             =>
            Set_Body (Ctx, Fabula.Args.Text (A, First_Capture));

         when E_Split_Body           =>
            Set_Tail (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Send_Raw             =>
            Send_Now (Ctx, Fabula.Args.Text (A, First_Capture) & CRLF & CRLF);

         when E_Send_Half            =>
            Ctx.Reply :=
              To_Unbounded_String
                (Exchange (Ctx.Port, "GET /x HT", Half_Head => True));

         when E_Send_Dribble         =>
            Dribble_At (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Send_Upgrade         =>
            Upgrade (Ctx, Fabula.Args.Word (A, First_Capture), "");

         when E_Send_Offer           =>
            Upgrade
              (Ctx,
               Fabula.Args.Word (A, First_Capture),
               Fabula.Args.Text (A, Second_Capture));

         when E_Check_Status         =>
            Check_Status_Is (Ctx, Fabula.Args.Int (A, First_Capture), R);

         when E_Check_Carries        =>
            Fabula.Check.Is_True
              (R,
               Has
                 (To_String (Ctx.Reply), Fabula.Args.Text (A, First_Capture)),
               "the reply was: " & Head_Line (To_String (Ctx.Reply)));

         when E_Check_Lacks          =>
            Fabula.Check.Is_False
              (R,
               Has
                 (To_String (Ctx.Reply), Fabula.Args.Text (A, First_Capture)),
               "the reply was: " & Head_Line (To_String (Ctx.Reply)));

         when E_Check_Silent         =>
            Fabula.Check.Ints.Equal (R, Length (Ctx.Reply), 0, "reply bytes");

         when E_Check_Handled        =>
            Fabula.Check.Ints.Equal
              (R,
               Cells.Handled,
               Fabula.Args.Int (A, First_Capture),
               "handled");

         when E_Check_Adopted        =>
            Check_Coding (Fabula.Args.Word (A, First_Capture), R);

         when E_Check_Not_Adopted    =>
            Fabula.Check.Ints.Equal (R, Cells.Adopted, 0, "adopted");

         when E_Check_Saw_Upgrade    =>
            Fabula.Check.Is_True (R, Cells.Saw_Upgrade, "typed as an upgrade");

         when E_Check_No_Upgrade     =>
            Fabula.Check.Is_False
              (R, Cells.Saw_Upgrade, "typed as an upgrade");

         when E_Check_Gunzips        =>
            Check_Gunzip (Ctx, R);

         when E_Check_Big_Body       =>
            Fabula.Check.Is_True
              (R,
               Body_Of (To_String (Ctx.Reply)) = Big_Json,
               "the body is the big JSON");

         when E_Check_Length_Matches =>
            Check_Length (Ctx, R);
      end case;
   end Execute;

end Nuntius_Steps.Web;
