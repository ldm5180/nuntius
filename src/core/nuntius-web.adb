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

   Max_Decimal_Digits : constant := 10;
   --  Natural'Last is 2_147_483_647: ten digits.

   --  A Natural without 'Image's leading space, so it drops into the
   --  Content-Length header verbatim.  The length bound is what lets
   --  Response_Head's concatenation prove its upper bound.
   function Decimal_Image (N : Natural) return String
   with Post => Decimal_Image'Result'Length in 1 .. Max_Decimal_Digits;

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
      R.Method := (if Text (1 .. Sp1 - 1) = "GET" then Get else Other);
      R.Well_Formed := True;
      return R;
   end Parse_Request;

   function Response_Head
     (S : Status; Content_Type : String; Content_Length : Natural)
      return String
   is ("HTTP/1.1 "
       & Status_Line (S)
       & CRLF
       & "Connection: close"
       & CRLF
       & "Cache-Control: no-store"
       & CRLF
       & "Content-Type: "
       & Content_Type
       & CRLF
       & "Content-Length: "
       & Decimal_Image (Content_Length)
       & CRLF
       & CRLF);

end Nuntius.Web;
