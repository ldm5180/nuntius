with Ada.Streams;
with Ada.Strings.Unbounded;

with GNAT.Sockets;

--  A websocket server that plays a script: it accepts one connection,
--  reads the client's upgrade request, then runs its steps in order and
--  hangs up.  Steps accumulate into one pending write, and Flush, Hold,
--  Await_Pong and the script's end send it -- so a script says which
--  frames reach the client glued into one read, which is what the
--  burst and handshake cases are about.  Frames go out unmasked
--  (RFC 6455 5.1), each payload under 126 bytes.

package Nuntius_World.Ws_Script is

   type Step_Kind is
     (Upgrade,       --  the 101 head
      Text,          --  a whole text frame
      Text_Start,    --  a text frame without FIN
      Continuation,  --  a continuation frame with FIN
      Ping,          --  an empty ping
      Close,         --  an empty close
      Burst,         --  Count one-byte text frames, payload 0, 1, ..
      Raw,           --  one frame: first byte Lead, Count bytes of 'x'
      Flush,         --  send what is pending
      Hold,          --  flush, then wait Pause
      Await_Pong);   --  flush, then read one frame and note a pong

   type Step is record
      Kind  : Step_Kind := Close;
      Text  : Ada.Strings.Unbounded.Unbounded_String;
      Count : Natural := 0;
      Lead  : Ada.Streams.Stream_Element := 16#81#;
      Pause : Duration := 0.0;
   end record;

   Max_Steps : constant := 32;

   type Script is array (Positive range <>) of Step;

   --  The steps by their names, for an aggregate that reads like the
   --  exchange it scripts.
   function Upgraded return Step
   is ((Kind => Upgrade, others => <>));
   function Text_Of (S : String) return Step;
   function Start_Of (S : String) return Step;
   function Continued (S : String) return Step;
   function Pinged return Step
   is ((Kind => Ping, others => <>));
   function Closed return Step
   is ((Kind => Close, others => <>));
   function Burst_Of (Count : Natural) return Step
   is ((Kind => Burst, Count => Count, others => <>));
   function Raw_Of
     (Lead : Ada.Streams.Stream_Element; Count : Natural) return Step
   is ((Kind => Raw, Lead => Lead, Count => Count, others => <>));
   function Flushed return Step
   is ((Kind => Flush, others => <>));
   function Held (Pause : Duration) return Step
   is ((Kind => Hold, Pause => Pause, others => <>));
   function Pong_Awaited return Step
   is ((Kind => Await_Pong, others => <>));

   --  Whether the last Await_Pong read a pong.
   protected Result is
      procedure Set_Pong (V : Boolean);
      function Pong_Seen return Boolean;
   private
      Seen : Boolean := False;
   end Result;

   task type Peer is
      entry Serve (Listener : GNAT.Sockets.Socket_Type; Plan : Script)
      with Pre => Plan'Length <= Max_Steps;
   end Peer;

   --  Bind a listener on 127.0.0.1:0, hand it and Plan to Srv, and
   --  answer the port it got.
   function Start
     (Srv : not null access Peer; Plan : Script) return GNAT.Sockets.Port_Type
   with Pre => Plan'Length <= Max_Steps;

   --  ws://127.0.0.1:<Port><Path>.
   function Url (Port : GNAT.Sockets.Port_Type; Path : String) return String;

end Nuntius_World.Ws_Script;
