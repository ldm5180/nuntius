--  The loopback world the suite and the features share: the peers,
--  servers and dialers the adapter tests stand up, in one place a second
--  test binary can reach.  This root holds what every child needs.

package Nuntius_World is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  Whether Needle appears in Haystack.
   function Has (Haystack, Needle : String) return Boolean;

end Nuntius_World;
