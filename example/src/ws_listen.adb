with Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;

with Nuntius.Ws.Aws_Client;

--  Dial a websocket endpoint, optionally send one text frame (a subscribe
--  payload, say), and print the first few inbound text frames.  Shows the
--  adapter's whole surface: the generic instantiation at the consumer's
--  own bounds, close-then-dial, and Ok = False as the one reconnect-worthy
--  signal (closed, errored, oversized frame, or idle past the limit).
--
--  Usage: ws_listen WS_URL [PAYLOAD]
--  e.g.:  ws_listen ws://127.0.0.1:8080/stream '{"subscribe":"all"}'

procedure Ws_Listen is

   Max_Frame : constant := 4_096;

   package Clients is new
     Nuntius.Ws.Aws_Client (Ring_Depth => 64, Max_Frame_Bytes => Max_Frame);

   Frames_To_Show : constant := 5;

begin
   if Ada.Command_Line.Argument_Count < 1 then
      Put_Line ("usage: ws_listen WS_URL [PAYLOAD]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   declare
      C    : Clients.Client;
      Buf  : String (1 .. Max_Frame);
      Last : Natural;
      Ok   : Boolean;
   begin
      Clients.Connect (C, Ada.Command_Line.Argument (1), Ok);
      if not Ok then
         Put_Line ("could not dial " & Ada.Command_Line.Argument (1));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;

      if Ada.Command_Line.Argument_Count >= 2 then
         Clients.Send_Text (C, Ada.Command_Line.Argument (2), Ok);
         if not Ok then
            Put_Line ("send failed; the connection is not usable");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;
      end if;

      for I in 1 .. Frames_To_Show loop
         Clients.Receive (C, Buf, Last, Ok);
         if not Ok then
            --  Reconnect-worthy; a real consumer would redial here.
            Put_Line ("stream ended (closed, errored, or idle)");
            exit;
         end if;
         Put_Line (Buf (1 .. Last));
      end loop;

      Clients.Close (C);
   end;
end Ws_Listen;
