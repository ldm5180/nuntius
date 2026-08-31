--  The websocket transport port: exactly the shapes a streaming consumer
--  needs (dial, send one text frame, block for the next inbound text
--  frame, hang up).  Tests plug in a scripted fake; production plugs in
--  the AWS-crate adapter.  Keeping the port this narrow is what keeps
--  every consumer test offline -- and what would let a hand-rolled
--  websocket library replace the AWS crate without touching anything
--  else.

package Nuntius.Ws is

   type Transport is limited interface;

   --  Ok False means the endpoint could not be dialed (or the upgrade
   --  handshake failed).  Connecting an already-connected transport is
   --  the adapter's problem to make safe (close-then-dial).
   procedure Connect (Self : in out Transport; URL : String; Ok : out Boolean)
   is abstract;

   --  One outbound text frame.  Ok False means the connection is
   --  unusable and should be re-dialed.
   procedure Send_Text
     (Self : in out Transport; Payload : String; Ok : out Boolean)
   is abstract;

   --  Block for the next inbound text frame, delivered in
   --  Into (Into'First .. Last).  Ok False means closed, failed, a frame
   --  too large for Into, or a stream silent past the adapter's idle
   --  limit -- all reconnect-worthy.
   procedure Receive
     (Self : in out Transport;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean)
   is abstract;

   --  Block for the next inbound text frame for at most Patience
   --  seconds.  Timed_Out True (with Ok True and Last = 0) means the
   --  wait elapsed with the connection still healthy -- deliberately
   --  NOT reconnect-worthy: a quiet stream is the caller's business,
   --  and this is the primitive a keepalive scheduler needs (a consumer
   --  that must SEND on a schedule cannot sit in Receive forever, and a
   --  quiet stream would park it there past the idle limit).
   --  Everything Ok False meant on Receive it still means here, and the
   --  idle limit keeps its authority: the idle clock accumulates ACROSS
   --  calls in the adapter, so total silence past the limit is still
   --  reported dead however patient each individual call was.
   procedure Receive_For
     (Self      : in out Transport;
      Into      : out String;
      Last      : out Natural;
      Patience  : Duration;
      Ok        : out Boolean;
      Timed_Out : out Boolean)
   is abstract;

   procedure Close (Self : in out Transport) is abstract;

   ---------------------------------------------------------------------
   --  What the adapter absorbed
   ---------------------------------------------------------------------

   --  Inbound frames lost on the CURRENT connection, by reason.
   --
   --  Neither number can reach a consumer through Receive, which is the
   --  whole reason for asking separately.  A ring that overflowed KEPT
   --  streaming -- a transient burst must not cost a redial, which
   --  would lose the whole backlog and add a gap -- so the loss never
   --  ends a Receive call and the feed simply looks quiet.  An
   --  oversized frame is discarded BEFORE any Receive could see it, so
   --  a consumer measuring frame sizes for itself cannot see the frame
   --  that mattered: its high-water reads low at exactly the moment the
   --  bound is the problem, and the only symptom is a reconnect loop
   --  with no stated cause.
   --
   --  Kept apart because they call for opposite fixes -- drain faster
   --  or go deeper for one, raise the bound for the other -- and
   --  Largest is what says how far to raise it.
   type Loss_Report is record
      Dropped   : Natural := 0;  --  ring full; connection kept
      Oversized : Natural := 0;  --  past the bound; connection died
      Largest   : Natural := 0;  --  the longest oversized frame's length
   end record;

   function Losses (Self : Transport) return Loss_Report is abstract;

   ---------------------------------------------------------------------
   --  Optional diagnostics
   ---------------------------------------------------------------------

   --  Why the last failed operation failed, for adapters that can say.
   --
   --  A SECOND interface rather than a new Transport primitive, so no
   --  existing adapter or test fake owes an implementation: a consumer
   --  that wants the reason membership-tests for it --
   --
   --     if Ws.all in Nuntius.Ws.Diagnosable'Class then ...
   --
   --  -- and one that does not keeps dialing on Ok alone.  It exists
   --  because Ok = False deliberately absorbs the adapter's exception
   --  (the port contract; a reconnect loop must not die), and absorbing
   --  the MESSAGE with it once cost a real outage its diagnosis: a
   --  total TLS failure read as nothing but "connect failed" retrying
   --  forever, and the reason took a throwaway main to see.
   type Diagnosable is limited interface;

   --  The stored reason ("" when nothing has failed since the last
   --  success).  Text for a log line, never for dispatching on.
   function Last_Error (Self : Diagnosable) return String is abstract;

end Nuntius.Ws;
