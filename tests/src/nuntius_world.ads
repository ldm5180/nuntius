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

end Nuntius_World;
