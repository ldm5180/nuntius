--  The raw-TCP transport port: a byte stream, nothing more.  Where
--  Nuntius.Ws hands whole text MESSAGES (the RFC 6455 adapter does the
--  framing), this port hands whatever bytes the kernel had -- because the
--  protocols it serves carry their own length prefixes and resynchronize
--  on nothing else.  A consumer accumulates and frames; the adapter only
--  reports "here are some bytes" or "this connection is finished".
--
--  Tests plug in a scripted fake; production plugs in the GNAT.Sockets
--  adapter in the Native child.  Keeping the port this narrow is what
--  keeps every consumer test offline.

package Nuntius.Tcp is

   type Transport is limited interface;

   --  Ok False means the endpoint could not be dialed (refused, host
   --  unresolvable, socket unavailable).  Connecting an already-connected
   --  transport is the adapter's problem to make safe (close-then-dial).
   procedure Connect
     (Self : in out Transport; Host : String; Port : Natural; Ok : out Boolean)
   is abstract;

   --  Send every byte of Data.  Ok False means the connection is unusable
   --  and should be re-dialed -- a partial write is a failure, not a
   --  shorter success: the port has no "sent this much" shape because a
   --  half-written control line is not a thing a caller can recover from.
   procedure Send (Self : in out Transport; Data : String; Ok : out Boolean)
   is abstract;

   --  Block for the next slice of inbound bytes, delivered in
   --  Into (Into'First .. Last) with Last >= Into'First on success.  There
   --  is no framing and no minimum: a caller must expect its own protocol
   --  units to arrive split across calls, or several at once.
   --
   --  Ok False means closed, failed, or a stream silent past the adapter's
   --  idle limit -- all reconnect-worthy, and all with Last = 0.
   procedure Receive
     (Self : in out Transport;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean)
   is abstract;

   procedure Close (Self : in out Transport) is abstract;

end Nuntius.Tcp;
