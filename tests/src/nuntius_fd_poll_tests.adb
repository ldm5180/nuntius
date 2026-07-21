with AUnit.Assertions; use AUnit.Assertions;

with Interfaces.C; use Interfaces.C;

with System;

with Nuntius.Fd_Poll;

--  The zero-timeout poll(2) shim, proven against the plainest readable
--  descriptor there is: a pipe polls NOT-readable while empty and
--  readable the moment a byte lands -- so an event loop can gate a
--  blocking read(2) on it and never stall.

package body Nuntius_Fd_Poll_Tests is

   use AUnit.Test_Cases.Registration;

   type Fd_Pair is array (0 .. 1) of int with Convention => C;

   function C_Pipe (Fds : access Fd_Pair) return int
   with Import, Convention => C, External_Name => "pipe";

   function C_Write (Fd : int; Buf : System.Address; N : size_t) return long
   with Import, Convention => C, External_Name => "write";

   function C_Read (Fd : int; Buf : System.Address; N : size_t) return long
   with Import, Convention => C, External_Name => "read";

   function C_Close (Fd : int) return int
   with Import, Convention => C, External_Name => "close";

   procedure Test_Pipe_Readability
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Fds    : aliased Fd_Pair := [others => -1];
      Byte   : aliased Character := 'x';
      Unused : long;
   begin
      Assert (C_Pipe (Fds'Access) = 0, "the pipe was created");

      Assert
        (not Nuntius.Fd_Poll.Readable (Integer (Fds (0))),
         "an empty pipe polls not-readable");

      Unused := C_Write (Fds (1), Byte'Address, 1);
      Assert
        (Nuntius.Fd_Poll.Readable (Integer (Fds (0))),
         "a queued byte polls readable");

      Unused := C_Read (Fds (0), Byte'Address, 1);
      Assert
        (not Nuntius.Fd_Poll.Readable (Integer (Fds (0))),
         "a drained pipe polls not-readable again");

      declare
         Unused_Close : int;
      begin
         Unused_Close := C_Close (Fds (0));
         Unused_Close := C_Close (Fds (1));
      end;
   end Test_Pipe_Readability;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Pipe_Readability'Access,
         "a pipe fd polls readable exactly when data waits");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Fd_Poll (the zero-timeout poll(2) shim)"));

end Nuntius_Fd_Poll_Tests;
