with Interfaces;
with Interfaces.C; use Interfaces.C;

with System;

with Nuntius.Fd_Poll;

package body Nuntius.Fd_Wake is

   Efd_Cloexec  : constant int := 16#8_0000#;  --  EFD_CLOEXEC
   Efd_Nonblock : constant int := 16#800#;     --  EFD_NONBLOCK

   function C_Eventfd (Initval : unsigned; Flags : int) return int
   with Import, Convention => C, External_Name => "eventfd";

   function C_Write (Fd : int; Buf : System.Address; N : size_t) return long
   with Import, Convention => C, External_Name => "write";

   function C_Read (Fd : int; Buf : System.Address; N : size_t) return long
   with Import, Convention => C, External_Name => "read";

   function C_Close (Fd : int) return int
   with Import, Convention => C, External_Name => "close";

   function Create return Integer
   is (Integer (C_Eventfd (0, Efd_Cloexec + Efd_Nonblock)));

   procedure Signal (Fd : Integer) is
      One    : aliased Interfaces.Unsigned_64 := 1;
      Unused : long;
   begin
      if Fd >= 0 then
         Unused := C_Write (int (Fd), One'Address, 8);
      end if;
   end Signal;

   --  Readable-guarded reads never block (even on a fd someone else
   --  made blocking), and the loop runs until poll says empty -- one
   --  read for an eventfd, as many as it takes for anything else.
   procedure Drain (Fd : Integer) is
      Sink : aliased Interfaces.Unsigned_64 := 0;
   begin
      if Fd >= 0 then
         while Nuntius.Fd_Poll.Readable (Fd) loop
            exit when C_Read (int (Fd), Sink'Address, 8) <= 0;
         end loop;
      end if;
   end Drain;

   procedure Close (Fd : Integer) is
      Unused : int;
   begin
      if Fd >= 0 then
         Unused := C_Close (int (Fd));
      end if;
   end Close;

end Nuntius.Fd_Wake;
