with AUnit.Assertions; use AUnit.Assertions;

with Ada.Calendar; use Ada.Calendar;

with Interfaces.C; use Interfaces.C;

with System;

with Nuntius.Fd_Poll;
with Nuntius.Fd_Wake;

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

   --  Wait's three arms.  The bounds are deliberately generous: these
   --  assert the SHAPE (returns at once / waits out the timeout), not a
   --  scheduler latency, and CI boxes are slow and shared.

   function Elapsed_Since (T : Time) return Duration
   is (Clock - T);

   procedure Test_Wait_Wakes_On_Signal
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Fd    : constant Integer := Nuntius.Fd_Wake.Create;
      Start : Time;
   begin
      Assert (Fd >= 0, "the eventfd was created");
      Nuntius.Fd_Wake.Signal (Fd);

      Start := Clock;
      Nuntius.Fd_Poll.Wait (Fd, 5_000);
      Assert
        (Elapsed_Since (Start) < 1.0,
         "an already-signalled fd returns long before the timeout");

      Nuntius.Fd_Wake.Close (Fd);
   end Test_Wait_Wakes_On_Signal;

   procedure Test_Wait_Times_Out (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Fd    : constant Integer := Nuntius.Fd_Wake.Create;
      Start : Time;
      Took  : Duration;
   begin
      Assert (Fd >= 0, "the eventfd was created");

      Start := Clock;
      Nuntius.Fd_Poll.Wait (Fd, 100);
      Took := Elapsed_Since (Start);
      Assert (Took >= 0.1, "an unsignalled fd waits out the timeout");
      Assert (Took < 2.0, "and returns once it elapses");

      Nuntius.Fd_Wake.Close (Fd);
   end Test_Wait_Times_Out;

   procedure Test_Wait_Unarmed_Sleeps
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Start : constant Time := Clock;
      Took  : Duration;
   begin
      Nuntius.Fd_Poll.Wait (-1, 100);
      Took := Elapsed_Since (Start);
      Assert (Took >= 0.1, "an unarmed fd degrades to a plain sleep");
      Assert (Took < 2.0, "of the timeout, and no longer");
   end Test_Wait_Unarmed_Sleeps;

   --  One poll over several fds: the stream task waits on its wake
   --  cell and every client at once, and has to be told WHICH woke it.
   procedure Test_Wait_Any_Reports_Ready
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Nuntius.Fd_Poll;

      A     : constant Integer := Nuntius.Fd_Wake.Create;
      B     : constant Integer := Nuntius.Fd_Wake.Create;
      Ready : Ready_Set (1 .. 3);
      Start : Time;
   begin
      Assert (A >= 0 and then B >= 0, "two eventfds");

      Nuntius.Fd_Wake.Signal (B);
      Wait_Any ([A, B, -1], 100, Ready);
      Assert (not Ready (1), "the quiet fd is not ready");
      Assert (Ready (2), "the signalled one is");
      Assert (not Ready (3), "and a negative fd never is");

      Nuntius.Fd_Wake.Drain (B);
      Start := Clock;
      Wait_Any ([A, B, -1], 100, Ready);
      Assert
        (not Ready (1) and then not Ready (2) and then not Ready (3),
         "nothing signalled, nothing ready");
      Assert (Elapsed_Since (Start) >= 0.1, "and the timeout was waited out");

      Nuntius.Fd_Wake.Close (A);
      Nuntius.Fd_Wake.Close (B);
   end Test_Wait_Any_Reports_Ready;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Pipe_Readability'Access,
         "a pipe fd polls readable exactly when data waits");
      Register_Routine
        (T,
         Test_Wait_Wakes_On_Signal'Access,
         "Wait returns early on a signalled fd");
      Register_Routine
        (T, Test_Wait_Times_Out'Access, "Wait waits out an idle fd");
      Register_Routine
        (T,
         Test_Wait_Unarmed_Sleeps'Access,
         "Wait on an unarmed fd is a plain sleep");
      Register_Routine
        (T,
         Test_Wait_Any_Reports_Ready'Access,
         "Wait_Any says which of several fds woke it");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Fd_Poll (the zero-timeout poll(2) shim)"));

end Nuntius_Fd_Poll_Tests;
