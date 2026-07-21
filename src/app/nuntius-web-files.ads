with Ada.Strings.Unbounded;

--  The capped whole-file read a Handle serves static content with.
--  Only the exact path the caller names is ever opened -- no traversal
--  surface exists unless the caller builds one.  The three outcomes
--  stay distinct so the caller owns the logging and status policy: an
--  oversized file is REFUSED whole (never truncated -- a partial page
--  reads as corruption, not content), and Missing covers unreadable.

package Nuntius.Web.Files is

   type Read_Result is (Read_Ok, Missing, Oversized);

   procedure Read_Capped
     (Path      : String;
      Max_Bytes : Positive;
      Content   : out Ada.Strings.Unbounded.Unbounded_String;
      Result    : out Read_Result);

end Nuntius.Web.Files;
