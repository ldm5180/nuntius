with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

--  The HTTP client port: the narrow set of shapes a REST-and-OAuth
--  application needs -- a form-encoded POST for token endpoints, and a
--  JSON POST / PUT / GET / DELETE with a Bearer token for the API
--  proper.  Tests plug in a recording fake; production plugs in
--  Nuntius.Http.Curl.  Keeping the port this narrow is what keeps every
--  consumer test offline.
--
--  Narrow is not the same as minimal.  Each verb here earns its place by
--  being a shape a REST API actually requires rather than prefers: PUT
--  is here because an idempotent REPLACE of an existing resource cannot
--  be expressed as a POST without changing what the server does with it,
--  and an application that had to fall back to delete-then-create would
--  be trading an atomic operation for a race.

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

   --  A JSON PUT with a Bearer token: replace an existing resource.
   --
   --  It returns no Location, and that asymmetry with Post_Json is the
   --  point rather than an oversight -- a PUT names the resource in its
   --  own URL, so there is no created-resource location for the server
   --  to report.  What a replacement's response body says about it is
   --  the caller's to read.
   procedure Put_Json
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Status        : out Natural;
      Reply         : out Unbounded_String;
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
