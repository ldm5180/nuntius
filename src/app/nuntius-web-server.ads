--  The serving side's socket loop, deliberately thin: bind, listen,
--  then serve one connection at a time (Connection: close), polling the
--  listening fd so a stop request is noticed within a poll slice -- the
--  un-abortable-foreign-call rule means the loop must never park in
--  accept(2).  Parsing is the pure parent (Nuntius.Web); everything a
--  consumer decides -- which targets exist, what their payloads are,
--  where log lines go -- comes in as formals.  Handle is called once
--  per well-formed GET or POST and must call Respond exactly once; a
--  malformed head (400), a body over Max_Body_Bytes (413), a POST with
--  no Content-Length (400), a GET that brought a body (400) and any
--  other method (405) are all answered before it.  On_Listening
--  reports the BOUND port (port 0 requests an ephemeral one), so tests
--  and supervisors can find the server; production wiring may ignore
--  it.  The loop is no longer assumed to be loopback-only: a
--  whole-connection budget (Connection_Seconds) bounds what one peer
--  can hold, however it paces its bytes.  An upgrade request the
--  consumer accepts is answered 101 and handed to Adopt; the loop
--  never touches that socket again.  Coding_Policy decides whether a
--  client's offer of a coding is taken: gzip on a response body, and
--  permessage-deflate on an adopted socket, which Adopt is told.

with GNAT.Sockets;

with Nuntius.Codings;

generic
   with function Stop return Boolean;
   with procedure Sleep_Ms (Ms : Natural);
   with procedure Log_Info (Line : String);
   with procedure Log_Warn (Line : String);
   with procedure On_Listening (Port : Natural) is null;
   --  The whole-connection budget: a peer that has not delivered its
   --  head and body within this many seconds is dropped quietly,
   --  however it paces its bytes (the per-read IO timeout alone would
   --  let a dribble hold the serial loop for hours).
   Connection_Seconds : Natural := 10;
   --  Whether a coding the client offers is applied.  The default is
   --  every byte as before codings existed, so a consumer opts in.
   Coding_Policy : Nuntius.Codings.Policy := Nuntius.Codings.Identity_Only;
   --  Called once per well-formed GET or POST with the parsed head and
   --  the body: exactly R.Content_Length bytes for a POST, always ""
   --  for a GET (one with a body was answered 400 before this).  Must
   --  call Respond exactly once.
   with
     procedure Handle
       (R       : Request;
        Payload : String;
        Respond :
          not null access procedure
            (S : Status; Content_Type, Payload : String));
   --  Whether a well-formed upgrade request on this target is taken.
   --  True means the loop writes the 101 and calls Adopt with the
   --  request and the socket, which the consumer then OWNS -- the loop
   --  neither reads nor closes it again.  False means Handle answers
   --  it like any other GET.  Coding is what the 101 agreed, and what
   --  the consumer's peer must honour.  Adopt must not raise.
   with function Accepts_Upgrade (R : Request) return Boolean is Never_Upgrade;
   with
     procedure Adopt
       (R      : Request;
        Sock   : GNAT.Sockets.Socket_Type;
        Coding : Nuntius.Codings.Message_Coding) is null;
procedure Nuntius.Web.Server (Bind : String; Port : Natural);
