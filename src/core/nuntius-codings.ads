--  The codings the serving side can put on what it sends, as types, so
--  the HTTP head, the 101 and the frame header all say the same thing
--  about a body.  A small unit of its own because Nuntius.Web and
--  Nuntius.Rfc6455 both name them and neither withs the other.

package Nuntius.Codings
  with Pure, SPARK_Mode
is

   --  An HTTP body as sent (RFC 9110 8.4): verbatim, or one gzip
   --  member (RFC 1952) named by Content-Encoding.
   type Content_Coding is (Identity, Gzip);

   --  A websocket message as sent: verbatim, or permessage-deflate's
   --  raw deflate (RFC 7692 7.2) with RSV1 set on its frame.
   type Message_Coding is (Plain, Deflated);

   --  Whether a server applies a coding its client offers.
   --  Identity_Only is every byte as it was before codings existed.
   type Policy is (Identity_Only, Compress_When_Offered);

end Nuntius.Codings;
