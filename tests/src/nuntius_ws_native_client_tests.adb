with AUnit.Assertions; use AUnit.Assertions;

with GNAT.Sockets; use GNAT.Sockets;

with Nuntius.Ws.Native_Client;

with Nuntius_World.Ws_Script; use Nuntius_World.Ws_Script;

--  The native RFC 6455 adapter.  Offline behavior first (unconnected /
--  refused-dial, no server), then a full loopback exchange against a tiny
--  in-process GNAT.Sockets websocket server: the upgrade handshake, a
--  single text message, a fragmented message reassembled, and an auto-pong
--  to a ping -- all over ws:// on a loopback port, no network.

package body Nuntius_Ws_Native_Client_Tests is

   use type Nuntius.Ws.Receive_Outcome;

   use AUnit.Test_Cases.Registration;

   --  Whether Got delivered exactly Text into Buf.
   function Holds_Frame
     (Got : Nuntius.Ws.Reception; Buf : String; Text : String) return Boolean
   is (Got.Outcome = Nuntius.Ws.Delivered
       and then Buf (Buf'First .. Got.Last) = Text);

   --  Fail fast rather than block a suite: tiny idle/poll so a hung read
   --  ends in a couple of seconds.
   package Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 8,
        Max_Frame_Bytes => 256,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   --  Tiny frames but a deep ring: a burst of many frames arrives in one
   --  read that far exceeds the accumulator, so the read pump must not drop
   --  the surplus (the desync bug this guards against).  The whole burst is
   --  one contiguous write (~300 bytes) landing in one recv, far past the
   --  16 + header accumulator.
   Burst_Count : constant := 100;

   package Burst_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 128,
        Max_Frame_Bytes => 16,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   --  A burst into a ring FAR too shallow for it: Drain decodes every
   --  frame already buffered, so all Flood_Count land on a ring holding
   --  four and the rest are refused -- with the connection KEPT, which
   --  is the right reaction and exactly why the loss has to be counted.
   --  Nothing else about it is observable.
   --
   --  The bound is roomy on purpose.  The read accumulator is
   --  Max_Frame_Bytes + a header, and the whole burst has to FIT it in
   --  one go for the drop to be deterministic: at a tight bound only a
   --  couple of frames are decodable per Drain and a shallow ring is
   --  never actually overrun.
   Flood_Count : constant := 40;

   package Flood_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 4,
        Max_Frame_Bytes => 256,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   --  One text frame whose payload is past this instance's bound.
   Over_Bytes : constant := 100;

   package Over_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 4,
        Max_Frame_Bytes => 32,
        Idle_Limit      => 2.0,
        Poll_Slice      => 0.25);

   --  Receive_For's idle persistence: Idle_Limit 1.0 over 0.25 slices,
   --  so four silent slices kill the connection even when they are
   --  spread over four separate patient calls.  A per-call idle clock
   --  would never fire and a silent partition would never be detected.
   package Idle_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => 8,
        Max_Frame_Bytes => 256,
        Idle_Limit      => 1.0,
        Poll_Slice      => 0.25);

   ------------------------------------------------------------------
   --  Offline cases
   ------------------------------------------------------------------

   procedure Test_Unconnected (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C   : Ws.Client;
      Buf : String (1 .. 64);
      Got : Nuntius.Ws.Reception;
      Ok  : Boolean;
   begin
      Ws.Send_Text (C, "hello", Ok);
      Assert (not Ok, "send before any dial reports Ok = False");
      Ws.Receive (C, Buf, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Lost, "receive before any dial is lost");
      Assert (Got.Last = 0, "receive before any dial delivers nothing");
      Ws.Receive_For (C, Buf, 0.1, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Lost,
         "a timed receive before any dial is dead, never a timeout");
      Ws.Close (C);  --  harmless no-op
   end Test_Unconnected;

   procedure Test_Refused_Dial (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C  : Ws.Client;
      Ok : Boolean;
   begin
      Ws.Connect (C, "ws://127.0.0.1:9/", Ok);
      Assert (not Ok, "a refused dial reports Ok = False");
      Ws.Connect (C, "ws://127.0.0.1:9/", Ok);
      Assert (not Ok, "a refused redial reports Ok = False, reusable");
      Ws.Close (C);
   end Test_Refused_Dial;

   ------------------------------------------------------------------
   --  Loopback: a scripted websocket peer (Nuntius_World.Ws_Script)
   ------------------------------------------------------------------

   --  The handshake, a single message, a fragmented message reassembled,
   --  a ping auto-ponged, and the peer's close as a loss.
   procedure Test_Loopback (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Ws.Client;
      Buf  : String (1 .. 256);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port :=
        Start
          (Srv'Access,
           [Upgraded,
            Flushed,
            Text_Of ("hello"),
            Flushed,
            Start_Of ("foo"),
            Flushed,
            Continued ("bar"),
            Flushed,
            Pinged,
            Pong_Awaited,
            Closed]);
      Ws.Connect (C, Url (Port, "/v1"), Ok);
      Assert (Ok, "handshake completes over loopback");

      Ws.Receive (C, Buf, Got);
      Assert (Holds_Frame (Got, Buf, "hello"), "first message is hello");

      Ws.Receive (C, Buf, Got);
      Assert
        (Holds_Frame (Got, Buf, "foobar"),
         "fragmented message reassembles to foobar");

      --  After the ping (auto-ponged) the server closes: next receive is
      --  reconnect-worthy.
      Ws.Receive (C, Buf, Got);
      Assert (Got.Outcome = Nuntius.Ws.Lost, "peer close is lost");

      Ws.Close (C);
      Assert (Result.Pong_Seen, "client auto-ponged the server's ping");
   end Test_Loopback;

   ------------------------------------------------------------------
   --  Receive_For: the patience-bounded receive
   ------------------------------------------------------------------

   --  A quiet quarter second is a HEALTHY timeout; the frame that
   --  arrives later is delivered by a patient call on the same
   --  connection; the peer's close is dead, never a timeout.
   procedure Test_Receive_For_Quiet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Ws.Client;
      Buf  : String (1 .. 256);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port :=
        Start (Srv'Access, [Upgraded, Held (1.5), Text_Of ("late"), Closed]);
      Ws.Connect (C, Url (Port, "/v1"), Ok);
      Assert (Ok, "handshake completes over loopback");

      Ws.Receive_For (C, Buf, 0.25, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Expired and then Got.Last = 0,
         "a quiet quarter-second is a healthy timeout, not a death");

      Ws.Receive_For (C, Buf, 5.0, Got);
      Assert
        (Holds_Frame (Got, Buf, "late"),
         "the late frame is delivered inside a patient wait");

      Ws.Receive_For (C, Buf, 5.0, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Lost, "peer close is dead, never a timeout");
      Ws.Close (C);
   end Test_Receive_For_Quiet;

   --  The idle clock persists ACROSS calls: at Idle_Limit 1.0 over
   --  0.25 slices, four silent quarter-second calls report the
   --  connection dead, with healthy timeouts before it.  A per-call
   --  clock would time out politely forever and no silent partition
   --  would ever be detected.
   procedure Test_Receive_For_Idle_Persists
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv      : aliased Peer;
      C        : Idle_Ws.Client;
      Buf      : String (1 .. 256);
      Got      : Nuntius.Ws.Reception;
      Ok       : Boolean;
      Timeouts : Natural := 0;
      Calls    : Natural := 0;
      Port     : Port_Type;
   begin
      Port := Start (Srv'Access, [Upgraded, Held (2.5), Closed]);
      Idle_Ws.Connect (C, Url (Port, "/v1"), Ok);
      Assert (Ok, "handshake completes over loopback");

      for K in 1 .. 10 loop
         Idle_Ws.Receive_For (C, Buf, 0.25, Got);
         Calls := K;
         exit when Got.Outcome = Nuntius.Ws.Lost;
         Timeouts :=
           Timeouts + (if Got.Outcome = Nuntius.Ws.Expired then 1 else 0);
      end loop;

      Assert
        (Got.Outcome = Nuntius.Ws.Lost,
         "total silence past the idle limit is still dead");
      Assert
        (Timeouts >= 2,
         "with healthy timeouts before it; saw" & Timeouts'Image);
      Assert
        (Calls <= 8,
         "the idle clock persisted across the calls; died on call"
         & Calls'Image);
      Idle_Ws.Close (C);
   end Test_Receive_For_Idle_Persists;

   --  The 101 head, Burst_Count tiny frames and the close in ONE write,
   --  so head, burst and close land in the client's kernel buffer
   --  together and its handshake read finds the whole burst GLUED to
   --  the head -- the shape a fast localhost server produces, and the
   --  hostile case for both the handshake (surplus past the
   --  accumulator) and the read pump (one oversized recv).
   procedure Test_Burst (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Burst_Ws.Client;
      Buf  : String (1 .. 32);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port := Start (Srv'Access, [Upgraded, Burst_Of (Burst_Count), Closed]);
      Burst_Ws.Connect (C, Url (Port, "/b"), Ok);
      Assert (Ok, "burst: handshake completes");

      --  Every one of the Burst_Count frames must arrive, in order, none
      --  dropped by an over-long read.
      for I in 0 .. Burst_Count - 1 loop
         Burst_Ws.Receive (C, Buf, Got);
         Assert
           (Got.Outcome = Nuntius.Ws.Delivered,
            "burst: frame" & I'Image & " delivered");
         Assert
           (Got.Last = 1 and then Character'Pos (Buf (1)) = I,
            "burst: frame" & I'Image & " has the right payload, in order");
      end loop;

      Burst_Ws.Close (C);
   end Test_Burst;

   --  The 101 only after a pause LONGER than the client's Poll_Slice
   --  (its socket receive timeout) and well inside Idle_Limit.  A
   --  scheduler hiccup on a loaded CI box puts every real server here
   --  occasionally -- the dial must wait out Idle_Limit, not give up at
   --  the first empty poll slice.  Three slices of silence, then one
   --  frame so the exchange proves the stream survived.
   procedure Test_Slow_Handshake (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Ws.Client;
      Buf  : String (1 .. 32);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port :=
        Start
          (Srv'Access,
           [Held (0.75), Upgraded, Flushed, Text_Of ("s"), Flushed, Closed]);
      Ws.Connect (C, Url (Port, "/s"), Ok);
      Assert (Ok, "slow handshake: the dial waits out Idle_Limit");

      Ws.Receive (C, Buf, Got);
      Assert
        (Holds_Frame (Got, Buf, "s"),
         "slow handshake: the frame behind it still arrives");

      Ws.Close (C);
   end Test_Slow_Handshake;

   --  AN OVERSIZED FRAME KILLS THE CONNECTION AND MUST SAY SO.
   --
   --  It is discarded before any Receive could see it, so a consumer
   --  measuring frame sizes for itself -- which is the whole point of a
   --  provisional Max_Frame_Bytes -- can never see the frame that
   --  mattered.  Its high-water reads LOW at exactly the moment the
   --  bound is the problem, and the only symptom is a reconnect loop
   --  with no stated reason.  So the adapter reports the count AND the
   --  length, because the length is the number the bound has to be
   --  raised past.
   procedure Test_Oversized_Is_Reported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Over_Ws.Client;
      Buf  : String (1 .. 256);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port := Start (Srv'Access, [Upgraded, Raw_Of (16#81#, Over_Bytes)]);
      Over_Ws.Connect (C, Url (Port, "/o"), Ok);
      Assert (Ok, "oversize: handshake completes");

      Over_Ws.Receive (C, Buf, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Lost,
         "an oversized frame is reconnect-worthy");

      Assert
        (Over_Ws.Losses (C).Oversized = 1,
         "and it is COUNTED -- otherwise the death is indistinguishable"
         & " from any other dropped connection; got"
         & Over_Ws.Losses (C).Oversized'Image);
      Assert
        (Over_Ws.Losses (C).Largest = Over_Bytes,
         "with the length the bound has to be raised past; wanted"
         & Natural'Image (Over_Bytes)
         & ", got"
         & Over_Ws.Losses (C).Largest'Image);

      Over_Ws.Close (C);
   end Test_Oversized_Is_Reported;

   --  The client offers no extension, so a frame with RSV1 set is a
   --  protocol violation: reconnect-worthy, and NOT counted as an
   --  oversize, which would send an operator raising the wrong bound.
   procedure Test_Rsv1_Is_Fatal (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Over_Ws.Client;
      Buf  : String (1 .. 256);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port := Start (Srv'Access, [Upgraded, Raw_Of (16#C1#, 5)]);
      Over_Ws.Connect (C, Url (Port, "/r"), Ok);
      Assert (Ok, "rsv1: handshake completes");

      Over_Ws.Receive (C, Buf, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Lost,
         "an RSV1 frame on a plain socket is reconnect-worthy");
      Assert (Over_Ws.Losses (C).Oversized = 0, "and it is not an oversize");

      Over_Ws.Close (C);
   end Test_Rsv1_Is_Fatal;

   --  A FULL RING DROPS FRAMES AND KEEPS STREAMING, WHICH IS WORSE TO
   --  DIAGNOSE THAN A RECONNECT.
   --
   --  Keeping the connection is right: a transient burst must not cost
   --  a redial, which would lose the whole backlog and add a gap.  But
   --  Push's Ok is the only signal the refusal gives, and a consumer
   --  never sees it -- so without a tally the data is simply missing
   --  and the feed looks quiet.  The burst goes in the handshake read's
   --  surplus, so one Drain sees all of it.
   procedure Test_Ring_Overflow_Is_Reported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv  : aliased Peer;
      C    : Flood_Ws.Client;
      Buf  : String (1 .. 32);
      Got  : Nuntius.Ws.Reception;
      Ok   : Boolean;
      Port : Port_Type;
   begin
      Port := Start (Srv'Access, [Upgraded, Burst_Of (Flood_Count)]);
      Flood_Ws.Connect (C, Url (Port, "/f"), Ok);
      Assert (Ok, "flood: handshake completes");

      --  One pop is enough: the whole burst arrived in a single recv and
      --  one Drain decoded all of it, so the refusals have already
      --  happened.
      Flood_Ws.Receive (C, Buf, Got);
      Assert
        (Got.Outcome = Nuntius.Ws.Delivered,
         "the frames that DID fit are still delivered");

      Assert
        (Flood_Ws.Losses (C).Dropped > 0,
         "and the ones the ring could not hold are counted rather than"
         & " vanishing; got"
         & Flood_Ws.Losses (C).Dropped'Image);
      Assert
        (Flood_Ws.Losses (C).Oversized = 0,
         "a full ring is not an oversized frame -- they call for"
         & " opposite fixes and must not share a counter");

      Flood_Ws.Close (C);
   end Test_Ring_Overflow_Is_Reported;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T, Test_Unconnected'Access, "unconnected client refuses politely");
      Register_Routine
        (T, Test_Refused_Dial'Access, "refused dial is Ok = False, reusable");
      Register_Routine
        (T,
         Test_Loopback'Access,
         "loopback: handshake, message, fragmentation, auto-pong");
      Register_Routine
        (T,
         Test_Burst'Access,
         "burst of many frames in one read: none dropped, in order");
      Register_Routine
        (T,
         Test_Oversized_Is_Reported'Access,
         "an oversized frame is counted, with its length");
      Register_Routine
        (T,
         Test_Ring_Overflow_Is_Reported'Access,
         "frames the ring could not hold are counted");
      Register_Routine
        (T,
         Test_Slow_Handshake'Access,
         "a handshake reply slower than one poll slice still connects");
      Register_Routine
        (T,
         Test_Receive_For_Quiet'Access,
         "Receive_For: a quiet wait times out healthy, a frame delivers");
      Register_Routine
        (T,
         Test_Receive_For_Idle_Persists'Access,
         "Receive_For: the idle clock persists across patient calls");
      Register_Routine
        (T,
         Test_Rsv1_Is_Fatal'Access,
         "a frame with RSV1 set is a fault, not an oversize");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return
        AUnit.Format ("Nuntius.Ws.Native_Client (RFC 6455 websocket adapter)");
   end Name;

end Nuntius_Ws_Native_Client_Tests;
