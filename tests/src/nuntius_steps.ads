with Ada.Strings.Unbounded;

with Nuntius.Http;
with Nuntius.Http.Fetch;
with Nuntius.Ws;

with Nuntius_World.Browser;

with Fabula.Args;
with Fabula.Check;
with Fabula.Frames;
with Fabula.Registry;

--  The step registry the feature runner dispatches on: one Step_Kind
--  per pattern, one table that reads like the features, and one Execute
--  that offers each step to every feature's state machine.

package Nuntius_Steps is

   use Ada.Strings.Unbounded;

   --  The steps, grouped by the feature that reads them.  Each is an
   --  event of that feature's state machine, in its own child package.
   type Step_Kind is
     (E_Start_Server,
      E_Start_Short_Server,
      E_Start_Stream_Server,
      E_Start_Deflate_Server,
      E_Start_Gzip_Server,
      E_Send_Request,
      E_Add_Header,
      E_Add_Body,
      E_Split_Body,
      E_Send_Raw,
      E_Send_Half,
      E_Send_Dribble,
      E_Send_Upgrade,
      E_Send_Offer,
      E_Check_Status,
      E_Check_Carries,
      E_Check_Lacks,
      E_Check_Silent,
      E_Check_Handled,
      E_Check_Adopted,
      E_Check_Not_Adopted,
      E_Check_Saw_Upgrade,
      E_Check_No_Upgrade,
      E_Check_Gunzips,
      E_Check_Big_Body,
      E_Check_Length_Matches,
      E_Set_Agent,
      E_Curl_Refused,
      E_Curl_Recorded,
      E_Fetch_Recorded,
      E_Fetch_Pump,
      E_Fetch_Start,
      E_Fetch_Cancel,
      E_Fetch_Until_Done,
      E_Fetch_Fill,
      E_Check_Response_Failure,
      E_Check_Response_Status,
      E_Check_Wire,
      E_Check_Completion_Status,
      E_Check_No_Completion,
      E_Check_In_Flight,
      E_Check_Completion_Failure,
      E_Check_Within,
      E_Check_Start_Refused,
      E_Check_All_Complete,
      E_Ws_Default,
      E_Ws_Shaped,
      E_Ws_Impatient,
      E_Start_Peer,
      E_Ws_Dial_Refused,
      E_Ws_Connect,
      E_Ws_Until_Lost,
      E_Ws_Receive_For,
      E_Ws_Receive_Many,
      E_Ws_Receive,
      E_Check_Dial_Failed,
      E_Check_Reception,
      E_Check_Message,
      E_Check_Pong,
      E_Check_In_Order,
      E_Check_Dropped,
      E_Check_Oversized,
      E_Check_No_Oversized,
      E_Check_Lost_Within,
      E_Pair_Plain,
      E_Pair_Deflated,
      E_Peer_Send_Big,
      E_Peer_Send_Packed,
      E_Peer_Send_Text,
      E_Browser_Ping,
      E_Browser_Close,
      E_Browser_Long,
      E_Browser_Binary,
      E_Browser_Rsv1,
      E_Browser_Ping_Rsv1,
      E_Browser_Packed_Json,
      E_Browser_Packed_Zeros,
      E_Browser_Named,
      E_Browser_Json,
      E_Browser_Hangs_Up,
      E_Peer_Pump,
      E_Check_Pump,
      E_Check_Read_Sent,
      E_Check_Text_Frame,
      E_Check_Text_Length,
      E_Check_Packed_Frame,
      E_Check_Pong_Frame,
      E_Check_Close_Frame,
      E_Check_Shut,
      E_Check_Send_Fails,
      E_Gzip_Json,
      E_Gzip_Noise,
      E_Pack_Json,
      E_Check_Tenth,
      E_Check_Gunzip_Back,
      E_Check_Unpack_Back,
      E_Check_Packed_Word,
      --  Events no pattern names: a machine posts them to itself after
      --  an action whose result the next row's guard reads.
      E_Listened,
      E_Adoption_Settled,
      --  Added when the features took over the integration tests: the
      --  exact facts those tests asserted.
      E_Check_Echoed,
      E_Check_Big_Prefix,
      E_Check_Response_Empty,
      E_Check_Slots_Taken);

   type Hook_Kind is (Fresh_World, Stop_World);

   --  A request being composed: its head so far, its body, and how long
   --  after the head the body follows.  It goes out at the first check.
   type Pending_Request is record
      Method  : Unbounded_String;
      Target  : Unbounded_String;
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

   --  What the websocket client met: the scripted peer's port, the dial,
   --  the last reception and its text, and a run of receives' tallies.
   type Ws_Reading is record
      Peer     : Natural := 0;
      Dialed   : Boolean := False;
      Got      : Nuntius.Ws.Reception;
      Message  : Unbounded_String;
      Wanted   : Natural := 0;
      Received : Natural := 0;
      In_Order : Boolean := True;
      Calls    : Natural := 0;
      Timeouts : Natural := 0;
   end record;

   --  What the served end did: the last pump's outcome and message,
   --  what the browser sent, and what the peer packed.
   type Peer_Reading is record
      Outcome : Nuntius_World.Browser.Peers.Pump_Outcome :=
        Nuntius_World.Browser.Peers.Nothing;
      Read    : Unbounded_String;
      Sent    : Unbounded_String;
      Packed  : Unbounded_String;
   end record;

   --  A round trip through Nuntius.Deflate: the text, and what came out.
   type Coding_Reading is record
      Text   : Unbounded_String;
      Result : Unbounded_String;
   end record;

   --  What one scenario reads back.  fabula copies it per step, so it
   --  holds values only; the sockets and tasks live in Nuntius_World.
   type World is record
      Port    : Natural := 0;
      Request : Pending_Request;
      Reply   : Unbounded_String;
      Client  : Client_Reading;
      Ws      : Ws_Reading;
      Peer    : Peer_Reading;
      Coding  : Coding_Reading;
   end record;

   --  One step as a machine sees it: the scenario, the step's arguments,
   --  frame and outcome, and the event an action asks to be taken next
   --  (Then_Take), which the runner posts before the step returns.
   type Step_Context is record
      W        : World;
      A        : Fabula.Args.List;
      Info     : Fabula.Frames.Frame;
      R        : Fabula.Check.Outcome;
      Has_Next : Boolean := False;
      Next     : Step_Kind := Step_Kind'First;
   end record;

   procedure Then_Take (Ctx : in out Step_Context; Evt : Step_Kind);

   --  Whether capture N reads as a whole number of zero or more: the
   --  guard every counting step's rows share.
   function Count_Read (Ctx : Step_Context; N : Positive := 1) return Boolean;

   --  Capture N, which Count_Read said reads.
   function Count (Ctx : Step_Context; N : Positive := 1) return Natural
   with Pre => Count_Read (Ctx, N);

   --  Fail the step for capture N: why it does not read as a count.
   procedure Refuse_Count (Ctx : in out Step_Context; N : Positive := 1);

   package Steps is new
     Fabula.Registry
       (Step_Kind => Step_Kind,
        Hook_Kind => Hook_Kind,
        Context   => World);
   use Steps;

   --!format off
   Step_Defs : constant Steps.Step_Table :=
     [Step ("a serving loop on loopback")                     >= E_Start_Server,
      Step ("a serving loop with a 1-second connection budget")
                                                              >= E_Start_Short_Server,
      Step ("a serving loop that takes upgrades on {word}")
                                                              >= E_Start_Stream_Server,
      Step ("a serving loop that compresses when offered "
            & "and takes upgrades on {word}")            >= E_Start_Deflate_Server,
      Step ("a serving loop that compresses when offered")    >= E_Start_Gzip_Server,
      Step ("the client sends a {word} to {word}")            >= E_Send_Request,
      Step ("with header {string}")                           >= E_Add_Header,
      Step ("with the body arriving {int} ms later")          >= E_Split_Body,
      Step ("with the body {}")                               >= E_Add_Body,
      Step ("the client sends half a head and hangs up")      >= E_Send_Half,
      Step ("the client dribbles one byte every {int} ms")    >= E_Send_Dribble,
      Step ("the client sends {string}")                      >= E_Send_Raw,
      Step ("the client upgrades to {word} offering {string}")
                                                              >= E_Send_Offer,
      Step ("the client upgrades to {word}")                  >= E_Send_Upgrade,
      Step ("the reply status is {int}")                      >= E_Check_Status,
      Step ("the reply carries no {string}")                  >= E_Check_Lacks,
      Step ("the reply carries {string}")                     >= E_Check_Carries,
      Step ("the handler received {string}")                  >= E_Check_Carries,
      Step ("the handler echoed the request")                 >= E_Check_Echoed,
      Step ("the reply body is {int} bytes of the big JSON")  >= E_Check_Big_Prefix,
      Step ("no reply arrives")                               >= E_Check_Silent,
      Step ("the handler saw {int} request(s)")               >= E_Check_Handled,
      Step ("the handler saw it as an upgrade")               >= E_Check_Saw_Upgrade,
      Step ("the handler did not see an upgrade")             >= E_Check_No_Upgrade,
      Step ("the socket was adopted {word}")                  >= E_Check_Adopted,
      Step ("no socket was adopted")                          >= E_Check_Not_Adopted,
      Step ("the reply body gunzips to the big JSON")         >= E_Check_Gunzips,
      Step ("the reply body is the big JSON")                 >= E_Check_Big_Body,
      Step ("the reply's Content-Length is its body's")       >= E_Check_Length_Matches,
      Step ("the User-Agent is {string}")                     >= E_Set_Agent,
      Step ("the curl client sends a {word} to a refused loopback port")
                                                              >= E_Curl_Refused,
      Step ("the curl client sends a GET to a recording peer")
                                                              >= E_Curl_Recorded,
      Step ("the async client sends a GET to a recording peer")
                                                              >= E_Fetch_Recorded,
      Step ("the async client pumps once")                    >= E_Fetch_Pump,
      Step ("the async client starts a {word} to a refused loopback port")
                                                              >= E_Fetch_Start,
      Step ("the async client cancels it")                    >= E_Fetch_Cancel,
      Step ("the async client pumps and waits until it completes")
                                                              >= E_Fetch_Until_Done,
      Step ("the async client fills its table with GETs to a refused "
            & "loopback port")                                >= E_Fetch_Fill,
      Step ("the response is a transport failure")            >= E_Check_Response_Failure,
      Step ("the response status is {int}")                   >= E_Check_Response_Status,
      Step ("the request on the wire carried {string}")       >= E_Check_Wire,
      Step ("the response carries no reply and no location")  >= E_Check_Response_Empty,
      Step ("every slot of the table was taken")              >= E_Check_Slots_Taken,
      Step ("the completion status is {int}")                 >= E_Check_Completion_Status,
      Step ("no completion surfaced")                         >= E_Check_No_Completion,
      Step ("the async client has {int} transfer(s) in flight")
                                                              >= E_Check_In_Flight,
      Step ("the completion is a transport failure")          >= E_Check_Completion_Failure,
      Step ("it surfaced within {int} seconds")               >= E_Check_Within,
      Step ("one more start is refused")                      >= E_Check_Start_Refused,
      Step ("every started transfer completes")               >= E_Check_All_Complete,
      Step ("a websocket client whose ring holds {int} frames of up to {int} "
            & "bytes")                                        >= E_Ws_Shaped,
      Step ("a websocket client that gives up after 1 second of silence")
                                                              >= E_Ws_Impatient,
      Step ("a websocket client")                             >= E_Ws_Default,
      Step ("a scripted websocket peer that sends:")          >= E_Start_Peer,
      Step ("the websocket client dials a refused loopback port")
                                                              >= E_Ws_Dial_Refused,
      Step ("the websocket client connects")                  >= E_Ws_Connect,
      Step ("the websocket client receives with {int} ms patience until it "
            & "is lost")                                      >= E_Ws_Until_Lost,
      Step ("the websocket client receives with {int} ms patience")
                                                              >= E_Ws_Receive_For,
      Step ("the websocket client receives {int} messages")   >= E_Ws_Receive_Many,
      Step ("the websocket client receives")                  >= E_Ws_Receive,
      Step ("the dial fails")                                 >= E_Check_Dial_Failed,
      Step ("the reception is {word}")                        >= E_Check_Reception,
      Step ("the message is {string}")                        >= E_Check_Message,
      Step ("the peer saw a pong")                            >= E_Check_Pong,
      Step ("every one was delivered, in order")              >= E_Check_In_Order,
      Step ("the client counted dropped frames and no oversized one")
                                                              >= E_Check_Dropped,
      Step ("the client counted {int} oversized frame(s), the largest {int} "
            & "bytes")                                        >= E_Check_Oversized,
      Step ("the client counted no oversized frame")          >= E_Check_No_Oversized,
      Step ("it was lost within {int} receives, after at least {int} healthy "
            & "timeouts")                                     >= E_Check_Lost_Within,
      Step ("a deflated websocket pair")                      >= E_Pair_Deflated,
      Step ("a websocket pair")                               >= E_Pair_Plain,
      Step ("the peer sends a {int}-byte message")            >= E_Peer_Send_Big,
      Step ("the peer sends {int} bytes of JSON, packed")     >= E_Peer_Send_Packed,
      Step ("the peer sends {string}")                        >= E_Peer_Send_Text,
      Step ("the browser sends a ping with RSV1 set")         >= E_Browser_Ping_Rsv1,
      Step ("the browser sends a ping {string}")              >= E_Browser_Ping,
      Step ("the browser sends a close with code {int}")      >= E_Browser_Close,
      Step ("the browser sends a {int}-byte text message")    >= E_Browser_Long,
      Step ("the browser sends a binary frame")               >= E_Browser_Binary,
      Step ("the browser sends a text frame with RSV1 set")   >= E_Browser_Rsv1,
      Step ("the browser sends {int} bytes of JSON, packed")  >= E_Browser_Packed_Json,
      Step ("the browser sends {int} zeros, packed")          >= E_Browser_Packed_Zeros,
      Step ("the browser sends the bytes named {word} as a packed frame")
                                                              >= E_Browser_Named,
      Step ("the browser sends the text {}")                  >= E_Browser_Json,
      Step ("the browser hangs up")                           >= E_Browser_Hangs_Up,
      Step ("the peer pumps")                                 >= E_Peer_Pump,
      Step ("the pump outcome is {word}")                     >= E_Check_Pump,
      Step ("the peer read what the browser sent")            >= E_Check_Read_Sent,
      Step ("the browser reads a text frame of {int} bytes")  >= E_Check_Text_Length,
      Step ("the browser reads a text frame {string}")        >= E_Check_Text_Frame,
      Step ("the browser reads a packed frame of what the peer packed")
                                                              >= E_Check_Packed_Frame,
      Step ("the browser reads a pong {string}")              >= E_Check_Pong_Frame,
      Step ("the browser reads a close with code {int}")      >= E_Check_Close_Frame,
      Step ("the peer is shut")                               >= E_Check_Shut,
      Step ("a send from the peer fails")                     >= E_Check_Send_Fails,
      Step ("{int} bytes of JSON are gzipped")                >= E_Gzip_Json,
      Step ("{int} bytes of noise are gzipped")               >= E_Gzip_Noise,
      Step ("{int} bytes of JSON are packed")                 >= E_Pack_Json,
      Step ("the result is under a tenth of them")            >= E_Check_Tenth,
      Step ("zlib reads the result back whole")               >= E_Check_Gunzip_Back,
      Step ("it unpacks to the same text")                    >= E_Check_Unpack_Back,
      Step ("{word} was packed")                              >= E_Check_Packed_Word];
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
