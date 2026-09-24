--  Bodies the compression tests share, and zlib's own reading of a gzip
--  member -- independent of Nuntius.Deflate, so a test of what the
--  server sent does not grade the unit with itself.

package Test_Payloads is

   --  Repetitive JSON, Rows rows of 38 bytes: what a dashboard sends.
   function Json_Like (Rows : Positive) return String;

   --  Bytes no deflate can shrink, from a fixed LCG so a test is
   --  stable.
   function Noise (Length : Natural) return String;

   --  The text of a gzip member, read by zlib; at most Max bytes.
   function Gunzip (Member : String; Max : Positive) return String;

end Test_Payloads;
