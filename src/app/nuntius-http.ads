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

   --  The User-Agent every adapter puts on every request.  libcurl --
   --  unlike the curl CLI -- sends none unless told to, and some API
   --  edges (Tastytrade's production nginx, for one) refuse a request
   --  without one with an HTML 401 before the application ever sees
   --  it, so a missing header looks exactly like a dead credential.
   --  The default names this crate; a composition root registers its
   --  program's identity once, before any task activates, because this
   --  is plain package state read by every adapter at request time.
   function User_Agent return String;

   procedure Set_User_Agent (Value : String)
   with Pre => Value'Length > 0, Post => User_Agent = Value;

   --  One exchange's outcome.  Ok False is a transport-level failure
   --  (connect, TLS, timeout), and then Status is 0 and Reply empty;
   --  Status and Reply are the server's only when Ok is True.  Location
   --  is the response's Location header, empty when absent -- some APIs
   --  return a created resource's id there, not in the body.
   type Response is record
      Ok       : Boolean := False;
      Status   : Natural := 0;
      Reply    : Unbounded_String;
      Location : Unbounded_String;
   end record;

   --  The 2xx statuses: a request the server carried out.
   subtype Success_Status is Natural range 200 .. 299;

   --  Whether R is a carried-out request: the exchange held and the
   --  server answered 2xx.
   function Succeeded (R : Response) return Boolean
   is (R.Ok and then R.Status in Success_Status);

   type Transport is limited interface;

   --  Ok False means a transport-level failure (connect/TLS/timeout);
   --  Status and Reply are meaningful only when Ok is True.
   procedure Post_Form
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is abstract;

   --  A JSON POST with a Bearer token, and the one verb whose Result
   --  carries the Location header: some APIs return a created
   --  resource's id there, not in the (possibly empty) body.
   procedure Post_Json
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is abstract;

   --  A JSON PUT with a Bearer token: replace an existing resource.
   --
   --  Its Result has no Location, and that asymmetry with Post_Json is the
   --  point rather than an oversight -- a PUT names the resource in its
   --  own URL, so there is no created-resource location for the server
   --  to report.  What a replacement's response body says about it is
   --  the caller's to read.
   procedure Put_Json
     (Self          : in out Transport;
      URL           : String;
      Content       : String;
      Authorization : String;
      Result        : out Response)
   is abstract;

   --  A GET with a Bearer token.
   procedure Get
     (Self          : in out Transport;
      URL           : String;
      Authorization : String;
      Result        : out Response)
   is abstract;

   --  A DELETE with a Bearer token.
   procedure Delete
     (Self          : in out Transport;
      URL           : String;
      Authorization : String;
      Result        : out Response)
   is abstract;

end Nuntius.Http;
