with AUnit.Assertions; use AUnit.Assertions;

with Ada.Streams;       use Ada.Streams;
with Ada.Strings;       use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with GNAT.Sockets;      use GNAT.Sockets;

with Nuntius.Ws.Native_Client;

--  The native RFC 6455 adapter.  Offline behavior first (unconnected /
--  refused-dial, no server), then a full loopback exchange against a tiny
--  in-process GNAT.Sockets websocket server: the upgrade handshake, a
--  single text message, a fragmented message reassembled, and an auto-pong
--  to a ping -- all over ws:// on a loopback port, no network.

package body Nuntius_Ws_Native_Client_Tests is

   use AUnit.Test_Cases.Registration;

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
      C     : Ws.Client;
      Buf   : String (1 .. 64);
      Last  : Natural;
      Ok    : Boolean;
      Timed : Boolean;
   begin
      Ws.Send_Text (C, "hello", Ok);
      Assert (not Ok, "send before any dial reports Ok = False");
      Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "receive before any dial reports Ok = False");
      Assert (Last = 0, "receive before any dial delivers nothing");
      Ws.Receive_For (C, Buf, Last, 0.1, Ok, Timed);
      Assert
        (not Ok and then not Timed,
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
   --  Loopback server: a scripted websocket peer
   ------------------------------------------------------------------

   --  Cross-task result: did the client's auto-pong reach the server?
   protected Result is
      procedure Set_Pong (V : Boolean);
      function Pong_Seen return Boolean;
   private
      Seen : Boolean := False;
   end Result;

   protected body Result is
      procedure Set_Pong (V : Boolean) is
      begin
         Seen := V;
      end Set_Pong;
      function Pong_Seen return Boolean
      is (Seen);
   end Result;

   procedure Send_Bytes (S : Socket_Type; Bytes : Stream_Element_Array) is
      Off  : Stream_Element_Offset := Bytes'First;
      Last : Stream_Element_Offset;
   begin
      while Off <= Bytes'Last loop
         Send_Socket (S, Bytes (Off .. Bytes'Last), Last);
         exit when Last < Off;
         Off := Last + 1;
      end loop;
   end Send_Bytes;

   task type Server is
      entry Serve (Listener : Socket_Type);
   end Server;

   task body Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;

      Accept_Socket (Listen, Peer, From);

      --  Read the client's upgrade request up to the blank line.
      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;  --  enough to have crossed CRLFCRLF
         end loop;
      end;

      --  101 response, then a single message, a fragmented message, a ping.
      Send_Bytes
        (Peer,
         [Character'Pos ('H'),
          Character'Pos ('T'),
          Character'Pos ('T'),
          Character'Pos ('P'),
          Character'Pos ('/'),
          Character'Pos ('1'),
          Character'Pos ('.'),
          Character'Pos ('1'),
          Character'Pos (' '),
          Character'Pos ('1'),
          Character'Pos ('0'),
          Character'Pos ('1'),
          13,
          10,
          13,
          10]);

      --  Unmasked server frames (RFC 6455 5.1):
      --  "hello"
      Send_Bytes
        (Peer,
         [16#81#,
          16#05#,
          Character'Pos ('h'),
          Character'Pos ('e'),
          Character'Pos ('l'),
          Character'Pos ('l'),
          Character'Pos ('o')]);
      --  fragmented "foo" (text, not FIN) + "bar" (continuation, FIN)
      Send_Bytes
        (Peer,
         [16#01#,
          16#03#,
          Character'Pos ('f'),
          Character'Pos ('o'),
          Character'Pos ('o')]);
      Send_Bytes
        (Peer,
         [16#80#,
          16#03#,
          Character'Pos ('b'),
          Character'Pos ('a'),
          Character'Pos ('r')]);
      --  empty ping
      Send_Bytes (Peer, [16#89#, 16#00#]);

      --  Wait for the client's masked pong (opcode 0x8A).
      declare
         Buf  : Stream_Element_Array (1 .. 64);
         Last : Stream_Element_Offset;
      begin
         Receive_Socket (Peer, Buf, Last);
         Result.Set_Pong
           (Last >= Buf'First and then (Buf (Buf'First) and 16#0F#) = 16#0A#);
      exception
         when others =>
            Result.Set_Pong (False);
      end;

      --  Close, then hang up.
      Send_Bytes (Peer, [16#88#, 16#00#]);
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Result.Set_Pong (False);
   end Server;

   procedure Test_Loopback (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Addr   : Sock_Addr_Type;
      Srv    : Server;
      C      : Ws.Client;
      Buf    : String (1 .. 256);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Addr := Get_Socket_Name (Listen);
      Port := Addr.Port;

      Srv.Serve (Listen);

      Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/v1",
         Ok);
      Assert (Ok, "handshake completes over loopback");

      Ws.Receive (C, Buf, Last, Ok);
      Assert (Ok and then Buf (1 .. Last) = "hello", "first message is hello");

      Ws.Receive (C, Buf, Last, Ok);
      Assert
        (Ok and then Buf (1 .. Last) = "foobar",
         "fragmented message reassembles to foobar");

      --  After the ping (auto-ponged) the server closes: next receive is
      --  reconnect-worthy.
      Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "peer close reports Ok = False");

      Ws.Close (C);
      Assert (Result.Pong_Seen, "client auto-ponged the server's ping");
   end Test_Loopback;

   ------------------------------------------------------------------
   --  Receive_For: the patience-bounded receive
   ------------------------------------------------------------------

   --  Serve the upgrade, hold the line silent for Hold, then (when
   --  Speak) send one "late" text frame, and hang up with a close
   --  frame either way.
   task type Quiet_Server is
      entry Serve (Listener : Socket_Type; Hold : Duration; Speak : Boolean);
   end Quiet_Server;

   task body Quiet_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
      Quiet  : Duration;
      Chatty : Boolean;
   begin
      accept Serve
        (Listener : Socket_Type; Hold : Duration; Speak : Boolean)
      do
         Listen := Listener;
         Quiet := Hold;
         Chatty := Speak;
      end Serve;
      Accept_Socket (Listen, Peer, From);

      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;
         end loop;
      end;

      Send_Bytes
        (Peer,
         [Character'Pos ('H'),
          Character'Pos ('T'),
          Character'Pos ('T'),
          Character'Pos ('P'),
          Character'Pos ('/'),
          Character'Pos ('1'),
          Character'Pos ('.'),
          Character'Pos ('1'),
          Character'Pos (' '),
          Character'Pos ('1'),
          Character'Pos ('0'),
          Character'Pos ('1'),
          13,
          10,
          13,
          10]);

      delay Quiet;

      if Chatty then
         Send_Bytes
           (Peer,
            [16#81#,
             16#04#,
             Character'Pos ('l'),
             Character'Pos ('a'),
             Character'Pos ('t'),
             Character'Pos ('e')]);
      end if;

      Send_Bytes (Peer, [16#88#, 16#00#]);
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         null;  --  the client hanging up early is fine
   end Quiet_Server;

   function Serve_Quiet
     (Srv : access Quiet_Server; Hold : Duration; Speak : Boolean)
      return Port_Type
   is
      Listen : Socket_Type;
      Addr   : Sock_Addr_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Addr := Get_Socket_Name (Listen);
      Srv.Serve (Listen, Hold, Speak);
      return Addr.Port;
   end Serve_Quiet;

   function Loop_Url (Port : Port_Type) return String
   is ("ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/v1");

   --  A quiet quarter second is a HEALTHY timeout; the frame that
   --  arrives later is delivered by a patient call on the same
   --  connection; the peer's close is dead, never a timeout.
   procedure Test_Receive_For_Quiet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Srv   : aliased Quiet_Server;
      C     : Ws.Client;
      Buf   : String (1 .. 256);
      Last  : Natural;
      Ok    : Boolean;
      Timed : Boolean;
   begin
      Ws.Connect (C, Loop_Url (Serve_Quiet (Srv'Access, 1.5, True)), Ok);
      Assert (Ok, "handshake completes over loopback");

      Ws.Receive_For (C, Buf, Last, 0.25, Ok, Timed);
      Assert
        (Ok and then Timed and then Last = 0,
         "a quiet quarter-second is a healthy timeout, not a death");

      Ws.Receive_For (C, Buf, Last, 5.0, Ok, Timed);
      Assert
        (Ok and then not Timed and then Buf (1 .. Last) = "late",
         "the late frame is delivered inside a patient wait");

      Ws.Receive_For (C, Buf, Last, 5.0, Ok, Timed);
      Assert
        (not Ok and then not Timed, "peer close is dead, never a timeout");
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
      Srv      : aliased Quiet_Server;
      C        : Idle_Ws.Client;
      Buf      : String (1 .. 256);
      Last     : Natural;
      Ok       : Boolean;
      Timed    : Boolean;
      Timeouts : Natural := 0;
      Calls    : Natural := 0;
   begin
      Idle_Ws.Connect (C, Loop_Url (Serve_Quiet (Srv'Access, 2.5, False)), Ok);
      Assert (Ok, "handshake completes over loopback");

      for K in 1 .. 10 loop
         Idle_Ws.Receive_For (C, Buf, Last, 0.25, Ok, Timed);
         Calls := K;
         exit when not Ok;
         Timeouts := Timeouts + (if Timed then 1 else 0);
      end loop;

      Assert (not Ok, "total silence past the idle limit is still dead");
      Assert
        (Timeouts >= 2,
         "with healthy timeouts before it; saw" & Timeouts'Image);
      Assert
        (Calls <= 8,
         "the idle clock persisted across the calls; died on call"
         & Calls'Image);
      Idle_Ws.Close (C);
   end Test_Receive_For_Idle_Persists;

   --  Serve the upgrade, then fire Burst_Count tiny text frames back to
   --  back (payload = the frame's index) with no delay, so they land in the
   --  client in one oversized read.
   task type Burst_Server is
      entry Serve (Listener : Socket_Type);
   end Burst_Server;

   task body Burst_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);

      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;
         end loop;
      end;

      --  The 101 head AND every frame in ONE write, so head, burst and
      --  close land in the client's kernel buffer together and its
      --  handshake read finds the whole burst GLUED to the head -- the
      --  shape a fast localhost server (the Terminal) produces, and the
      --  hostile case for both the handshake (surplus past the
      --  accumulator) and the read pump (one oversized recv).  Unmasked
      --  single-byte text frames [FIN|text, len 1, index].
      declare
         Head : constant Stream_Element_Array :=
           [Character'Pos ('H'),
            Character'Pos ('T'),
            Character'Pos ('T'),
            Character'Pos ('P'),
            Character'Pos ('/'),
            Character'Pos ('1'),
            Character'Pos ('.'),
            Character'Pos ('1'),
            Character'Pos (' '),
            Character'Pos ('1'),
            Character'Pos ('0'),
            Character'Pos ('1'),
            13,
            10,
            13,
            10];
         Blob :
           Stream_Element_Array
             (1 .. Head'Length + Stream_Element_Offset (Burst_Count * 3) + 2);
      begin
         Blob (1 .. Head'Length) := Head;
         for I in 0 .. Burst_Count - 1 loop
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 1)) := 16#81#;
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 2)) := 16#01#;
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 3)) :=
              Stream_Element (I);
         end loop;
         Blob (Blob'Last - 1) := 16#88#;  --  close
         Blob (Blob'Last) := 16#00#;
         Send_Bytes (Peer, Blob);
      end;

      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Close_Socket (Peer);
   end Burst_Server;

   procedure Test_Burst (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Srv    : Burst_Server;
      C      : Burst_Ws.Client;
      Buf    : String (1 .. 32);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;

      Srv.Serve (Listen);

      Burst_Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/b",
         Ok);
      Assert (Ok, "burst: handshake completes");

      --  Every one of the Burst_Count frames must arrive, in order, none
      --  dropped by an over-long read.
      for I in 0 .. Burst_Count - 1 loop
         Burst_Ws.Receive (C, Buf, Last, Ok);
         Assert (Ok, "burst: frame" & I'Image & " delivered");
         Assert
           (Last = 1 and then Character'Pos (Buf (1)) = I,
            "burst: frame" & I'Image & " has the right payload, in order");
      end loop;

      Burst_Ws.Close (C);
   end Test_Burst;

   --  Serve the upgrade like Server, but only after a pause LONGER than
   --  the client's Poll_Slice (its socket receive timeout) and well
   --  inside Idle_Limit.  A scheduler hiccup on a loaded CI box puts
   --  every real server here occasionally -- the dial must wait out
   --  Idle_Limit, not give up at the first empty poll slice.
   task type Slow_Server is
      entry Serve (Listener : Socket_Type);
   end Slow_Server;

   task body Slow_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);

      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;
         end loop;
      end;

      --  Three poll slices of silence: past one Receive_Timeout, far
      --  under Idle_Limit (2.0).
      delay 0.75;

      Send_Bytes
        (Peer,
         [Character'Pos ('H'),
          Character'Pos ('T'),
          Character'Pos ('T'),
          Character'Pos ('P'),
          Character'Pos ('/'),
          Character'Pos ('1'),
          Character'Pos ('.'),
          Character'Pos ('1'),
          Character'Pos (' '),
          Character'Pos ('1'),
          Character'Pos ('0'),
          Character'Pos ('1'),
          13,
          10,
          13,
          10]);
      --  One text frame so the exchange proves the stream survived.
      Send_Bytes (Peer, [16#81#, 16#01#, Character'Pos ('s')]);
      Send_Bytes (Peer, [16#88#, 16#00#]);  --  close
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Close_Socket (Peer);
   end Slow_Server;

   procedure Test_Slow_Handshake (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Srv    : Slow_Server;
      C      : Ws.Client;
      Buf    : String (1 .. 32);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;

      Srv.Serve (Listen);

      Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/s",
         Ok);
      Assert (Ok, "slow handshake: the dial waits out Idle_Limit");

      Ws.Receive (C, Buf, Last, Ok);
      Assert
        (Ok and then Last = 1 and then Buf (1) = 's',
         "slow handshake: the frame behind it still arrives");

      Ws.Close (C);
   end Test_Slow_Handshake;

   --  Burst_Server's shape at Flood_Count, so the whole burst lands in
   --  the handshake read's surplus and one Drain sees all of it.
   task type Flood_Server is
      entry Serve (Listener : Socket_Type);
   end Flood_Server;

   task body Flood_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);

      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;
         end loop;
      end;

      declare
         Head : constant Stream_Element_Array :=
           [Character'Pos ('H'),
            Character'Pos ('T'),
            Character'Pos ('T'),
            Character'Pos ('P'),
            Character'Pos ('/'),
            Character'Pos ('1'),
            Character'Pos ('.'),
            Character'Pos ('1'),
            Character'Pos (' '),
            Character'Pos ('1'),
            Character'Pos ('0'),
            Character'Pos ('1'),
            13,
            10,
            13,
            10];
         Blob :
           Stream_Element_Array
             (1 .. Head'Length + Stream_Element_Offset (Flood_Count * 3));
      begin
         Blob (1 .. Head'Length) := Head;
         for I in 0 .. Flood_Count - 1 loop
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 1)) := 16#81#;
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 2)) := 16#01#;
            Blob (Head'Length + Stream_Element_Offset (I * 3 + 3)) :=
              Stream_Element (I);
         end loop;
         Send_Bytes (Peer, Blob);
      end;

      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Close_Socket (Peer);
   end Flood_Server;

   --  Serves the upgrade and then ONE frame: Lead is its first byte
   --  (FIN, RSV and opcode) and Payload its length in 'x's.  Payload
   --  under 126 bytes, so the length rides the second byte directly and
   --  no extended-length field is involved -- the frame's first byte or
   --  the client's bound is what is under test, not the header codec.
   task type One_Frame_Server
     (Lead    : Stream_Element;
      Payload : Natural)
   is
      entry Serve (Listener : Socket_Type);
   end One_Frame_Server;

   task body One_Frame_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);

      declare
         Buf  : Stream_Element_Array (1 .. 1_024);
         Last : Stream_Element_Offset;
         Seen : Natural := 0;
      begin
         loop
            Receive_Socket (Peer, Buf, Last);
            exit when Last < Buf'First;
            Seen := Seen + Natural (Last);
            exit when Seen >= 4;
         end loop;
      end;

      declare
         Head : constant Stream_Element_Array :=
           [Character'Pos ('H'),
            Character'Pos ('T'),
            Character'Pos ('T'),
            Character'Pos ('P'),
            Character'Pos ('/'),
            Character'Pos ('1'),
            Character'Pos ('.'),
            Character'Pos ('1'),
            Character'Pos (' '),
            Character'Pos ('1'),
            Character'Pos ('0'),
            Character'Pos ('1'),
            13,
            10,
            13,
            10];
         Blob :
           Stream_Element_Array
             (1 .. Head'Length + 2 + Stream_Element_Offset (Payload));
      begin
         Blob (1 .. Head'Length) := Head;
         Blob (Head'Length + 1) := Lead;
         Blob (Head'Length + 2) := Stream_Element (Payload);
         for K in 1 .. Stream_Element_Offset (Payload) loop
            Blob (Head'Length + 2 + K) := Character'Pos ('x');
         end loop;
         Send_Bytes (Peer, Blob);
      end;

      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         Close_Socket (Peer);
   end One_Frame_Server;

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
      Listen : Socket_Type;
      Srv    : One_Frame_Server (Lead => 16#81#, Payload => Over_Bytes);
      C      : Over_Ws.Client;
      Buf    : String (1 .. 256);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;

      Srv.Serve (Listen);

      Over_Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/o",
         Ok);
      Assert (Ok, "oversize: handshake completes");

      Over_Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "an oversized frame is reconnect-worthy");

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
      Listen : Socket_Type;
      Srv    : One_Frame_Server (Lead => 16#C1#, Payload => 5);
      C      : Over_Ws.Client;
      Buf    : String (1 .. 256);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;

      Srv.Serve (Listen);

      Over_Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/r",
         Ok);
      Assert (Ok, "rsv1: handshake completes");

      Over_Ws.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "an RSV1 frame on a plain socket is reconnect-worthy");
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
   --  and the feed looks quiet.
   procedure Test_Ring_Overflow_Is_Reported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Srv    : Flood_Server;
      C      : Flood_Ws.Client;
      Buf    : String (1 .. 32);
      Last   : Natural;
      Ok     : Boolean;
      Port   : Port_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;

      Srv.Serve (Listen);

      Flood_Ws.Connect
        (C,
         "ws://127.0.0.1:" & Trim (Port_Type'Image (Port), Both) & "/f",
         Ok);
      Assert (Ok, "flood: handshake completes");

      --  One pop is enough: the whole burst arrived in a single recv and
      --  one Drain decoded all of it, so the refusals have already
      --  happened.
      Flood_Ws.Receive (C, Buf, Last, Ok);
      Assert (Ok, "the frames that DID fit are still delivered");

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
