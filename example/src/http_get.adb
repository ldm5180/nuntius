with Ada.Command_Line;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with Nuntius.Http.Curl;

--  Fetch a URL over the libcurl adapter and print the status and the head
--  of the body -- the whole consumer story in one screen: register the
--  backend once, make the call, branch on Ok (a transport failure is a
--  result, never an exception).
--
--  Usage: http_get [URL]        (default https://example.com/)

procedure Http_Get is

   Default_URL : constant String := "https://example.com/";

   URL : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else Default_URL);

   Body_Head : constant := 200;
   --  How much of the reply to show; enough to see what came back.

   Transport : Nuntius.Http.Curl.Curl_Transport;
   Status    : Natural;
   Reply     : Unbounded_String;
   Ok        : Boolean;

begin
   Nuntius.Http.Curl.Register;

   Transport.Get
     (URL, Authorization => "", Status => Status, Reply => Reply, Ok => Ok);

   if not Ok then
      Put_Line ("transport failure: could not reach " & URL);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Put_Line ("HTTP" & Status'Image & " from " & URL);

   declare
      Text : constant String := To_String (Reply);
      Last : constant Natural :=
        Natural'Min (Text'Last, Text'First + Body_Head - 1);
   begin
      Put_Line (Text (Text'First .. Last));
   end;
end Http_Get;
