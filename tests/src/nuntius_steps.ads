with Ada.Strings.Unbounded;

with Nuntius.Http;
with Nuntius.Http.Fetch;
with Nuntius.Ws;

with Fabula.Args;
with Fabula.Check;
with Fabula.Frames;
with Fabula.Registry;

--  The step registry the feature runner dispatches on: one Step_Kind
--  per pattern, one table that reads like the features, one Execute.

package Nuntius_Steps is

   use Ada.Strings.Unbounded;

   --  The steps, grouped by the feature that reads them; each group is
   --  a subtype, dispatched to its own child package.
   type Step_Kind is
     (Start_Server,
      Start_Short_Server,
      Start_Stream_Server,
      Start_Deflate_Server,
      Send_Request,
      Add_Header,
      Add_Body,
      Split_Body,
      Send_Raw,
      Send_Half,
      Send_Dribble,
      Send_Upgrade,
      Send_Offer,
      Check_Status,
      Check_Carries,
      Check_Lacks,
      Check_Silent,
      Check_Handled,
      Check_Adopted,
      Check_Not_Adopted,
      Check_Saw_Upgrade,
      Check_No_Upgrade,
      Set_Agent,
      Curl_Refused,
      Curl_Recorded,
      Fetch_Recorded,
      Fetch_Pump,
      Fetch_Start,
      Fetch_Cancel,
      Fetch_Until_Done,
      Fetch_Fill,
      Check_Response_Failure,
      Check_Response_Status,
      Check_Wire,
      Check_Completion_Status,
      Check_No_Completion,
      Check_In_Flight,
      Check_Completion_Failure,
      Check_Within,
      Check_Start_Refused,
      Check_All_Complete,
      Ws_Default,
      Ws_Shaped,
      Ws_Impatient,
      Start_Peer,
      Ws_Dial_Refused,
      Ws_Connect,
      Ws_Until_Lost,
      Ws_Receive_For,
      Ws_Receive_Many,
      Ws_Receive,
      Check_Dial_Failed,
      Check_Reception,
      Check_Message,
      Check_Pong,
      Check_In_Order,
      Check_Dropped,
      Check_Oversized,
      Check_No_Oversized,
      Check_Lost_Within);

   subtype Web_Step is Step_Kind range Start_Server .. Check_No_Upgrade;
   subtype Http_Step is Step_Kind range Set_Agent .. Check_All_Complete;
   subtype Ws_Step is Step_Kind range Ws_Default .. Check_Lost_Within;

   type Hook_Kind is (Fresh_World, Stop_World);

   --  A request being composed: its head so far, its body, and how long
   --  after the head the body follows.  It goes out at the first check.
   type Pending_Request is record
      Waiting : Boolean := False;
      Head    : Unbounded_String;
      Content : Unbounded_String;
      Tail_Ms : Natural := 0;
   end record;

   --  What the HTTP clients answered: the sync response, the async
   --  completion and how long it took, and the async table's tally.
   type Client_Reading is record
      Response : Nuntius.Http.Response;
      Done     : Nuntius.Http.Fetch.Completion;
      Got      : Boolean := False;
      Id       : Nuntius.Http.Fetch.Request_Id :=
        Nuntius.Http.Fetch.No_Request;
      Elapsed  : Duration := 0.0;
      Started  : Natural := 0;
      Refused  : Boolean := False;
   end record;

   --  What the websocket client answered: the dial, the last reception
   --  and its text, and the tallies of a run of receives.
   type Ws_Reading is record
      Dialed   : Boolean := False;
      Got      : Nuntius.Ws.Reception;
      Message  : Unbounded_String;
      Wanted   : Natural := 0;
      Received : Natural := 0;
      In_Order : Boolean := True;
      Calls    : Natural := 0;
      Timeouts : Natural := 0;
   end record;

   --  What one scenario reads back.  fabula copies it per step, so it
   --  holds values only; the sockets and tasks live in Nuntius_World.
   type World is record
      Port    : Natural := 0;
      Request : Pending_Request;
      Reply   : Unbounded_String;
      Client  : Client_Reading;
      Ws      : Ws_Reading;
   end record;

   package Steps is new
     Fabula.Registry
       (Step_Kind => Step_Kind,
        Hook_Kind => Hook_Kind,
        Context   => World);
   use Steps;

   --!format off
   Step_Defs : constant Steps.Step_Table :=
     [Step ("a serving loop on loopback")                     >= Start_Server,
      Step ("a serving loop with a 1-second connection budget")
                                                              >= Start_Short_Server,
      Step ("a serving loop that takes upgrades on {word}")
                                                              >= Start_Stream_Server,
      Step ("a serving loop that compresses when offered "
            & "and takes upgrades on {word}")            >= Start_Deflate_Server,
      Step ("the client sends a {word} to {word}")            >= Send_Request,
      Step ("with header {string}")                           >= Add_Header,
      Step ("with the body arriving {int} ms later")          >= Split_Body,
      Step ("with the body {}")                               >= Add_Body,
      Step ("the client sends half a head and hangs up")      >= Send_Half,
      Step ("the client dribbles one byte every {int} ms")    >= Send_Dribble,
      Step ("the client sends {string}")                      >= Send_Raw,
      Step ("the client upgrades to {word} offering {string}")
                                                              >= Send_Offer,
      Step ("the client upgrades to {word}")                  >= Send_Upgrade,
      Step ("the reply status is {int}")                      >= Check_Status,
      Step ("the reply carries no {string}")                  >= Check_Lacks,
      Step ("the reply carries {string}")                     >= Check_Carries,
      Step ("the handler received {string}")                  >= Check_Carries,
      Step ("no reply arrives")                               >= Check_Silent,
      Step ("the handler saw {int} request(s)")               >= Check_Handled,
      Step ("the handler saw it as an upgrade")               >= Check_Saw_Upgrade,
      Step ("the handler did not see an upgrade")             >= Check_No_Upgrade,
      Step ("the socket was adopted {word}")                  >= Check_Adopted,
      Step ("no socket was adopted")                          >= Check_Not_Adopted,
      Step ("the User-Agent is {string}")                     >= Set_Agent,
      Step ("the curl client sends a {word} to a refused loopback port")
                                                              >= Curl_Refused,
      Step ("the curl client sends a GET to a recording peer")
                                                              >= Curl_Recorded,
      Step ("the async client sends a GET to a recording peer")
                                                              >= Fetch_Recorded,
      Step ("the async client pumps once")                    >= Fetch_Pump,
      Step ("the async client starts a {word} to a refused loopback port")
                                                              >= Fetch_Start,
      Step ("the async client cancels it")                    >= Fetch_Cancel,
      Step ("the async client pumps and waits until it completes")
                                                              >= Fetch_Until_Done,
      Step ("the async client fills its table with GETs to a refused "
            & "loopback port")                                >= Fetch_Fill,
      Step ("the response is a transport failure")            >= Check_Response_Failure,
      Step ("the response status is {int}")                   >= Check_Response_Status,
      Step ("the request on the wire carried {string}")       >= Check_Wire,
      Step ("the completion status is {int}")                 >= Check_Completion_Status,
      Step ("no completion surfaced")                         >= Check_No_Completion,
      Step ("the async client has {int} transfer(s) in flight")
                                                              >= Check_In_Flight,
      Step ("the completion is a transport failure")          >= Check_Completion_Failure,
      Step ("it surfaced within {int} seconds")               >= Check_Within,
      Step ("one more start is refused")                      >= Check_Start_Refused,
      Step ("every started transfer completes")               >= Check_All_Complete,
      Step ("a websocket client whose ring holds {int} frames of up to {int} "
            & "bytes")                                        >= Ws_Shaped,
      Step ("a websocket client that gives up after 1 second of silence")
                                                              >= Ws_Impatient,
      Step ("a websocket client")                             >= Ws_Default,
      Step ("a scripted websocket peer that sends:")          >= Start_Peer,
      Step ("the websocket client dials a refused loopback port")
                                                              >= Ws_Dial_Refused,
      Step ("the websocket client connects")                  >= Ws_Connect,
      Step ("the websocket client receives with {int} ms patience until it "
            & "is lost")                                      >= Ws_Until_Lost,
      Step ("the websocket client receives with {int} ms patience")
                                                              >= Ws_Receive_For,
      Step ("the websocket client receives {int} messages")   >= Ws_Receive_Many,
      Step ("the websocket client receives")                  >= Ws_Receive,
      Step ("the dial fails")                                 >= Check_Dial_Failed,
      Step ("the reception is {word}")                        >= Check_Reception,
      Step ("the message is {string}")                        >= Check_Message,
      Step ("the peer saw a pong")                            >= Check_Pong,
      Step ("every one was delivered, in order")              >= Check_In_Order,
      Step ("the client counted dropped frames and no oversized one")
                                                              >= Check_Dropped,
      Step ("the client counted {int} oversized frame(s), the largest {int} "
            & "bytes")                                        >= Check_Oversized,
      Step ("the client counted no oversized frame")          >= Check_No_Oversized,
      Step ("it was lost within {int} receives, after at least {int} healthy "
            & "timeouts")                                     >= Check_Lost_Within];
   --!format on

   Hook_Defs : constant Steps.Hook_Table :=
     [Before >= Fresh_World, After >= Stop_World];

   procedure Execute
     (S    : Step_Kind;
      Ctx  : in out World;
      A    : Fabula.Args.List;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome);

   procedure Run_Hook
     (H    : Hook_Kind;
      Ctx  : in out World;
      Info : Fabula.Frames.Frame;
      R    : in out Fabula.Check.Outcome);

end Nuntius_Steps;
