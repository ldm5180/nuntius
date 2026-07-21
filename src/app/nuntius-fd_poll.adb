with Interfaces.C;

package body Nuntius.Fd_Poll is

   use type Interfaces.C.int;

   --  struct pollfd; the event masks are C shorts, held unsigned for
   --  the bit tests.
   type Poll_Flags is mod 2**16 with Size => 16;

   Pollin : constant Poll_Flags := 16#0001#;

   type Pollfd is record
      Fd      : Interfaces.C.int;
      Events  : Poll_Flags;
      Revents : Poll_Flags;
   end record
   with Convention => C;

   function C_Poll
     (Fds     : access Pollfd;
      N       : Interfaces.C.unsigned_long;
      Timeout : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "poll";

   function Readable (Fd : Integer) return Boolean is
      P : aliased Pollfd :=
        (Fd => Interfaces.C.int (Fd), Events => Pollin, Revents => 0);
   begin
      return C_Poll (P'Access, 1, 0) > 0 and then (P.Revents and Pollin) /= 0;
   end Readable;

end Nuntius.Fd_Poll;
