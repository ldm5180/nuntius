with Ada.Characters.Handling;

with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings;

with System.Address_To_Access_Conversions;

package body Nuntius.Http.Fetch.Curl is

   use type System.Address;

   pragma Linker_Options ("-lcurl");

   --  ===== The narrow libcurl slice this driver needs ==================
   --
   --  Option/info ids follow curl.h's stable ABI scheme (kind base +
   --  ordinal), pinned here rather than dragging in a binding crate.
   --  curl_easy_setopt/getinfo are C variadics, so every import carries
   --  the variadic-after-2 convention.

   subtype Curl_Code is int;   --  CURLcode and CURLMcode both
   Curle_Ok : constant Curl_Code := 0;

   Opt_Writedata      : constant int := 10_001;
   Opt_Url            : constant int := 10_002;
   Opt_Httpheader     : constant int := 10_023;
   Opt_Headerdata     : constant int := 10_029;
   Opt_Customrequest  : constant int := 10_036;
   Opt_Post           : constant int := 47;
   Opt_Followlocation : constant int := 52;
   Opt_Httpget        : constant int := 80;
   Opt_Nosignal       : constant int := 99;
   Opt_Timeout_Ms     : constant int := 155;
   Opt_Copypostfields : constant int := 10_165;
   Opt_Writefunction  : constant int := 20_011;
   Opt_Headerfunction : constant int := 20_079;

   Info_Response_Code : constant int := 16#20_0002#;
   Msg_Done           : constant unsigned := 1;
   Global_Default     : constant long := 3;

   function Global_Init (Flags : long) return Curl_Code
   with Import, Convention => C, External_Name => "curl_global_init";

   function Easy_Init return System.Address
   with Import, Convention => C, External_Name => "curl_easy_init";

   procedure Easy_Cleanup (E : System.Address)
   with Import, Convention => C, External_Name => "curl_easy_cleanup";

   function Setopt_Long
     (E : System.Address; Opt : int; Val : long) return Curl_Code
   with
     Import,
     Convention    => C_Variadic_2,
     External_Name => "curl_easy_setopt";

   function Setopt_Ptr
     (E : System.Address; Opt : int; Val : System.Address) return Curl_Code
   with
     Import,
     Convention    => C_Variadic_2,
     External_Name => "curl_easy_setopt";

   function Setopt_Str
     (E : System.Address; Opt : int; Val : Interfaces.C.Strings.chars_ptr)
      return Curl_Code
   with
     Import,
     Convention    => C_Variadic_2,
     External_Name => "curl_easy_setopt";

   type Data_Callback is
     access function
       (Data : System.Address; Size, Nmemb : size_t; User : System.Address)
        return size_t
   with Convention => C;

   function Setopt_Callback
     (E : System.Address; Opt : int; Val : Data_Callback) return Curl_Code
   with
     Import,
     Convention    => C_Variadic_2,
     External_Name => "curl_easy_setopt";

   function Getinfo_Long
     (E : System.Address; Info : int; Val : access long) return Curl_Code
   with
     Import,
     Convention    => C_Variadic_2,
     External_Name => "curl_easy_getinfo";

   function Multi_Init return System.Address
   with Import, Convention => C, External_Name => "curl_multi_init";

   function Multi_Cleanup (M : System.Address) return Curl_Code
   with Import, Convention => C, External_Name => "curl_multi_cleanup";

   function Multi_Add (M, E : System.Address) return Curl_Code
   with Import, Convention => C, External_Name => "curl_multi_add_handle";

   function Multi_Remove (M, E : System.Address) return Curl_Code
   with Import, Convention => C, External_Name => "curl_multi_remove_handle";

   function Multi_Perform
     (M : System.Address; Running : access int) return Curl_Code
   with Import, Convention => C, External_Name => "curl_multi_perform";

   --  struct CURLMsg: the enum, the easy handle, then a union whose only
   --  member we read is the CURLcode (valid exactly when Msg is DONE).
   --  Convention C lays the record out as the C compiler does.
   type Multi_Msg is record
      Msg    : unsigned;
      Easy   : System.Address;
      Result : unsigned;
   end record
   with Convention => C;

   type Multi_Msg_Access is access all Multi_Msg with Convention => C;

   function Multi_Info_Read
     (M : System.Address; Left : access int) return Multi_Msg_Access
   with Import, Convention => C, External_Name => "curl_multi_info_read";

   function Slist_Append
     (L : System.Address; S : Interfaces.C.Strings.chars_ptr)
      return System.Address
   with Import, Convention => C, External_Name => "curl_slist_append";

   procedure Slist_Free (L : System.Address)
   with Import, Convention => C, External_Name => "curl_slist_free_all";

   --  A failed setopt on a live easy handle is effectively unreachable
   --  (OOM); the transfer itself reports any real trouble.  Swallowing
   --  the code keeps the configuration read as straight-line policy.
   procedure Best_Effort (Code : Curl_Code) is null;

   --  ===== The write-side callbacks ====================================

   package Slot_Access is new System.Address_To_Access_Conversions (Slot);

   --  Body bytes accumulate into the slot; past the cap the callback
   --  short-writes, aborting the transfer (CURLE_WRITE_ERROR), and the
   --  overflow mark turns the completion into a transport failure.
   function On_Body
     (Data : System.Address; Size, Nmemb : size_t; User : System.Address)
      return size_t
   with Convention => C;

   function On_Body
     (Data : System.Address; Size, Nmemb : size_t; User : System.Address)
      return size_t
   is
      S   : constant Slot_Access.Object_Pointer :=
        Slot_Access.To_Pointer (User);
      Len : constant Natural := Natural (Size * Nmemb);
   begin
      if Length (S.Reply) + Len > Max_Reply_Bytes then
         S.Overflow := True;
         return 0;
      end if;
      declare
         Chunk : String (1 .. Len)
         with Import, Address => Data;
      begin
         Append (S.Reply, Chunk);
      end;
      return Size * Nmemb;
   end On_Body;

   --  Header lines arrive one per call; only Location is kept (some
   --  APIs return a created resource's id there).
   function On_Header
     (Data : System.Address; Size, Nmemb : size_t; User : System.Address)
      return size_t
   with Convention => C;

   function On_Header
     (Data : System.Address; Size, Nmemb : size_t; User : System.Address)
      return size_t
   is
      Name : constant String := "location:";
      S    : constant Slot_Access.Object_Pointer :=
        Slot_Access.To_Pointer (User);
      Len  : constant Natural := Natural (Size * Nmemb);
   begin
      if Len > Name'Length then
         declare
            Line : String (1 .. Len)
            with Import, Address => Data;

            First : Natural := Name'Length + 1;
            Last  : Natural := Len;
         begin
            if Ada.Characters.Handling.To_Lower (Line (1 .. Name'Length))
              = Name
            then
               while First <= Last and then Line (First) = ' ' loop
                  First := First + 1;
               end loop;
               while Last >= First
                 and then Line (Last) in ' ' | ASCII.CR | ASCII.LF
               loop
                  Last := Last - 1;
               end loop;
               S.Location := To_Unbounded_String (Line (First .. Last));
            end if;
         end;
      end if;
      return Size * Nmemb;
   end On_Header;

   --  ===== Slot lifecycle ==============================================

   procedure Ensure_Multi (Self : in out Curl_Client) is
   begin
      if Self.Multi = System.Null_Address then
         Self.Multi := Multi_Init;
      end if;
   end Ensure_Multi;

   function Free_Slot (Self : Curl_Client) return Natural is
   begin
      for K in Self.Slots'Range loop
         if not Self.Slots (K).Used then
            return K;
         end if;
      end loop;
      return 0;
   end Free_Slot;

   --  Detach and destroy a slot's transfer and reset it for reuse.
   procedure Release (Self : in out Curl_Client; K : Positive) is
      S : Slot renames Self.Slots (K);
   begin
      if S.Easy /= System.Null_Address then
         Best_Effort (Multi_Remove (Self.Multi, S.Easy));
         Easy_Cleanup (S.Easy);
      end if;
      if S.Headers /= System.Null_Address then
         Slist_Free (S.Headers);
      end if;
      S :=
        (Used     => False,
         Easy     => System.Null_Address,
         Headers  => System.Null_Address,
         Id       => No_Request,
         Reply    => Null_Unbounded_String,
         Location => Null_Unbounded_String,
         Overflow => False);
      Self.Live := Self.Live - 1;
   end Release;

   --  One "Name: value" line onto the slot's header list (curl copies
   --  the string; the temporary is freed at once).
   procedure Add_Header (S : in out Slot; Name, Value : String) is
      Line : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Name & ": " & Value);
   begin
      S.Headers := Slist_Append (S.Headers, Line);
      Interfaces.C.Strings.Free (Line);
   end Add_Header;

   --  The one string option helper: curl copies every char* option
   --  since 7.17, so the temporary is freed at once.
   procedure Set_String (E : System.Address; Opt : int; Value : String) is
      V : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Value);
   begin
      Best_Effort (Setopt_Str (E, Opt, V));
      Interfaces.C.Strings.Free (V);
   end Set_String;

   procedure Set_Verb (E : System.Address; R : Request) is
   begin
      case R.Verb is
         when Get    =>
            Best_Effort (Setopt_Long (E, Opt_Httpget, 1));

         when Post   =>
            Best_Effort (Setopt_Long (E, Opt_Post, 1));
            Set_String (E, Opt_Copypostfields, To_String (R.Content));

         when Delete =>
            Set_String (E, Opt_Customrequest, "DELETE");
      end case;
   end Set_Verb;

   procedure Set_Headers (S : in out Slot; R : Request) is
   begin
      if Length (R.Authorization) > 0 then
         Add_Header (S, "Authorization", To_String (R.Authorization));
      end if;
      if Length (R.Content_Type) > 0 then
         Add_Header (S, "Content-Type", To_String (R.Content_Type));
      end if;
      if S.Headers /= System.Null_Address then
         Best_Effort (Setopt_Ptr (S.Easy, Opt_Httpheader, S.Headers));
      end if;
   end Set_Headers;

   --  The whole transfer configuration: verb, headers, callbacks wired
   --  to this slot's address, the per-request timeout, no signals (a
   --  tasking program), and NO redirect-following -- a 201's Location
   --  carries the created id and must come back verbatim.
   procedure Configure (S : in out Slot; R : Request) is
      E : constant System.Address := S.Easy;
   begin
      Set_String (E, Opt_Url, To_String (R.URL));
      Set_Verb (E, R);
      Set_Headers (S, R);
      Best_Effort (Setopt_Callback (E, Opt_Writefunction, On_Body'Access));
      Best_Effort (Setopt_Ptr (E, Opt_Writedata, S'Address));
      Best_Effort (Setopt_Callback (E, Opt_Headerfunction, On_Header'Access));
      Best_Effort (Setopt_Ptr (E, Opt_Headerdata, S'Address));
      Best_Effort (Setopt_Long (E, Opt_Nosignal, 1));
      Best_Effort (Setopt_Long (E, Opt_Followlocation, 0));
      Best_Effort (Setopt_Long (E, Opt_Timeout_Ms, long (R.Timeout_Ms)));
   end Configure;

   --  ===== The port operations =========================================

   overriding
   procedure Start
     (Self : in out Curl_Client; R : Request; Id : out Request_Id)
   is
      K : constant Natural := Free_Slot (Self);
   begin
      Id := No_Request;
      Ensure_Multi (Self);
      if K = 0 or else Self.Multi = System.Null_Address then
         return;
      end if;

      declare
         S : Slot renames Self.Slots (K);
      begin
         S.Easy := Easy_Init;
         if S.Easy = System.Null_Address then
            return;
         end if;

         S.Used := True;
         S.Id := Self.Next_Id;
         Self.Next_Id :=
           (if Self.Next_Id = Request_Id'Last then 1 else Self.Next_Id + 1);
         Self.Live := Self.Live + 1;

         Configure (S, R);
         if Multi_Add (Self.Multi, S.Easy) /= Curle_Ok then
            Release (Self, K);
            return;
         end if;
         Id := S.Id;
      end;
   end Start;

   --  Turn a DONE message into its slot's completion and free the slot.
   procedure Complete
     (Self   : in out Curl_Client;
      Easy   : System.Address;
      Result : unsigned;
      Done   : out Completion;
      Got    : out Boolean)
   is
      Code : aliased long := 0;
   begin
      Got := False;
      for K in Self.Slots'Range loop
         if Self.Slots (K).Used and then Self.Slots (K).Easy = Easy then
            declare
               S : Slot renames Self.Slots (K);
            begin
               if Result = 0 and then not S.Overflow then
                  Best_Effort
                    (Getinfo_Long (Easy, Info_Response_Code, Code'Access));
                  Done :=
                    (Id       => S.Id,
                     Ok       => True,
                     Status   => Natural (Code),
                     Reply    => S.Reply,
                     Location => S.Location);
               else
                  Done :=
                    (Id       => S.Id,
                     Ok       => False,
                     Status   => 0,
                     Reply    => Null_Unbounded_String,
                     Location => Null_Unbounded_String);
               end if;
            end;
            Got := True;
            Release (Self, K);
            return;
         end if;
      end loop;
   end Complete;

   overriding
   procedure Pump
     (Self : in out Curl_Client; Done : out Completion; Got : out Boolean)
   is
      Running : aliased int := 0;
      Left    : aliased int := 0;
      M       : Multi_Msg_Access;
   begin
      Done := (others => <>);
      Got := False;
      if Self.Multi = System.Null_Address or else Self.Live = 0 then
         return;
      end if;

      Best_Effort (Multi_Perform (Self.Multi, Running'Access));

      --  DONE messages queue inside libcurl until read, so a burst
      --  survives across Pump calls; surface one per call.
      loop
         M := Multi_Info_Read (Self.Multi, Left'Access);
         exit when M = null;
         if M.Msg = Msg_Done then
            Complete (Self, M.Easy, M.Result, Done, Got);
            exit when Got;
         end if;
      end loop;
   end Pump;

   overriding
   procedure Cancel (Self : in out Curl_Client; Id : Request_Id) is
   begin
      for K in Self.Slots'Range loop
         if Self.Slots (K).Used and then Self.Slots (K).Id = Id then
            Release (Self, K);
            return;
         end if;
      end loop;
   end Cancel;

   overriding
   function In_Flight (Self : Curl_Client) return Natural
   is (Self.Live);

   overriding
   procedure Finalize (Self : in out Curl_Client) is
   begin
      if Self.Multi = System.Null_Address then
         return;
      end if;
      for K in Self.Slots'Range loop
         if Self.Slots (K).Used then
            Release (Self, K);
         end if;
      end loop;
      Best_Effort (Multi_Cleanup (Self.Multi));
      Self.Multi := System.Null_Address;
   end Finalize;

begin
   --  Elaboration is single-threaded, which is exactly what
   --  curl_global_init needs; libcurl refcounts it against utilada's
   --  own Register.
   Best_Effort (Global_Init (Global_Default));
end Nuntius.Http.Fetch.Curl;
