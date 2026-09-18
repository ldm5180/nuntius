package body Nuntius.Web
  with SPARK_Mode
is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  RFC 9110 tokens are wider, but every real method is uppercase
   --  ASCII; anything else reads as line noise, not a request.
   function Is_Method_Char (C : Character) return Boolean
   is (C in 'A' .. 'Z');

   --  Printable ASCII without SP and DEL: the target's SP/CTL exclusion.
   function Is_Target_Char (C : Character) return Boolean
   is (C in '!' .. '~');

   --  Optional whitespace around a header value (RFC 9110 5.5).
   function Is_Space (C : Character) return Boolean
   is (C = ' ' or else C = ASCII.HT);

   function Lower (C : Character) return Character
   is (if C in 'A' .. 'Z' then Character'Val (Character'Pos (C) + 32) else C);

   --  Header names and scheme words are ASCII case-insensitive.
   function Same_Ci (A, B : String) return Boolean
   is (A'Length = B'Length
       and then (for all K in 0 .. A'Length - 1 =>
                   Lower (A (A'First + K)) = Lower (B (B'First + K))));

   function All_Digits (S : String) return Boolean
   is (S'Length > 0 and then (for all C of S => C in '0' .. '9'));

   --  Every string below is a slice of the 4 KB request text (a null
   --  slice's bounds are otherwise unconstrained, which is what the
   --  arithmetic here needs ruled out).
   function In_Text_Bounds (S : String) return Boolean
   is (S'First >= 1 and then S'Last in 0 .. Max_Request_Bytes);

   --  The first index of C in S, or 0.
   function Index_Of (S : String; C : Character) return Natural
   with
     Pre  => In_Text_Bounds (S),
     Post => Index_Of'Result = 0 or else Index_Of'Result in S'Range;

   Max_Decimal_Digits : constant := 10;
   --  Natural'Last is 2_147_483_647: ten digits.

   --  A header value without its surrounding SP/HTAB.
   function Trimmed (S : String) return String
   with
     Pre  => In_Text_Bounds (S),
     Post =>
       Trimmed'Result'Length <= S'Length
       and then In_Text_Bounds (Trimmed'Result);

   function Digit (C : Character) return Natural
   is (Character'Pos (C) - Character'Pos ('0'))
   with Pre => C in '0' .. '9', Post => Digit'Result <= 9;

   --  A digit run short enough that its value cannot overflow: four
   --  digits is 9_999, which is already past Max_Body_Bytes.  Spelled
   --  out per length rather than accumulated, so the bound is the
   --  expression's own and needs no loop invariant.
   function Digits_Value (S : String) return Natural
   is (case S'Length is
         when 1      => Digit (S (S'First)),
         when 2      => Digit (S (S'First)) * 10 + Digit (S (S'First + 1)),
         when 3      =>
           Digit (S (S'First))
           * 100
           + Digit (S (S'First + 1)) * 10
           + Digit (S (S'First + 2)),
         when others =>
           Digit (S (S'First))
           * 1_000
           + Digit (S (S'First + 1)) * 100
           + Digit (S (S'First + 2)) * 10
           + Digit (S (S'First + 3)))
   with
     Pre  => All_Digits (S) and then S'Length <= 4,
     Post => Digits_Value'Result <= 9_999;

   --  A Natural without 'Image's leading space, so it drops into the
   --  Content-Length header verbatim.  The length bound is what lets
   --  Response_Head's concatenation prove its upper bound.
   function Decimal_Image (N : Natural) return String
   with Post => Decimal_Image'Result'Length in 1 .. Max_Decimal_Digits;

   function Index_Of (S : String; C : Character) return Natural is
   begin
      for K in S'Range loop
         if S (K) = C then
            return K;
         end if;
      end loop;
      return 0;
   end Index_Of;

   function Trimmed (S : String) return String is
      F : Natural := S'First;
      L : Natural := S'Last;
   begin
      while F <= L and then Is_Space (S (F)) loop
         pragma Loop_Invariant (F in S'First .. L);
         pragma Loop_Variant (Increases => F);
         F := F + 1;
      end loop;
      while L >= F and then Is_Space (S (L)) loop
         pragma Loop_Invariant (L in F .. S'Last);
         pragma Loop_Variant (Decreases => L);
         L := L - 1;
      end loop;
      return S (F .. L);
   end Trimmed;

   function Decimal_Image (N : Natural) return String is
      Buf   : String (1 .. Max_Decimal_Digits) := [others => '0'];
      Pos   : Positive := Buf'Last + 1;
      Value : Natural := N;
   begin
      loop
         pragma Loop_Invariant (Pos in Buf'First + 1 .. Buf'Last + 1);
         pragma Loop_Invariant (for all C of Buf => C in '0' .. '9');
         pragma Loop_Variant (Decreases => Pos);
         Pos := Pos - 1;
         Buf (Pos) := Character'Val (Character'Pos ('0') + Value mod 10);
         Value := Value / 10;
         exit when Value = 0 or else Pos = Buf'First;
      end loop;
      return Buf (Pos .. Buf'Last);
   end Decimal_Image;

   function Parse_Request (Text : String) return Request is
      R : Request;

      Line_Last : Natural := 0;   --  last index BEFORE the CRLF
      Found     : Boolean := False;
      Sp1       : Natural := 0;   --  method/target separator
      Sp2       : Natural := 0;   --  target/version separator

      --  A refused header keeps the request from being well-formed;
      --  Length_Refused is what separates a 413 from a 400.
      Bad_Header  : Boolean := False;
      Seen_Length : Boolean := False;

      --  Content-Type, as far as the first ';' (the parameters are a
      --  charset, never the media type).
      function Is_Json (Value : String) return Boolean
      with Pre => In_Text_Bounds (Value)
      is
         Semi : constant Natural := Index_Of (Value, ';');
         Last : constant Natural :=
           (if Semi = 0 then Value'Last else Semi - 1);
      begin
         return
           Same_Ci (Trimmed (Value (Value'First .. Last)), "application/json");
      end Is_Json;

      procedure Read_Length (Value : String) is
      begin
         if Seen_Length then
            --  Two lengths are a smuggling shape, not a request.
            Bad_Header := True;
            return;
         end if;
         Seen_Length := True;
         if not All_Digits (Value) then
            Bad_Header := True;
         elsif Value'Length > 4 then
            --  Refused on its LENGTH alone, so nothing is evaluated.
            Bad_Header := True;
            R.Length_Refused := True;
         elsif Digits_Value (Value) > Max_Body_Bytes then
            Bad_Header := True;
            R.Length_Refused := True;
         else
            R.Content_Length := Digits_Value (Value);
         end if;
      end Read_Length;

      --  RFC 6750 2.1: the scheme word, one or more SP, then the token.
      procedure Read_Bearer (Value : String) with Pre => In_Text_Bounds (Value)
      is
         Sp : constant Natural := Index_Of (Value, ' ');
         T  : Natural;
      begin
         if Sp = 0
           or else not Same_Ci (Value (Value'First .. Sp - 1), "Bearer")
         then
            return;
         end if;
         T := Sp + 1;
         while T <= Value'Last and then Value (T) = ' ' loop
            pragma Loop_Invariant (T in Sp + 1 .. Value'Last);
            pragma Loop_Variant (Increases => T);
            T := T + 1;
         end loop;
         if Value'Last >= T and then Value'Last - T + 1 <= Max_Bearer then
            R.Bearer_Len := Value'Last - T + 1;
            R.Bearer (1 .. R.Bearer_Len) := Value (T .. Value'Last);
         end if;
      end Read_Bearer;

      procedure Read_Forwarded (Value : String) is
      begin
         if Value'Length in 1 .. Max_Forwarded
           and then (for all C of Value => C in ' ' .. '~')
         then
            R.Forwarded_Len := Value'Length;
            R.Forwarded_For (1 .. Value'Length) := Value;
         end if;
      end Read_Forwarded;

      --  One header line, name before the first ':'.  A line with no
      --  colon is not a header and is skipped: the head is still a
      --  head, and nothing here decides well-formedness on its own.
      procedure Read_Header (Line : String) with Pre => In_Text_Bounds (Line)
      is
         Colon : constant Natural := Index_Of (Line, ':');
      begin
         if Colon <= Line'First then
            return;
         end if;
         declare
            Name  : constant String := Line (Line'First .. Colon - 1);
            Value : constant String := Trimmed (Line (Colon + 1 .. Line'Last));
         begin
            if Same_Ci (Name, "Content-Length") then
               Read_Length (Value);
            elsif Same_Ci (Name, "Content-Type") then
               R.Json_Body := Is_Json (Value);
            elsif Same_Ci (Name, "Authorization") then
               Read_Bearer (Value);
            elsif Same_Ci (Name, "X-Forwarded-For") then
               Read_Forwarded (Value);
            end if;
         end;
      end Read_Header;

      --  The header block: from just past the request line's CRLF to
      --  the first EMPTY line.  Never to Text'Last.
      procedure Read_Headers (From : Positive) is
         Pos : Natural := From;
         E   : Natural;
      begin
         while Pos <= Text'Last loop
            pragma Loop_Invariant (Pos in From .. Text'Last);
            pragma Loop_Variant (Increases => Pos);
            E := 0;
            for K in Pos .. Text'Last - 1 loop
               if Text (K) = ASCII.CR and then Text (K + 1) = ASCII.LF then
                  E := K;
                  exit;
               end if;
            end loop;
            exit when E = 0;     --  a head that never ends: nothing more
            exit when E = Pos;   --  the empty line: the block is done
            Read_Header (Text (Pos .. E - 1));
            Pos := E + 2;
         end loop;
      end Read_Headers;

   begin
      for K in 1 .. Text'Length - 1 loop
         if Text (K) = ASCII.CR and then Text (K + 1) = ASCII.LF then
            Line_Last := K - 1;
            Found := True;
            exit;
         end if;
      end loop;
      if not Found then
         return R;
      end if;

      for K in 1 .. Line_Last loop
         if Text (K) = ' ' then
            Sp1 := K;
            exit;
         end if;
      end loop;
      if Sp1 < 2 then
         --  No separator, or an empty method.
         return R;
      end if;

      for K in Sp1 + 1 .. Line_Last loop
         if Text (K) = ' ' then
            Sp2 := K;
            exit;
         end if;
      end loop;
      if Sp2 = 0 or else Sp2 = Sp1 + 1 then
         --  No second separator, or an empty target.
         return R;
      end if;

      if Sp2 - Sp1 - 1 > Max_Target
        or else Line_Last /= Sp2 + 8
        or else Text (Sp2 + 1 .. Sp2 + 7) /= "HTTP/1."
        or else Text (Sp2 + 8) not in '0' .. '9'
        or else (for some K in 1 .. Sp1 - 1 => not Is_Method_Char (Text (K)))
        or else (for some K in Sp1 + 1 .. Sp2 - 1 =>
                   not Is_Target_Char (Text (K)))
      then
         return R;
      end if;

      R.Target_Len := Sp2 - Sp1 - 1;
      R.Target (1 .. R.Target_Len) := Text (Sp1 + 1 .. Sp2 - 1);
      R.Method :=
        (if Text (1 .. Sp1 - 1) = "GET"
         then Get
         elsif Text (1 .. Sp1 - 1) = "POST"
         then Post
         else Other);
      if Line_Last + 3 <= Text'Last then
         Read_Headers (Line_Last + 3);
      end if;
      R.Well_Formed := not Bad_Header;
      return R;
   end Parse_Request;

   --  -gnatyB asks for "or else" below.  Short-circuiting is exactly
   --  what this compare must not do -- it visits every byte whatever
   --  the first difference -- so the style check is off for this body
   --  alone.
   pragma Style_Checks (Off);

   function Same_Text (A, B : String) return Boolean is
      Diff : Boolean := False;
   begin
      for K in 0 .. A'Length - 1 loop
         Diff := Diff or (A (A'First + K) /= B (B'First + K));
         pragma
           Loop_Invariant
             (Diff
                = (A (A'First .. A'First + K) /= B (B'First .. B'First + K)));
      end loop;
      return not Diff;
   end Same_Text;

   pragma Style_Checks (On);

   function Response_Head
     (S : Status; Content_Type : String; Content_Length : Natural)
      return String
   is ("HTTP/1.1 "
       & Status_Line (S)
       & CRLF
       & (if S = Unauthorized_401 then Challenge & CRLF else "")
       & "Connection: close"
       & CRLF
       & "Cache-Control: no-store"
       & CRLF
       & "Content-Security-Policy: frame-ancestors 'none'"
       & CRLF
       & "X-Content-Type-Options: nosniff"
       & CRLF
       & "Content-Type: "
       & Content_Type
       & CRLF
       & "Content-Length: "
       & Decimal_Image (Content_Length)
       & CRLF
       & CRLF);

end Nuntius.Web;
