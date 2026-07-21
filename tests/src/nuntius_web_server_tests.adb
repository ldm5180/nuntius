with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNAT.Sockets;

with AUnit.Assertions; use AUnit.Assertions;

with Nuntius.Web.Server;

--  The serial serve loop over a REAL loopback socket -- the coverage
--  the mechanics never had while they lived in a consumer: 200 through
--  the Handle seam, 400 on garbage, 405 on POST, and the quiet drop of
--  a half-sent head.  Port 0 + On_Listening keeps the test free of
--  fixed-port flakes.

package body Nuntius_Web_Server_Tests is

   use AUnit.Test_Cases.Registration;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Has (Haystack, Needle : String) return Boolean
   is (Ada.Strings.Fixed.Index (Haystack, Needle) > 0);

   protected Cells is
      procedure Set_Port (P : Natural);
      function Port return Natural;
      procedure Request_Stop;
      function Stopped return Boolean;
   private
      Port_V : Natural := 0;
      Stop_V : Boolean := False;
   end Cells;

   protected body Cells is
      procedure Set_Port (P : Natural) is
      begin
         Port_V := P;
      end Set_Port;

      function Port return Natural
      is (Port_V);

      procedure Request_Stop is
      begin
         Stop_V := True;
      end Request_Stop;

      function Stopped return Boolean
      is (Stop_V);
   end Cells;

   function Stop return Boolean
   is (Cells.Stopped);

   procedure Sleep_Ms (Ms : Natural) is
   begin
      delay Duration (Ms) / 1_000.0;
   end Sleep_Ms;

   procedure Log_Quiet (Line : String) is null;

   procedure On_Listening (Port : Natural) is
   begin
      Cells.Set_Port (Port);
   end On_Listening;

   --  The whole routing policy a consumer would bring: echo the target.
   procedure Handle
     (Target  : String;
      Respond :
        not null access procedure
          (S : Nuntius.Web.Status; Content_Type, Payload : String)) is
   begin
      Respond (Nuntius.Web.Ok_200, "text/plain", "hi:" & Target);
   end Handle;

   procedure Serve is new
     Nuntius.Web.Server
       (Stop         => Stop,
        Sleep_Ms     => Sleep_Ms,
        Log_Info     => Log_Quiet,
        Log_Warn     => Log_Quiet,
        On_Listening => On_Listening,
        Handle       => Handle);

   --  One serial exchange: connect, send Request_Text, read to the
   --  server's Connection: close.  Half_Head sends without the blank
   --  line and closes our write side instead.
   function Exchange
     (Port : Natural; Request_Text : String; Half_Head : Boolean := False)
      return String
   is
      use GNAT.Sockets;
      use type Ada.Streams.Stream_Element_Offset;

      Sock  : Socket_Type;
      Addr  : constant Sock_Addr_Type :=
        (Family => Family_Inet,
         Addr   => Inet_Addr ("127.0.0.1"),
         Port   => Port_Type (Port));
      Reply : Unbounded_String;
   begin
      Create_Socket (Sock);
      Connect_Socket (Sock, Addr);
      declare
         Buf  : Ada.Streams.Stream_Element_Array (1 .. Request_Text'Length);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         for K in Request_Text'Range loop
            Buf
              (Ada.Streams.Stream_Element_Offset
                 (K - Request_Text'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Request_Text (K)));
         end loop;
         Send_Socket (Sock, Buf, Last);
      end;
      if Half_Head then
         Shutdown_Socket (Sock, Shut_Write);
      end if;
      loop
         declare
            Chunk : Ada.Streams.Stream_Element_Array (1 .. 1_024);
            Last  : Ada.Streams.Stream_Element_Offset;
         begin
            Receive_Socket (Sock, Chunk, Last);
            exit when Last < Chunk'First;
            for K in 1 .. Last loop
               Append (Reply, Character'Val (Chunk (K)));
            end loop;
         exception
            when Socket_Error =>
               exit;
         end;
      end loop;
      Close_Socket (Sock);
      return To_String (Reply);
   end Exchange;

   procedure Test_Loopback (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      R_Ok, R_Post, R_Bad, R_Half : Unbounded_String;
      Port_Seen                   : Natural := 0;
   begin
      declare
         task Server_Task;

         task body Server_Task is
         begin
            Serve ("127.0.0.1", 0);
         end Server_Task;
      begin
         for K in 1 .. 500 loop
            exit when Cells.Port /= 0;
            delay 0.01;
         end loop;
         Port_Seen := Cells.Port;
         if Port_Seen /= 0 then
            R_Ok :=
              To_Unbounded_String
                (Exchange (Port_Seen, "GET /x HTTP/1.1" & CRLF & CRLF));
            R_Post :=
              To_Unbounded_String
                (Exchange (Port_Seen, "POST /x HTTP/1.1" & CRLF & CRLF));
            R_Bad :=
              To_Unbounded_String
                (Exchange (Port_Seen, "garbage" & CRLF & CRLF));
            R_Half :=
              To_Unbounded_String
                (Exchange (Port_Seen, "GET /x HT", Half_Head => True));
         end if;
         Cells.Request_Stop;
      exception
         when others =>
            Cells.Request_Stop;
            raise;
      end;

      Assert (Port_Seen /= 0, "the server reported its bound port");
      Assert
        (Has (To_String (R_Ok), "HTTP/1.1 200 OK")
         and then Has (To_String (R_Ok), "hi:/x"),
         "a GET reaches Handle and its payload comes back: "
         & To_String (R_Ok));
      Assert
        (Has (To_String (R_Post), "405 Method Not Allowed"),
         "a POST answers 405, not 400: " & To_String (R_Post));
      Assert
        (Has (To_String (R_Bad), "400 Bad Request"),
         "a malformed line answers 400: " & To_String (R_Bad));
      Assert
        (Length (R_Half) = 0,
         "half a head then close drops quietly, no response bytes: "
         & To_String (R_Half));
   end Test_Loopback;

   overriding
   procedure Register_Tests (T : in out Test) is
   begin
      Register_Routine
        (T,
         Test_Loopback'Access,
         "loopback serve: 200 via Handle, 405, 400, quiet half-head drop");
   end Register_Tests;

   overriding
   function Name (T : Test) return AUnit.Message_String
   is (AUnit.Format ("Nuntius.Web.Server (serial loopback serve loop)"));

end Nuntius_Web_Server_Tests;
