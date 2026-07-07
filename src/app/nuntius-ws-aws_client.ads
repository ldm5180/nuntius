with AWS.Net.WebSocket;

with Nuntius.Frame_Fifo;

--  The production Nuntius.Ws adapter over the AWS crate's client-side
--  websocket: Connect hangs up and frees any previous dial (the port's
--  close-then-dial contract; AWS allocates per dial) before dialing the
--  URI, Poll pumps inbound frames into a small FIFO via the On_Message
--  callback (client mode -- everything runs on the caller's task, no
--  locking), and close/error callbacks mark the connection dead so
--  Receive reports it.  A stream silent past the idle limit is treated
--  as a lost connection too -- a silent TCP partition never fires a
--  callback.  The FIFO slots are bounded, so the per-frame hot path
--  never touches the heap.  All AWS specifics stay behind this one
--  unit.
--
--  Generic over the ring bounds so the transport, its consumer, and the
--  consumer's proof harness can share one set of numbers and never
--  disagree about what fits.

generic
   Ring_Depth : Positive;
   --  Inbound-frame ring depth: deep enough to absorb a burst while the
   --  single consumer pops one frame per Receive.

   Max_Frame_Bytes : Positive;
   --  Largest inbound frame accepted; anything longer marks the
   --  connection dead (reconnect-worthy, per the port contract).

   Idle_Limit : Duration := 45.0;
   --  A stream with no traffic at all -- no data, no control frames --
   --  for this long is treated as lost: Receive reports Ok = False and
   --  the consumer redials.  A silent TCP partition (NAT timeout,
   --  pulled cable) never fires On_Close/On_Error, so only a deadline
   --  can catch it.

   Poll_Slice : Duration := 1.0;
   --  How long each poll waits before the connection flags are
   --  re-checked; Receive itself blocks until a frame arrives, the
   --  socket dies, or the stream has been silent past Idle_Limit.

package Nuntius.Ws.Aws_Client
is

   type Client is limited new Nuntius.Ws.Transport with private;

   overriding
   procedure Connect (Self : in out Client; URL : String; Ok : out Boolean);

   overriding
   procedure Send_Text
     (Self : in out Client; Payload : String; Ok : out Boolean);

   overriding
   procedure Receive
     (Self : in out Client;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean);

   overriding
   procedure Close (Self : in out Client);

private

   --  An oversized inbound frame marks the connection dead
   --  (reconnect-worthy, per the port contract); a merely full ring
   --  drops the newest frame and keeps streaming (a burst must not
   --  reconnect).
   package Frames is new
     Nuntius.Frame_Fifo
       (Depth           => Ring_Depth,
        Max_Frame_Bytes => Max_Frame_Bytes);

   --  The derived AWS socket: callbacks fill the fifo and the flag.
   type Socket_Type is new AWS.Net.WebSocket.Object with record
      Inbound : Frames.Fifo;
      Dead    : Boolean := False;
   end record;

   --  Each dial owns a fresh Socket_Type on the heap, released whole the
   --  next time Connect runs.  AWS's WebSocket.Free frees the socket
   --  through its HTTP connection but leaves the object's aliased
   --  Socket_Access field dangling, so freeing a reused object a second
   --  time double-frees; a one-dial-per-object lifetime frees each
   --  exactly once, and a pristine object's field is null (a safe no-op).
   type Socket_Access is access Socket_Type;

   overriding
   procedure On_Message (Socket : in out Socket_Type; Message : String);

   overriding
   procedure On_Close (Socket : in out Socket_Type; Message : String);

   overriding
   procedure On_Error (Socket : in out Socket_Type; Message : String);

   type Client is limited new Nuntius.Ws.Transport with record
      Sock      : Socket_Access;
      Connected : Boolean := False;
   end record;

end Nuntius.Ws.Aws_Client;
