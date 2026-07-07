--  Production transport over libcurl (utilada_curl).  All libcurl
--  specifics stay behind this one unit -- including backend registration,
--  so consumers never with Util.*.

package Nuntius.Http.Curl is

   --  Register the libcurl backend with utilada.  The composition root
   --  must call this exactly once before the first request on any
   --  Curl_Transport.
   procedure Register;

   type Curl_Transport is limited new Transport with null record;

   overriding
   procedure Post_Form
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean);

   overriding
   procedure Post_Json
     (Self          : in out Curl_Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Location      : out Unbounded_String;
      Ok            : out Boolean);

   overriding
   procedure Get
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean);

   overriding
   procedure Delete
     (Self          : in out Curl_Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean);

end Nuntius.Http.Curl;
