--  The serving side's socket loop, deliberately thin: bind, listen,
--  then serve GET requests one connection at a time (Connection:
--  close), polling the listening fd so a stop request is noticed
--  within a poll slice -- the un-abortable-foreign-call rule means the
--  loop must never park in accept(2).  Parsing is the pure parent
--  (Nuntius.Web); everything a consumer decides -- which targets
--  exist, what their payloads are, where log lines go -- comes in as
--  formals.  Handle is called once per well-formed GET and must call
--  Respond exactly once; malformed heads (400) and non-GET methods
--  (405) are answered before it.  On_Listening reports the BOUND port
--  (port 0 requests an ephemeral one), so tests and supervisors can
--  find the server; production wiring may ignore it.

generic
   with function Stop return Boolean;
   with procedure Sleep_Ms (Ms : Natural);
   with procedure Log_Info (Line : String);
   with procedure Log_Warn (Line : String);
   with procedure On_Listening (Port : Natural) is null;
   with
     procedure Handle
       (Target  : String;
        Respond :
          not null access procedure
            (S : Status; Content_Type, Payload : String));
procedure Nuntius.Web.Server (Bind : String; Port : Natural);
