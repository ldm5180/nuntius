with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

package body Nuntius_World.Ws_Script is

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use GNAT.Sockets;

   function Text_Of (S : String) return Step
   is ((Kind => Text, Text => To_Unbounded_String (S), others => <>));

   function Start_Of (S : String) return Step
   is ((Kind => Text_Start, Text => To_Unbounded_String (S), others => <>));

   function Continued (S : String) return Step
   is ((Kind => Continuation, Text => To_Unbounded_String (S), others => <>));

   protected body Result is
      procedure Set_Pong (V : Boolean) is
      begin
         Seen := V;
      end Set_Pong;

      function Pong_Seen return Boolean
      is (Seen);
   end Result;

   --  The first byte of each frame kind: FIN and opcode.
   Fin_Text         : constant Stream_Element := 16#81#;
   Open_Text        : constant Stream_Element := 16#01#;
   Fin_Continuation : constant Stream_Element := 16#80#;
   Fin_Ping         : constant Stream_Element := 16#89#;
   Fin_Close        : constant Stream_Element := 16#88#;
   Pong_Opcode      : constant Stream_Element := 16#0A#;
   Opcode_Bits      : constant Stream_Element := 16#0F#;

   function Bytes_Of (S : String) return Stream_Element_Array is
      B : Stream_Element_Array (1 .. S'Length);
   begin
      for K in S'Range loop
         B (Stream_Element_Offset (K - S'First + 1)) :=
           Stream_Element (Character'Pos (S (K)));
      end loop;
      return B;
   end Bytes_Of;

   --  One unmasked frame: Lead, the length, the payload.
   function Frame
     (Lead : Stream_Element; Payload : String) return Stream_Element_Array
   is ([Lead, Stream_Element (Payload'Length)] & Bytes_Of (Payload));

   function Burst_Frames (Count : Natural) return Stream_Element_Array is
      B : Stream_Element_Array (1 .. Stream_Element_Offset (Count * 3));
   begin
      for I in 0 .. Count - 1 loop
         B (Stream_Element_Offset (I * 3 + 1)) := Fin_Text;
         B (Stream_Element_Offset (I * 3 + 2)) := 1;
         B (Stream_Element_Offset (I * 3 + 3)) := Stream_Element (I);
      end loop;
      return B;
   end Burst_Frames;

   --  The bytes one accumulating step adds to the pending write.
   function Bytes_For (S : Step) return Stream_Element_Array
   is (case S.Kind is
         when Upgrade                   =>
           Bytes_Of ("HTTP/1.1 101" & CRLF & CRLF),
         when Text                      =>
           Frame (Fin_Text, To_String (S.Text)),
         when Text_Start                =>
           Frame (Open_Text, To_String (S.Text)),
         when Continuation              =>
           Frame (Fin_Continuation, To_String (S.Text)),
         when Ping                      => [Fin_Ping, 0],
         when Close                     => [Fin_Close, 0],
         when Burst                     => Burst_Frames (S.Count),
         when Raw                       =>
           Frame (S.Lead, [1 .. S.Count => 'x']),
         when Flush | Hold | Await_Pong => [1 .. 0 => 0]);

   procedure Send_Bytes (S : Socket_Type; Bytes : Stream_Element_Array) is
      Off  : Stream_Element_Offset := Bytes'First;
      Last : Stream_Element_Offset;
   begin
      while Off <= Bytes'Last loop
         Send_Socket (S, Bytes (Off .. Bytes'Last), Last);
         exit when Last < Off;
         Off := Last + 1;
      end loop;
   end Send_Bytes;

   --  The client's upgrade request, read far enough to have crossed
   --  its blank line.
   procedure Read_Request (Peer : Socket_Type) is
      Buf  : Stream_Element_Array (1 .. 1_024);
      Last : Stream_Element_Offset;
      Seen : Natural := 0;
   begin
      loop
         Receive_Socket (Peer, Buf, Last);
         exit when Last < Buf'First;
         Seen := Seen + Natural (Last);
         exit when Seen >= 4;
      end loop;
   end Read_Request;

   procedure Note_Pong (Peer : Socket_Type) is
      Buf  : Stream_Element_Array (1 .. 64);
      Last : Stream_Element_Offset;
   begin
      Receive_Socket (Peer, Buf, Last);
      Result.Set_Pong
        (Last >= Buf'First
         and then (Buf (Buf'First) and Opcode_Bits) = Pong_Opcode);
   exception
      when others =>
         Result.Set_Pong (False);
   end Note_Pong;

   task body Peer is
      Listen  : Socket_Type;
      Client  : Socket_Type;
      From    : Sock_Addr_Type;
      Steps   : Script (1 .. Max_Steps);
      Count   : Natural := 0;
      Pending : Unbounded_String;

      procedure Send_Pending is
      begin
         if Length (Pending) > 0 then
            Send_Bytes (Client, Bytes_Of (To_String (Pending)));
            Pending := Null_Unbounded_String;
         end if;
      end Send_Pending;

      procedure Add (B : Stream_Element_Array) is
      begin
         for E of B loop
            Append (Pending, Character'Val (E));
         end loop;
      end Add;
   begin
      accept Serve (Listener : Socket_Type; Plan : Script) do
         Listen := Listener;
         Count := Plan'Length;
         Steps (1 .. Count) := Plan;
      end Serve;
      Accept_Socket (Listen, Client, From);
      Read_Request (Client);
      for S of Steps (1 .. Count) loop
         case S.Kind is
            when Flush      =>
               Send_Pending;

            when Hold       =>
               Send_Pending;
               delay S.Pause;

            when Await_Pong =>
               Send_Pending;
               Note_Pong (Client);

            when others     =>
               Add (Bytes_For (S));
         end case;
      end loop;
      Send_Pending;
      Close_Socket (Client);
      Close_Socket (Listen);
   exception
      when others =>
         Close_Socket (Client);
   end Peer;

   function Start
     (Srv : not null access Peer; Plan : Script) return GNAT.Sockets.Port_Type
   is
      Listen : Socket_Type;
   begin
      Create_Socket (Listen);
      Set_Socket_Option (Listen, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Listen, (Family_Inet, Loopback_Inet_Addr, 0));
      Listen_Socket (Listen);
      Srv.Serve (Listen, Plan);
      return Get_Socket_Name (Listen).Port;
   end Start;

   function Url (Port : GNAT.Sockets.Port_Type; Path : String) return String
   is ("ws://127.0.0.1:"
       & Ada.Strings.Fixed.Trim (Port_Type'Image (Port), Ada.Strings.Both)
       & Path);

   type Peer_Access is access Peer;

   procedure Free is new Ada.Unchecked_Deallocation (Peer, Peer_Access);

   Scripted : Peer_Access;

   --  How long Stop_Scripted lets a peer finish before aborting it.
   Finish_Polls : constant := 300;
   Finish_Slice : constant Duration := 0.01;

   procedure Start_Scripted (Plan : Script; Port : out GNAT.Sockets.Port_Type)
   is
   begin
      Stop_Scripted;
      Scripted := new Peer;
      Port := Start (Scripted, Plan);
   end Start_Scripted;

   procedure Await_Finish is
   begin
      for K in 1 .. Finish_Polls loop
         exit when Scripted'Terminated;
         delay Finish_Slice;
      end loop;
   end Await_Finish;

   procedure Stop_Scripted is
   begin
      if Scripted = null then
         return;
      end if;
      Await_Finish;
      if not Scripted'Terminated then
         abort Scripted.all;
         Await_Finish;
      end if;
      Free (Scripted);
   end Stop_Scripted;

end Nuntius_World.Ws_Script;
