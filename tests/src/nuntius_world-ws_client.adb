with Ada.Unchecked_Deallocation;

with Nuntius.Ws.Native_Client;

package body Nuntius_World.Ws_Client is

   --  The shapes: a ring depth and a frame bound each.
   Default_Depth : constant := 8;
   Default_Bytes : constant := 256;
   Burst_Depth   : constant := 128;
   Burst_Bytes   : constant := 16;
   Flood_Depth   : constant := 4;
   Flood_Bytes   : constant := 256;
   Over_Depth    : constant := 4;
   Over_Bytes    : constant := 32;

   Default_Idle : constant Duration := 2.0;
   Short_Idle   : constant Duration := 1.0;
   Slice        : constant Duration := 0.25;

   package Default_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => Default_Depth,
        Max_Frame_Bytes => Default_Bytes,
        Idle_Limit      => Default_Idle,
        Poll_Slice      => Slice);

   package Burst_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => Burst_Depth,
        Max_Frame_Bytes => Burst_Bytes,
        Idle_Limit      => Default_Idle,
        Poll_Slice      => Slice);

   package Flood_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => Flood_Depth,
        Max_Frame_Bytes => Flood_Bytes,
        Idle_Limit      => Default_Idle,
        Poll_Slice      => Slice);

   package Over_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => Over_Depth,
        Max_Frame_Bytes => Over_Bytes,
        Idle_Limit      => Default_Idle,
        Poll_Slice      => Slice);

   package Idle_Ws is new
     Nuntius.Ws.Native_Client
       (Ring_Depth      => Default_Depth,
        Max_Frame_Bytes => Default_Bytes,
        Idle_Limit      => Short_Idle,
        Poll_Slice      => Slice);

   type Client_Access is access Nuntius.Ws.Transport'Class;

   procedure Free is new
     Ada.Unchecked_Deallocation (Nuntius.Ws.Transport'Class, Client_Access);

   Chosen : Client_Access := new Default_Ws.Client;

   procedure Replace (With_Client : Client_Access) is
   begin
      Drop;
      Chosen := With_Client;
   end Replace;

   procedure Choose_Default is
   begin
      Replace (new Default_Ws.Client);
   end Choose_Default;

   procedure Choose (Depth, Bytes : Natural; Found : out Boolean) is
   begin
      Found := True;
      if Depth = Burst_Depth and then Bytes = Burst_Bytes then
         Replace (new Burst_Ws.Client);
      elsif Depth = Flood_Depth and then Bytes = Flood_Bytes then
         Replace (new Flood_Ws.Client);
      elsif Depth = Over_Depth and then Bytes = Over_Bytes then
         Replace (new Over_Ws.Client);
      elsif Depth = Default_Depth and then Bytes = Default_Bytes then
         Replace (new Default_Ws.Client);
      else
         Found := False;
      end if;
   end Choose;

   procedure Choose_Impatient is
   begin
      Replace (new Idle_Ws.Client);
   end Choose_Impatient;

   function Client return not null access Nuntius.Ws.Transport'Class
   is (Chosen);

   procedure Drop is
   begin
      if Chosen /= null then
         Chosen.Close;
         Free (Chosen);
      end if;
   end Drop;

end Nuntius_World.Ws_Client;
