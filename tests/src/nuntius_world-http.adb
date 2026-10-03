with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with GNAT.Sockets;

with Nuntius.Http.Curl;

with Loopback_Capture;

package body Nuntius_World.Http is

   use Nuntius.Http.Fetch;

   --  The words the features spell each verb with.
   function Word_Of (V : Verb) return String
   is (case V is
         when Get       => "GET",
         when Delete    => "DELETE",
         when Json_Post => "JSON-POST",
         when Json_Put  => "JSON-PUT",
         when Form_Post => "form-POST");

   procedure Verb_Named (Word : String; V : out Verb; Found : out Boolean) is
   begin
      V := Verb'First;
      Found := False;
      for Candidate in Verb loop
         if Word_Of (Candidate) = Word then
            V := Candidate;
            Found := True;
         end if;
      end loop;
   end Verb_Named;

   Bearer : constant String := "Bearer x";

   function Send (V : Verb; URL : String) return Nuntius.Http.Response is
      Transport : Nuntius.Http.Curl.Curl_Transport;
      Result    : Nuntius.Http.Response;
   begin
      Nuntius.Http.Curl.Register;
      case V is
         when Get       =>
            Transport.Get (URL, Bearer, Result);

         when Delete    =>
            Transport.Delete (URL, Bearer, Result);

         when Json_Post =>
            Transport.Post_Json (URL, "{}", Bearer, Result);

         when Json_Put  =>
            Transport.Put_Json (URL, "{}", Bearer, Result);

         when Form_Post =>
            Transport.Post_Form (URL, "a=b", "Basic x", Result);
      end case;
      return Result;
   end Send;

   --  The path a recorded request asks for.
   Recorded_Path : constant String := "/ua";

   function Recorded_Get return Nuntius.Http.Response is
      Listen : GNAT.Sockets.Socket_Type;
      Port   : Natural;
      Result : Nuntius.Http.Response;
   begin
      Loopback_Capture.Listen_Loopback (Listen, Port);
      declare
         Srv : Loopback_Capture.Server;
      begin
         Srv.Serve (Listen);
         Result :=
           Send (Get, Loopback_Capture.Loopback_URL (Port, Recorded_Path));
      end;
      return Result;
   end Recorded_Get;

   type Client_Access is access Nuntius.Http.Fetch.Curl.Curl_Client;

   procedure Free is new
     Ada.Unchecked_Deallocation
       (Nuntius.Http.Fetch.Curl.Curl_Client,
        Client_Access);

   Client : Client_Access := new Nuntius.Http.Fetch.Curl.Curl_Client;

   --  The identity the crate set, before any feature changed it.
   Original_Agent : constant String := Nuntius.Http.User_Agent;

   function Async return not null access Nuntius.Http.Fetch.Curl.Curl_Client
   is (Client);

   procedure Renew_Client is
   begin
      Free (Client);
      Client := new Nuntius.Http.Fetch.Curl.Curl_Client;
      Nuntius.Http.Set_User_Agent (Original_Agent);
   end Renew_Client;

   --  Every request's transfer timeout: past any loopback answer.
   Timeout_Ms : constant := 2_000;

   function Request_For
     (Method : Nuntius.Http.Fetch.Method; URL : String)
      return Nuntius.Http.Fetch.Request
   is (Verb          => Method,
       URL           => To_Unbounded_String (URL),
       Content       =>
         To_Unbounded_String (if Method in Post | Put then "{}" else ""),
       Content_Type  =>
         To_Unbounded_String
           (if Method in Post | Put then "application/json" else ""),
       Authorization => To_Unbounded_String (Bearer),
       Timeout_Ms    => Timeout_Ms);

   --  How long Pump_Until_Done keeps at it: ten seconds of waits.
   Wait_Cycles : constant := 50;
   Wait_Ms     : constant := 200;

   procedure Pump_Until_Done
     (Done : out Nuntius.Http.Fetch.Completion; Got : out Boolean) is
   begin
      Done := (others => <>);
      Got := False;
      for K in 1 .. Wait_Cycles loop
         Client.Pump (Done, Got);
         exit when Got;
         Client.Wait (Wait_Ms, No_Extra_Fds);
      end loop;
   end Pump_Until_Done;

   procedure Recorded_Fetch
     (Done : out Nuntius.Http.Fetch.Completion; Got : out Boolean)
   is
      Listen : GNAT.Sockets.Socket_Type;
      Port   : Natural;
      Id     : Request_Id;
   begin
      Loopback_Capture.Listen_Loopback (Listen, Port);
      declare
         Srv : Loopback_Capture.Server;
      begin
         Srv.Serve (Listen);
         Client.Start
           (Request_For
              (Get, Loopback_Capture.Loopback_URL (Port, Recorded_Path)),
            Id);
         Pump_Until_Done (Done, Got);
      end;
   end Recorded_Fetch;

end Nuntius_World.Http;
