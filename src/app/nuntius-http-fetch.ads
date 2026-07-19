--  The ASYNC HTTP client port: fire-and-poll transfers for a consumer
--  that must never wait on the network -- an event loop Starts a request
--  (never blocking), keeps Pumping, and handles each Completion on a
--  later pass.  The verdict convention matches the sync port: Ok False
--  is a transport-level failure (connect/TLS/timeout/overflow) with
--  Status 0; an HTTP-level reply -- any status -- is Ok True.  Tests plug
--  in a scripted fake; production plugs in Nuntius.Http.Fetch.Curl.

package Nuntius.Http.Fetch is

   type Request_Id is new Natural;
   No_Request : constant Request_Id := 0;

   type Method is (Get, Post, Delete);

   type Request is record
      Verb          : Method := Get;
      URL           : Unbounded_String;
      Content       : Unbounded_String;  --  POST body; ignored otherwise
      Content_Type  : Unbounded_String;  --  empty => no header
      Authorization : Unbounded_String;  --  empty => no header
      Timeout_Ms    : Positive := 30_000;
   end record;

   --  Location is the response's Location header -- empty when absent --
   --  because some APIs return a created resource's id there, not in
   --  the (possibly empty) body.
   type Completion is record
      Id       : Request_Id := No_Request;
      Ok       : Boolean := False;
      Status   : Natural := 0;
      Reply    : Unbounded_String;
      Location : Unbounded_String;
   end record;

   type Client is limited interface;

   --  Start never waits on the network.  Id = No_Request means the
   --  client cannot take another transfer (table full, or the transfer
   --  could not even be created) -- the caller treats it like a
   --  transport failure.
   procedure Start (Self : in out Client; R : Request; Id : out Request_Id)
   is abstract;

   --  Drive in-flight transfers and surface at most one finished
   --  exchange; call until Got = False to drain.  NEVER blocks.
   procedure Pump
     (Self : in out Client; Done : out Completion; Got : out Boolean)
   is abstract;

   --  Drop an in-flight transfer; it will never surface from Pump.
   --  Unknown ids are ignored (the transfer may just have completed).
   procedure Cancel (Self : in out Client; Id : Request_Id) is abstract;

   function In_Flight (Self : Client) return Natural is abstract;

   --  Extra file descriptors a Wait folds into its poll set (inotify
   --  watchers, wake pipes): any of them becoming readable ends the
   --  wait early.
   type Fd_List is array (Positive range <>) of Integer;
   No_Extra_Fds : constant Fd_List (1 .. 0) := [];

   --  The event loop's ONE blocking call: block up to Timeout_Ms for
   --  transfer-socket activity or a readable extra fd.  May return
   --  early -- activity, a wake, or spuriously -- but never later than
   --  the timeout; callers re-derive due-ness from their clock.  Wait
   --  does not drive transfers or read the extra fds: Pump (and the
   --  caller's own drains) do that on the pass it wakes.
   procedure Wait (Self : in out Client; Timeout_Ms : Natural; Extra : Fd_List)
   is abstract;

end Nuntius.Http.Fetch;
