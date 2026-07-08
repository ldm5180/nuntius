with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Nuntius.Rfc6455; use Nuntius.Rfc6455;

package body Nuntius.Ws.Native_Client is

   Recv_Chunk : constant := 2_048;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.Sockets.Error_Type;

   --------------
   -- Evaluate --
   --------------

   function Evaluate
     (G : Guard_Kind; Ctx : Context; Evt : Event) return Boolean
   is
      pragma Unreferenced (G, Ctx, Evt);
   begin
      return True;  --  Always: every reaction is unconditional
   end Evaluate;

   -------------
   -- Execute --
   -------------

   procedure Execute (A : Action_Kind; Ctx : in out Context; Evt : Event) is
      pragma Unreferenced (Evt);
      Ok : Boolean;
   begin
      case A is
         when A_Nothing =>
            null;

         when A_Deliver =>
            Frames.Push (Ctx.Inbound, Ctx.In_Frame (1 .. Ctx.In_Len), Ok);

         when A_Begin   =>
            Ctx.Assembly (1 .. Ctx.In_Len) := Ctx.In_Frame (1 .. Ctx.In_Len);
            Ctx.Asm_Len := Ctx.In_Len;

         when A_Extend  =>
            Ctx.Assembly (Ctx.Asm_Len + 1 .. Ctx.Asm_Len + Ctx.In_Len) :=
              Ctx.In_Frame (1 .. Ctx.In_Len);
            Ctx.Asm_Len := Ctx.Asm_Len + Ctx.In_Len;

         when A_Finish  =>
            Ctx.Assembly (Ctx.Asm_Len + 1 .. Ctx.Asm_Len + Ctx.In_Len) :=
              Ctx.In_Frame (1 .. Ctx.In_Len);
            Ctx.Asm_Len := Ctx.Asm_Len + Ctx.In_Len;
            Frames.Push (Ctx.Inbound, Ctx.Assembly (1 .. Ctx.Asm_Len), Ok);
            Ctx.Asm_Len := 0;

         when A_Pong    =>
            Ctx.Pong (1 .. Ctx.In_Len) := Ctx.In_Frame (1 .. Ctx.In_Len);
            Ctx.Pong_Len := Ctx.In_Len;
            Ctx.Pending := Send_Pong;

         when A_Die     =>
            Ctx.Dead := True;
      end case;
   end Execute;

   ----------
   -- Post --
   ----------

   --  Step the read machine; an event with no row is a protocol violation
   --  (e.g. a continuation while Open) and is reconnect-worthy.
   procedure Post (Self : in out Client; Kind : Read_Event) is
      M       : SM.Machine := SM.Make (Table, Initial => Self.State);
      Handled : Boolean;
   begin
      SM.Process_Event (M, Self.Ctx, (Kind => Kind), Handled);
      Self.State := SM.State_Of (M);
      if not Handled then
         Self.Ctx.Dead := True;
      end if;
   end Post;

   --------------
   -- Teardown --
   --------------

   procedure Teardown (Self : in out Client) is
   begin
      if Self.Has_Socket then
         begin
            GNAT.Sockets.Shutdown_Socket (Self.Sock);
         exception
            when others =>
               null;  --  peer already gone; nothing to say goodbye to
         end;
         begin
            GNAT.Sockets.Close_Socket (Self.Sock);
         exception
            when others =>
               null;
         end;
         Self.Has_Socket := False;
      end if;
   end Teardown;

   -----------
   -- Reset --
   -----------

   procedure Reset (Ctx : in out Context) is
   begin
      Frames.Clear (Ctx.Inbound);
      Ctx.In_Len := 0;
      Ctx.Asm_Len := 0;
      Ctx.Dead := False;
      Ctx.Pending := None;
      Ctx.Pong_Len := 0;
   end Reset;

   ---------------
   -- Next_Mask --
   ---------------

   procedure Next_Mask (Self : in out Client; M : out Mask_Key) is
      use Interfaces;
   begin
      --  A cheap LCG: the mask only needs to be present and varied (a
      --  localhost link has no caching proxy to defeat), so no crypto RNG.
      Self.Mask_Seed := Self.Mask_Seed * 1_664_525 + 1_013_904_223;
      M :=
        [Octet (Shift_Right (Self.Mask_Seed, 24) and 16#FF#),
         Octet (Shift_Right (Self.Mask_Seed, 16) and 16#FF#),
         Octet (Shift_Right (Self.Mask_Seed, 8) and 16#FF#),
         Octet (Self.Mask_Seed and 16#FF#)];
   end Next_Mask;

   --------------
   -- Send_Raw --
   --------------

   procedure Send_Raw (Self : in out Client; Bytes : Octets) is
      Data : Ada.Streams.Stream_Element_Array (1 .. Bytes'Length);
      Off  : Ada.Streams.Stream_Element_Offset := 1;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Bytes'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Bytes'First + 1)) :=
           Ada.Streams.Stream_Element (Bytes (I));
      end loop;
      while Off <= Data'Last loop
         GNAT.Sockets.Send_Socket (Self.Sock, Data (Off .. Data'Last), Last);
         exit when Last < Off;  --  nothing sent / closed
         Off := Last + 1;
      end loop;
   end Send_Raw;

   ---------------
   -- Send_Pong --
   ---------------

   procedure Send_Pong (Self : in out Client) is
      M       : Mask_Key;
      Wire    : Octets (1 .. 125 + 6);
      Last    : Natural;
      Payload : Octets (1 .. Self.Ctx.Pong_Len);
   begin
      for I in Payload'Range loop
         Payload (I) := Octet (Character'Pos (Self.Ctx.Pong (I)));
      end loop;
      Next_Mask (Self, M);
      Encode_Control (Op_Pong, Payload, M, Wire, Last);
      Send_Raw (Self, Wire (1 .. Last));
   end Send_Pong;

   ------------------
   -- Handle_Frame --
   ------------------

   --  A whole, in-range frame is present at the front of Accum: lift its
   --  payload into the staging buffer, classify it into an event, step the
   --  machine, and honour any pong the machine asked for.
   procedure Handle_Frame (Self : in out Client; H : Header) is
   begin
      Get_Text
        (Self.Accum (1 .. Self.Accum_Len),
         H,
         Self.Ctx.In_Frame,
         Self.Ctx.In_Len);

      case H.Op is
         when Op_Text         =>
            Post (Self, (if H.Fin then E_Text else E_Start));

         when Op_Continuation =>
            if Self.Ctx.Asm_Len > Max_Frame_Bytes - Self.Ctx.In_Len then
               Post (Self, E_Oversized);
            else
               Post (Self, (if H.Fin then E_End else E_Cont));
            end if;

         when Op_Ping         =>
            Post (Self, (if H.Payload_Bytes > 125 then E_Fault else E_Ping));

         when Op_Pong         =>
            Post (Self, E_Pong);

         when Op_Close        =>
            Post (Self, E_Close);

         when Op_Binary       =>
            Post (Self, E_Fault);  --  a text feed never sends binary
      end case;

      if Self.Ctx.Pending = Send_Pong then
         Send_Pong (Self);
         Self.Ctx.Pending := None;
      end if;
   end Handle_Frame;

   -------------
   -- Consume --
   -------------

   procedure Consume (Self : in out Client; Count : Natural) is
   begin
      Self.Accum (1 .. Self.Accum_Len - Count) :=
        Self.Accum (Count + 1 .. Self.Accum_Len);
      Self.Accum_Len := Self.Accum_Len - Count;
   end Consume;

   -----------
   -- Drain --
   -----------

   --  Decode and dispatch every complete frame already buffered.
   procedure Drain (Self : in out Client) is
   begin
      while not Self.Ctx.Dead loop
         declare
            H : constant Header := Decode (Self.Accum (1 .. Self.Accum_Len));
         begin
            case H.Status is
               when Need_More =>
                  exit;

               when Invalid   =>
                  Post (Self, E_Fault);
                  exit;

               when Ready     =>
                  if H.Payload_Bytes > Max_Frame_Bytes then
                     Post (Self, E_Oversized);
                     exit;
                  elsif Self.Accum_Len < H.Header_Bytes + H.Payload_Bytes then
                     exit;  --  header in, payload still arriving
                  else
                     Handle_Frame (Self, H);
                     Consume (Self, H.Header_Bytes + H.Payload_Bytes);
                  end if;
            end case;
         end;
      end loop;
   end Drain;

   ---------------
   -- Read_Some --
   ---------------

   --  Pull one slice of bytes into Accum.  A timeout is "nothing yet"; a
   --  peer close, a socket error, or a full accumulator is fatal.
   procedure Read_Some
     (Self : in out Client; Got : out Boolean; Fatal : out Boolean)
   is
      Buf  : Ada.Streams.Stream_Element_Array (1 .. Recv_Chunk);
      Last : Ada.Streams.Stream_Element_Offset;
      Room : constant Natural := Self.Accum'Length - Self.Accum_Len;
   begin
      Got := False;
      Fatal := False;
      if Room = 0 then
         Fatal := True;  --  a frame larger than the accumulator; reconnect
         return;
      end if;

      begin
         GNAT.Sockets.Receive_Socket (Self.Sock, Buf, Last);
      exception
         when E : GNAT.Sockets.Socket_Error =>
            if GNAT.Sockets.Resolve_Exception (E)
              = GNAT.Sockets.Resource_Temporarily_Unavailable
            then
               return;  --  receive timeout: no data this slice

            end if;
            Fatal := True;
            return;
         when others =>
            Fatal := True;
            return;
      end;

      if Last < Buf'First then
         Fatal := True;  --  peer closed the connection
         return;
      end if;

      declare
         N       : constant Natural := Natural (Last);
         To_Copy : constant Natural := Natural'Min (N, Room);
      begin
         for I in 1 .. To_Copy loop
            Self.Accum (Self.Accum_Len + I) :=
              Octet (Buf (Ada.Streams.Stream_Element_Offset (I)));
         end loop;
         Self.Accum_Len := Self.Accum_Len + To_Copy;
         Got := To_Copy > 0;
      end;
   end Read_Some;

   -------------
   -- Receive --
   -------------

   overriding
   procedure Receive
     (Self : in out Client;
      Into : out String;
      Last : out Natural;
      Ok   : out Boolean)
   is
      Idle  : Duration := 0.0;
      Got   : Boolean;
      Fatal : Boolean;
   begin
      Last := 0;
      Ok := False;
      if not Self.Connected then
         return;
      end if;

      loop
         if Frames.Count (Self.Ctx.Inbound) > 0 then
            Frames.Pop (Self.Ctx.Inbound, Into, Last, Ok);
            return;
         end if;

         if Self.Ctx.Dead then
            return;
         end if;

         Drain (Self);
         if Frames.Count (Self.Ctx.Inbound) > 0 or else Self.Ctx.Dead then
            null;  --  loop head delivers or reports

         else
            Read_Some (Self, Got, Fatal);
            if Fatal then
               Self.Ctx.Dead := True;
               return;
            end if;
            if Got then
               Idle := 0.0;
            else
               Idle := Idle + Poll_Slice;
               if Idle >= Idle_Limit then
                  Post (Self, E_Idle);
                  return;
               end if;
            end if;
         end if;
      end loop;
   end Receive;

   ---------------
   -- Parse_Url --
   ---------------

   procedure Parse_Url
     (URL  : String;
      Host : out Unbounded_String;
      Path : out Unbounded_String;
      Port : out GNAT.Sockets.Port_Type;
      Ok   : out Boolean)
   is
      Prefix : constant String := "ws://";
   begin
      Host := Null_Unbounded_String;
      Path := To_Unbounded_String ("/");
      Port := 80;
      Ok := False;

      if URL'Length <= Prefix'Length
        or else URL (URL'First .. URL'First + Prefix'Length - 1) /= Prefix
      then
         return;
      end if;

      declare
         Rest  : constant String :=
           URL (URL'First + Prefix'Length .. URL'Last);
         Slash : Natural := 0;
         Colon : Natural := 0;
      begin
         for I in Rest'Range loop
            if Rest (I) = '/' then
               Slash := I;
               exit;
            end if;
         end loop;

         declare
            Authority : constant String :=
              (if Slash = 0 then Rest else Rest (Rest'First .. Slash - 1));
         begin
            if Slash /= 0 then
               Path := To_Unbounded_String (Rest (Slash .. Rest'Last));
            end if;
            for I in Authority'Range loop
               if Authority (I) = ':' then
                  Colon := I;
                  exit;
               end if;
            end loop;
            if Colon = 0 then
               Host := To_Unbounded_String (Authority);
            else
               Host :=
                 To_Unbounded_String
                   (Authority (Authority'First .. Colon - 1));
               Port :=
                 GNAT.Sockets.Port_Type'Value
                   (Authority (Colon + 1 .. Authority'Last));
            end if;
         end;
      end;

      if Length (Host) not in 1 .. 255 then
         return;
      end if;
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Parse_Url;

   -------------
   -- Resolve --
   -------------

   procedure Resolve
     (Host : String; Addr : out GNAT.Sockets.Inet_Addr_Type; Ok : out Boolean)
   is
   begin
      Ok := True;
      Addr := GNAT.Sockets.Inet_Addr (Host);  --  numeric dotted-quad
   exception
      when others =>
         begin
            Addr :=
              GNAT.Sockets.Addresses (GNAT.Sockets.Get_Host_By_Name (Host), 1);
            Ok := True;
         exception
            when others =>
               Ok := False;
         end;
   end Resolve;

   ------------------
   -- Do_Handshake --
   ------------------

   procedure Do_Handshake
     (Self : in out Client;
      Host : String;
      Port : GNAT.Sockets.Port_Type;
      Path : String;
      Ok   : out Boolean)
   is
      Nonce    : Octets (1 .. 16);
      Mask     : Mask_Key;
      Port_S   : constant String :=
        Ada.Strings.Fixed.Trim
          (GNAT.Sockets.Port_Type'Image (Port), Ada.Strings.Left);
      Buf      : String (1 .. 8_192) := [others => ASCII.NUL];
      Len      : Natural := 0;
      Boundary : Natural := 0;
   begin
      Ok := False;

      --  A 16-byte key nonce from the same LCG (only base64 shape matters).
      for K in 1 .. 4 loop
         Next_Mask (Self, Mask);
         for J in 0 .. 3 loop
            Nonce (K * 4 - 3 + J) := Mask (J);
         end loop;
      end loop;

      declare
         Req       : constant String :=
           Client_Handshake (Host & ":" & Port_S, Path, Base64 (Nonce));
         Req_Bytes : Octets (1 .. Req'Length);
      begin
         for I in Req'Range loop
            Req_Bytes (I - Req'First + 1) := Octet (Character'Pos (Req (I)));
         end loop;
         Send_Raw (Self, Req_Bytes);
      end;

      --  Read the response head up to the blank line; keep any frame bytes
      --  that arrive glued to it.
      loop
         for I in 4 .. Len loop
            if Buf (I - 3 .. I) = CRLF & CRLF then
               Boundary := I;
               exit;
            end if;
         end loop;
         exit when Boundary > 0 or else Len = Buf'Last;

         declare
            Sbuf  : Ada.Streams.Stream_Element_Array (1 .. 2_048);
            SLast : Ada.Streams.Stream_Element_Offset;
         begin
            GNAT.Sockets.Receive_Socket (Self.Sock, Sbuf, SLast);
            if SLast < Sbuf'First then
               return;  --  closed before the head completed

            end if;
            declare
               N    : constant Natural := Natural (SLast);
               Room : constant Natural := Buf'Last - Len;
               C    : constant Natural := Natural'Min (N, Room);
            begin
               for I in 1 .. C loop
                  Buf (Len + I) :=
                    Character'Val
                      (Natural (Sbuf (Ada.Streams.Stream_Element_Offset (I))));
               end loop;
               Len := Len + C;
            end;
         exception
            when others =>
               return;  --  timeout/error before the head completed
         end;
      end loop;

      if Boundary = 0
        or else Ada.Strings.Fixed.Index (Buf (1 .. Boundary), "101") = 0
      then
         return;  --  no upgrade

      end if;

      --  Push trailing frame bytes (after the blank line) into Accum.
      if Len - Boundary > Self.Accum'Length then
         return;  --  improbable first burst; treat as reconnect-worthy

      end if;
      for I in Boundary + 1 .. Len loop
         Self.Accum (Self.Accum_Len + (I - Boundary)) :=
           Octet (Character'Pos (Buf (I)));
      end loop;
      Self.Accum_Len := Self.Accum_Len + (Len - Boundary);
      Ok := True;
   end Do_Handshake;

   -------------
   -- Connect --
   -------------

   overriding
   procedure Connect (Self : in out Client; URL : String; Ok : out Boolean) is
      Host : Unbounded_String;
      Path : Unbounded_String;
      Port : GNAT.Sockets.Port_Type;
      POk  : Boolean;
   begin
      Close (Self);  --  close-then-dial
      Reset (Self.Ctx);
      Self.State := S_Open;
      Self.Accum_Len := 0;

      Parse_Url (URL, Host, Path, Port, POk);
      if not POk then
         Ok := False;
         return;
      end if;

      declare
         Addr : GNAT.Sockets.Sock_Addr_Type;
      begin
         Resolve (To_String (Host), Addr.Addr, POk);
         if not POk then
            Ok := False;
            return;
         end if;
         Addr.Port := Port;

         GNAT.Sockets.Create_Socket (Self.Sock);
         Self.Has_Socket := True;
         GNAT.Sockets.Connect_Socket (Self.Sock, Addr);
         GNAT.Sockets.Set_Socket_Option
           (Self.Sock,
            GNAT.Sockets.Socket_Level,
            (Name => GNAT.Sockets.Receive_Timeout, Timeout => Poll_Slice));

         Do_Handshake (Self, To_String (Host), Port, To_String (Path), POk);
         if not POk then
            Teardown (Self);
            Ok := False;
            return;
         end if;

         Self.Connected := True;
         Ok := True;
      exception
         when others =>
            Teardown (Self);
            Self.Connected := False;
            Ok := False;
      end;
   end Connect;

   ---------------
   -- Send_Text --
   ---------------

   overriding
   procedure Send_Text
     (Self : in out Client; Payload : String; Ok : out Boolean)
   is
      M    : Mask_Key;
      Wire : Octets (1 .. Payload'Length + Max_Header_Bytes);
      Last : Natural;
   begin
      if not Self.Connected or else Payload'Length > 65_535 then
         Ok := False;
         return;
      end if;
      Next_Mask (Self, M);
      Encode_Text (Payload, M, Wire, Last);
      Send_Raw (Self, Wire (1 .. Last));
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Send_Text;

   -----------
   -- Close --
   -----------

   overriding
   procedure Close (Self : in out Client) is
   begin
      Self.Connected := False;
      Teardown (Self);
   end Close;

end Nuntius.Ws.Native_Client;
