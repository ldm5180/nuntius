with AUnit.Assertions; use AUnit.Assertions;

with Ada.Streams;  use Ada.Streams;
with GNAT.Sockets; use GNAT.Sockets;

with Nuntius.Tcp;
with Nuntius.Tcp.Native;

--  The raw-TCP port and its GNAT.Sockets adapter.  Offline behavior first
--  (unconnected, refused dial), then loopback exchanges against tiny
--  in-process servers: a byte echo, a peer that hangs up, and a peer that
--  goes silent past the adapter's idle limit.  No network, no framing --
--  the port hands raw bytes and says only "usable" or "reconnect".

package body Nuntius_Tcp_Native_Tests is

   use AUnit.Test_Cases.Registration;

   --  Fail fast rather than block the suite: a hung read ends in about a
   --  second, since the poll slice tracks the idle limit.
   Test_Idle : constant Duration := 1.0;

   ------------------------------------------------------------------
   --  A listening socket on an ephemeral loopback port
   ------------------------------------------------------------------

   procedure Listen_Loopback (Listen : out Socket_Type; Port : out Port_Type)
   is
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Port := Get_Socket_Name (Listen).Port;
   end Listen_Loopback;

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

   function Octets (S : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. S'Length);
   begin
      for I in S'Range loop
         Result (Stream_Element_Offset (I - S'First + 1)) :=
           Stream_Element (Character'Pos (S (I)));
      end loop;
      return Result;
   end Octets;

   ------------------------------------------------------------------
   --  Offline cases
   ------------------------------------------------------------------

   procedure Test_Unconnected (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C    : Nuntius.Tcp.Native.Client;
      Buf  : String (1 .. 64);
      Last : Natural;
      Ok   : Boolean;
   begin
      Nuntius.Tcp.Native.Send (C, "hello", Ok);
      Assert (not Ok, "send before any dial reports Ok = False");
      Nuntius.Tcp.Native.Receive (C, Buf, Last, Ok);
      Assert (not Ok, "receive before any dial reports Ok = False");
      Assert (Last = 0, "receive before any dial delivers nothing");
      Nuntius.Tcp.Native.Close (C);  --  harmless no-op
   end Test_Unconnected;

   procedure Test_Refused_Dial (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C  : Nuntius.Tcp.Native.Client;
      Ok : Boolean;
   begin
      --  Port 9 (discard) is closed on a loopback with no inetd.
      Nuntius.Tcp.Native.Connect (C, "127.0.0.1", 9, Ok);
      Assert (not Ok, "a refused dial reports Ok = False");
      Nuntius.Tcp.Native.Connect (C, "127.0.0.1", 9, Ok);
      Assert (not Ok, "a refused redial reports Ok = False, reusable");
      Nuntius.Tcp.Native.Close (C);
   end Test_Refused_Dial;

   procedure Test_Unresolvable (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      C  : Nuntius.Tcp.Native.Client;
      Ok : Boolean;
   begin
      Nuntius.Tcp.Native.Connect
        (C, "no-such-host.invalid.nuntius.test", 13_000, Ok);
      Assert (not Ok, "an unresolvable host reports Ok = False");
   end Test_Unresolvable;

   ------------------------------------------------------------------
   --  Echo server: read a slice, write it straight back, hang up
   ------------------------------------------------------------------

   task type Echo_Server is
      entry Serve (Listener : Socket_Type);
   end Echo_Server;

   task body Echo_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
      Buf    : Stream_Element_Array (1 .. 256);
      Last   : Stream_Element_Offset;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;

      Accept_Socket (Listen, Peer, From);
      Receive_Socket (Peer, Buf, Last);
      if Last >= Buf'First then
         Send_Bytes (Peer, Buf (Buf'First .. Last));
      end if;
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         null;  --  the assertions in the client task carry the verdict
   end Echo_Server;

   procedure Test_Loopback_Echo (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Port   : Port_Type;
      C      : Nuntius.Tcp.Native.Client;
      Buf    : String (1 .. 256);
      Last   : Natural;
      Ok     : Boolean;
   begin
      Listen_Loopback (Listen, Port);
      declare
         Srv : Echo_Server;
      begin
         Srv.Serve (Listen);

         Nuntius.Tcp.Native.Set_Idle_Limit (C, Test_Idle);
         Nuntius.Tcp.Native.Connect (C, "127.0.0.1", Natural (Port), Ok);
         Assert (Ok, "dial to the loopback listener succeeds");

         Nuntius.Tcp.Native.Send (C, "ping-me", Ok);
         Assert (Ok, "send over an open socket reports Ok = True");

         Nuntius.Tcp.Native.Receive (C, Buf, Last, Ok);
         Assert (Ok, "the echoed bytes come back Ok");
         Assert (Buf (1 .. Last) = "ping-me", "raw bytes round-trip verbatim");

         --  The server hung up right after echoing.
         Nuntius.Tcp.Native.Receive (C, Buf, Last, Ok);
         Assert (not Ok, "a closed peer reports Ok = False");

         Nuntius.Tcp.Native.Close (C);
      end;
   end Test_Loopback_Echo;

   ------------------------------------------------------------------
   --  Chunking: a long payload arrives over however many reads it takes
   ------------------------------------------------------------------

   Burst : constant String (1 .. 900) := [others => 'x'];

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
      Send_Bytes (Peer, Octets (Burst));
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         null;
   end Burst_Server;

   procedure Test_Partial_Reads (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Port   : Port_Type;
      C      : Nuntius.Tcp.Native.Client;
      Buf    : String (1 .. 128);
      Last   : Natural;
      Ok     : Boolean;
      Seen   : Natural := 0;
   begin
      Listen_Loopback (Listen, Port);
      declare
         Srv : Burst_Server;
      begin
         Srv.Serve (Listen);

         Nuntius.Tcp.Native.Set_Idle_Limit (C, Test_Idle);
         Nuntius.Tcp.Native.Connect (C, "127.0.0.1", Natural (Port), Ok);
         Assert (Ok, "dial to the burst listener succeeds");

         --  No framing: every Receive delivers whatever is available, at
         --  most Into'Length bytes, and the caller reassembles.
         loop
            Nuntius.Tcp.Native.Receive (C, Buf, Last, Ok);
            exit when not Ok;
            Assert (Last in 1 .. Buf'Length, "a successful read is non-empty");
            for I in 1 .. Last loop
               Assert (Buf (I) = 'x', "no byte is invented or dropped");
            end loop;
            Seen := Seen + Last;
         end loop;

         Assert
           (Seen = Burst'Length,
            "every byte of the burst arrives across the partial reads");
         Nuntius.Tcp.Native.Close (C);
      end;
   end Test_Partial_Reads;

   ------------------------------------------------------------------
   --  Silent server: accepted, then nothing -- the idle limit fires
   ------------------------------------------------------------------

   task type Silent_Server is
      entry Serve (Listener : Socket_Type);
      entry Done;
   end Silent_Server;

   task body Silent_Server is
      Listen : Socket_Type;
      Peer   : Socket_Type;
      From   : Sock_Addr_Type;
   begin
      accept Serve (Listener : Socket_Type) do
         Listen := Listener;
      end Serve;
      Accept_Socket (Listen, Peer, From);
      --  Hold the connection open, saying nothing, until released.
      accept Done;
      Close_Socket (Peer);
      Close_Socket (Listen);
   exception
      when others =>
         null;
   end Silent_Server;

   procedure Test_Idle_Limit (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Listen : Socket_Type;
      Port   : Port_Type;
      C      : Nuntius.Tcp.Native.Client;
      Buf    : String (1 .. 64);
      Last   : Natural;
      Ok     : Boolean;
   begin
      Listen_Loopback (Listen, Port);
      declare
         Srv : Silent_Server;
      begin
         Srv.Serve (Listen);

         Nuntius.Tcp.Native.Set_Idle_Limit (C, Test_Idle);
         Nuntius.Tcp.Native.Connect (C, "127.0.0.1", Natural (Port), Ok);
         Assert (Ok, "dial to the silent listener succeeds");

         Nuntius.Tcp.Native.Receive (C, Buf, Last, Ok);
         Assert (not Ok, "a stream silent past the idle limit is not Ok");
         Assert (Last = 0, "an idle timeout delivers no bytes");

         Nuntius.Tcp.Native.Close (C);
         Srv.Done;
      end;
   end Test_Idle_Limit;

   ------------------------------------------------------------------

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine (T, Test_Unconnected'Access, "tcp: unconnected");
      Register_Routine (T, Test_Refused_Dial'Access, "tcp: refused dial");
      Register_Routine (T, Test_Unresolvable'Access, "tcp: unresolvable host");
      Register_Routine (T, Test_Loopback_Echo'Access, "tcp: loopback echo");
      Register_Routine (T, Test_Partial_Reads'Access, "tcp: partial reads");
      Register_Routine (T, Test_Idle_Limit'Access, "tcp: idle limit");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Nuntius.Tcp.Native");
   end Name;

end Nuntius_Tcp_Native_Tests;
