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

   procedure Wait_Any
     (Fds : Fd_Set; Timeout_Ms : Natural; Ready : out Ready_Set)
   is
      --  aliased, and passed by the first element's access: the same
      --  shape Nuntius.Http.Fetch.Curl's wait table uses.
      type Poll_Table is array (Fds'Range) of aliased Pollfd;

      P      : Poll_Table :=
        [for K in Fds'Range =>
           (Fd => Interfaces.C.int (Fds (K)), Events => Pollin, Revents => 0)];
      Unused : Interfaces.C.int;
   begin
      Ready := [others => False];
      if Fds'Length = 0 then
         delay Duration (Timeout_Ms) / 1_000.0;
         return;
      end if;
      Unused :=
        C_Poll
          (P (P'First)'Access,
           Interfaces.C.unsigned_long (Fds'Length),
           Interfaces.C.int (Timeout_Ms));
      for K in Fds'Range loop
         Ready (K) := (P (K).Revents and Pollin) /= 0;
      end loop;
   end Wait_Any;

   procedure Wait (Fd : Integer; Timeout_Ms : Natural) is
      P      : aliased Pollfd :=
        (Fd => Interfaces.C.int (Fd), Events => Pollin, Revents => 0);
      Unused : Interfaces.C.int;
   begin
      if Fd < 0 then
         --  Nothing to poll: honour the timeout as a plain sleep, so a
         --  caller with an unarmed wake cell still paces itself.
         delay Duration (Timeout_Ms) / 1_000.0;
      else
         Unused := C_Poll (P'Access, 1, Interfaces.C.int (Timeout_Ms));
      end if;
   end Wait;

end Nuntius.Fd_Poll;
