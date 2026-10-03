with Nuntius.Ws;

--  The websocket client a scenario dials with, in the shapes the suite
--  instantiates: a ring depth, a frame bound and an idle limit are
--  generic parameters, so each shape is an instance here and a scenario
--  holds one through the port's own interface.  Poll slices are short
--  so a hung read ends in seconds.

package Nuntius_World.Ws_Client is

   --  The default shape: 8 frames of up to 256 bytes, 2 s idle limit.
   procedure Choose_Default;

   --  Whether the world has a client of this ring depth and frame bound
   --  at the default idle limit.
   function Has_Shape (Depth, Bytes : Natural) return Boolean;

   --  That client; Found False when the world has no such instance.
   procedure Choose (Depth, Bytes : Natural; Found : out Boolean);

   --  The default shape with a 1 s idle limit instead.
   procedure Choose_Impatient;

   --  The chosen client, which every step dials and receives through.
   function Client return not null access Nuntius.Ws.Transport'Class;

   --  Close the chosen client and let it go.
   procedure Drop;

end Nuntius_World.Ws_Client;
