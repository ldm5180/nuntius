with Nuntius.Rfc6455;

--  The loopback world the suite and the features share: the peers,
--  servers and dialers the adapter tests stand up, in one place a second
--  test binary can reach.  This root holds what every child needs.

package Nuntius_World is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  Whether Needle appears in Haystack.
   function Has (Haystack, Needle : String) return Boolean;

   --  Reply's first line, or "(nothing)" when it is empty: what a
   --  failed check quotes, since a whole reply outruns its message.
   function Head_Line (Reply : String) return String;

   --  The bytes of tests/features/bytes/<Name>.hex: hex pairs separated
   --  by blanks, `#` to the end of a line a comment.  Ok False when the
   --  file is missing or holds anything else, so a step can name it.
   procedure Named_Bytes
     (Dir    : String;
      Name   : String;
      Result : out Nuntius.Rfc6455.Octets;
      Last   : out Natural;
      Ok     : out Boolean)
   with Pre => Result'First = 1;

   --  B's octets as characters, and S's characters as octets.
   function Chars_Of (B : Nuntius.Rfc6455.Octets) return String;
   function Octets_Of (S : String) return Nuntius.Rfc6455.Octets;

   --  N bytes of repetitive JSON, cut from Test_Payloads.Json_Like.
   function Json_Of (N : Natural) return String;

end Nuntius_World;
