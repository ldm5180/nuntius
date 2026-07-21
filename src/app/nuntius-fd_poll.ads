--  A zero-timeout poll(2) over one file descriptor: True exactly when
--  a read would return at once.  The non-blocking companion to
--  Nuntius.Http.Fetch.Wait's blocking multi-fd poll: an event loop
--  gates each blocking read(2) -- an inotify pump, a serial accept
--  loop -- on this, so the read is only ever issued when the data is
--  already there.

package Nuntius.Fd_Poll is

   function Readable (Fd : Integer) return Boolean;

end Nuntius.Fd_Poll;
