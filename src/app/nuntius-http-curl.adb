with Util.Http.Clients;
with Util.Http.Clients.Curl;

package body Nuntius.Http.Curl is

   procedure Register is
   begin
      Util.Http.Clients.Curl.Register;
   end Register;

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

      Request_Timeout : constant Duration := 30.0;
      --  Token calls are quick; without a timeout a black-holed connection
      --  would block a synchronous refresh loop indefinitely (no
      --  exception, no recovery) while the access token silently expires.

      Client   : Util.Http.Clients.Client;
      Response : Util.Http.Clients.Response;
   begin
      Client.Set_Timeout (Request_Timeout);
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

   --  The API calls carry a JSON body (POST) or none (GET/DELETE) and a
   --  Bearer token; the same 30s timeout guards a black-holed connection,
   --  and any transport exception becomes Ok => False so the caller backs
   --  off rather than crashing.
   Json_Content_Type : constant String := "application/json";
   Request_Timeout   : constant Duration := 30.0;

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
      Client.Set_Timeout (Request_Timeout);
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
      Client.Set_Timeout (Request_Timeout);
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
      Client.Set_Timeout (Request_Timeout);
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
