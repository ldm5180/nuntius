package body Nuntius.Frame_Fifo
  with SPARK_Mode
is

   procedure Clear (Self : in out Fifo) is
   begin
      Self.Head := 1;
      Self.Tail := 1;
      Self.Used := 0;
   end Clear;

   procedure Push (Self : in out Fifo; Frame : String; Ok : out Boolean) is
   begin
      if Self.Used = Depth or else Frame'Length > Max_Frame_Bytes then
         Ok := False;
         return;
      end if;
      Self.Slots (Self.Tail).Text (1 .. Frame'Length) := Frame;
      Self.Slots (Self.Tail).Len := Frame'Length;
      Self.Tail := (Self.Tail mod Depth) + 1;
      Self.Used := Self.Used + 1;
      Ok := True;
   end Push;

   procedure Pop
     (Self : in out Fifo;
      Into : in out String;
      Last : out Natural;
      Ok   : out Boolean) is
   begin
      Last := 0;
      Ok := False;

      if Self.Used = 0 then
         return;
      end if;

      declare
         Len : constant Frame_Length := Self.Slots (Self.Head).Len;
      begin
         if Len <= Into'Length then
            Into (1 .. Len) := Self.Slots (Self.Head).Text (1 .. Len);
            Last := Len;
            Ok := True;
         end if;
      end;

      --  Consumed either way; see Pop's contract.
      Self.Head := (Self.Head mod Depth) + 1;
      Self.Used := Self.Used - 1;
   end Pop;

end Nuntius.Frame_Fifo;
