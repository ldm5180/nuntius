--  A zero-timeout poll(2) over one file descriptor: True exactly when
--  a read would return at once.  The non-blocking companion to
--  Nuntius.Http.Fetch.Wait's blocking multi-fd poll: an event loop
--  gates each blocking read(2) -- an inotify pump, a serial accept
--  loop -- on this, so the read is only ever issued when the data is
--  already there.

package Nuntius.Fd_Poll is

   function Readable (Fd : Integer) return Boolean;

   --  Block until Fd is readable or Timeout_Ms elapses, whichever is
   --  first.  Does NOT read the fd -- the caller drains.  A negative Fd
   --  (the unarmed wake-cell value) degrades to a plain sleep of
   --  Timeout_Ms, so callers need no guards.  Timeout_Ms = 0 returns at
   --  once (Readable without the answer).
   procedure Wait (Fd : Integer; Timeout_Ms : Natural);

end Nuntius.Fd_Poll;
