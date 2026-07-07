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

end Nuntius.Ws;
