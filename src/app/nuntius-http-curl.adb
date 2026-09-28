with Util.Http.Clients;
with Util.Http.Clients.Curl;

package body Nuntius.Http.Curl is

   procedure Register is
   begin
      Util.Http.Clients.Curl.Register;
   end Register;

   --  Every call: a 30s timeout (without one a black-holed connection
   --  would block a synchronous loop indefinitely -- no exception, no
   --  recovery -- while an access token silently expires) and the
   --  registered User-Agent, since libcurl sends none on its own.
   Request_Timeout : constant Duration := 30.0;

   procedure Prepare (Client : in out Util.Http.Clients.Client) is
   begin
      Client.Set_Timeout (Request_Timeout);
      Client.Set_Header ("User-Agent", User_Agent);
   end Prepare;

   --  A reply that arrived, as the port reports it: the exchange held,
   --  with the server's status and body.  No Location; a verb that
   --  reads one sets it itself.
   function Answered (Reply : Util.Http.Clients.Response) return Response
   is (Ok       => True,
       Status   => Reply.Get_Status,
       Reply    => To_Unbounded_String (Reply.Get_Body),
       Location => Null_Unbounded_String);

   --  Post_Form sends form-encoded bodies (OAuth token endpoints); this is
   --  the Content-Type header that declares that encoding.
   Form_Content_Type : constant String := "application/x-www-form-urlencoded";

   overriding
   procedure Post_Form
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is
      pragma Unreferenced (Self);
      Client : Util.Http.Clients.Client;
      Reply  : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Form_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Post (URL, Content, Reply);
      Result := Answered (Reply);
   exception
      when others =>
         Result := (others => <>);
   end Post_Form;

   --  The API calls carry a JSON body (POST/PUT) or none (GET/DELETE)
   --  and a Bearer token; any transport exception becomes Ok => False so
   --  the caller backs off rather than crashing.
   Json_Content_Type : constant String := "application/json";

   overriding
   procedure Post_Json
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is
      pragma Unreferenced (Self);
      Client : Util.Http.Clients.Client;
      Reply  : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Json_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Post (URL, Content, Reply);
      Result := Answered (Reply);
      if Reply.Contains_Header ("Location") then
         Result.Location :=
           To_Unbounded_String (Reply.Get_Header ("Location"));
      end if;
   exception
      when others =>
         Result := (others => <>);
   end Post_Json;

   overriding
   procedure Put_Json
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is
      pragma Unreferenced (Self);
      Client : Util.Http.Clients.Client;
      Reply  : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Json_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Put (URL, Content, Reply);
      Result := Answered (Reply);
   exception
      when others =>
         Result := (others => <>);
   end Put_Json;

   overriding
   procedure Get
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Result        : out Response)
   is
      pragma Unreferenced (Self);
      Client : Util.Http.Clients.Client;
      Reply  : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Authorization", Authorization);
      Client.Get (URL, Reply);
      Result := Answered (Reply);
   exception
      when others =>
         Result := (others => <>);
   end Get;

   overriding
   procedure Delete
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Result        : out Response)
   is
      pragma Unreferenced (Self);
      Client : Util.Http.Clients.Client;
      Reply  : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Authorization", Authorization);
      Client.Delete (URL, Reply);
      Result := Answered (Reply);
   exception
      when others =>
         Result := (others => <>);
   end Delete;

end Nuntius.Http.Curl;
