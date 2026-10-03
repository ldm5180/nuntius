# Feature tests plan

The crate's behavior, stated in Gherkin and run against the real
adapters over loopback sockets.  `*.feature` files under
`tests/features/` say what a transport does -- a refused dial reports
and never raises, a full ring drops the newest frame and keeps the
connection, a big body to a client that accepts gzip goes out gzipped
-- and a small Ada step registry on
[fabula](https://github.com/ldm5180/fabula) runs them, through the
same in-process peers the AUnit suite already stands up.  The unit
suite keeps the mechanism (a header byte, a ring index); the features
keep the contract (`CLAUDE.md` "Port contracts (do not break)",
stated once each, in the operator's words).

This is the second of a family: `fructus/docs/feature-tests-plan.md`
is the first, and its decisions carry over wherever this crate does
not say otherwise.  What is different here is the world: fructus
scripts its broker and its clock; nuntius IS the wire, so a feature
opens a real socket on 127.0.0.1, port 0, and nothing else.

## How to use this plan

Work the items in order; each is one TDD cycle (RED first, the exact
assertion given) and one commit, logged in `docs/tdd-log.md`.  F0 is
the dependency, F1 the wiring and F2 the world, with nothing of the
crate's behavior in them; F3-F8 are the six features of the first
wave, each lifted from named unit tests; F9 is the documentation.
After each item: `alr --non-interactive build --validation`,
`make test`, `make features`, `make format`.  Nothing in this plan
touches `src/`, so `make prove` is never owed by it.

Three decisions, taken up front:

- **Loopback is the seam.**  A feature's server is a real
  `Nuntius.Web.Server` instance bound to `127.0.0.1:0`; its websocket
  peer is a real `GNAT.Sockets` listener; its client is the real
  curl, native-ws or TCP adapter.  Nothing leaves the host, nothing
  depends on a port being free, and a scenario that opens a socket
  closes it in the `After` hook.  The proven core (`Nuntius.Web`'s
  parser, `Nuntius.Rfc6455`, `Nuntius.Frame_Fifo`) is driven
  directly only where that reads better than a socket would.
- **One test project, two mains.**  `tests/test_nuntius.gpr` gains
  `with "fabula"` and `nuntius_features.ads`; the step packages live
  in `tests/src/` beside `Loopback_Capture` and `Test_Payloads`, which
  they reuse.  `make format` already covers that directory.
- **Features lift, they do not copy.**  The web-server suite's
  `Cells`/`Serve`/`Exchange`/`Await_Port` and the native-ws suite's
  scripted `Server` task move into a shared `Nuntius_World`; the unit
  tests call them from there and keep every assertion they have.

### Do not

- Do not bind a fixed port.  Port 0 and `On_Listening` (or
  `Get_Socket_Name`) is how every loopback test here finds its peer,
  and it is why the suite has never flaked on a port.
- Do not reach past 127.0.0.1.  The examples (`example/src`) are the
  only things in this crate that talk to a real endpoint, and CI
  builds them without running them; the features are not a third
  path to the network.
- Do not let a scenario leave a task running.  Every server task is
  stopped through its `Stop` formal and joined (`'Terminated`) in the
  `After` hook; a feature binary whose scenarios leak tasks hangs at
  exit, where the suite's declare-block scoping could not.
- Do not restate a unit test's assertions line for line.  "a PUT
  answers 405" is a feature; "the status line is byte-identical to
  this golden" stays a unit test.
- Do not time a scenario on the idle limits of production.  The
  suite instantiates `Native_Client` at `Idle_Limit => 2.0` and
  `Poll_Slice => 0.25` so a silent partition is detected in seconds;
  the world instantiates the same way, and the two scenarios that
  wait out an idle limit are tagged `@slow`.
- Do not add fabula to `proof/proof.gpr`.  It is a test dependency;
  the proof tree sources `src/core` and withs nothing.
- Do not fix fabula's `-gnatwu` warning (`fabula-run.adb:258`, a GNAT
  15 false positive in a declare expression) from here.  Under the
  dependency profile it is a warning, and this crate builds clean
  with it under `--validation` (section 5).

## 1. What fabula is, in the terms this crate uses

A fabula binary is one instantiation of `Fabula.Main` over a
`Fabula.Registry` instance: an enumeration of step kinds, a table
mapping a Cucumber-expression pattern to a kind
(`Step ("a PUT answers {int}") >= Check_Status`), an enumeration of
hook kinds with its table, a `Context` record one scenario owns, and
two procedures -- `Execute (Kind, Ctx, Args, Frame, Outcome)` and
`Run_Hook`.  Checks record into an `Outcome` (`Fabula.Check.Ints.Equal`,
`Fabula.Check.Text_Equal`, `Fabula.Check.Is_True`, `Fail_Step`); a step
body that raises becomes a failed step and the run goes on, which is
the right reaction to a `Socket_Error` in a step.  Captures read
1-based (`Fabula.Args.Int`, `.Text`, `.Word`); a step's data table
reads as raw cells or as hashes.  The binary walks its paths sorted,
exits 1 on any failed scenario, and prints `N Scenarios (...)`.

fabula copies the `Context` once per step and keeps the copy only on
a normal return.  A socket handle copies fine; a task does not copy
at all.  So the context carries what a scenario reads back -- the
bound port, the last reply's text, the last reception, the loss
report -- and the servers, their `Cells` and the client instances
live at library level in `Nuntius_World`, reset by `Before` and
stopped by `After`.

Two fabula limits matter.  `Fabula.Limits.Max_Line_Length` is 2 048,
so a 2 280-byte JSON body cannot be a feature-file line: a step
generates it (`a {int}-row JSON body`, over `Test_Payloads.Json_Like`).
And `Max_Message_Length` is 512, so a failed check that quotes a whole
reply is truncated; a step quotes the status line, not the body.

## 2. Where things live

```
tests/
  features/
    web-server.feature         F3
    upgrade.feature            F4
    http-client.feature        F5
    websocket-client.feature   F6
    websocket-peer.feature     F7
    codings.feature            F8
    bytes/                     named sequences, one .hex per name (3.2)
  src/
    nuntius_features.ads       F1  the main: Fabula.Main instantiated
    nuntius_steps.ads/.adb     F1  Step_Kind, Hook_Kind, the tables, Execute
    nuntius_world.ads/.adb     F2  the loopback servers, peers and clients
    nuntius_web_server_tests.adb      loses the helpers F2 lifts
    nuntius_ws_native_client_tests.adb  loses its Server task
    loopback_capture.ads/.adb         unchanged
    test_payloads.ads/.adb            unchanged
  test_nuntius.gpr             F1  with "fabula"; a second main
```

The steps package grows one `Step_Kind` literal per pattern; past
about forty, split by feature under one registry, dispatching on
subtype ranges as fabula's own example does.

## 3. The step vocabulary

Every pattern, the kind it names, and what the body does.  Status
codes are written as numbers (`405`) and matched against
`Nuntius.Web.Status_Line`; headers are written as the wire spells
them.  A reply is kept whole in the context (`Last_Reply`), and every
"the reply ..." step reads it.

| Pattern | Kind | Body |
|---|---|---|
| `a serving loop on loopback` | `Start_Server` | `Serve ("127.0.0.1", 0)` on the world's task; `Await_Port` |
| `a serving loop that compresses when offered` | `Start_Gzip_Server` | the `Compress_When_Offered` instance |
| `a serving loop whose {word} target takes upgrades` | `Start_Stream_Server` | the `Accepts_Upgrade`/`Adopt` instance |
| `a serving loop with a 1-second connection budget` | `Start_Short_Server` | the `Connection_Seconds => 1` instance, the only budget the features use |
| `the client sends a {word} to {word}` | `Send_Request` | a well-formed head from method and target, sent at the first "Then" |
| `with header {string}` | `Add_Header` | appended to the pending head |
| `with the body {}` | `Add_Body` | the rest of the line as the body, and its `Content-Length` |
| `with the body arriving {int} ms later` | `Split_Body` | `Exchange`'s `Tail`/`Tail_Delay` |
| `the client sends {string}` | `Send_Raw` | the text as the request line, then the blank line; no escapes |
| `the client sends the lines:` + one-column table | `Send_Lines` | the rows joined by CRLF, then the blank line (section 3.2) |
| `the client sends the bytes named {word}` | `Send_Named_Bytes` | `tests/features/bytes/<name>.hex`, decoded, sent verbatim (section 3.2) |
| `the client sends half a head and hangs up` | `Send_Half` | `Exchange (..., Half_Head => True)` |
| `the client dribbles one byte every {int} ms` | `Send_Dribble` | the dribble writer the suite has |
| `the reply status is {int}` | `Check_Status` | `Has (Last_Reply, Status_Line (S))` by the number |
| `the reply carries {string}` | `Check_Carries` | substring of the reply |
| `the handler received {string}` | `Check_Carries` | the same check, read as the echo |
| `the reply carries no {word} header` | `Check_No_Header` | its absence |
| `the reply body is the gzip of the payload` | `Check_Gunzip` | `Test_Payloads.Gunzip (Body_Of (Last_Reply))` |
| `no reply arrives` | `Check_Silent` | `Last_Reply'Length = 0` |
| `the handler saw {int} request(s)` | `Check_Handled` | `Cells.Handled` |
| `the socket was adopted {word}` | `Check_Adopted` | `Cells.Adopted = 1` and `Kept_Coding` is `plain`/`deflated` |
| `a refused loopback port` | `Use_Refused` | `http://127.0.0.1:9/` |
| `the curl client {word}s {word}` | `Curl_Verb` | `Nuntius.Http.Curl` by verb; `Response` kept |
| `the response is a transport failure` | `Check_Failure` | `not Ok and then Status = 0` |
| `the request on the wire carried {string}` | `Check_Wire` | `Loopback_Capture.Head` |
| `the async client starts a {word}` | `Fetch_Start` | `Nuntius.Http.Fetch.Curl.Start`; the id kept |
| `the async client cancels it` | `Fetch_Cancel` | `Cancel (Id)` |
| `the async client pumps for {int} ms` | `Fetch_Pump` | `Pump`/`Wait` cycle to the deadline |
| `{word} completion(s) surfaced` | `Check_Completions` | `no`/`one` |
| `a scripted websocket peer that sends {string}` + table | `Start_Ws_Peer` | the lifted `Server` task, fed the frames the table lists |
| `the websocket client connects` | `Ws_Connect` | `Native_Client.Connect` to the peer's port; `Ok` kept |
| `the websocket client receives` | `Ws_Receive` | `Receive`; the `Reception` kept |
| `the websocket client receives with {int} ms patience` | `Ws_Receive_For` | `Receive_For` |
| `the reception is {word}` | `Check_Reception` | `Delivered`/`Expired`/`Lost` |
| `the message is {string}` | `Check_Message` | the delivered text |
| `the peer saw a pong` | `Check_Pong` | `Result.Pong_Seen` |
| `the losses report {int} dropped and {int} oversized` | `Check_Losses` | `Losses (C)` |
| `a websocket pair` | `Pair_Sockets` | `Pair (Browser, Served)`; the peer adopts `Served` |
| `the browser sends {string}` | `Browser_Text` | one masked text frame |
| `the browser sends a {word} frame` | `Browser_Control` | `ping`/`close`/`binary`/`rsv1`/`oversize` |
| `the peer pumps` | `Peer_Pump` | `Pump (Readable => True)`; the outcome kept |
| `the pump outcome is {word}` | `Check_Pump` | `Nothing`/`Message`/`Closed`/`Faulted` |
| `the browser reads a {word} frame` | `Check_Frame` | opcode of the next frame on the browser end, unmasked |
| `a {int}-row JSON body` | `Make_Json` | `Test_Payloads.Json_Like (N)` into the context |
| `{int} bytes of noise` | `Make_Noise` | `Test_Payloads.Noise (N)` |
| `gzipped and gunzipped it reads back` | `Check_Gzip_Trip` | `Deflate.Gzip` then `Test_Payloads.Gunzip` |
| `packed and unpacked it reads back` | `Check_Pack_Trip` | `Deflate.Pack` then `Deflate.Unpack` is `Done` |

### 3.1 The frame table

A scripted peer's script is a table, one frame per row, in the order
it sends them after the 101:

```gherkin
Given a scripted websocket peer that sends:
  | kind         | text   |
  | text         | hello  |
  | text-start   | foo    |
  | continuation | bar    |
  | ping         |        |
  | close        |        |
```

`kind` is one of `text`, `text-start`, `continuation`, `ping`,
`close`, `oversize` (a text frame past the client's bound), `rsv1`,
`burst N` (N tiny text frames in one write, the desync case) and
`bytes <name>` (a named sequence, section 3.2, for a frame no kind
spells).  An unknown kind fails the step with its name.  The peer
hangs up after its last row, as the suite's `Server` does.

### 3.2 Bytes that do not fit a line

Gherkin has no escape sequences: a cell or a quoted capture is the
characters as written, so a request that needs a CRLF cannot be a
`"..."` argument without a private `\r\n` convention that only one
step knows.  Three forms, chosen by what the reader should see:

- **An HTTP head is lines.**  `the client sends the lines:` takes a
  one-column table and joins the rows with CRLF, then the blank line.
  The reader sees the request as a browser would send it; the step
  owns the line endings.  Most scenarios need less than that:
  `Send_Request` + `Add_Header` + `Add_Body` compose the head from
  the sentence.

  ```gherkin
  When the client sends the lines:
    | GET /x HTTP/1.1    |
    | Content-Length: 5  |
  And with a 5-byte body
  ```

- **A websocket frame is a kind.**  The frame table's `kind` column
  (3.1) names every frame the first wave sends; the step encodes it
  with `Nuntius.Rfc6455`, which is what a browser does too.

- **Anything else is a named sequence on disk.**
  `tests/features/bytes/<name>.hex` holds one sequence as hex pairs,
  whitespace-separated, `#` to end of line a comment, and a step
  names it (`the client sends the bytes named half-head`; a frame
  row `bytes rsv1-fragment`).  A file per name rather than one JSON
  document of them, because this crate withs no JSON reader and a
  hand parser in test code would be a worse smell than the escapes
  were; because a `.hex` diff is reviewable where a `.bin` is not;
  and because the name is the file name, so a missing one fails the
  step by name.  fructus, which has `lector`, may keep its sequences
  in one JSON file under the same rule: the feature names the bytes,
  it never spells them.  The reader is `Nuntius_World.Named_Bytes
  (Name) return Rfc6455.Octets`, a dozen lines over `Ada.Text_IO`.

## 4. Items

### F0 -- fabula is a test dependency

- **Where:** `alire.toml:18` (`aunit`, the one existing test
  dependency), `:24` (`[[pins]]`, whose comment already states the
  rule: a consumer must pin the same `sml`).
- **What is wrong:** nothing runs a `.feature` file.
- **Why:** the suite is AUnit end to end.
- **Fix:** `fabula = "*"` after `aunit`, and under `[[pins]]`
  `fabula = { url = "https://github.com/ldm5180/fabula.git", commit = "746a234df5581c2e38c4202aeee8b07473fb6a51" }`
  with a comment in the house shape.  fabula pins `sml 3ccd0e4`,
  which is this crate's pin since the 2026-10-03 bump; Alire refuses
  two links to one crate at different commits, so that equality is
  the precondition and the comment at `:24` is where it is stated.
- **RED first:** `alr --non-interactive build --validation` with only
  the dependency line and no pin fails to resolve `fabula` (it is not
  in the community index); with the pin it builds, verified in
  section 5 at 2.1 s.

### F1 -- The feature binary builds and runs an empty feature

- **Where:** `tests/test_nuntius.gpr:1-2` (`with "aunit"; with
  "../nuntius.gpr";`) and `:16` (`for Main`); `alire.toml:47-62` (the
  four `[[actions]]` of type `test`); `Makefile:16-21` (`test:`),
  `:28-33` (`format:`, whose `tests/src/*.ad[sb]` glob covers the new
  packages); `.github/workflows/ci.yml:75` (the `alr test` step).
- **Fix:** `with "fabula";` beside `aunit` and
  `for Main use ("test_runner.adb", "nuntius_features.ads");` -- a
  generic instantiation is a SPEC, so the main is an `.ads`, as
  fabula's `example/src/box_main.ads` is.  `tests/src/nuntius_features.ads`
  instantiates `Fabula.Main` over `Nuntius_Steps`;
  `tests/src/nuntius_steps.ads/.adb` is a three-step registry whose
  `Before` hook resets the context; `tests/features/smoke.feature` is
  the one scenario.  Two more `[[actions]]` after the existing four,
  argv-only like them:
  `["alr", "exec", "--", "tests/bin/release/nuntius_features", "tests/features"]`
  and its `debug` twin; the gprbuild actions already build every main
  of the gpr.  A `features` target, because fabula exits 0 for a
  missing path and an empty file by design:

  ```make
  ## features    Build and run the Gherkin features in both modes
  features:
  	alr exec -- gprbuild -p -j0 -XMODE=debug -P tests/test_nuntius.gpr
  	alr exec -- gprbuild -p -j0 -XMODE=release -P tests/test_nuntius.gpr
  	@for mode in debug release; do \
  	  out=$$(alr exec -- tests/bin/$$mode/nuntius_features tests/features) || \
  	    { printf '%s\n' "$$out"; exit 1; }; \
  	  printf '%s\n' "$$out" | grep -qE '^[1-9][0-9]* Scenarios? \([0-9]+ passed\)$$' || \
  	    { printf '%s\n' "$$out"; echo "features: $$mode: a scenario did not pass"; exit 1; }; \
  	done; echo 'features: every scenario passed in both modes'
  ```

  The CI workflow needs no new step: `alr test` runs the actions.
- **RED first:** `make features` -- "No rule to make target".  Then,
  with the target and an empty step table, the smoke scenario's first
  step is `UNDEFINED` and the binary exits 1; the rows turn it green.
  The smoke scenario, verified in section 5:

  ```gherkin
  Feature: The feature runner runs
    Scenario: Bytes are counted
      Given nothing has been sent
      When 3 bytes are sent
      And 4 bytes are sent
      Then 7 bytes have been sent
  ```

### F2 -- The world: the loopback peers, shared

- **Where:** `tests/src/nuntius_web_server_tests.adb:36-179` (the
  protected `Cells`, spec and body), `:181-193` (`Stop`, `Sleep_Ms`,
  `Log_Quiet`, `On_Listening`), `:207-234` (`Handle`, the echo
  policy), `:286-339` (the five `Serve*` instances), `:357`
  (`Exchange`), `:473` (`Await_Port`), `:827-833` (`Body_Of`,
  `Get_With`, `Accepting`);
  `tests/src/nuntius_ws_native_client_tests.adb:30-35` (the `Ws`
  instance at `Idle_Limit => 2.0`), `:133` (`Result`), `:160-258`
  (the scripted `Server` task), `:310` (`Quiet_Server`);
  `tests/src/nuntius_ws_peer_tests.adb:34-56` (`Pair`), `:59-75`
  (`Browser_Text`, `Browser_Control`), `:78-109` (`Read_Some`,
  `Read_Frame`); `tests/src/loopback_capture.ads` (unchanged, used as
  is).
- **What is wrong:** three suites each stand up their own loopback
  peer, and none of it is reachable from a second binary.
- **Why:** each suite was written for one adapter.
- **Fix:** `tests/src/nuntius_world.ads/.adb` holds them with the
  same names, plus what a feature needs and the suites did not: a
  `Reset` the `Before` hook calls (`Cells.Reset`, a fresh `Result`, the
  context's replies cleared) and a `Stop_All` the `After` hook calls
  (`Cells.Request_Stop`, then wait on each server task's
  `'Terminated`, bounded by a few seconds, then close any socket a
  scenario left open).  The scripted ws peer takes its frames from a
  list rather than the fixed hello/foo/bar/ping sequence, so the
  suite's `Test_Loopback` becomes one row set and `Test_Burst`,
  `Test_Oversized_Is_Reported` and `Test_Rsv1_Is_Fatal` other row
  sets.  The server tasks become task TYPES with a `Serve` entry, as
  `Loopback_Capture.Server` already is, so a scenario can start one
  and the hook can see it end.
- **RED first:** the web-server suite, its helper bodies removed and
  `with Nuntius_World;` added, fails to compile on the first missing
  name (`Exchange`); green when `make test` passes both modes with no
  assertion changed.

### F3 -- `web-server.feature`: the serving loop

- **Where:** `tests/src/nuntius_web_server_tests.adb:489-614`
  (`Test_Loopback`), `:620` (`Test_Dribble_Is_Dropped`).
- **What is wrong:** the loop's nine answers -- 200 through the Handle
  seam, 405, 400 three ways, 413, two quiet drops, a split body -- are
  nine `Assert` messages in one 125-line test.
- **Why:** it was written as "the coverage the mechanics never had".
- **Fix:** the first feature, one scenario per answer, each title
  the sentence the unit test's `Assert` message was reaching for.  No
  scenario spells a wire byte: the head is composed from the sentence
  (section 3.2), and the one raw send is a word.

  ```gherkin
  Feature: The serving loop answers every request it is sent

    Background:
      Given a serving loop on loopback

    Scenario: A GET reaches the handler with an empty payload
      When the client sends a GET to /x
      Then the reply status is 200
      And the handler received "hi:GET:/x:"

    Scenario: A method that is neither GET nor POST is refused, not misread
      When the client sends a PUT to /x
      Then the reply status is 405
      And the reply carries "method not allowed"

    Scenario: A malformed request line is refused
      When the client sends "garbage"
      Then the reply status is 400

    Scenario: A GET that brought a body is refused unread
      When the client sends a GET to /x
      And with the body abcde
      Then the reply status is 400
      And the reply carries "no body on GET"

    Scenario: A POST with no length is refused
      When the client sends a POST to /api/close
      Then the reply status is 400
      And the reply carries "length required"

    Scenario: A body over the cap is refused before it is read
      When the client sends a POST to /api/close
      And with header "Content-Length: 5000"
      Then the reply status is 413
      And the reply carries "body too large"

    Scenario: A JSON POST reaches the handler with its body
      When the client sends a POST to /api/close
      And with header "Content-Type: application/json"
      And with the body {"scope":"all"}
      Then the reply status is 200
      And the handler received "hi:POST:/api/close:{"

    Scenario: A body that arrives in a second write still reaches the handler
      When the client sends a POST to /api/close
      And with the body {"scope":"all"}
      And with the body arriving 200 ms later
      Then the reply status is 200
      And the handler saw 1 request

    Scenario: Half a head, then a hangup, is dropped quietly
      When the client sends half a head and hangs up
      Then no reply arrives
      And the handler saw 0 requests

    @slow
    Scenario: A dribble is ended by the connection budget
      Given a serving loop with a 1-second connection budget
      When the client dribbles one byte every 300 ms
      Then no reply arrives
      And the handler saw 0 requests
  ```

  A composed request is sent when the first "Then" step runs, so
  the `with ...` steps can keep adding to it; the context carries
  the pending head and the flag that it went.
- **RED first:** `make features` reports `a serving loop on loopback`
  `UNDEFINED`; each row turns one step green, in the order the
  Background and the first scenario read.  The requests and the
  expected texts are `Test_Loopback`'s own.

### F4 -- `upgrade.feature`: a websocket upgrade is adopted or refused

- **Where:** `tests/src/nuntius_web_server_tests.adb:685`
  (`Test_Upgrade_Is_Adopted`), `:744` (`Test_Upgrade_Refused_Reaches_Handle`),
  `:780` (`Test_Plain_Get_On_Stream_Path`), `:992` (`Test_Upgrade_Deflate`).
- **What is wrong:** that the loop answers 101 and hands the socket
  over exactly once, that a refused upgrade reaches `Handle` (503
  here, 426 for a plain GET on the stream path), and that a
  `permessage-deflate` offer is answered with no context takeover,
  are the contract fructus's dashboard stream stands on
  (`docs/web-stream-plan.md` WP-N5) and are stated only in the suite.
- **Fix:** four scenarios over `Start_Stream_Server`: the four
  upgrade headers get 101 and `the socket was adopted plain`; the
  same with `Sec-WebSocket-Extensions: permessage-deflate` gets
  `adopted deflated` and the reply carries
  `permessage-deflate; server_no_context_takeover; client_no_context_takeover`;
  an upgrade to a target the consumer declines gets 503 through
  `Handle`; a plain GET on the stream path gets 426 carrying
  `Upgrade: websocket`.
- **RED first:** `a serving loop whose /api/stream target takes
  upgrades` is `UNDEFINED`; green on the 101 and the adoption count.

### F5 -- `http-client.feature`: the curl adapters never raise

- **Where:** `tests/src/nuntius_http_curl_tests.adb:71`
  (`Test_User_Agent_On_The_Wire`), `:101` (`Test_Refused_Connection`);
  `tests/src/nuntius_http_fetch_curl_tests.adb:129-303` (`Test_Empty_Pump`
  through `Test_Wait_Drives_A_Transfer`).
- **What is wrong:** "a transport failure is `Ok` False and `Status`
  0 on every verb, never an exception" is the port contract
  `CLAUDE.md:130-132` lists, asserted once per verb in prose nobody
  reads as a list.
- **Fix:** an outline over the five verbs against the refused port
  (`Use_Refused`, `Curl_Verb`, `Check_Failure`); one scenario that
  the default identity reaches the wire (`Loopback_Capture`,
  `Check_Wire` with `User-Agent: nuntius/`); and the async client's
  four: an idle client pumps nothing, a cancelled transfer never
  surfaces, a refused transfer surfaces as a failure through the
  pump/wait cycle in under three seconds, and the in-flight table is
  bounded (`Fetch_Start` until `No_Request`).
- **RED first:** `the curl client GETs a refused loopback port` is
  `UNDEFINED`; green on `not Ok and then Status = 0`.

### F6 -- `websocket-client.feature`: the port contracts

- **Where:** `tests/src/nuntius_ws_native_client_tests.adb:96-126`
  (`Test_Unconnected`, `Test_Refused_Dial`), `:260-301`
  (`Test_Loopback`), `:439` (`Test_Receive_For_Idle_Persists`), `:553`
  (`Test_Burst`), `:840` (`Test_Oversized_Is_Reported`), `:931`
  (`Test_Ring_Overflow_Is_Reported`); `CLAUDE.md:119-132`.
- **What is wrong:** the four "do not break" contracts are the most
  important sentences in the crate and live in `CLAUDE.md`, where no
  gate reads them.
- **Why:** they were written as a reviewer's checklist.
- **Fix:** one feature, one scenario per contract, each over a
  scripted peer (section 3.1): a refused dial reports and is
  reusable; the handshake, one message, a fragmented message
  reassembled, a ping auto-ponged, and the peer's close as `Lost`; a
  burst of 100 tiny frames in one write all arrive in order; a
  burst into a ring of four reports dropped frames and KEEPS the
  connection (`the losses report 36 dropped and 0 oversized`, then
  another receive is `Delivered`); an oversize frame is `Lost` and
  counted; `@slow`, a stream silent past the idle limit is `Lost`
  even across patient receives, and a patient receive on a quiet
  line is `Expired`, not `Lost`.
- **RED first:** `a scripted websocket peer that sends:` with the
  hello/foo/bar/ping/close table is `UNDEFINED`; green on
  `the message is "hello"`.

### F7 -- `websocket-peer.feature`: the server side of a socket

- **Where:** `tests/src/nuntius_ws_peer_tests.adb:197`
  (`Test_Ping_Is_Ponged`), `:220` (`Test_Close_Is_Echoed`), `:245-291`
  (the three `*_Faults`), `:398-424` (`Test_Packed_Inbound*`), `:456`
  (`Test_Eof_Is_Closed`), `:473` (`Test_Send_Text_Unmasked`).
- **What is wrong:** what a browser gets back -- unmasked frames, a
  pong, an echoed close, a close code for anything binary,
  fragmented, oversize or RSV1 -- is the whole of what the dashboard
  can rely on, stated as frame bytes.
- **Fix:** scenarios over `Pair_Sockets`: the peer's text is
  unmasked (`the browser reads a text frame`); a ping is ponged; a
  close is echoed and the peer is closed; each of binary, RSV1 and
  oversize is `Faulted` and the browser reads a close frame; a packed
  message on a `deflated` peer unpacks (`Check_Message`), and a
  corrupt one is `Faulted`.  The corrupt packed message is the first
  named sequence (`tests/features/bytes/corrupt-deflate.hex`): no
  frame kind spells "deflate that is not deflate", and the bytes
  are the point.
- **RED first:** `a websocket pair` is `UNDEFINED`; green on the pong.

### F8 -- `codings.feature`: gzip when offered, deflate when adopted

- **Where:** `tests/src/nuntius_web_server_tests.adb:837-990`
  (`Test_Gzip_Responses`), `tests/src/nuntius_deflate_tests.adb:17-92`.
- **What is wrong:** the floor (512 bytes), the text-likeness test,
  the `Vary` header and the packed `Content-Length` are the four
  rules a page's size depends on, asserted in one 150-line test.
- **Fix:** over `Start_Gzip_Server`: a 60-row JSON body to a client
  offering gzip goes out `Content-Encoding: gzip` with
  `Vary: Accept-Encoding` and the body is the gzip of the payload; the
  same body to a client offering nothing goes plain; a 100-byte body
  stays plain (the floor); an `image/png` body stays plain; the
  default server ignores the offer.  Two round-trip scenarios on
  `Nuntius.Deflate` directly: a 60-row body gzips and reads back;
  noise packs and unpacks.
- **RED first:** `a serving loop that compresses when offered` is
  `UNDEFINED`; green on the `Content-Encoding` header.

### F9 -- The docs say so

- **Where:** `CLAUDE.md:17-28` ("Commands"), `:63` (the `tests/`
  layout line), `:82-94` ("TDD protocol", whose last bullet reads
  "Tests stay off the network: adapter tests use loopback
  connection-refusals only"); `README.md:92` ("Develop").
- **What is wrong:** the off-the-network rule as written forbids the
  loopback servers the suite has run since the serving side arrived,
  and says nothing about features.
- **Fix:** a `make features` line in both; the layout line names
  `tests/features/` and `nuntius_features.ads`; the TDD bullet
  becomes "Tests stay off the network: loopback only, port 0, never a
  fixed port, never a real endpoint -- adapter tests and features
  alike".

## 5. Verified in a scratch worktree (iteration 3)

Against the tree at `97ebb6a7`, in a detached worktree under the
session scratchpad, GNAT 15.2.0, gprbuild 26.0.1, 2026-10-03:

1. `fabula = "*"` pinned at `746a234` beside `aunit`:
   `alr --non-interactive build --validation` succeeds in 2.1 s, no
   pin conflict -- this crate's `sml` is already fabula's.  fabula
   compiles under the dependency profile with its `-gnatwu` line as
   a warning.
2. The F1 sketch typed in: `with "fabula"`, the second main,
   `nuntius_steps.ads/.adb` (three steps, one hook),
   `tests/features/smoke.feature`.  `gprbuild -P tests/test_nuntius.gpr`
   builds both mains and the run prints `1 Scenario (1 passed) /
   4 Steps (4 passed)`, exit 0.  One correction came from the typing:
   a conditional expression over fabula's discriminated `Read` does
   not type; a step reads a capture in its own arm.
3. Not verified here, and the reason it is F2's RED: that a server
   task started from a step and stopped from a hook ends cleanly.
   The suite always scoped its tasks in a declare block; the world's
   task types with `'Terminated` are the design, and the first
   scenario of F3 is where it is proved.

## 6. The second wave, sketched

- **The event-loop primitives** (`Nuntius.Fd_Poll`, `Nuntius.Fd_Wake`):
  "a signalled wake fd ends the wait", "a drained one is quiet", over
  the suite at `tests/src/nuntius_fd_poll_tests.adb`.
- **The raw TCP adapter** (`Nuntius.Tcp.Native`): the echo, partial
  reads, and the idle limit, over its suite's loopback echo server.
- **The TLS client** (`Nuntius.Ws.Aws_Client`): only its offline
  refusals, as now; a `wss://` loopback needs a certificate the repo
  does not hold.
- **The proven parser** (`Nuntius.Web.Parse_Request`): an outline of
  request lines to parsed methods and targets, if the proof's
  contracts ever stop reading as the better statement.

## Revision notes

- **Iteration 1 (draft):** the seam, the layout, the step table, ten
  items, a second wave -- the fructus plan's shape with the world
  replaced.
- **Iteration 2 (as a newcomer):** added the three up-front
  decisions and the "Do not" list, section 1 with the two fabula
  limits that bite here (a 2 280-byte body is not a feature line; a
  512-byte failure message does not hold a reply), the frame table
  (3.1), a full Gherkin sketch for F3 and the Makefile for F1, the
  `@slow` tag for the two idle-limit scenarios, and a RED per item.
  Made the task lifecycle an explicit item of F2 after noticing the
  suite only ever scoped its server tasks in declare blocks.
- **Iteration 3 (against the tree at `97ebb6a7`, and the scratch
  builds of section 5):** every `file:line` re-located.  Corrected:
  the F1 main was first sketched as `.adb`; the smoke step body as
  first typed did not compile (section 5, item 2); the `[[actions]]`
  span is `47-62`; `Exchange` is at 357 and `Await_Port` at 473, not
  adjacent; `Cells` is spec AND body, `36-179`, where the draft cited
  the spec alone; `Handle` is `207-234`; the five `Serve*` instances
  span `286-339`; the ws `Server` task is `160-258`, `Quiet_Server`
  starts at 310 and the offline tests end at 126; `Pair` is `34-56`
  and the browser helpers `59-75`/`78-109`; the fetch tests run to
  303; the port contracts are `CLAUDE.md:119-132` (the file's last
  line).  Confirmed: `aunit` at `alire.toml:18`,
  `[[pins]]` at `:24`, `for Main` at `tests/test_nuntius.gpr:16`,
  `test:` at `Makefile:17`, the CI test step at `ci.yml:75`, the
  off-the-network bullet at `CLAUDE.md:92`, the port contracts at
  `CLAUDE.md:119`.
- **After review (2026-10-03):** F3 was an outline whose Examples
  cells held `\r\n`-escaped request strings, a private wire syntax
  Gherkin does not have and only one step would know.  Replaced by
  one scenario per answer, the head composed from the sentence; added
  section 3.2 (lines table for a head, the frame kind for a frame, a
  named `.hex` sequence on disk for anything else -- a file per name
  rather than one JSON document, since this crate withs no JSON
  reader), the `bytes/` directory, the `bytes <name>` frame kind, and
  F7's first named sequence.
- **During F3 (2026-10-03):** fabula's `{string}` is double-quoted
  only, so a JSON body cannot be a quoted capture; `with the body {}`
  takes the rest of the line verbatim instead of `with a {int}-byte
  body`.  The 413 scenario sends `Content-Length: 5000` and no body --
  the claim is what the loop refuses, as the unit test always sent
  it.  The connection-budget step names the one budget that exists.
