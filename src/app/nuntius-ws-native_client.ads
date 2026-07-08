with GNAT.Sockets;
with Interfaces;

with Sml.Machines;
with Sml.Machines.Operators;

with Nuntius.Frame_Fifo;
with Nuntius.Rfc6455;

--  The production Nuntius.Ws adapter over a hand-rolled RFC 6455 client
--  (GNAT.Sockets, no TLS -- the feed is a plaintext localhost Terminal).
--  Connect dials, runs the HTTP upgrade handshake, and starts fresh; Send
--  emits one masked text frame; Receive pumps the socket, decodes frames
--  with Nuntius.Rfc6455, and delivers whole text messages.  The
--  opcode/fragmentation reactions -- deliver, begin/extend/finish a
--  fragmented message, auto-pong a ping, die on close/oversize/idle/fault
--  -- are an sml transition table (the Read_State machine below), so every
--  frame class dispatches through a visible row instead of nested ifs.  A
--  bounded FIFO (Nuntius.Frame_Fifo) buffers delivered messages; the wire
--  arithmetic is proved in Nuntius.Rfc6455.  All socket specifics stay
--  behind this one unit.
--
--  Generic over the ring bounds so the transport, its consumer, and the
--  consumer's proof harness share one set of numbers.

generic
   Ring_Depth : Positive;
   --  Inbound-message ring depth: absorbs a burst while the single
   --  consumer pops one message per Receive.

   Max_Frame_Bytes : Positive;
   --  Largest inbound message accepted (a single frame, or a reassembled
   --  fragmented one); anything longer marks the connection dead.

   Idle_Limit : Duration := 45.0;
   --  A stream silent this long -- no data, no control frames -- is treated
   --  as a lost connection (a silent TCP partition fires no close).

   Poll_Slice : Duration := 1.0;
   --  Each blocking socket read waits at most this long before the
   --  connection flags and idle deadline are re-checked.

package Nuntius.Ws.Native_Client
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

   package Frames is new
     Nuntius.Frame_Fifo
       (Depth           => Ring_Depth,
        Max_Frame_Bytes => Max_Frame_Bytes);

   subtype Frame_Length is Natural range 0 .. Max_Frame_Bytes;
   subtype Control_Length is Natural range 0 .. 125;

   --  Read-side lifecycle: Open (between messages), Assembling (mid a
   --  fragmented message awaiting continuations), Dead (reconnect-worthy).
   type Read_State is (S_Open, S_Assembling, S_Dead);

   --  One event per decoded frame class the read pump posts.
   type Read_Event is
     (E_Text,       --  FIN text frame: a whole single-frame message
      E_Start,      --  non-FIN text frame: start of a fragmented message
      E_Cont,       --  non-FIN continuation
      E_End,        --  FIN continuation: completes the message
      E_Ping,       --  ping: auto-pong
      E_Pong,       --  pong: ignore (liveness only)
      E_Close,      --  peer close frame
      E_Oversized,  --  a frame/message past Max_Frame_Bytes
      E_Idle,       --  stream silent past Idle_Limit
      E_Fault);     --  protocol violation or socket error

   type Event is record
      Kind : Read_Event;
   end record;

   type Command is (None, Send_Pong);

   --  The read machine's context: the just-decoded frame staged by the
   --  shell (In_Frame), the reassembly buffer (Assembly), the delivered-
   --  message ring, the death flag, and the one request the machine hands
   --  back (a pong to send, with its echoed payload).
   type Context is record
      Inbound  : Frames.Fifo;
      In_Frame : String (1 .. Max_Frame_Bytes) := [others => ' '];
      In_Len   : Frame_Length := 0;
      Assembly : String (1 .. Max_Frame_Bytes) := [others => ' '];
      Asm_Len  : Frame_Length := 0;
      Dead     : Boolean := False;
      Pending  : Command := None;
      Pong     : String (1 .. 125) := [others => ' '];
      Pong_Len : Control_Length := 0;
   end record;

   type Guard_Kind is (Always);
   type Action_Kind is
     (A_Nothing, A_Deliver, A_Begin, A_Extend, A_Finish, A_Pong, A_Die);

   function Kind_Of (E : Event) return Read_Event
   is (E.Kind);

   function Evaluate
     (G : Guard_Kind; Ctx : Context; Evt : Event) return Boolean;

   procedure Execute (A : Action_Kind; Ctx : in out Context; Evt : Event);

   package SM is new
     Sml.Machines
       (State       => Read_State,
        Event_Kind  => Read_Event,
        Event       => Event,
        Context     => Context,
        Guard_Kind  => Guard_Kind,
        Action_Kind => Action_Kind,
        Kind_Of     => Kind_Of,
        Evaluate    => Evaluate,
        Execute     => Execute);

   package Op is new SM.Operators (Always => Always, Nothing => A_Nothing);

   use SM;
   use Op;

   Text_F      : constant Op.Ev := (Kind => E_Text);
   Start_F     : constant Op.Ev := (Kind => E_Start);
   Cont_F      : constant Op.Ev := (Kind => E_Cont);
   End_F       : constant Op.Ev := (Kind => E_End);
   Ping_F      : constant Op.Ev := (Kind => E_Ping);
   Pong_F      : constant Op.Ev := (Kind => E_Pong);
   Close_F     : constant Op.Ev := (Kind => E_Close);
   Oversized_F : constant Op.Ev := (Kind => E_Oversized);
   Idle_F      : constant Op.Ev := (Kind => E_Idle);
   Fault_F     : constant Op.Ev := (Kind => E_Fault);

   --!format off
   Table : constant SM.Transition_Table :=
     [S_Open       + Text_F      / A_Deliver >= S_Open,
      S_Open       + Start_F     / A_Begin   >= S_Assembling,
      S_Open       + Ping_F      / A_Pong    >= S_Open,
      S_Open       + Pong_F                  >= S_Open,
      S_Open       + Close_F     / A_Die     >= S_Dead,
      S_Open       + Oversized_F / A_Die     >= S_Dead,
      S_Open       + Idle_F      / A_Die     >= S_Dead,
      S_Open       + Fault_F     / A_Die     >= S_Dead,
      S_Assembling + Cont_F      / A_Extend  >= S_Assembling,
      S_Assembling + End_F       / A_Finish  >= S_Open,
      S_Assembling + Ping_F      / A_Pong    >= S_Assembling,
      S_Assembling + Pong_F                  >= S_Assembling,
      S_Assembling + Close_F     / A_Die     >= S_Dead,
      S_Assembling + Oversized_F / A_Die     >= S_Dead,
      S_Assembling + Idle_F      / A_Die     >= S_Dead,
      S_Assembling + Fault_F     / A_Die     >= S_Dead];
   --!format on

   --  The read machine carries no state beyond its current State (the table
   --  is a constant), so the Client persists only the State and rebuilds a
   --  transient Machine per event -- which also sidesteps embedding sml's
   --  discriminated Machine type as a component.
   type Client is limited new Nuntius.Ws.Transport with record
      Sock       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Has_Socket : Boolean := False;
      Connected  : Boolean := False;
      State      : Read_State := S_Open;
      Ctx        : Context;
      Accum      :
        Nuntius.Rfc6455.Octets
          (1 .. Max_Frame_Bytes + Nuntius.Rfc6455.Max_Header_Bytes) :=
          [others => 0];
      Accum_Len  : Natural := 0;
      Mask_Seed  : Interfaces.Unsigned_32 := 16#1234_5678#;
   end record;

end Nuntius.Ws.Native_Client;
