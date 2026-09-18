with GNAT.Sockets;

with Nuntius.Rfc6455;

--  The one socket write both serving loops share: send every byte or
--  raise.  Send_Socket returns short whenever the kernel buffer fills,
--  so a whole response is a loop; the caller's Send_Timeout is what
--  bounds a peer that has stopped reading.

package Nuntius.Socket_Io is

   --  Raises GNAT.Sockets.Socket_Error on a dead or stalled peer.
   procedure Send_All (Sock : GNAT.Sockets.Socket_Type; Text : String);

   procedure Send_All
     (Sock : GNAT.Sockets.Socket_Type; Bytes : Nuntius.Rfc6455.Octets);

end Nuntius.Socket_Io;
