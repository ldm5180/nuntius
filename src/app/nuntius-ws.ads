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

end Nuntius.Ws;
