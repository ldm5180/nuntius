with Nuntius.Rfc6455;

--  The one unit that calls zlib (the binding the aws crate bundles):
--  a gzip member for Content-Encoding, and permessage-deflate's pack
--  and unpack of one websocket message.  No zlib state outlives a call
--  -- the 101 agreed no context takeover both ways -- and nothing here
--  raises: a failure is an empty result or a verdict, and the caller
--  sends the bytes plain.

package Nuntius.Deflate is

   --  The largest body this unit packs; past it every function answers
   --  as it does on a zlib failure, and the body goes out as it is.
   Max_Pack_Bytes : constant := 64 * 1_024 * 1_024;

   --  A scratch size above zlib's deflateBound for Length bytes plus the
   --  gzip header and footer, so one deflate call always finishes.
   function Worst_Case (Length : Natural) return Positive
   is (Length + Length / 1_000 + 128)
   with Pre => Length <= Max_Pack_Bytes;

   --  The gzip member (RFC 1952) of Payload.  Empty on a zlib failure
   --  or a Payload over Max_Pack_Bytes, and the caller sends identity.
   function Gzip (Payload : String) return String;

   --  The permessage-deflate payload of one message (RFC 7692 7.2.1):
   --  raw deflate, flushed, its 00 00 FF FF tail removed.  Empty when
   --  the text is under Nuntius.Web.Min_Compress_Bytes, over
   --  Max_Pack_Bytes, or zlib fails -- all read as "send it plain".
   function Pack (Text : String) return Nuntius.Rfc6455.Octets;

   type Unpack_Verdict is (Done, Too_Big, Corrupt);

   --  The text of one packed message into Into (1 .. Last), the tail
   --  re-appended before inflating.  Too_Big when the text would pass
   --  Into'Length, found before a byte past it is kept, so a small
   --  frame cannot fill more than the caller's buffer; Corrupt when
   --  zlib refuses the stream.  Last is 0 unless Done.
   function Unpack
     (Packed : Nuntius.Rfc6455.Octets; Into : out String; Last : out Natural)
      return Unpack_Verdict
   with Pre => Into'First = 1;

end Nuntius.Deflate;
