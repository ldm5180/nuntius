with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  The HTTP client port: the narrow set of shapes a REST-and-OAuth
--  application needs -- a form-encoded POST for token endpoints, and a
--  JSON POST / GET / DELETE with a Bearer token for the API proper.
--  Tests plug in a recording fake; production plugs in Nuntius.Http.Curl.
--  Keeping the port this narrow is what keeps every consumer test
--  offline.

package Nuntius.Http is

   type Transport is limited interface;

   --  Ok False means a transport-level failure (connect/TLS/timeout);
   --  Status and Reply are meaningful only when Ok is True.
   procedure Post_Form
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is abstract;

   --  A JSON POST with a Bearer token.  Location is the response's
   --  Location header -- empty when absent -- because some APIs return a
   --  created resource's id there, not in the (possibly empty) body.
   procedure Post_Json
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Location      : out Unbounded_String;
      Ok            : out Boolean)
   is abstract;

   --  A GET with a Bearer token.
   procedure Get
     (Self          : in out Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is abstract;

   --  A DELETE with a Bearer token.
   procedure Delete
     (Self          : in out Transport;
      URL           : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
      Ok            : out Boolean)
   is abstract;

end Nuntius.Http;
