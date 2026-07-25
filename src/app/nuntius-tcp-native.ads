private with GNAT.Sockets;

--  The production Nuntius.Tcp adapter over GNAT.Sockets: dial a host and
--  port, write bytes, read bytes, hang up.  No TLS and no framing -- this
--  is the plain stream socket, for protocols that authenticate in-band
--  (Databento's live gateway keeps its key off the wire with a SHA-256
--  challenge) and length-prefix their own records.
--
--  Liveness is the adapter's one policy: a stream that says nothing for
--  Idle_Limit is reported dead, because a silent TCP partition fires no
--  close and a consumer blocked on a socket that will never speak again
--  is indistinguishable from a healthy quiet market.  The socket's
--  receive timeout is the poll slice, so the deadline is re-checked on a
--  cadence rather than waited out in one indivisible read.

package Nuntius.Tcp.Native is

   Default_Idle_Limit : constant Duration := 45.0;

   type Client is limited new Nuntius.Tcp.Transport with private;

   --  How long a silent stream is tolerated before Receive reports the
   --  connection finished.  Takes effect on the next Connect (the socket's
   --  receive timeout is set at dial), so set it before dialing.
   procedure Set_Idle_Limit (Self : in out Client; Seconds : Duration)
   with Pre => Seconds > 0.0;

   overriding
   procedure Connect
     (Self : in out Client; Host : String; Port : Natural; Ok : out Boolean);

   overriding
   procedure Send (Self : in out Client; Data : String; Ok : out Boolean);

   overriding
   procedure Receive
     (Self : in out Client;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean);

   overriding
   procedure Close (Self : in out Client);

private

   --  The longest a single blocking read may wait before the idle deadline
   --  is re-checked.  Capped by the idle limit itself so a short limit
   --  (tests) still fires promptly.
   Max_Poll_Slice : constant Duration := 1.0;

   type Client is limited new Nuntius.Tcp.Transport with record
      Sock       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Has_Socket : Boolean := False;
      Connected  : Boolean := False;
      Idle_Limit : Duration := Default_Idle_Limit;
   end record;

end Nuntius.Tcp.Native;
