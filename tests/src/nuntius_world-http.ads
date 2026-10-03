with Nuntius.Http;
with Nuntius.Http.Fetch;
with Nuntius.Http.Fetch.Curl;

--  The HTTP clients as the features drive them: the curl transport by
--  verb, a recording loopback peer, and one async client per scenario.
--  Nothing here reaches past 127.0.0.1.

package Nuntius_World.Http is

   --  Port 9 (discard) on loopback: as close to guaranteed-refused as it
   --  gets without a network.
   Refused_URL : constant String := "http://127.0.0.1:9/";

   --  The curl transport's verbs, by the words the features use: GET,
   --  DELETE, JSON-POST, JSON-PUT, form-POST.
   type Verb is (Get, Delete, Json_Post, Json_Put, Form_Post);

   --  The verb a feature's word names; Found False for any other word.
   procedure Verb_Named (Word : String; V : out Verb; Found : out Boolean);

   --  V to URL over the curl transport.
   function Send (V : Verb; URL : String) return Nuntius.Http.Response;

   --  A GET over the curl transport to a loopback peer that records the
   --  request head (Loopback_Capture.Head) and answers 200.
   function Recorded_Get return Nuntius.Http.Response;

   --  The same through the async client, pumped to completion.
   procedure Recorded_Fetch
     (Done : out Nuntius.Http.Fetch.Completion; Got : out Boolean);

   --  The scenario's async client, fresh from Renew_Client.
   function Async return not null access Nuntius.Http.Fetch.Curl.Curl_Client;

   --  Drop the async client, finalizing every transfer it held, and
   --  make a fresh one; and put the User-Agent back as the crate set it.
   procedure Renew_Client;

   --  A request of Method to URL, as the suite's own requests are.
   function Request_For
     (Method : Nuntius.Http.Fetch.Method; URL : String)
      return Nuntius.Http.Fetch.Request;

   --  Pump and wait until a completion surfaces, for at most ten
   --  seconds; Got False when none did.
   procedure Pump_Until_Done
     (Done : out Nuntius.Http.Fetch.Completion; Got : out Boolean);

end Nuntius_World.Http;
