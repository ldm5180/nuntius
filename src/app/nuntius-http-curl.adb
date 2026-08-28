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

   --  Post_Form sends form-encoded bodies (OAuth token endpoints); this is
   --  the Content-Type header that declares that encoding.
   Form_Content_Type : constant String := "application/x-www-form-urlencoded";

   overriding
   procedure Post_Form
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is
      pragma Unreferenced (Self);
      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Form_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Post (URL, Content, Response);

      Status := Response.Get_Status;
      Reply := To_Unbounded_String (Response.Get_Body);
      Ok := True;
   exception
      when others =>
         Status := 0;
         Reply := Null_Unbounded_String;
         Ok := False;
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
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Location      : out Unbounded_String;
      Ok            : out Boolean)
   is
      pragma Unreferenced (Self);
      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Json_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Post (URL, Content, Response);

      Status := Response.Get_Status;
      Reply := To_Unbounded_String (Response.Get_Body);
      Location :=
        (if Response.Contains_Header ("Location")
         then To_Unbounded_String (Response.Get_Header ("Location"))
         else Null_Unbounded_String);
      Ok := True;
   exception
      when others =>
         Status := 0;
         Reply := Null_Unbounded_String;
         Location := Null_Unbounded_String;
         Ok := False;
   end Post_Json;

   overriding
   procedure Put_Json
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is
      pragma Unreferenced (Self);
      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Content-Type", Json_Content_Type);
      Client.Set_Header ("Authorization", Authorization);
      Client.Put (URL, Content, Response);

      Status := Response.Get_Status;
      Reply := To_Unbounded_String (Response.Get_Body);
      Ok := True;
   exception
      when others =>
         Status := 0;
         Reply := Null_Unbounded_String;
         Ok := False;
   end Put_Json;

   overriding
   procedure Get
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is
      pragma Unreferenced (Self);
      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Authorization", Authorization);
      Client.Get (URL, Response);

      Status := Response.Get_Status;
      Reply := To_Unbounded_String (Response.Get_Body);
      Ok := True;
   exception
      when others =>
         Status := 0;
         Reply := Null_Unbounded_String;
         Ok := False;
   end Get;

   overriding
   procedure Delete
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is
      pragma Unreferenced (Self);
      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Prepare (Client);
      Client.Set_Header ("Authorization", Authorization);
      Client.Delete (URL, Response);

      Status := Response.Get_Status;
      Reply := To_Unbounded_String (Response.Get_Body);
      Ok := True;
   exception
      when others =>
         Status := 0;
         Reply := Null_Unbounded_String;
         Ok := False;
   end Delete;

end Nuntius.Http.Curl;
