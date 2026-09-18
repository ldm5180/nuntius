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

   type Fd_Set is array (Positive range <>) of Integer;
   type Ready_Set is array (Positive range <>) of Boolean;

   --  One poll(2) over every fd at once, for at most Timeout_Ms: an
   --  event loop waiting on its wake cell AND its clients needs to be
   --  told which of them woke it.  A negative fd is ignored by poll(2)
   --  itself and reads not ready, so a sparse table needs no guards.
   --  Does NOT read anything -- the caller drains.
   procedure Wait_Any
     (Fds : Fd_Set; Timeout_Ms : Natural; Ready : out Ready_Set)
   with Pre => Ready'First = Fds'First and then Ready'Length = Fds'Length;

end Nuntius.Fd_Poll;
