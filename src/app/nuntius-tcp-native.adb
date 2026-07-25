with Ada.Streams;

package body Nuntius.Tcp.Native is

   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.Sockets.Error_Type;

   function Poll_Slice (Self : Client) return Duration
   is (Duration'Min (Max_Poll_Slice, Self.Idle_Limit));

   --------------------
   -- Set_Idle_Limit --
   --------------------

   procedure Set_Idle_Limit (Self : in out Client; Seconds : Duration) is
   begin
      Self.Idle_Limit := Seconds;
   end Set_Idle_Limit;

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
      Self.Connected := False;
   end Teardown;

   -----------
   -- Close --
   -----------

   overriding
   procedure Close (Self : in out Client) is
   begin
      Teardown (Self);
   end Close;

   -------------
   -- Resolve --
   -------------

   --  A dotted quad first (the common case: a gateway given by address),
   --  then DNS.  Mirrors the native websocket adapter's resolver.
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

   -------------
   -- Connect --
   -------------

   overriding
   procedure Connect
     (Self : in out Client; Host : String; Port : Natural; Ok : out Boolean)
   is
      Addr : GNAT.Sockets.Sock_Addr_Type;
      ROk  : Boolean;
   begin
      Close (Self);  --  close-then-dial

      if Host'Length = 0 or else Port not in 1 .. 65_535 then
         Ok := False;
         return;
      end if;

      Resolve (Host, Addr.Addr, ROk);
      if not ROk then
         Ok := False;
         return;
      end if;
      Addr.Port := GNAT.Sockets.Port_Type (Port);

      GNAT.Sockets.Create_Socket (Self.Sock);
      Self.Has_Socket := True;
      GNAT.Sockets.Connect_Socket (Self.Sock, Addr);
      GNAT.Sockets.Set_Socket_Option
        (Self.Sock,
         GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Receive_Timeout, Timeout => Poll_Slice (Self)));

      Self.Connected := True;
      Ok := True;
   exception
      when others =>
         Teardown (Self);
         Ok := False;
   end Connect;

   ----------
   -- Send --
   ----------

   overriding
   procedure Send (Self : in out Client; Data : String; Ok : out Boolean) is
      Wire : Ada.Streams.Stream_Element_Array (1 .. Data'Length);
      Off  : Ada.Streams.Stream_Element_Offset := 1;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Ok := False;
      if not Self.Connected then
         return;
      end if;
      if Data'Length = 0 then
         Ok := True;
         return;
      end if;

      for I in Data'Range loop
         Wire (Ada.Streams.Stream_Element_Offset (I - Data'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Data (I)));
      end loop;

      while Off <= Wire'Last loop
         GNAT.Sockets.Send_Socket (Self.Sock, Wire (Off .. Wire'Last), Last);
         if Last < Off then
            return;  --  nothing moved: the peer is gone, so is the write

         end if;
         Off := Last + 1;
      end loop;
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Send;

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
      Idle : Duration := 0.0;
   begin
      Into := [others => ASCII.NUL];
      Last := 0;
      Ok := False;
      if not Self.Connected or else Into'Length = 0 then
         return;
      end if;

      loop
         declare
            Buf   : Ada.Streams.Stream_Element_Array (1 .. Into'Length);
            SLast : Ada.Streams.Stream_Element_Offset;
         begin
            GNAT.Sockets.Receive_Socket (Self.Sock, Buf, SLast);

            if SLast < Buf'First then
               return;  --  peer closed the connection

            end if;

            for I in Buf'First .. SLast loop
               Into (Into'First + Natural (I - Buf'First)) :=
                 Character'Val (Buf (I));
            end loop;
            Last := Into'First + Natural (SLast - Buf'First);
            Ok := True;
            return;
         exception
            when E : GNAT.Sockets.Socket_Error =>
               if GNAT.Sockets.Resolve_Exception (E)
                 /= GNAT.Sockets.Resource_Temporarily_Unavailable
               then
                  return;  --  a real socket fault: reconnect-worthy

               end if;
               --  Receive timeout: no data this slice.  Charge the wait
               --  against the idle budget and look again.
               Idle := Idle + Poll_Slice (Self);
               if Idle >= Self.Idle_Limit then
                  return;
               end if;
            when others =>
               return;
         end;
      end loop;
   end Receive;

end Nuntius.Tcp.Native;
