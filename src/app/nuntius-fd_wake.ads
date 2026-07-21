--  eventfd(2)-backed wake tokens (Nuntius.Fd_Poll's writing sibling,
--  Linux-only like the syscall it wraps): a producer Signals the fd, a
--  poll(2)-blocked consumer wakes, Drains it, and acts.  Signal is one
--  atomic 8-byte write -- safe from another task, never blocking short
--  of a 2**64-1 counter -- and back-to-back signals coalesce into one
--  readable state.  Drain must leave the fd unreadable: an undrained
--  wake fd turns every poll into an instant return -- a busy spin.
--  Every operation is a no-op on a negative fd (the unarmed value), so
--  callers need no guards.

package Nuntius.Fd_Wake is

   --  A fresh non-blocking, close-on-exec eventfd; -1 if the kernel
   --  refuses (the caller's poll set just goes without).
   function Create return Integer;

   procedure Signal (Fd : Integer);
   procedure Drain (Fd : Integer);
   procedure Close (Fd : Integer);

end Nuntius.Fd_Wake;
