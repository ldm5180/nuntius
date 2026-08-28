with GNAT.Sockets;

--  A one-shot loopback HTTP peer for adapter tests: it accepts a single
--  connection, keeps the request head it was sent, answers a minimal
--  200 and hangs up.  What the adapter put on the wire -- the headers
--  no port-level fake can see -- is then readable through Head.

package Loopback_Capture is

   procedure Listen_Loopback
     (Listen : out GNAT.Sockets.Socket_Type; Port : out Natural);

   task type Server is
      entry Serve (Listener : GNAT.Sockets.Socket_Type);
   end Server;

   --  The head of the one request served, complete once the Server
   --  task has ended (the enclosing block joins it).
   function Head return String;

   function Loopback_URL (Port : Natural; Path : String) return String;

end Loopback_Capture;
