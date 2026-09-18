# Plan: the dashboard streams over one websocket (`web-stream`)

Status: EXECUTED 2026-09-18 on branch `web-stream` in all three repos
-- nuntius `9640aa24`, fructus `dd834603`, arb-ada `3382bb5`, pushed in
that order, none merged.  The bases were the `web-*` tips as the
paragraph below says, resolved to nuntius `origin/main` (a merge of
`web-post` with a zero content diff) and fructus
`origin/web-day-chart-rebased` (identical content to `web-day-chart`,
on top of today's `main`).  Section 7 was walked against a running
binary; item 7 (Tailscale Serve/Funnel) stays open -- see section 10.
Two deliberate departures from the text: `Nuntius.Rfc6455.Decode`
widened from a 16-bit length cap to `Natural'Last` on the 64-bit form,
because WP-N4's own 70_000-byte round trip needs it; and
`Fructus.Web.Auth.Note_Refusal` grew a `Label` so D21's "the two
tasks' lines read apart" holds for the shared refusal line too.

Written 2026-09-18, iteration 3 of 3 (two
adversarial review rounds folded in: Ada-side reviewers compiled the
sketches with the Alire GNAT 15.2.1 toolchain and measured them with
fructus's `tools/fructustools/shape_check.py`; frontend reviewers ran
the toolchain in a scratch copy of `ui/` under node and jsdom and
probed TanStack, zod, jsdom and Node's `WebSocket` empirically;
findings marked [R1]/[R2]). Every `file:line` below was verified on
2026-09-18 against fructus `b24353a6` (branch `web-day-chart`, 34
commits ahead of `main`, which is contained in it), nuntius `2755761`
(branch `web-post`, the commit fructus pins) and arb-ada `d88da04`
(branch `web-day-chart`). If a file has drifted, re-locate by the named
subprogram or export, not the line.

**The branches start from the `web-*` tips, not `main`.** arb-ada's
fructus pin is a `web-day-chart` commit and fructus's nuntius pin is a
`web-post` commit; a branch cut from either `main` would drop the
bearer gate, the close route, the sign-in form and the day chart from
the arb binary. `git worktree add -b web-stream <dir> web-post` in
nuntius, `git worktree add -b web-stream <dir> web-day-chart` in
fructus.

This file is committed in THREE repos as `docs/web-stream-plan.md`:
arb-ada (where it was written), fructus (the canonical copy once the
fructus branch exists) and nuntius (sections 4 and 6 are what matter
there, but the whole file travels). Section 4 is nuntius work, section
5 is fructus work, section 5b is arb-ada work and runs after both
branches are pushed.

Table of contents

- 0. The idea in one paragraph
- 1. What already exists (read these before writing anything)
- 2. Design decisions (the why, so nobody "fixes" them later)
- 3. The wire contract: `GET /api/stream`
- 4. Work packages, nuntius (WP-N1 .. WP-N6)
- 5. Work packages, fructus (WP-F0 .. WP-F9)
- 5b. Work packages, arb-ada (WP-B)
- 6. TDD order (the RED that starts each package)
- 7. Verification checklist
- 8. Failure modes (design them in, then test them)
- 9. Deliberately out of scope
- 10. Open items
- Execution prompt

---

## 0. The idea in one paragraph

Today the dashboard POLLS: `@tanstack/react-query` re-fetches
`/api/positions` once a second, `/api/schedule` every 5 s,
`/api/series` every 15 s and `/api/stats` every 10 s on the health
page, and every one of those is a fresh TCP connection (and, through
the Tailscale proxy, a fresh TLS handshake) because the Ada server is a
serial `Connection: close` loop. This plan replaces the polls with ONE
websocket per open page: the browser upgrades `GET /api/stream`, sends
its bearer token as the first frame, and from then on the server PUSHES
each document the moment its publisher changed it, paced per document
so the byte volume never exceeds today's polling. The documents on the
wire are byte-identical to the GET documents, wrapped in a one-key
envelope, so every zod schema, every component and every golden stays
as it is; the GET routes remain for `curl`, the Alloy `/metrics`
scrape and as the page's automatic FALLBACK whenever the socket is not
open. The server side splits into the existing serial HTTP task, which
performs the upgrade handshake and hands the socket over, and a new
stream task that owns at most eight adopted sockets, waits on them and
on an eventfd the publishers signal, and writes unmasked RFC 6455 text
frames. The frame header, the upgrade parsing and the handshake head
are pure and proved in nuntius; the socket mechanics live in nuntius's
shell; the documents, the pacing table, the auth and the task are
fructus; arb-ada repins and declares the task.

---

## 1. What already exists (read these before writing anything)

Paths are relative to `~/git/fructus` unless prefixed `nuntius/` or
`arb-ada/`. On this box the pinned sources are also under
`arb-ada/alire/cache/pins/fructus_b24353a6/` and
`arb-ada/alire/cache/pins/nuntius_27557618/`.

| What | Where | Notes |
|---|---|---|
| The polls | `ui/src/api/queries.ts:15-27` (`LIVE_MS 1000`, `HIDDEN_MS 5000`, `HEALTH_MS 10000`, `SCHEDULE_MS 5000`/`30000`, `SERIES_MS 15000`/`60000`), `:36-45` (`usePositions`: `refetchInterval` as a function of `document.hidden`, `refetchIntervalInBackground: true`, `retry: false`), `:47-54` (`useStats`: a CONSTANT `HEALTH_MS`, `refetchIntervalInBackground: false`), `:56-64` (`useSchedule`), `:66-73` (`useSeries`), `:79-85` (`useClose`, the one mutation; `onSettled` at `:83` invalidates `["positions"]`) | The answer to "is it polling": yes, four timers. The hooks are what every component reads, and they stay. |
| The fetch | `ui/src/api/client.ts:15` (`TIMEOUT_MS = 6000`, "every response carries Connection: close, so each poll pays a fresh TCP and TLS handshake"), `:32-44` (`fetchJson`: bearer via `authHeaders (readToken ())`, `HttpError` on non-2xx), `:48-64` (`postJson`) | The stream reuses `HttpError` for nothing; its refusal is a close code. |
| The app root | `ui/src/App.tsx:27-32` (the three queries, once for the whole app), `:46-48` (the `signedOut` latch: SET by a 401 on the positions poll at `:47`, CLEARED by `positions.isSuccess` at `:48`), `:58` (`refused = signedOut && token !== ""`), `:60-63` (`signOut`: clears the token, `void queryClient.invalidateQueries ()`), `:85-86` (`updatedAt={positions.dataUpdatedAt}` `error={positions.error}` into `Shell`), `:92-98` (`SignIn`; `onSubmit` at `:94-97`: `setToken`, `invalidateQueries ()`), `:105-112` (`<PositionsPage doc sched series ...>`), `:122` (`<HealthPage />`) | The stream hook mounts HERE, once, beside the queries. `main.tsx:17` wraps `<App />` in `<StrictMode>`: effects mount twice in dev (D9's identity guard is why that is harmless). |
| The token store | `ui/src/lib/token.ts:36-42` (`readToken ()` reads `localStorage["fructus.token"]` at call time), `:48-61` (`useToken ()`, a `useSyncExternalStore` store), `ui/src/lib/auth.ts` (`isUnauthorized`, `authHeaders`), `ui/src/api/queries.ts:29-35` (the rule: "the client reads it from the store at the moment of the request") | The stream sends `readToken ()` at open, the same rule. |
| The connection dot | `ui/src/components/ConnectionDot.tsx:10` (`AMBER_MS = 3000`), `:19-20` (`age = useNow (1000) - updatedAt`; red on `error`, amber past 3 s, green under) | [R1, verified against query-core 5.102.8] `setQueryData` stamps `dataUpdatedAt = Date.now ()`, nulls `error` and makes `isSuccess` true, so the dot and the `App.tsx:48` latch clear work unchanged over the stream. The positions heartbeat (D6) is sized under `AMBER_MS`. |
| Vite | `ui/vite.config.ts:9` (`outDir: "../web"`, `chunkSizeWarningLimit: 1024` -- Vite's kB is 1000 bytes, so the warning line is 1_024_000 bytes), `:10` (`server: { proxy: { "/api": "http://127.0.0.1:9321" } }`), `:11` (`test.environment: "node"`), `ui/scripts/check-size.mjs:5` (2 MiB per asset) | The dev proxy needs `ws: true` for the upgrade. No new npm dependency: `WebSocket` is a browser global. Bundle today `web/assets/index-B52C5VGP.js` = 1_011_778 bytes; [R1] with the three new modules it measured 1_013_369, about 10.6 kB under the warning line. |
| Tests, UI | `ui/src/components/DayChart.dom.test.tsx:1` (`// @vitest-environment jsdom`, `@testing-library/react`), `ui/src/App.test.tsx` (`vi.stubGlobal` for `fetch`), `ui/src/api/schema.test.ts` (parses the Ada goldens through zod), `ui/src/lib/testGoldens.ts` | The hook test runs under jsdom with a fake `WebSocket` installed by `vi.stubGlobal`; jsdom's origin is `http://localhost:3000`; `document.hidden` is a getter-only accessor there. TanStack schedules NO intervals under node (`isServer`), so every polling assertion is a jsdom test. |
| The HTTP loop | `nuntius/src/app/nuntius-web-server.ads:1-16` (the paragraph), `:18-40` (generic formals: `Stop`, `Sleep_Ms`, `Log_Info`, `Log_Warn`, `On_Listening is null`, `Connection_Seconds : Natural := 10`, `Handle (R, Payload, Respond)`); the spec has NO context clause; `nuntius-web-server.adb:6` (`with GNAT.Sockets`), `:17` (`Poll_Ms = 100`), `:22` (`Io_Timeout = 2.0`, set as `Receive_Timeout` AND `Send_Timeout` on every accepted socket at `:244-251`), `:34-48` (`Send_All (Sock, Text)`), `:55-197` (`Serve_One`, with the nested `Respond`, `Read_Head`, `Read_Body`, `Dispatch`), `:153-180` (`Dispatch`: 413/400/405 then `Handle`), `:237-275` (the accept loop: `Fd_Poll.Readable (To_C (Listener))`, `Accept_Socket`, `Serve_One`, `Close_Socket (Sock)` at `:253`, and the `when others` handler at `:254-265` that closes `Sock` again at `:261`) | Serial by design: one connection at a time, never parks in `accept(2)`. nuntius has NO shape lint (`Makefile`: build/test/prove/format/example only). The upgrade is a new branch in `Dispatch` and TWO `Close_Socket` calls that are skipped once the socket was adopted. |
| The request parser | `nuntius/src/core/nuntius-web.ads:17` (`Max_Request_Bytes = 4_096`), `:33-69` (`Request`: `Well_Formed`, `Method`, `Target`, `Content_Length`, `Length_Refused`, `Json_Body`, `Bearer`, `Forwarded_For`), `:87-88` (`Parse_Request`), `:96-106` (`Status`: 200, 202, 400, 401, 403, 404, 405, 409, 413, 415), `:132-135` (`Response_Head`; `Connection: close`, `Cache-Control: no-store`, CSP, nosniff, `Content-Type`, `Content-Length`; the `Challenge` line on a 401 only), `nuntius-web.adb:147-215` (the header walk's nested `Read_Length`/`Read_Bearer`/`Read_Forwarded`/`Is_Json`; `Parse_Request` is 86 lines) | Pure SPARK, proved. The four upgrade headers are four more `Read_*`/`Is_*` procedures in the same walk. |
| The frame codec | `nuntius/src/core/nuntius-rfc6455.ads:50-58` (`Decode`: the three length forms, MASKED OR NOT), `:60-70` (`Get_Text`: unmasks only when `H.Masked`, `nuntius-rfc6455.adb:125`), `:72-80` (`Encode_Text`: a MASKED client frame, `Text'Length <= 65_535`), `:82-95` (`Encode_Control`: masked Ping/Pong/Close), `:110-113` (`Base64`), `:117-122` (`Client_Handshake`) | Everything a SERVER needs that is missing: an unmasked frame header with the 64-bit length form, and a close payload. `Decode` already reads the browser's masked frames. |
| The websocket client | `nuntius/src/app/nuntius-ws-native_client.ads` (generic over `Ring_Depth`, `Max_Frame_Bytes`, `Idle_Limit := 45.0` at `:35`, `Poll_Slice := 1.0` at `:39`; `Connect`, `Send_Text`, `Receive`, `Receive_For`, `Close`), `nuntius-ws-native_client.adb:197-234` (`Handle_Frame`), `:252-280` (`Drain`), `:288` (`Read_Some`), `:543-666` (`Do_Handshake`; `:649` accepts any status line carrying `101` and returns `Ok = False` otherwise -- it does NOT verify `Sec-WebSocket-Accept`) | The client is the loopback TEST PEER for the new server side (WP-N5): it dials, upgrades and receives unmasked frames. Instantiate it in tests with a SMALL `Idle_Limit` and `Max_Frame_Bytes >= 70_000`, and read with `Receive_For`, or a failing test hangs 45 s. It is not reused as the server peer (D23). |
| poll(2) and eventfd | `nuntius/src/app/nuntius-fd_poll.ads` (`Readable (Fd)`: zero-timeout poll on ONE fd; `Wait (Fd, Timeout_Ms)`: blocking poll on ONE fd, negative fd = sleep at `nuntius-fd_poll.adb:57-63`), `nuntius-fd_poll.adb:13-24` (the `Pollfd` record and the `poll` import), `nuntius-fd_wake.ads` (`Create`/`Signal`/`Drain`/`Close`: an eventfd; a negative fd is a no-op), `nuntius/src/app/nuntius-http-fetch.ads:63` (`type Fd_List is array (Positive range <>) of Integer`) | The stream task needs ONE poll over up to nine fds (eight clients and the wake): a `Wait_Any` beside `Wait`, over the existing `Pollfd`. `poll(2)` ignores a negative fd and reports `revents = 0` for it (man 2 poll). |
| The wake cell | `src/app/shell/fructus-wake_cell.ads:15-26` (generic; `Arm`, `Signal`, `Fd`, `Wait_Ms`), `fructus-wake_cell.adb:9-32` (a protected `Cell` over `Nuntius.Fd_Wake`; `Signal` writes the eventfd INSIDE the protected body at `:53-56`, a no-op while unarmed), `src/app/web_stats/fructus-intervene_wake.ads` (`package Fructus.Intervene_Wake is new Fructus.Wake_Cell;`), `src/app/boot/fructus-runtime.adb:123-129` and `:731` (a cell may `Arm` inside the task that READS it -- `Md_Wake`) | The publishers' "something changed" signal is a second instance, armed by the stream task. |
| The fructus server | `src/app/web/fructus-web-server.ads:42-46` (`Task_Stack_Bytes = Base_Bytes + 3 * Stats.Snapshot + 3 * Schedule.Snapshot + 3 * Samples.Snapshot`), `:48-60` (`Ports`: `Stop`, `Clock_Ms`, `Sleep_Ms`, `Lane_On`), `:68` (`Run (P, C, G)`), `fructus-web-server.adb:196-239` (`Serve_Document_Route`), `:245-275` (`Serve_Get`, the GET route `case`: [R1] measured 31 lines / 15 statements / 5 params -- NOT at its limit; the day-chart plan's 56/37 figure predates the `Serve_Document_Route` extraction), `:277-375` (`Run`: the `Refusals` throttle, `Commands_On`, and the nested `Stop`/`Sleep_Ms`/`Log_Info`/`Log_Warn`/`On_Listening`/`Handle` -- five of them WAIVED `nested 1` at `tools/shape-waivers:383-387`; `Handle` at `:316-350` judges the bearer FIRST via `Fructus.Web.Auth.Accepts`, then `Api_Close` or `Serve_Get`; `:340-345` answers a POST on any other route `405`; the instantiation at `:363-374`) | The upgrade is decided here (route, knob, room) and the socket handed to the stream task's lobby. NO new nested body in `Run`: the two new actuals are package-level (WP-F5). |
| Route table | `src/app/web_stats/fructus-web.ads:64-73` (`Route is (Root, Api_Stats, Api_Positions, Api_Schedule, Api_Series, Metrics, Api_Close, Asset, Unknown)`; `subtype Document is Route range Api_Stats .. Metrics`; `Needs_Token (R) is (R in Document | Api_Close)`; `Route_Of`, exact match, no query strings), `tests/src/fructus_web_tests.adb:36-75` (`Test_Route_Mapping`) | `Api_Stream` goes AFTER `Metrics` and before `Api_Close` so `Document` stays contiguous. It does NOT join `Needs_Token`: its bearer arrives in-band (D2). |
| Auth | `src/app/web/fructus-web-auth.ads` (`Guard`, `Of_Token`, `Accepts (G, Bearer)`, `Throttle`, `Note_Refusal (T, Now_Ms, Forwarded)`, `Xff_Text`) | The stream task holds its own `Throttle`; `Accepts` is called on the first frame's token. |
| Config | `src/app/web/fructus-web-config.ads` (`Settings`: `Enabled`, `Port`, `Bind`, `Root`, `Control`), `fructus-web-config.adb:10-27` (`Read_Web`: one `Tabula.Config.Get` per knob) | One more Boolean, `Stream`, default True. |
| The cells | `src/app/web_stats/fructus-web-stats.ads:289-316` (`Publish_Positions`, `Publish_Accounts`, `Publish_Brokers`, `Publish_Day_Orders`, `Publish_Md`, `Publish_Dx_Frame_Bytes`, `Publish_Alert_Drops`, `Publish_Signal_Drops`, `Publish_Dbn_Feed`, `Publish_Dbn_Md`, `Peek`), `fructus-web-stats.adb:170-227` and `:238-241` (each wrapper is one `Cell.X` call), `fructus-web-schedule.adb:22-48` (the `Cell` template: `Publish`/`Peek`/`Reset`) and `:50-53` (the `Publish` wrapper), `fructus-web-samples.ads:90` / `fructus-web-samples.adb:133` (`Note (Kind, Name, Val, Instant)`) | The `Bump` of D5 is one line added to each wrapper. Cells are protected; the stream task and the HTTP task both only `Peek`. |
| Collect and render | `src/app/web/fructus-web-collect.ads` (`Snapshot_Now`, `Schedule_Now`, `Samples_Now`, each `(Now_Ms)`), `fructus-web-render.ads` (`To_Json` = `/api/stats`, `To_Positions_Json`, `To_Metrics`), `fructus-web-render-schedule.ads` (`To_Json`), `fructus-web-render-samples.ads` (`To_Json`), `fructus-web-render.adb` (878 of the 1000-line R8 limit) | The stream task calls exactly these, exactly as `Serve_Document_Route` does. |
| Publishers and their cadence | Bot tick: `src/app/bot/fructus-session_runner-driver.adb:653-674` (`Publish_Stats`: `Publish_Accounts`, `Publish_Positions`, `Schedule.Publish`, every `Heartbeat_Ms = 500`, `fructus-session_runner.adb:108`; waived `nested 1` at `tools/shape-waivers:200` -- NOT touched by this plan); md hub: `src/app/md/fructus-md-runner.adb:701+` (`Publish_Md_Stats`, once per pass; the Theta poll is `Default_Theta_Poll_Ms = 100`, `fructus-md-config.ads:20`), `:694` (`Samples.Note`); arb monitor: `arb-ada/src/app/og_arb/fructus-og-monitor_runner.adb:124,136,168` (`Publish_Book` at seed, each beat of `Cadence_S`, and each adoption) → `fructus-og-monitor.adb:221` (`Publish_Positions (Spreads, ...)`) | The generation counters move at up to 10 Hz (the hub); the pacing table (D6) is what keeps the wire at 1 Hz. |
| The command parser | `src/app/web/fructus-web-command.ads` (`Parse (Payload, Cmd, Ok)` with `Pre => Payload'Length <= Max_Body`), `fructus-web-command.adb:19-43` (`Lector.Scan.String_Value (Payload, "name", 1)`, `Number_Value`) | The stream's first frame is parsed the same way. `Lector.Scan` reads strings, numbers and the flat objects of an array (`Object_Value`, `lector/src/core/lector-scan.ads:82-90`), not an array of scalars. |
| The tasks and the abort backstop | `src/app/boot/fructus-runtime.ads:257` (`task type Web_Task with Storage_Size => Fructus.Web.Server.Task_Stack_Bytes;`), `fructus-runtime.adb:826-844` (`Web_Task` body: `Guard`, `if Current.Web.Enabled then Fructus.Web.Server.Run (P => (...), C => Current.Web, G => Of_Token (To_String (Current.Web_Token)))`, `Log_Task_Death (..., Fructus.Notify.Web)` at `:843`), `src/app/boot/fructus-main.adb:122-133` (the task declarations; `Web : Fructus.Runtime.Web_Task` at `:132`), `:135-148` (`Abort_All`: `abort Web` at `:146`), `:150-151` (`Web_Done is (Web'Terminated)`); `arb-ada/src/app/arb_main.adb:717-726` (`Md_Hub`, `Strategy`, `Web` at `:723-725`), `:1065-1084` (the abort list; `abort Web` at `:1084`), `:1095` (`Web'Terminated`) | The stream task is a second task TYPE, a second declaration in each root, AND a line in each root's abort list and done check. |
| Shape lint (fructus only) | `CLAUDE.md:219-245` (R1 40 statement lines, R2 60 lines, R3 depth 3, R4 no nested bodies except ≤3-line expression functions, R5 5 params, R6 2 outs, R7 no adjacent Booleans, R8 1000 lines per body, R9 no bare literal ≥ 100 outside a constant), `tools/fructustools/shape_check.py:483-491` (R9 exempts only declarations that declare a constant or bound a type), `:682-683` (scans `src/**`; tests are exempt), `tools/shape-waivers` (may only shrink) | Every fructus subprogram sketched below was measured by [R1]. |
| Pins | fructus `alire.toml:59` (`nuntius = { url = ..., commit = "2755761..." }`), fructus `proof/proof.gpr:33` (`../alire/cache/pins/nuntius_27557618/src/core`); arb-ada `alire.toml:48` (fructus pin), `:66` (nuntius pin, the SAME commit -- "pins only bind at the workspace root"), arb-ada `proof/proof.gpr:36` (fructus core) and `:40` (nuntius core) | A nuntius bump is FOUR edits across fructus and arb-ada plus arb-ada's fructus pin. `tools/*/dag_check.py` globs the pin directories. Both proof trees source nuntius `src/core` WHOLESALE, so `Rfc6455` additions are analysed without any `with`. |
| Deployment | `docs/web-close-actions-plan.md` (the Tailscale migration section, cited as "12" by the running configs' comments; the proxy terminates TLS in front and forwards `X-Forwarded-For`), `arb-ada/fructus-running/fructus-running.toml:108` and `arb-ada/arb-running/arb-running.toml:316` (BOTH still `bind = "0.0.0.0"`: the migration to loopback behind the proxy has NOT happened yet) | The websocket crosses the same proxy once it exists. Tailscale Serve's reverse proxy is Go's `httputil.ReverseProxy`, which forwards `Upgrade`; section 7 item 7 verifies it on the real box and section 10 keeps it open until then. |

---

## 2. Design decisions (the why, so nobody "fixes" them later)

**D1. A websocket, on the same listener, at `GET /api/stream`.** Not
server-sent events: `EventSource` cannot send headers any more than
`WebSocket` can, so SSE has the same token problem (D2) and none of the
return channel; and the crate already carries a proved RFC 6455 codec.
Same port, same bind, same proxy: nothing new to open or to route.

**D2. The bearer travels IN-BAND, as the first frame.** The browser
`WebSocket` API sets no request headers, and a token in the URL would
be written to the proxy's log and the browser's history. So the
upgrade itself is unauthenticated and costs nothing (no document is
sent), and the first frame the client sends is `{"token":"<t>"}`. The
server judges it with the same `Fructus.Web.Auth.Accepts` and the same
refusal throttle as HTTP; a refused token is answered with close code
`4401` and nothing else; a client that has sent nothing acceptable
within `Auth_Deadline_Ms = 5_000` of adoption is closed `1008`.

**D3. The serial HTTP task performs the upgrade and HANDS THE SOCKET
OVER; a second task owns the stream.** `Nuntius.Web.Server` is one
connection at a time and must stay so (the un-abortable-foreign-call
rule; the 10 s connection budget). A websocket is a connection that
does not end, so it cannot live on that loop. The loop writes the
`101`, calls the consumer's `Adopt (R, Sock)` and skips BOTH its
`Close_Socket` calls; the stream task takes the socket from a bounded
lobby on its next wake. Two tasks, no shared mutable state beyond the
protected lobby and the protected cells both already read.

**D4. The documents are the GET documents, byte for byte, in a one-key
envelope.** A frame is
`{"doc":"positions","body":<exactly what GET /api/positions returns>}`.
The zod schemas, the goldens, `Test_*_Golden` and every component are
untouched; the client dispatches on `doc` and parses `body` with the
schema it already has. `/metrics` never streams (it is a scrape
format). The GETs stay, for `curl`, for Alloy, and as the fallback
(D8).

**D5. Push on CHANGE, announced by the publishers, never by a timer
in the trading tasks.** `Fructus.Web.Pulse` holds one generation
counter per streamed document and an eventfd (a second
`Fructus.Wake_Cell` instance, `Fructus.Web.Stream_Wake`). Each
existing `Publish_*` wrapper bumps the counter of the document(s) it
feeds and signals the fd: one protected write and one atomic 8-byte
write, on the publisher's own task, no rendering. The stream task
wakes, compares the counters to what it last sent, renders once and
writes to every authenticated client. Rendering moves OFF the trading
tasks and onto the stream task, where the HTTP task already does it
today.

**D6. Paced per document, with a floor and a ceiling.** The counters
move at up to 10 Hz (the hub's `Publish_Md` bumps positions); the wire
must not. A constant table in `Fructus.Web.Stream_Pace`:

| document | `Min_Ms` (never sooner than) | `Max_Ms` (heartbeat: sent even if unchanged) |
|---|---|---|
| positions | 1_000 | 2_000 |
| stats | 5_000 | 10_000 |
| schedule | 5_000 | 30_000 |
| series | 15_000 | 60_000 |

`Min_Ms` equals today's poll cadence, so bytes on the wire are at most
today's, minus the HTTP heads and handshakes. `Max_Ms` is a keepalive
that carries content: the positions heartbeat at 2 s keeps
`ConnectionDot` under its 3 s amber line and is the dead-peer detector
in both directions (D9). Constants, not TOML: the same shape as the
resubmit ladder.

**D7. At most `Max_Clients = 8` sockets.** The phone, the desktop, a
spare tab and room to be wrong. A ninth upgrade is answered `503` by
the HTTP loop before any handshake, and the page falls back to polling
(D8). No dynamic memory: a fixed array of client slots. Occupancy is
ONE count owned by the lobby: `Offer` takes a place, `Release` gives it
back when the stream task frees the slot, and `Room` is that count
against `Max_Clients` while the task is `Serving`.

**D8. The polls STAY, as the fallback, and the socket feeds the same
cache.** `useStream` writes each frame into TanStack's cache with
`queryClient.setQueryData ([doc], parsed)`, so `usePositions ()` and
its siblings, `dataUpdatedAt`, the `isSuccess` latch clear and every
component are unchanged. Each `refetchInterval` function returns
`false` while the socket is OPEN and its present value otherwise, and
the hook calls `invalidateQueries ()` on every close of the CURRENT
socket so the timers re-arm at once. [R1, verified] TanStack re-reads a
function interval on every query update, so a timer armed before the
socket opened fires ONE more poll unless the first frame lands first,
and `invalidateQueries ()` refetches at once even while the interval
reads `false`; a socket closed WITHOUT the invalidate leaves the poll
dead until the next update, which is why the invalidate is not
optional. A proxy that drops upgrades, a server with `stream =
false`, a full lobby, a version skew: all of them degrade to exactly
today's page.

**D9. One socket at a time; only the CURRENT socket's events act;
reconnect on a fixed ladder; a refused token stops it.** The hook
keeps `ws` (the current socket) and every handler starts with `if
(stopped || sock !== ws) return;` -- a close that lands after cleanup,
after a token change, after a hidden-tab close or after StrictMode's
first mount does NOTHING ([R1]: without the guard a dead effect
redials, and on sign-out re-sends the old token and un-signs-out the
page). `dial ()` clears any pending redial timer first. Close of the
current socket → `setStreamOpen (false)`, `invalidateQueries ()`, then
wait `1, 2, 4, 8, 16, 30, 30, ...` s and dial again; a successful open
resets the ladder. Close code `4401` sets `refused` and the hook does
NOT redial until the token in the store changes (a sign-in). A
silence timer of `SILENCE_MS = 10_000` is armed AT DIAL (so a handshake
that hangs is cut at 10 s too) and re-armed on every frame; it RETIRES
the socket: close `1000`, the open flag cleared, the polls re-armed by
an invalidate, and a redial scheduled -- inline, because the guard
ignores the `onclose` of a close the hook asked for.

**D10. A hidden tab closes its socket.** On `visibilitychange` to
hidden the hook drops the current socket (`ws = null` FIRST, then
`close (1000)` on the old one, so its late `onclose` is ignored by D9's
guard) and clears any redial timer; on visible, with no current socket
and not `refused`, it dials at once. A redial timer that fires while
hidden dials nothing. While hidden the fallback polls run at their
hidden cadence, exactly as today. One rule instead of a server-side
"slow mode".

**D11. Server frames are unmasked, and the payload is never copied.**
RFC 6455 §5.1: a server MUST NOT mask. The new encoder produces only
the frame HEADER (2 to 10 bytes) for a given opcode and length; the
peer writes the header and then the document string itself, in 4 KB
chunks. A 5.7 MB positions document at `Max_Rows` therefore costs one
rendered String on the stream task's stack, not two, and
`Task_Stack_Bytes` already budgets that.

**D12. Inbound is tiny and strict.** A client message over
`Max_Inbound_Bytes = 512` (the token is at most 128) is answered close
`1009`; a binary frame, a continuation frame or a reserved opcode is
close `1003`; a ping is answered with a pong; a pong is ignored; a
close is echoed (its payload verbatim) and the slot freed. The peer
never buffers more than one message.

**D13. The first frame is the ONLY frame the server acts on.** Its
grammar is `{"token":"<t>"}`; every authenticated client receives
every streamed document. No subscription set: the health page's
`/api/stats` is about 2 KB every 5 to 10 s, cheaper than a
subscription grammar and a per-client set.

**D14. After a token is accepted the server sends `hello` then every
document once.** `{"hello":{"proto":1}}` then positions, stats,
schedule, series in that order, at once and regardless of pacing, so
a page that just opened is complete before the first pushed change.

**D15. One knob: `[web] stream`, default `true`.** It opens no new
socket and exposes nothing the bearer does not already gate, so the
house "off unless asked" rule for listeners does not apply. `false`
answers every upgrade `503` and the page polls.

**D16. Two new statuses in nuntius: `Upgrade_Required_426` and
`Unavailable_503`.** A plain GET on `/api/stream` (no `Upgrade`) is
`426`, and its head carries `Upgrade: websocket` as RFC 9110 §15.5.22
requires (the same shape as the 401's `Challenge` line); a knob off, a
lobby full or a stream task not serving is `503`. Both carry the
standard head, so a browser or `curl` reads them as what they are.

**D17. The nuntius seam is two generic formals with defaults.**
`Accepts_Upgrade (R : Request) return Boolean is Never_Upgrade` and
`Adopt (R : Request; Sock : GNAT.Sockets.Socket_Type) is null`. `Adopt`
receives the REQUEST as well as the socket so the consumer needs no
state between the two calls (the forwarded-for text for the audit line
comes from `R`). Every existing instantiation (the fructus server, the
nuntius loopback tests) compiles unchanged and behaves unchanged: an
upgrade request reaches `Handle` as a well-formed GET, as it does
today.

**D18. The stream task renders on its own stack with the SAME budget
as the HTTP task.** `Fructus.Web.Server.Task_Stack_Bytes` names the
largest document held once plus the collector's snapshots; the stream
task holds exactly that (one document, one snapshot) plus its client
table (small). It reuses the constant rather than deriving a second
one.

**D19. The stream task's loop is a `poll(2)` over the wake fd and the
client fds, sliced at `Slice_Ms = 250`.** A publisher's signal wakes
it at once; a client's frame wakes it at once; with neither it wakes
four times a second to check the ceilings and the auth deadline and
`Stop`. Same shape as `Nuntius.Web.Server`'s 100 ms listener poll.

**D20. Sends are blocking with the 2 s `Send_Timeout` the accept loop
already set.** A client that cannot take a document within 2 s is
dropped (its slot freed, one log line). Worst case one pass is delayed
2 s per stalled client; with eight stalled clients the stream is 16 s
late and NOTHING else is: the trading tasks never wait on the stream
task. A per-client outbound ring is out of scope (section 9).

**D21. The client's refusal throttle is the HTTP one, a second
instance.** `Fructus.Web.Auth.Throttle` is a plain record on the
task's stack; the stream task owns its own. Log lines say `web:
stream ...` so the two tasks' lines read apart.

**D22. The upgrade parse is pure and proved; the accept key is
shell.** `Sec-WebSocket-Accept` is `base64 (SHA-1 (key ||
"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))` (RFC 6455 §4.2.2) and SHA-1
comes from `GNAT.SHA1`, which is not SPARK, so it lives in
`Nuntius.Web.Handshake` (app), pinned to the RFC's own worked example.
The parse of `Upgrade`, `Connection`, `Sec-WebSocket-Key` and
`Sec-WebSocket-Version` into `Request` and the `101` head are in
`Nuntius.Web` (core) with the rest of the header walk.

**D23. `Nuntius.Ws.Peer` is a new server-side adapter, not a
refactor of `Native_Client`.** The client dials, masks its sends, and
blocks in `Receive`; the peer is adopted, sends unmasked, and reads
only when the caller's poll said it may. They share `Rfc6455` and a
new `Nuntius.Socket_Io.Send_All` and nothing else. Folding the client
onto the peer is section 10.

**D24. A protocol number in `hello`.** `proto` is `1`. A client that
sees a `proto` it does not know closes with `1000` and polls. It costs
one field and prevents a wedged page on the day the envelope changes.

---

## 3. The wire contract: `GET /api/stream`

### 3.1 The upgrade

Request (what the browser sends; through the proxy the four
`X-Forwarded-*`/`Tailscale-*` headers are added, as on every route):

```
GET /api/stream HTTP/1.1
Host: fructus.tail1234.ts.net
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Origin: https://fructus.tail1234.ts.net

```

Response, byte for byte (`Nuntius.Web.Upgrade_Head`; 129 bytes: 32 +
2, 18 + 2, 19 + 2, 22 + 28 + 2, 2):

```
HTTP/1.1 101 Switching Protocols\r\n
Upgrade: websocket\r\n
Connection: Upgrade\r\n
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n
\r\n
```

`R.Upgrade` is True when ALL hold: method `GET`; an `Upgrade` header
whose value is `websocket` (ASCII case-insensitive, trimmed); a
`Connection` header one of whose comma-separated tokens is `Upgrade`
(case-insensitive, trimmed); `Sec-WebSocket-Version: 13`; a
`Sec-WebSocket-Key` of exactly 24 bytes from the base64 alphabet ending
in `==`. Anything else leaves `Upgrade` False and the request is the
plain GET it was; nothing is refused at the parser.

Refusals on the HTTP side (before any handshake):

| condition | status | body |
|---|---|---|
| `Route_Of = Api_Stream`, `R.Upgrade` False | `426 Upgrade Required` (head carries `Upgrade: websocket`) | `websocket only` |
| `Api_Stream`, `Upgrade`, `[web] stream = false` | `503 Service Unavailable` | `stream off` |
| `Api_Stream`, `Upgrade`, lobby full, or the stream task not serving | `503 Service Unavailable` | `stream full` / `stream down` |
| `Api_Stream`, a POST | `405` (the existing `Handle` path) | `POST not accepted here` |
| `R.Upgrade` True on any OTHER route | as today: the route's own answer | |

The `426` and `503` heads carry `Connection: close` like every head,
so the browser's `WebSocket` sees a failed handshake (`error` then
`close` with `1006`) and the hook backs off (D9). Node's client fires
`error` and never `close` on a failed handshake (section 7).

### 3.2 Frames from the client

Exactly one is acted on, the first, within 5 s of adoption:

```json
{"token":"<the 64-character WEB_TOKEN>"}
```

Unknown keys are ignored. A frame with no `token` key, an empty one, or
one over `Nuntius.Web.Max_Bearer` (128) is a refusal. After
acceptance every further text frame is read and dropped (so a client
that re-sends does no harm); control frames behave per D12.

### 3.3 Frames from the server

Text frames only. Each is one JSON object with exactly one top-level
key.

```json
{"hello":{"proto":1}}
{"doc":"positions","body":{"as_of_ms":1758211200000,"day":20260918,...}}
{"doc":"stats","body":{...}}
{"doc":"schedule","body":{...}}
{"doc":"series","body":{...}}
```

`body` is the GET document VERBATIM (`Fructus.Web.Render.To_Positions_Json`
and friends), so `PositionsDoc.parse (frame.body)` is the same parse
the poll does. Order after `hello`: the four documents once each, then
pushes as D6 allows.

### 3.4 Close codes

| code | sent by | meaning | client reaction |
|---|---|---|---|
| `1000` | either | normal (hidden tab, sign-out, silence, shutdown, `Stop`) | redial per D9 unless hidden or signed out |
| `1003` | server | binary, continuation or reserved frame | redial per D9 |
| `1005` | (browser-reported) | the client sent `close ()` with no code and the server echoed the empty payload | none: the client asked |
| `1006` | (browser-reported) | the handshake failed or the connection dropped | redial per D9 |
| `1008` | server | no acceptable token within 5 s | redial per D9 |
| `1009` | server | client frame over 512 bytes | redial per D9 |
| `4401` | server | token refused | `refused`; no redial until the token changes; `invalidateQueries (["positions"])` so the poll's 401 shows the form |

### 3.5 Field sources

| frame | field | source |
|---|---|---|
| `hello` | `proto` | `Fructus.Web.Stream.Proto = 1` |
| `doc` | `doc` | `Fructus.Web.Doc_Name (D)`: `"stats"`, `"positions"`, `"schedule"`, `"series"` |
| `doc` | `body` | `Fructus.Web.Render.To_Json`, `To_Positions_Json`, `Render.Schedule.To_Json`, `Render.Samples.To_Json` over `Collect.Snapshot_Now`/`Schedule_Now`/`Samples_Now (Clock_Ms)` at the moment of the push |

---

## 4. Work packages, nuntius (WP-N1 .. WP-N6)

Branch `web-stream` from `web-post`, in a worktree. Gates: `make test`,
`make prove`, `make format`, `alr --non-interactive build --validation`
(warnings are errors: an unreferenced formal fails the build).
nuntius has no shape lint; follow the shapes the neighbouring code
uses (the nested `Read_*` procedures in `Parse_Request`, the nested
`Read_Head`/`Read_Body`/`Dispatch` in `Serve_One`).

### WP-N1 -- the upgrade in the request parser (`src/core/nuntius-web.ads/.adb`)

RED: `nuntius_web_tests.adb` gains

- `Test_Upgrade_Request_Parsed`: the 3.1 request text →
  `R.Well_Formed`, `R.Method = Get`, `R.Upgrade = True`,
  `Ws_Key_Of (R) = "dGhlIHNhbXBsZSBub25jZQ=="`.
- `Test_Upgrade_Needs_All_Four`: drop each of the four headers in
  turn → `R.Upgrade = False`, `Well_Formed` still True; `Connection:
  keep-alive, Upgrade` still True (token list); `Upgrade: WebSocket`
  still True (case); a 23-byte key → False; a POST with all four →
  False.
- `Test_Upgrade_Head_Bytes`: `Upgrade_Head ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")`
  equals the 3.1 response byte for byte (129 bytes).
- `Test_Never_Upgrade`: `Never_Upgrade (R) = False` for the parsed
  upgrade request.
- `Test_426_Head_Carries_Upgrade`: `Response_Head (Upgrade_Required_426,
  "text/plain", 14)` contains the line `Upgrade: websocket` CRLF
  directly after the status line, and `Response_Head (Ok_200, ...)`
  does not.

Spec additions:

```ada
   Ws_Key_Length : constant := 24;

   type Request is record
      ...
      --  The websocket upgrade, when the four headers agree (3.1).
      Upgrade : Boolean := False;
      Ws_Key  : String (1 .. Ws_Key_Length) := [others => ' '];
   end record;

   function Ws_Key_Of (R : Request) return String
   is (R.Ws_Key);

   --  The default for a consumer that takes no upgrades.
   function Never_Upgrade (Unused : Request) return Boolean
   is (False);

   Accept_Length : constant := 28;

   --  "HTTP/1.1 101 Switching Protocols" CRLF "Upgrade: websocket" CRLF
   --  "Connection: Upgrade" CRLF "Sec-WebSocket-Accept: <a>" CRLF CRLF.
   function Upgrade_Head (Accept_Key : String) return String
   with Pre => Accept_Key'Length = Accept_Length,
        Post => Upgrade_Head'Result'Length = 101 + Accept_Length;

   --  The one header a 426 MUST carry (RFC 9110 15.5.22).
   Upgrade_Offer : constant String := "Upgrade: websocket";

   type Status is (..., Not_Allowed_405, Conflict_409, Too_Large_413,
      Unsupported_Media_415, Upgrade_Required_426, Unavailable_503);
```

[R1] The formal is named `Unused`: GNAT suppresses the
unreferenced-formal warning on that name, and `-gnatwe` makes the
warning an error. `Status_Line` gains `"426 Upgrade Required"` and
`"503 Service Unavailable"`; `Response_Head` emits `Upgrade_Offer` CRLF
after the status line on a 426, as it emits `Challenge` on a 401. In
the body, the header walk in `Parse_Request` gains four recognised
names beside the existing four, each its own nested `Read_*`/`Is_*`
procedure in the existing style, and `Upgrade` is computed once after
the walk from four Booleans. `make prove` must stay at 0.

### WP-N2 -- the server frame header and the close payload (`src/core/nuntius-rfc6455.ads/.adb`)

RED: `nuntius_rfc6455_tests.adb` gains

- `Test_Server_Header_Short`: `Server_Header (Op_Text, 5)` →
  `[16#81#, 16#05#]`, `Last = 2`.
- `Test_Server_Header_16`: length 256 → `[16#81#, 16#7E#, 16#01#,
  16#00#]`, `Last = 4`.
- `Test_Server_Header_64`: length 65_536 → `[16#81#, 16#7F#, 0, 0, 0,
  0, 0, 1, 0, 0]`, `Last = 10`.
- `Test_Server_Header_Decodes`: `Decode` of each header (followed by
  that many zero bytes) is `Ready`, `Masked = False`, `Payload_Bytes`
  equal, `Header_Bytes = Last`.
- `Test_Close_Payload`: `Close_Payload (1000) = [16#03#, 16#E8#]`,
  `Close_Payload (4401) = [16#11#, 16#31#]`.

Spec additions:

```ada
   Max_Server_Header : constant := 10;

   subtype Server_Header_Count is Natural range 2 .. Max_Server_Header;

   --  A single, final, UNMASKED frame header (RFC 6455 5.1: a server
   --  must not mask).  The payload follows on the wire verbatim.
   procedure Server_Header
     (Op : Opcode; Payload_Length : Natural;
      Into : out Octets; Last : out Server_Header_Count)
   with Pre => Into'First = 1 and then Into'Length >= Max_Server_Header
        and then (if Op in Op_Close | Op_Ping | Op_Pong
                  then Payload_Length <= 125);

   subtype Close_Code is Natural range 1_000 .. 4_999;

   --  The two-byte network-order status a close frame carries.
   function Close_Payload (Code : Close_Code) return Octets
   with Post => Close_Payload'Result'Length = 2;
```

`Natural` is 31-bit on this target, so the 64-bit length form's top
four bytes are always zero; write them as such. `Encode_Text` and
`Encode_Control` are untouched.

### WP-N3 -- the accept key (`src/app/nuntius-web-handshake.ads/.adb`, new)

RED: `nuntius_web_handshake_tests.adb` (new, registered in
`nuntius_suite.adb`): `Accept_Key ("dGhlIHNhbXBsZSBub25jZQ==") =
"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="` (RFC 6455 §1.3 and §4.2.2).

```ada
with Nuntius.Web;

package Nuntius.Web.Handshake is

   function Accept_Key (Key : String) return String
   with Pre => Key'Length = Ws_Key_Length,
        Post => Accept_Key'Result'Length = Accept_Length;

end Nuntius.Web.Handshake;
```

Body: [R1] `GNAT.SHA1.Digest (S : String)` is OVERLOADED on its return
type (`Binary_Message_Digest` at `g-sechas.ads:170`, the hex
`Message_Digest` at `:186`), so bind it to a typed constant first:

```ada
   Guid : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   function Accept_Key (Key : String) return String is
      D : constant GNAT.SHA1.Binary_Message_Digest :=
        GNAT.SHA1.Digest (Key & Guid);   --  Stream_Element_Array (1 .. 20)
      O : Nuntius.Rfc6455.Octets (1 .. D'Length);
   begin
      for K in O'Range loop
         O (K) := Nuntius.Rfc6455.Octet (D (Ada.Streams.Stream_Element_Offset (K)));
      end loop;
      return Nuntius.Rfc6455.Base64 (O);
   end Accept_Key;
```

### WP-N4 -- the shared send and the server-side peer (`src/app/nuntius-socket_io.ads/.adb`, `src/app/nuntius-ws-peer.ads/.adb`, new)

`Nuntius.Socket_Io` first (a refactor under green, no RED of its own:
`nuntius_web_server_tests` keeps passing): `Send_All (Sock :
Socket_Type; Text : String)` moved out of `nuntius-web-server.adb:34-48`,
plus `Send_All (Sock; Bytes : Rfc6455.Octets)`. Both raise
`Socket_Error` on a dead peer, as today. `Nuntius.Web.Server` calls the
String one.

RED: `nuntius_ws_peer_tests.adb` (new). The tests build a loopback
pair with `GNAT.Sockets` (listen on port 0, connect, accept), SET
`Receive_Timeout` and `Send_Timeout` of 2 s on the accepted end (the
production accept loop does; a raw accept does not), adopt it, and
drive the other end with `Rfc6455.Encode_Text` / `Encode_Control`
(client frames are masked, so the existing encoders are exactly the
test's client):

- `Test_Pump_Delivers_Text`: write one masked text frame `{"token":"x"}`
  → `Pump` → `Message`, `Into (1 .. Last)` equals it.
- `Test_Pump_Nothing_When_Partial`: write the first 3 bytes of a frame
  → `Nothing`; write the rest → `Message`.
- `Test_Two_Frames_Two_Pumps`: two frames in one write → `Pump
  (Readable => True)` → `Message`, then `Pump (Readable => False)` →
  `Message` (the second from the buffer, WITHOUT a read), then `Pump
  (Readable => False)` → `Nothing` at once; and `Pump (Readable =>
  True)` on the idle socket → `Nothing` within the 2 s
  `Receive_Timeout` (a lying poll costs 2 s, never a hang).
- `Test_Ping_Is_Ponged`: a masked ping with payload `ab` → `Nothing`,
  and the client end reads an UNMASKED pong `[16#8A#, 2, 'a', 'b']`.
- `Test_Close_Is_Echoed`: a masked close 1000 → `Closed`, and the client
  end reads `[16#88#, 2, 16#03#, 16#E8#]`, then EOF.
- `Test_Oversize_Faults`: a 513-byte text frame → `Faulted`, client
  reads close 1009.
- `Test_Binary_Faults`: opcode 2 → `Faulted`, client reads close 1003.
- `Test_Eof_Is_Closed`: the client end closes → `Closed`.
- `Test_Send_Text_Unmasked`: `Send_Text ("hi")` → client reads
  `[16#81#, 2, 'h', 'i']`; a 70_000-byte text → header `7F` form and
  the bytes verbatim.
- `Test_Send_After_Closed_Fails`: the client end closes; `Pump` →
  `Closed`; then `Send_Text` → `Ok = False`. ([R1] the FIRST `send(2)`
  after a peer's FIN normally succeeds in the kernel; the assertion
  is after the peer has been seen closed.)

Spec:

```ada
with GNAT.Sockets;

with Nuntius.Rfc6455;

generic
   Max_Inbound_Bytes : Positive;
package Nuntius.Ws.Peer is

   type Peer is limited private;

   procedure Adopt (Self : in out Peer; Sock : GNAT.Sockets.Socket_Type);

   function Is_Open (Self : Peer) return Boolean;

   function Fd (Self : Peer) return Integer;

   type Pump_Outcome is (Nothing, Message, Closed, Faulted);

   --  Whole frames already buffered are decoded FIRST, without a read;
   --  only when none is whole and the caller's poll said Fd is
   --  readable is one Receive_Socket issued.  The first text frame is
   --  the Message; ping is ponged, pong dropped, close echoed then
   --  Closed; binary, continuation, reserved or oversize is answered
   --  with a close and Faulted.  Closed and Faulted leave Is_Open False.
   function Pump
     (Self : in out Peer; Readable : Boolean; Into : out String; Last : out Natural)
      return Pump_Outcome
   with Pre => Into'First = 1 and then Into'Length >= Max_Inbound_Bytes;

   procedure Send_Text (Self : in out Peer; Text : String; Ok : out Boolean);

   --  A close frame, then the socket; a no-op when not open.
   procedure Close (Self : in out Peer; Code : Nuntius.Rfc6455.Close_Code);

private

   --  Typed: a generic formal is not static, so no named number here.
   Accum_Bytes : constant Positive :=
     Max_Inbound_Bytes + Nuntius.Rfc6455.Max_Header_Bytes;

   type Peer is limited record
      Sock  : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Open  : Boolean := False;
      Accum : Nuntius.Rfc6455.Octets (1 .. Accum_Bytes);
      Len   : Natural := 0;
   end record;

end Nuntius.Ws.Peer;
```

`Pump` is a function with two `out` parameters (Ada 2012) so the
outcome is the result and no consumer's lint counts three outs.
`Readable` is the caller's poll verdict: `False` means "decode what
is buffered, read nothing".

Body shape (each its own subprogram): `Next_Frame` (`Decode` the
accumulator front; `Need_More` → not whole; a `Payload_Bytes` over
`Max_Inbound_Bytes` → close 1009, `Faulted`; `Invalid` → 1003),
`React (H)` (a `case H.Op`: text → `Get_Text` then `Consume`,
`Message`; ping → `Send_Control (Op_Pong, payload)`; pong → `Consume`;
close → `Send_Control (Op_Close, payload)` then `Close_Socket`,
`Closed`; others → 1003), `Read_Some` (one `Receive_Socket` into the
free tail; EOF → `Closed`; `Socket_Error` → `Closed`), `Consume (N)`
(shift the accumulator), `Send_Header_And (Op, Text)` (`Server_Header`
into a 10-byte local, `Socket_Io.Send_All (header)`, then the text in
4 KB `Octets` chunks). `Send_Text` is `Send_Header_And (Op_Text,
Text)`; a `Socket_Error` anywhere on a send closes the socket and
answers `Ok = False`.

### WP-N5 -- the upgrade in the serving loop and the multi-fd wait

RED, `nuntius_fd_poll_tests.adb`: `Test_Wait_Any_Reports_Ready`: two
eventfds (`Fd_Wake.Create`), signal the second → `Wait_Any ([A, B],
100, Ready)` → `Ready = [False, True]`; neither signalled →
`[False, False]` after ~100 ms; a negative fd in the list is never
ready.

```ada
   --  Nuntius.Fd_Poll
   type Fd_Set is array (Positive range <>) of Integer;
   type Ready_Set is array (Positive range <>) of Boolean;

   --  One poll(2) over every fd, at most Timeout_Ms; a negative fd is
   --  ignored by poll(2) itself and reads not ready.
   procedure Wait_Any (Fds : Fd_Set; Timeout_Ms : Natural; Ready : out Ready_Set)
   with Pre => Ready'First = Fds'First and then Ready'Length = Fds'Length;
```

Body: a local `array (Fds'Range) of aliased Pollfd` (`C_Poll` takes
`access Pollfd`, `nuntius-fd_poll.adb:20-24`; the precedent is
`Wait_Fd_Table is array (Natural range <>) of aliased Wait_Fd` at
`nuntius-http-fetch-curl.adb:120` and `:482`, passed as `P
(P'First)'Access` -- never `'Unrestricted_Access`), one `C_Poll`, then
`Ready (K) := (P (K).Revents and Pollin) /= 0`. `Fd_List` in
`Nuntius.Http.Fetch` stays where it is; `Fd_Set` is this unit's own
so `Fd_Poll` does not with the HTTP client.

RED, `nuntius_web_server_tests.adb` (the client instantiated with
`Idle_Limit => 2.0`, `Max_Frame_Bytes => 70_000`, reads via
`Receive_For` with a 2 s patience, so a failing test fails in seconds):

- `Test_Upgrade_Is_Adopted`: instantiate `Server` with
  `Accepts_Upgrade => Yes_On_Stream` (`R.Upgrade and then Target_Of (R)
  = "/api/stream"`) and `Adopt => Keep` (stores the socket in a
  protected cell and bumps a count); dial with
  `Nuntius.Ws.Native_Client` (`Connect ("ws://127.0.0.1:<port>/api/stream")`
  → `Ok = True`); from the cell, `Peer.Adopt` then `Send_Text
  ("{""hello"":{""proto"":1}}")`; the client's `Receive_For` returns
  that text. `Handled` (the `Handle` count) stays 0.
- `Test_Upgrade_Refused_Reaches_Handle`: `Accepts_Upgrade` returns
  False; `Handle` answers `503`; the client's `Connect` → `Ok =
  False`; `Handled = 1` and the `Request` it saw had `Upgrade = True`.
- `Test_Plain_Get_On_Stream_Path`: no upgrade headers → `Handle` with
  `Upgrade = False`, as today.

Spec (`nuntius-web-server.ads`): [R1] the spec has no context clause
today; add `with GNAT.Sockets;` at the top. After `Connection_Seconds`:

```ada
   --  Whether a well-formed upgrade request on this target is taken:
   --  True means the loop writes the 101 and calls Adopt with the
   --  request and the socket, which the consumer then owns (the loop
   --  neither reads nor closes it again); False means Handle answers
   --  it like any GET.
   with function Accepts_Upgrade (R : Request) return Boolean is Never_Upgrade;
   with procedure Adopt (R : Request; Sock : GNAT.Sockets.Socket_Type) is null;
```

Body:

- `Serve_One (Sock : Socket_Type; Adopted : in out Boolean)`; the
  accept loop declares `Adopted : Boolean := False` beside `Sock` and
  guards BOTH `Close_Socket (Sock)` calls (`:253` and `:261`) with
  `if not Adopted`. `in out` rather than `out` so a raise anywhere in
  `Serve_One` leaves the loop's `False` intact ([R1]).
- `Dispatch` gains, before the `R.Method = Get` arm: `elsif R.Upgrade
  and then Accepts_Upgrade (R) then Upgrade (R);`. `Upgrade (R)` is
  `Socket_Io.Send_All (Sock, Upgrade_Head (Handshake.Accept_Key (Ws_Key_Of
  (R)))); Adopt (R, Sock); Adopted := True;` -- the send comes first
  (a raise there means nothing was adopted and the loop closes the
  socket, correctly), `Adopt` is the LAST call, and `Adopted` is set
  the statement after it returns. The consumer's `Adopt` must not
  raise (WP-F5's does not: a protected `Offer` and, on refusal, a
  guarded `Close_Socket`).
- `Nuntius.Web.Server` now withs `Nuntius.Web.Handshake` and
  `Nuntius.Socket_Io`.

The spec comment paragraph at `nuntius-web-server.ads:1-16` gains one
sentence: "An upgrade request the consumer accepts is answered 101
and handed to Adopt; the loop never touches that socket again."

### WP-N6 -- the loopback end-to-end and the README

The three server tests of WP-N5 ARE the end-to-end: real sockets,
the real client, the real peer. `README.md`'s serving-side paragraph
names the peer and the seam. Bump nothing in `alire.toml` (commit
pins). Push the branch; record the sha for WP-F0.

---

## 5. Work packages, fructus (WP-F0 .. WP-F9)

Branch `web-stream` from `web-day-chart`, in a worktree. WP-F0 first.
Gates: `make test`, `make prove`, `make format`, `make dag-check`,
`make shape-check`, `alr --non-interactive build --validation`,
`make web-test`, `make web-check`.

### WP-F0 -- repin nuntius

`alire.toml:59` commit → the WP-N6 sha; `proof/proof.gpr:33` Source_Dir
→ `nuntius_<sha8>`. `alr update` (or `alr build`) deploys the pin
cache. `make prove` still 0: the proof tree sources nuntius `src/core`
wholesale (`proof.gpr:33`), so `Server_Header`, `Close_Payload` and the
`Request` additions are analysed without any `with`.

### WP-F1 -- the route, the names, the knob

RED, `fructus_web_tests.adb`: in `Test_Route_Mapping`, `Route_Of
("/api/stream") = Api_Stream` and `Route_Of ("/api/stream/") =
Unknown`; in the `Needs_Token` test, `Needs_Token (Api_Stream) =
False` with the comment "its bearer is the first frame"; new
`Test_Doc_Names`: `Doc_Name (Api_Positions) = "positions"` for all
four.

`src/app/web_stats/fructus-web.ads`:

```ada
   type Route is
     (Root, Api_Stats, Api_Positions, Api_Schedule, Api_Series, Metrics,
      Api_Stream, Api_Close, Asset, Unknown);

   subtype Document is Route range Api_Stats .. Metrics;
   --  What the stream carries: every document but the scrape.
   subtype Streamed is Route range Api_Stats .. Api_Series;

   function Doc_Name (D : Streamed) return String
   is (case D is
         when Api_Stats     => "stats",
         when Api_Positions => "positions",
         when Api_Schedule  => "schedule",
         when Api_Series    => "series");
```

`Route_Of` gains `elsif Target = "/api/stream" then Api_Stream`.
`Needs_Token` is unchanged in text and now excludes `Api_Stream` by
construction. Re-export `Upgrade_Required_426` and `Unavailable_503`
beside the other status constants.

RED, `fructus_web_config_tests.adb`: `stream = false` under `[web]`
loads False; absent loads True; a string loads True with a warning.
`Settings` gains `Stream : Boolean := True;` and `Read_Web` one
`Get`. `fructus.toml`'s `[web]` comment block gains the knob with
one line: `stream = true  # push documents over /api/stream; false
= the page polls`.

### WP-F2 -- the pulse (`src/app/web_stats/fructus-web-pulse.ads/.adb`, `fructus-web-stream_wake.ads`, new)

RED, `fructus_web_pulse_tests.adb` (new, registered): `Peek` after
`Reset` is all zero; `Bump (Api_Positions)` moves that counter alone by
one; two bumps → two; `Bump` with the wake armed leaves `Stream_Wake.Fd`
readable (`Nuntius.Fd_Poll.Readable`) and `Nuntius.Fd_Wake.Drain`
clears it.

```ada
package Fructus.Web.Stream_Wake is new Fructus.Wake_Cell;
```

```ada
with Fructus.Web;

package Fructus.Web.Pulse is

   type Generations is array (Fructus.Web.Streamed) of Natural;

   --  One publisher changed one document: count it and wake the stream.
   procedure Bump (D : Fructus.Web.Streamed);

   procedure Peek (G : out Generations);

   procedure Reset;

end Fructus.Web.Pulse;
```

Body: a protected `Cell` with `Gens : Generations := [others => 0]`;
`Bump` increments (wrapping at `Natural'Last` to 0 -- one `if`) and
then calls `Stream_Wake.Signal` (itself a protected operation of the
other cell; two cells, never nested in one action). The DAG holds:
`gpr/fructus_web_stats.gpr:6,8` withs `fructus_shell` and `nuntius`.

Then the publishers, one line each, in the wrappers of
`fructus-web-stats.adb:170-227` and `:238-241`: `Publish_Positions`,
`Publish_Accounts`, `Publish_Brokers`, `Publish_Day_Orders`,
`Publish_Md`, `Publish_Dx_Frame_Bytes`, `Publish_Alert_Drops`,
`Publish_Signal_Drops`, `Publish_Dbn_Feed`, `Publish_Dbn_Md` each call
`Pulse.Bump (Api_Positions)` and `Pulse.Bump (Api_Stats)` after their
`Cell.X` (both documents render from the one `Published` record);
`fructus-web-schedule.adb:50-53` `Publish` → `Bump (Api_Schedule)`;
`fructus-web-samples.adb:133` `Note` → `Bump (Api_Series)`. RED for
these: `fructus_web_stats_tests.adb` gains `Test_Publish_Bumps_Pulse`
(`Publish_Accounts` moves both counters); the schedule and samples
tests one assertion each. `Publish_Stats` in the driver is NOT
touched.

### WP-F3 -- the pace and the first frame (pure)

RED, `fructus_web_stream_pace_tests.adb` (new):

- `Test_Table`: `Cadence (Api_Positions) = (1_000, 2_000)` and the
  other three rows of D6.
- `Test_Due`: `Due (Moved => True, Since_Ms => 999, C => (1_000,
  2_000)) = False`; `(True, 1_000, ..) = True`; `(False, 1_999, ..) =
  False`; `(False, 2_000, ..) = True`; `Since_Ms = Natural'Last` →
  True whatever `Moved`.
- `Test_Elapsed`: `Elapsed (Now => 1_700_000_000_000, Clock => (Sent
  => False, others => <>)) = Natural'Last`; `(Sent => True, At_Ms =>
  Now - 1_500, others => <>) → 1_500`; an `At_Ms` past `Now` → 0; an
  `At_Ms` more than `Natural'Last` ms ago → `Natural'Last`.

```ada
with Fructus.Ports;
with Fructus.Web;

package Fructus.Web.Stream_Pace
  with SPARK_Mode
is

   type Cadence_Ms is record
      Min_Ms : Positive;
      Max_Ms : Positive;
   end record
   with Dynamic_Predicate => Cadence_Ms.Min_Ms <= Cadence_Ms.Max_Ms;

   Table : constant array (Fructus.Web.Streamed) of Cadence_Ms :=
     [Fructus.Web.Api_Stats     => (5_000, 10_000),
      Fructus.Web.Api_Positions => (1_000, 2_000),
      Fructus.Web.Api_Schedule  => (5_000, 30_000),
      Fructus.Web.Api_Series    => (15_000, 60_000)];

   function Cadence (D : Fructus.Web.Streamed) return Cadence_Ms
   is (Table (D));

   --  What the stream last sent of one document.
   type Doc_Clock is record
      Sent  : Boolean := False;
      At_Ms : Fructus.Ports.Epoch_Ms := 0;
      Gen   : Natural := 0;
   end record;

   --  Milliseconds since the last send, Natural'Last when never sent,
   --  clamped at both ends.
   function Elapsed (Now : Fructus.Ports.Epoch_Ms; Clock : Doc_Clock) return Natural
   is (if not Clock.Sent or else Now - Clock.At_Ms >= Fructus.Ports.Epoch_Ms (Natural'Last)
       then Natural'Last
       elsif Now < Clock.At_Ms then 0
       else Natural (Now - Clock.At_Ms));

   function Due (Moved : Boolean; Since_Ms : Natural; C : Cadence_Ms) return Boolean
   is ((Moved and then Since_Ms >= C.Min_Ms) or else Since_Ms >= C.Max_Ms);

end Fructus.Web.Stream_Pace;
```

[R1] `Fructus.Ports.Epoch_Ms` is `Long_Long_Integer`
(`fructus-ports.ads:20`), about 1.76e12 today: `Now - 0` does not fit
a `Natural`, which is what `Doc_Clock.Sent` and the clamp in `Elapsed`
are for. [R1] The cadences are a `constant` table, not bare aggregates
in an expression function, because R9 exempts only a constant's
declaration. `src/app/web_stats/`, with `SPARK_Mode` (no IO; proved
by review like `Fructus.Web`, since the proof tree sources `src/core`
only).

RED, `fructus_web_stream_frame_tests.adb` (new): `Parse
("{""token"":""abc""}")` → `Ok`, `Token_Of = "abc"`; a frame without
the key → `Ok False`; an empty token → `Ok False`; a 129-byte token →
`Ok False`; extra keys ignored; 512 bytes of garbage → `Ok False`.

```ada
with Nuntius.Web;

package Fructus.Web.Stream_Frame is

   Max_Frame : constant := 512;

   type Hello is record
      Ok        : Boolean := False;
      Token     : String (1 .. Nuntius.Web.Max_Bearer) := [others => ' '];
      Token_Len : Natural range 0 .. Nuntius.Web.Max_Bearer := 0;
   end record;

   function Token_Of (H : Hello) return String
   is (H.Token (1 .. H.Token_Len));

   function Parse (Text : String) return Hello
   with Pre => Text'Length <= Max_Frame;

end Fructus.Web.Stream_Frame;
```

Body: `Lector.Scan.String_Value (Text, "token", 1)` exactly as
`Fructus.Web.Command.Parse` uses it (`fructus-web-command.adb:19`);
`Ok` is `Len in 1 .. Max_Bearer`. `src/app/web/`
(`gpr/fructus_web.gpr:11` withs `lector`). A `Hello` never reaches a
log line.

RED, `fructus_web_render_tests.adb`: `Test_Envelope_Pinned`:
`Envelope ("positions", "{""a"":1}") = "{""doc"":""positions"",""body"":{""a"":1}}"`
and `Hello_Json = "{""hello"":{""proto"":1}}"`. Both in
`fructus-web-render.ads` as expression functions over `&` (two
declarations; the body file does not grow).

### WP-F4 -- the stream task (`src/app/web/fructus-web-stream.ads/.adb`, new)

RED first for the pure decisions and the lobby:

- `fructus_web_stream_tests.adb` (new): `Test_Slot_Lifecycle` over
  the `Slot` record's pure transitions: a default `Slot` is `Empty`;
  `Adopted_At (O, Now)` → `Awaiting_Token` with `Deadline_Ms = Now +
  Auth_Deadline_Ms` and `O`'s forwarded text copied; `Judged (S,
  Accepted => True)` → `Streaming`, `Accepted => False` → `Empty`;
  `Expired (S, Now + Auth_Deadline_Ms)` True while awaiting, False
  once streaming.
- `Test_Lobby_Bounds`: not serving → `Room` False and `Offer`
  refused; `Set_Serving (True)`; eight `Offer`s accepted, the ninth
  refused; `Take` drains in order; `Room` False at eight; one
  `Release` → `Room` True.

Spec:

```ada
with GNAT.Sockets;

with Nuntius.Web;

with Fructus.Ports;
with Fructus.Web.Auth;

package Fructus.Web.Stream is

   Proto            : constant := 1;
   Max_Clients      : constant := 8;
   Auth_Deadline_Ms : constant := 5_000;
   Slice_Ms         : constant := 250;

   type Ports is record
      Stop     : access function return Boolean := null;
      Clock_Ms : Fructus.Ports.Clock_Ms_Access := null;
      --  0 = until Stop; tests bound the loop.
      Max_Passes : Natural := 0;
   end record;

   --  A socket the HTTP task handed over, with the forwarded-for text
   --  bounded as Request carries it.
   type Offered is record
      Sock          : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Forwarded     : String (1 .. Nuntius.Web.Max_Forwarded) := [others => ' '];
      Forwarded_Len : Natural range 0 .. Nuntius.Web.Max_Forwarded := 0;
   end record;

   --  The HTTP task's side: room for one more, and the handoff.
   function Room return Boolean;
   procedure Offer (Sock : GNAT.Sockets.Socket_Type; Forwarded : String; Accepted : out Boolean)
   with Pre => Forwarded'Length <= Nuntius.Web.Max_Forwarded;

   --  The stream task's side, public so the lobby tests can drive it
   --  (the Reset precedent): Take dequeues, Release frees a place,
   --  Set_Serving opens and closes the lobby.
   procedure Take (O : out Offered; Got : out Boolean);
   procedure Release;
   procedure Set_Serving (On : Boolean);

   --  One client slot's pure lifecycle.
   type Slot_State is (Empty, Awaiting_Token, Streaming);

   type Slot is record
      State       : Slot_State := Empty;
      Deadline_Ms : Fructus.Ports.Epoch_Ms := 0;
      Forwarded   : String (1 .. Nuntius.Web.Max_Forwarded) := [others => ' '];
      Forwarded_Len : Natural range 0 .. Nuntius.Web.Max_Forwarded := 0;
   end record;

   function Adopted_At (O : Offered; Now : Fructus.Ports.Epoch_Ms) return Slot
   is ((State => Awaiting_Token, Deadline_Ms => Now + Auth_Deadline_Ms,
        Forwarded => O.Forwarded, Forwarded_Len => O.Forwarded_Len));

   function Judged (S : Slot; Accepted : Boolean) return Slot
   is ((S with delta State => (if Accepted then Streaming else Empty)));

   function Expired (S : Slot; Now : Fructus.Ports.Epoch_Ms) return Boolean
   is (S.State = Awaiting_Token and then Now >= S.Deadline_Ms);

   --  The stream task's body: adopt what the lobby holds, judge first
   --  frames, push documents as the pace allows, until Stop.
   procedure Run (P : Ports; G : Fructus.Web.Auth.Guard);

end Fructus.Web.Stream;
```

The peers themselves (limited `Nuntius.Ws.Peer` objects) live in a
body-level array beside the `Slot`s, indexed alike; `Slot` stays a
plain record so its transitions are pure functions the tests call.
The lobby is a protected object in the body: `Serving : Boolean :=
False`, `Occupied : Natural range 0 .. Max_Clients := 0`, `Pending :
array (1 .. Max_Clients) of Offered`, `Count`. `Offer` refuses unless
`Serving and then Occupied < Max_Clients`, and on acceptance
increments `Occupied` and queues; `Take` dequeues (occupancy
unchanged); `Release` decrements `Occupied` (called by the stream task
each time a slot is freed, for whatever reason); `Set_Serving` is
called by `Run` on entry (True) and in its `exception`/normal exit
(False). `Room` is `Serving and then Occupied < Max_Clients`. [R1] One
count, owned by one object, so a socket between `Take` and its slot
is never uncounted. [R2] `Take`, `Release`, `Set_Serving` and the
`Slot` functions are in the SPEC because the RED tests name them. `Fructus.Web.Peers is new Nuntius.Ws.Peer
(Max_Inbound_Bytes => Fructus.Web.Stream_Frame.Max_Frame)` at library
level in the body (`gpr/fructus_web.gpr:9` withs `nuntius`).

The task body, as named package-level subprograms (each under
R1/R2/R3; the executor measures with `python3
tools/fructustools/shape_check.py`):

```
Run:
   check ports (null → warn "web: stream missing ports; off", return)
   Stream_Wake.Arm             -- the reader arms (runtime.adb:123-129 precedent)
   Lobby.Set_Serving (True)
   Log "web: stream on (/api/stream, up to 8 clients)"
   loop
      exit when Stop or passes spent
      Wait_Any ([Stream_Wake.Fd, slot fds...], Slice_Ms, Ready)
      if Ready (wake): Nuntius.Fd_Wake.Drain (Stream_Wake.Fd)
      Adopt_Pending (Now)            -- Lobby.Take → free slots
      Read_Slots (Ready, Now, G)     -- Pump each slot with Readable => Ready (k); judge first frames
      Expire_Silent (Now)            -- awaiting past deadline → Close 1008, Release
      Push_Due (Now)                 -- per Streamed doc: Due? render once, send to every Streaming slot
   end loop
   Close every slot with 1000, Release each
   Lobby.Set_Serving (False)
   Log "web: stream stopped"
exception: Lobby.Set_Serving (False); re-raise (Log_Task_Death is the task body's)
```

`Judge (Slot, H : Hello, Now)`: `Auth.Accepts (G, Token_Of (H))` →
`Send_Text (Hello_Json)`, then `Send_Doc` for each of the four
`Streamed`, state `Streaming`, log `web: stream client <n> signed
in<xff>`; refused → `Auth.Note_Refusal (Throttle, Now,
Slot.Forwarded)`, `Close (4401)`, `Release`. `Push_Due (Now)`:
`Pulse.Peek (G)`; for each `D in Streamed`: `if Due (G (D) /= Clocks
(D).Gen, Elapsed (Now, Clocks (D)), Cadence (D))` then `Render (D)`
once into a local String (declare block) and `Send_Doc` to each
`Streaming` slot; `Clocks (D) := (Sent => True, At_Ms => Now, Gen => G
(D))`. `Send_Doc` failing (`Ok = False`) frees the slot with one log
line `web: stream client <n> dropped (send)` and a `Release`. `Render
(D)` is the `Serve_Document_Route` case, over `Collect` and `Render`,
returning `Envelope (Doc_Name (D), Body)`. A slot's `Pump` reporting
`Closed` or `Faulted` frees it (`web: stream client <n> closed`) and
`Release`s.

`Judge` sends the four documents but does NOT touch `Clocks`: the
task-wide clocks belong to `Push_Due` alone, and a fresh client's four
documents are per-client sends. Slots are indexed `1 .. Max_Clients`;
`<n>` in log lines is the slot number, never an address.

### WP-F5 -- the HTTP side of the handoff (`fructus-web-server.adb`)

RED, `fructus_web_tests.adb`: a pure `Upgrade_Verdict` in
`Fructus.Web`:

```ada
   type Stream_Gates is record
      On      : Boolean;
      Room    : Boolean;
   end record;

   type Upgrade_Answer is (Take, Not_Upgrade, Off, Full);

   function Upgrade_Verdict (Gates : Stream_Gates; R : Request) return Upgrade_Answer
   is (if not R.Upgrade then Not_Upgrade
       elsif not Gates.On then Off
       elsif not Gates.Room then Full
       else Take);
```

(A record, not two Boolean parameters: R7.) Tests: the four verdicts.

`fructus-web-server.adb`, at PACKAGE level ([R1]: `Run` already
carries five waived nested bodies and a waiver may not be added):

```ada
   --  Set once by Run before the loop starts; the loop is serial.
   Stream_On : Boolean := False;

   function Takes (R : Fructus.Web.Request) return Boolean
   is (Fructus.Web.Route_Of (Fructus.Web.Target_Of (R)) = Api_Stream
       and then Fructus.Web.Upgrade_Verdict
                  ((On => Stream_On, Room => Fructus.Web.Stream.Room), R)
                = Fructus.Web.Take);

   procedure Hand_Over (R : Fructus.Web.Request; Sock : GNAT.Sockets.Socket_Type) is
      Accepted : Boolean;
   begin
      Fructus.Web.Stream.Offer (Sock, Fructus.Web.Forwarded_For_Of (R), Accepted);
      if not Accepted then
         GNAT.Sockets.Close_Socket (Sock);   -- filled between Room and Offer
      end if;
   end Hand_Over;
```

`Run` sets `Stream_On := C.Stream;` before the instantiation, which
gains `Accepts_Upgrade => Takes, Adopt => Hand_Over`. `Hand_Over`
cannot raise past its `Close_Socket` (wrap that one call in a
`begin ... exception when others => null; end`, as the accept loop's
own handler does at `nuntius-web-server.adb:260-265`).

`Serve_Get` gains one arm, `when Api_Stream => Serve_Stream_Refusal
(Upgrade_Verdict ((Stream_On, Stream.Room), R), Respond)`, where the
new package-level `Serve_Stream_Refusal` answers `Not_Upgrade` → `426
websocket only`; `Off` → `503 stream off`; `Full` → `503 stream full`
(and, when `Stream.Room` is False because the task is not serving,
the same `503`; the body reads `stream down` if `Serving` is exposed
-- the executor may add `Fructus.Web.Stream.Serving return Boolean`
for the distinction or keep one body; either is fine). `Take` cannot
reach `Serve_Get` (the loop adopted it) and is its own arm raising
nothing: answer `503` defensively. [R1] `Serve_Get` measures 31 lines
today; one arm fits without extraction. `Handle`'s `when others` path
already routes a POST on `Api_Stream` to `405 POST not accepted here`.

`Serve_Get` needs the request now, not only the target, for
`Upgrade_Verdict`. Its signature today is `(P; C; R : Route; Target :
String; Respond)` (`:245-252`): rename the route parameter `Which`
(matching `Handle`'s own local at `:324`) and replace `Target` with `R
: Request`, so the count stays 5; `Serve_Asset` takes
`Asset_Name_Of (Target_Of (R))` (its `Pre` holds by `Target_Len`'s
subtype).

Startup lines, after the token line: `web: stream on (/api/stream)` or
`web: stream off (stream = false)`.

### WP-F6 -- the task (`fructus-runtime.ads/.adb`, `fructus-main.adb`)

`fructus-runtime.ads`, after `Web_Task` (`:257`):

```ada
   --  The dashboard's push channel; the same stack, it renders the
   --  same documents.
   task type Web_Stream_Task
     with Storage_Size => Fructus.Web.Server.Task_Stack_Bytes;
```

Body, beside `Web_Task`: `Guard; if Current.Web.Enabled and then
Current.Web.Stream then Fructus.Web.Stream.Run (P => (Stop =>
Shutdown.Requested'Access, Clock_Ms => Clock.Now_Ms'Access, Max_Passes
=> 0), G => Auth.Of_Token (To_String (Current.Web_Token))); else Log
"web: stream task off"; end if;` with the same `Log_Task_Death` handler
(`Fructus.Notify.Web`).

`fructus-main.adb`: `Web_Stream : Fructus.Runtime.Web_Stream_Task;`
beside `Web` at `:132`; `abort Web_Stream;` in `Abort_All` (`:135-148`)
beside `abort Web`; `Web_Done` (`:150-151`) becomes `Web'Terminated
and then Web_Stream'Terminated`. [R1] A task missing from the abort
list is one the backstop cannot kill.

A stream task that dies runs `Run`'s handler (`Set_Serving (False)`)
and then `Log_Task_Death`; the HTTP task's `Room` reads False from
then on and every upgrade answers `503`. A `Storage_Error` at task
CREATION is raised in the root's declaring block, not in the body, and
takes the siblings with it -- the same exposure `Web_Task` has today;
`Serving` starts False, so nothing is admitted to a task that never
ran.

### WP-F7 -- the page (`ui/src/api/stream.ts`, `ui/src/api/useStream.ts`, `ui/src/lib/streamOpen.ts`, `ui/src/api/queries.ts`, `ui/src/App.tsx`, `ui/src/App.test.tsx`, `ui/vite.config.ts`)

RED, `ui/src/api/stream.test.ts` (node):

- `streamUrl ({protocol: "https:", host: "h:9321"}) === "wss://h:9321/api/stream"`,
  `http:` → `ws://`.
- `backoffAfter (0) === 1000`, `(5) === 30000`, `(50) === 30000`.
- `helloFrame ("t") === '{"token":"t"}'`.
- `parseFrame ('{"hello":{"proto":1}}')` → `{kind: "hello", proto: 1}`;
  `parseFrame (JSON.stringify ({doc: "positions", body: positionsGolden}))`
  → `{kind: "doc", doc: "positions", body: <the golden as PositionsDoc
  parses it>}`; an unknown `doc` → `null`; a `body` failing its schema
  → `null`; a frame with no `body` → `null`; `'{"hello":{"proto":2}}'`
  → `{kind: "hello", proto: 2}` (the hook decides); `parseFrame ("not
  json")` THROWS (the hook's `try` is the catch, pinned here).

```ts
import { PositionsDoc, ScheduleDoc, SeriesDoc, StatsDoc, StreamFrame } from "./schema";

export const STREAM_PATH = "/api/stream";
export const PROTO = 1;
export const REFUSED_CODE = 4401;
export const SILENCE_MS = 10000;
const BACKOFF_MS = [1000, 2000, 4000, 8000, 16000, 30000];

export const DOC_SCHEMAS = {
  positions: PositionsDoc, stats: StatsDoc, schedule: ScheduleDoc, series: SeriesDoc,
} as const;
export type DocName = keyof typeof DOC_SCHEMAS;

export const streamUrl = (loc: { protocol: string; host: string }): string =>
  `${loc.protocol === "https:" ? "wss" : "ws"}://${loc.host}${STREAM_PATH}`;

export const backoffAfter = (failures: number): number =>
  BACKOFF_MS[Math.min(failures, BACKOFF_MS.length - 1)] ?? 30000;

export const helloFrame = (token: string): string => JSON.stringify({ token });

export type Frame =
  | { kind: "hello"; proto: number }
  | { kind: "doc"; doc: DocName; body: unknown };

const isDocName = (s: string): s is DocName => s in DOC_SCHEMAS;

export const parseFrame = (text: string): Frame | null => {
  const raw = StreamFrame.safeParse(JSON.parse(text));
  if (!raw.success) return null;
  if ("hello" in raw.data) return { kind: "hello", proto: raw.data.hello.proto };
  if (!isDocName(raw.data.doc)) return null;
  const body = DOC_SCHEMAS[raw.data.doc].safeParse(raw.data.body);
  return body.success ? { kind: "doc", doc: raw.data.doc, body: body.data } : null;
};
```

`StreamFrame` in `schema.ts`: `z.union ([z.object ({hello: z.object
({proto: z.number ()})}), z.object ({doc: z.string (), body: z.unknown
()})])`. [R1, zod 4.6.5] `z.unknown ()` is REQUIRED at runtime, so a
missing `body` fails as wanted; `z.object` strips unknown keys; a
discriminated union does not apply (no shared literal key); `safeParse`
with the `as const` map type-checks under TypeScript 6.0.3 strict.
`JSON.parse` of a non-JSON text throws: `parseFrame` is called inside
a `try` in the hook, and a throw counts as `null`.

RED, `ui/src/lib/streamOpen.test.ts`: `readStreamOpen ()` starts
False; `setStreamOpen (true)` makes it True and announces to a
subscriber. Two exports only, `readStreamOpen` and `setStreamOpen` (a
`useStreamOpen` hook has no consumer: not written).

RED, `ui/src/api/useStream.dom.test.tsx` (`// @vitest-environment
jsdom`). The fake: `class FakeWebSocket` with `static instances`, the
constructor recording `url`, `send (text)` pushing to `sent`, `close
(code?)` RECORDING `closedWith` and doing nothing else ([R1]: the
browser delivers `close` asynchronously, and a fake that fires it
synchronously hides the double-dial bugs), plus test-only drivers
`fireOpen ()`, `fireMessage (text)`, `fireClose (code)` that dispatch
`Event`/`MessageEvent`/`CloseEvent` to the handlers. Installed with
`vi.stubGlobal ("WebSocket", FakeWebSocket)` in `beforeEach` (the
`App.test.tsx` pattern for `fetch`), `vi.unstubAllGlobals ()` and
`cleanup ()` in `afterEach`, `vi.useFakeTimers ()`. `document.hidden`
is a getter-only accessor: set it with `Object.defineProperty
(document, "hidden", { configurable: true, get: () => true })` and
`document.dispatchEvent (new Event ("visibilitychange"))`. The
component under test is a two-line `Probe` that calls `useStream` and
renders nothing, inside a `QueryClientProvider` AND a `<StrictMode>`
wrapper ([R2]: `@testing-library/react`'s `render` applies no
StrictMode of its own). [R2] The fake lives in `ui/src/lib/testWs.ts`
beside `testGoldens.ts`, because `App.test.tsx` stubs it too. [R2] An
open socket left idle past `SILENCE_MS` of fake time is CUT and
redials -- correct behaviour, so a "no redial after 30 s" check must
either feed a frame or run against a socket that is already null
(the 4401 and hidden cases are).

- mounts with a token → ONE live socket (StrictMode mounts twice:
  `instances[0].closedWith === 1000`, `instances[1]` is live, and a
  late `fireClose` on `instances[0]` changes nothing) at
  `ws://localhost:3000/api/stream` (jsdom's origin); `fireOpen ()` →
  `sent[0] === '{"token":"t"}'`, `readStreamOpen () === true`.
- a `fireMessage` with the positions golden → `queryClient.getQueryData
  (["positions"])` equals the parsed golden and `getQueryState
  (["positions"]).dataUpdatedAt > 0`.
- `fireClose (1000)` on the live socket → `readStreamOpen () ===
  false`, a redial after `1000` ms (a new instance), the next after
  `2000`; `fireOpen` on it resets so the next close redials at 1000.
- a `fireClose` on a socket that is NOT the current one (the
  StrictMode-closed first instance, or after a token change) → no
  redial, `readStreamOpen ()` unchanged, no `invalidateQueries`.
- `fireClose (4401)` → `onRefused` called once, NO redial after 30 s;
  changing the token prop → a new instance dials (`instances.length
  === 2`; the refused socket was the SERVER's close, so there is
  nothing for the cleanup to close).
- changing the token prop on an OPEN socket → the old one
  `closedWith === 1000` and a new instance dials.
- unmount (sign-out: token → "") → the socket `closedWith === 1000`;
  a later `fireClose (1000)` on it dials nothing and sends nothing.
- hidden (`defineProperty` + event) → `closedWith === 1000` and no
  redial after 60 s even if `fireClose` is delivered; a pending
  redial timer set before hiding never dials; visible again → a new
  instance dials at once.
- no message for `10_000` ms after `fireOpen` → `closedWith === 1000`,
  `readStreamOpen () === false`, `invalidateQueries` called once, and
  a new instance dials after `1000` ms; a socket that never opens →
  the same at 10 s from dial. ([R2] These are the RED for `retire`:
  a sketch whose guard eats its own close passes the `closedWith`
  half and fails the rest.)
- `fireMessage ('{"hello":{"proto":2}}')` → `closedWith === 1000`,
  `readStreamOpen () === false`, `invalidateQueries` called, and no
  redial.
- with an empty token → no instance is created.

```ts
import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { backoffAfter, helloFrame, parseFrame, PROTO, REFUSED_CODE, SILENCE_MS, streamUrl } from "./stream";
import { readToken } from "@/lib/token";
import { setStreamOpen } from "@/lib/streamOpen";

//  One socket per page; only the CURRENT socket's events act.
export const useStream = ({ token, onRefused }: { token: string; onRefused: () => void }) => {
  const queryClient = useQueryClient();
  useEffect(() => {
    if (token === "") return;
    let ws: WebSocket | null = null;
    let failures = 0;
    let refused = false;
    let stopped = false;
    let redial: ReturnType<typeof setTimeout> | undefined;
    let silence: ReturnType<typeof setTimeout> | undefined;

    const drop = (code: number) => {
      const old = ws;
      ws = null;
      clearTimeout(silence);
      old?.close(code);
    };
    //  A close WE asked for: the guard ignores its onclose, so the
    //  bookkeeping a server close would do happens here.
    const retire = (redialAfter: boolean) => {
      drop(1000);
      setStreamOpen(false);
      void queryClient.invalidateQueries();
      if (redialAfter && !refused) schedule();
    };
    const schedule = () => {
      clearTimeout(redial);
      redial = setTimeout(() => {
        if (!stopped && !refused && !document.hidden && ws === null) dial();
      }, backoffAfter(failures++));
    };
    const dial = () => {
      clearTimeout(redial);
      const sock = new WebSocket(streamUrl(location));
      ws = sock;
      const armSilence = () => {
        clearTimeout(silence);
        silence = setTimeout(() => { if (sock === ws) retire(true); }, SILENCE_MS);
      };
      armSilence();
      sock.onopen = () => {
        if (stopped || sock !== ws) return;
        sock.send(helloFrame(readToken()));
        failures = 0;
        setStreamOpen(true);
        armSilence();
      };
      sock.onmessage = (e: MessageEvent<string>) => {
        if (stopped || sock !== ws) return;
        armSilence();
        let frame = null;
        try { frame = parseFrame(e.data); } catch { frame = null; }
        if (frame === null) return;
        if (frame.kind === "hello") { if (frame.proto !== PROTO) { refused = true; retire(false); } return; }
        queryClient.setQueryData([frame.doc], frame.body);
      };
      sock.onclose = (e: CloseEvent) => {
        if (stopped || sock !== ws) return;
        ws = null;
        clearTimeout(silence);
        setStreamOpen(false);
        void queryClient.invalidateQueries();
        if (e.code === REFUSED_CODE) { refused = true; onRefused(); return; }
        if (!refused) schedule();
      };
    };
    const onVisibility = () => {
      if (document.hidden) { clearTimeout(redial); if (ws !== null) retire(false); }
      else if (ws === null && !refused) dial();
    };
    document.addEventListener("visibilitychange", onVisibility);
    if (!document.hidden) dial();
    return () => {
      stopped = true;
      document.removeEventListener("visibilitychange", onVisibility);
      clearTimeout(redial);
      drop(1000);
      setStreamOpen(false);
    };
  }, [token, queryClient, onRefused]);
};
```

[R2] `retire` exists because the identity guard also ignores a close
the hook itself asked for: without it a silence cut left
`readStreamOpen ()` true, every interval reading `false`, and no
redial -- a page with neither socket nor polls. The three self-closes
(silence, proto mismatch, hidden) go through it; the cleanup does not
invalidate (a sign-out invalidates in `App`, a token change's new
socket feeds the cache itself). `close ()` on a socket still
CONNECTING is legal (Chrome logs an informational "closed before the
connection is established"; leave it). A proto mismatch sets
`refused` so the ladder stops (D24); a sign-in (token change) re-runs
the effect and tries again. `stopped` is READ in every handler ([R1]: the earlier sketch assigned it and never read
it, which `noUnusedLocals` and oxlint both reject). `void` on the
floating promises, the file's convention (`App.tsx:62`).

`queries.ts`: `usePositions`, `useSchedule`, `useSeries` get
`refetchInterval: () => readStreamOpen () ? false : (document.hidden ?
HIDDEN : LIVE)`; `useStats` gets `() => readStreamOpen () ? false :
HEALTH_MS` (it has no hidden variant). `App.tsx`: `useStream ({token,
onRefused})` after the three queries, where `onRefused` is a
`useCallback` that does ONE thing: `void queryClient.invalidateQueries
({queryKey: ["positions"]})` -- the poll's 401 then sets the
`signedOut` latch at `:47` within one fetch ([R1]: setting the latch
directly is undone on the next render by `:48`, because the stream
left the query in `success`). `App.test.tsx`: `vi.stubGlobal
("WebSocket", FakeWebSocket)` beside its `fetch` stub, or the tests
that hold a token dial a real undici socket. `vite.config.ts`: `proxy:
{ "/api": { target: "http://127.0.0.1:9321", ws: true } }` ([R1]
verified against Vite 8.3's proxy code; Vite's own HMR socket is keyed
on the `vite-hmr` subprotocol and does not clash). `ConnectionDot` is
unchanged. Comments in the new files: one terse line where a reader
would otherwise stop, none elsewhere.

### WP-F8 -- build, size, glossary, config comment

`make web`, `make web-check`, commit `web/` (the hash changes; [R1]
measured 1_013_369 bytes, about 10.6 kB under Vite's 1_024_000-byte
warning line -- the NEXT module trips the warning, which is a warning,
not a failure). `docs/glossary.md` gains `**Stream**` (the
dashboard's push channel; `/api/stream`, one websocket per page,
documents in an envelope, the polls as fallback) and `**Pulse**` (the
per-document generation counters the publishers bump). `fructus.toml`'s
`[web]` comment gains the `stream` line (WP-F1).

### WP-F9 -- push and land

Push `web-stream`; it lands on `main` together with (or after)
`web-close` and `web-day-chart` per the standing rule. Record the sha
for WP-B.

---

## 5b. Work packages, arb-ada (WP-B)

RED: none (a repin and a declaration; the build is the test).

1. `alire.toml:48` fructus commit → the WP-F9 sha; `alire.toml:66`
   nuntius commit → the WP-N6 sha; `proof/proof.gpr:36` and `:40`
   Source_Dirs for `fructus_<sha8>` and `nuntius_<sha8>`. `alr update`.
2. `src/app/arb_main.adb:725`: `Web_Stream : Fructus.Runtime.Web_Stream_Task;`
   beside `Web`; `abort Web_Stream;` in the abort list (`:1065-1084`,
   beside `abort Web` at `:1084`); `Web_Stream'Terminated` beside
   `Web'Terminated` at `:1095`.
3. `make web` (copies the pin's `web/`), `make web-check`, `make test`,
   `make prove`, `make format`, `make dag-check`, `alr
   --non-interactive build --validation`.
4. `arb.toml`'s `[web]` comment (`:441`) gains the `stream` line.
5. Copy this file to `docs/web-stream-plan.md` in fructus (canonical
   from then on) and nuntius.

---

## 6. TDD order (the RED that starts each package)

| # | repo | RED | file |
|---|---|---|---|
| 1 | nuntius | `Test_Upgrade_Request_Parsed` | `tests/src/nuntius_web_tests.adb` |
| 2 | nuntius | `Test_Upgrade_Needs_All_Four`, `Test_Upgrade_Head_Bytes`, `Test_Never_Upgrade`, `Test_426_Head_Carries_Upgrade` | same |
| 3 | nuntius | `Test_Server_Header_Short/16/64/Decodes`, `Test_Close_Payload` | `nuntius_rfc6455_tests.adb` |
| 4 | nuntius | `Accept_Key` RFC example | `nuntius_web_handshake_tests.adb` (new) |
| 5 | nuntius | (refactor, no RED) `Nuntius.Socket_Io.Send_All` extracted; server tests stay green | |
| 6 | nuntius | the ten `Nuntius_Ws_Peer_Tests` | `nuntius_ws_peer_tests.adb` (new) |
| 7 | nuntius | `Test_Wait_Any_Reports_Ready` | `nuntius_fd_poll_tests.adb` |
| 8 | nuntius | `Test_Upgrade_Is_Adopted`, `Test_Upgrade_Refused_Reaches_Handle`, `Test_Plain_Get_On_Stream_Path` | `nuntius_web_server_tests.adb` |
| 9 | fructus | route, `Needs_Token`, `Doc_Name` | `fructus_web_tests.adb` |
| 10 | fructus | `stream` knob | `fructus_web_config_tests.adb` |
| 11 | fructus | pulse counters and wake | `fructus_web_pulse_tests.adb` (new) |
| 12 | fructus | `Test_Publish_Bumps_Pulse` and the schedule/samples assertions | `fructus_web_stats_tests.adb`, `fructus_web_schedule_tests.adb`, `fructus_web_samples_tests.adb` |
| 13 | fructus | `Test_Table`, `Test_Due`, `Test_Elapsed` | `fructus_web_stream_pace_tests.adb` (new) |
| 14 | fructus | first-frame grammar | `fructus_web_stream_frame_tests.adb` (new) |
| 15 | fructus | `Test_Envelope_Pinned` | `fructus_web_render_tests.adb` |
| 16 | fructus | `Test_Slot_Lifecycle`, `Test_Lobby_Bounds` | `fructus_web_stream_tests.adb` (new) |
| 17 | fructus | `Upgrade_Verdict` | `fructus_web_tests.adb` |
| 18 | fructus | `stream.test.ts`, `streamOpen.test.ts`, `useStream.dom.test.tsx` | `ui/src/...` |

Every new AUnit file is registered in the suite the same commit it is
created. One commit per red/green/refactor cycle, logged in
`docs/tdd-log.md`.

---

## 7. Verification checklist

Against a running `fructus` (or `arb`) with `[web] enabled = true`,
`WEB_TOKEN` set, `bind = "127.0.0.1"`, `port = 9321`. Node 22 has a
global `WebSocket`, so no extra tool is needed. [R1] Node's client
fires `error` and NEVER `close` on a failed handshake (a browser fires
both, with `1006`), so the 426/503 checks below key on `error`.

```sh
# 1. the upgrade, by hand
printf 'GET /api/stream HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n' | nc -q1 127.0.0.1 9321 | head -4
# expect: HTTP/1.1 101 Switching Protocols / Upgrade: websocket / Connection: Upgrade / Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=

# 2. a plain GET
curl -si http://127.0.0.1:9321/api/stream | head -2
# expect: HTTP/1.1 426 Upgrade Required / Upgrade: websocket

# 3. the stream, end to end
node -e '
const ws = new WebSocket("ws://127.0.0.1:9321/api/stream");
ws.onopen = () => ws.send(JSON.stringify({ token: process.env.WEB_TOKEN }));
ws.onmessage = (e) => { const f = JSON.parse(e.data); console.log(Date.now(), Object.keys(f)[0], f.doc ?? "", e.data.length); };
ws.onerror = () => console.log("error");
ws.onclose = (e) => console.log("close", e.code);
setTimeout(() => ws.close(1000), 12000);'
# expect, in order: hello, doc positions, doc stats, doc schedule, doc series, then positions about every 1-2 s, stats every 5-10 s; close 1000 at the end
# (ws.close() with NO code would print close 1005: the server echoes the empty payload, RFC 6455 7.1.5)

# 4. a refused token
WEB_TOKEN=wrong node -e '<the same script>'
# expect: close 4401 within a second, nothing before it

# 5. silence
node -e 'const ws = new WebSocket("ws://127.0.0.1:9321/api/stream"); ws.onclose = (e) => console.log("close", e.code);'
# expect: close 1008 after 5 s

# 6. the fallback
# set [web] stream = false, restart; the browser page shows the dot green and the values moving at 1 Hz; the network tab shows /api/positions every second and a failed /api/stream at about 1, 3, 7, 15, 31 s and then every 30 s (the ladder)
# set it back; reload: the network tab shows ONE /api/stream (101) and, once the first frame has landed, NO periodic /api/positions -- one more poll may fire from a timer armed before the socket opened, and a window focus or a close command still fetches once (TanStack's refetchOnWindowFocus and the invalidates)

# 7. the proxy
# from a phone through https://<machine>.<tailnet>.ts.net/: the network tab shows the 101 and the frames; lock the phone 30 s, unlock: a new socket within about a second of the old close landing, and the values current
# through Funnel from OFF the tailnet: the same

# 8. the log
grep 'web: stream' logs/*.log | head
# expect: "stream on (/api/stream, up to 8 clients)", "client 1 signed in xff=...", on the phone lock "client 1 closed"

# 9. nine clients
# run item 3's script eight times in the background (a hidden browser tab holds NO socket, so tabs cannot fill the lobby); a ninth: "error" at once, and the server log shows the 503; kill one; the ninth retried: hello
```

Plus every gate of sections 4 and 5, and the bundle size line from
`make web`.

---

## 8. Failure modes (design them in, then test them)

| failure | behaviour | decided by |
|---|---|---|
| the proxy does not forward the upgrade | 4xx/5xx or a hang on the handshake; the 10 s silence timer armed at dial cuts a hang; the hook backs off on the ladder and the polls run | D8, D9 |
| a client stops reading (a phone in a tunnel) | `Send_Timeout` 2 s fires, the slot is freed with one log line; other clients are late by at most 2 s that pass | D20 |
| a half-open connection (NAT dropped it, nobody sent FIN) | the server notices when its 2 s heartbeat send fails; the browser notices at 10 s of silence and redials | D6, D9 |
| a close that lands late (StrictMode, a token change, a hidden tab) | ignored: it is not the current socket's | D9 |
| a publisher bumps 10 times a second | the counter moves, the wire waits for `Min_Ms` | D5, D6 |
| the stream task dies | `Set_Serving (False)` in its handler, then `Log_Task_Death` alarms via `Notify.Web`; upgrades answer `503`; the page polls | WP-F4, WP-F6 |
| the token changes on the server (a restart with a new `WEB_TOKEN`) | the old socket dies with the process; the redial's first frame is refused `4401`; the poll's 401 shows the form | D9 |
| a stale bundle on a new server or the reverse | `proto` in `hello`; a mismatch closes `1000` and polls until the next sign-in | D24 |
| a client sends 1 MB | `1009` at the 512-byte cap, before any buffer past 512 + 14 bytes exists | D12 |
| `Natural'Last` generations | wrap to 0; a wrapped counter still differs from the last sent value | WP-F2 |
| the lobby fills between `Room` and `Offer` | `Offer` refuses; `Hand_Over` closes the socket; the client redials on the ladder | WP-F5 |
| two first frames from one client | the second and later text frames are dropped unread | D13 |
| a `send(2)` that succeeds on a peer that already sent FIN | the next `Pump` reports `Closed` and frees the slot; nothing is lost but one frame the peer will never read | WP-N4 |

---

## 9. Deliberately out of scope

- Compression (`permessage-deflate`): the documents are small and the
  proxy already encrypts; a later plan measures first.
- Binary frames, fragmentation of server frames, server-initiated
  pings: none needed; the content heartbeat is the keepalive.
- A per-client outbound ring or non-blocking sends (D20 says why).
- A subscription grammar (D13).
- Sharing one socket across tabs (`BroadcastChannel`): eight slots
  are plenty for one operator.
- Streaming `/metrics`: Alloy scrapes.
- Re-basing `Nuntius.Ws.Native_Client` on `Nuntius.Ws.Peer` (D23).
- Deltas instead of whole documents: the documents are tens of KB at
  most; a diff protocol is a second schema to keep.
- TLS in the binary: the proxy's job, as before.
- Moving the running boxes to `bind = "127.0.0.1"` behind the proxy:
  the web-close plan's migration, still pending, independent of this.

---

## 10. Open items

1. Tailscale Serve/Funnel and `Upgrade`: Go's reverse proxy forwards
   it, and third-party reports show websockets through Serve, but the
   Tailscale docs do not state it. Checklist item 7 settles it on the
   real box; until then D8 is the insurance.
2. `Stream.Serving` as a public function so the `503` body can say
   `stream down` rather than `stream full`: cosmetic; the executor
   decides.

---

## Execution prompt (hand this to the implementing model)

> Implement `docs/web-stream-plan.md`. Three repos, in this order:
> nuntius (`~/git/nuntius`, branch `web-stream` cut from `web-post`,
> in a git worktree), then fructus (`~/git/fructus`, branch
> `web-stream` cut from `web-day-chart`, in a git worktree -- never in
> the checkout itself), then arb-ada (`~/git/arb-ada`, branch
> `web-stream` cut from `web-day-chart`). Read each repo's `CLAUDE.md`
> first and follow its strict TDD protocol: the RED test named in
> section 6 comes before every production change, one commit per
> red/green/refactor cycle, each cycle logged in `docs/tdd-log.md`
> (newest on top), files staged explicitly (never a bare `git add
> -u`). Commit messages: gitmoji shortcode prefix, imperative subject,
> a body naming the units touched, no test/prove counts. Comments in
> code are minimal and terse; the plan's sketches explain more than
> the code should.
>
> Every `file:line` in the plan was verified on 2026-09-18 against
> nuntius `2755761`, fructus `b24353a6` and arb-ada `d88da04`; if a
> line has moved, find the named subprogram or export. Where the plan
> gives Ada or TypeScript, use it verbatim; where it sketches, keep
> the names and adapt to what compiles. The intent -- one websocket
> per page at `GET /api/stream`, the token as the first frame and
> never in the URL, the GET documents byte for byte inside a one-key
> envelope, push on change announced by the publishers through
> `Fructus.Web.Pulse` and paced by the D6 table, the HTTP task handing
> the socket to a second task through a bounded lobby with one
> occupancy count, unmasked header-only server frames, a peer that
> drains its buffer before it reads, the polls kept as the fallback
> and fed from the same TanStack cache, only the current socket's
> events acting in the hook, a refused token stopping the redial --
> is binding. In fructus `tools/shape-waivers` may only shrink; never
> add a waiver line; nothing new nests in `Fructus.Web.Server.Run`;
> never touch `Publish_Stats` in the driver; add the new task to BOTH
> composition roots' abort lists.
>
> Do not put the token in a URL, a log line or a test name; do not
> mask a server frame; do not copy a document into an octet buffer;
> do not block the trading tasks on the stream task; do not add an
> npm dependency; do not let a fake `WebSocket` fire `close`
> synchronously from `close ()`.
>
> Push nuntius BEFORE repinning fructus, and fructus BEFORE repinning
> arb-ada; a nuntius repin is two files in fructus AND two in arb-ada
> (`alire.toml` and `proof/proof.gpr`). Gates before declaring a repo
> done: nuntius `make test`, `make prove`, `make format`, `alr
> --non-interactive build --validation`; fructus those plus `make
> dag-check`, `make shape-check`, `make web-test`, `make web-check`;
> arb-ada `make test`, `make prove`, `make format`, `make dag-check`,
> `make web-check`, `alr --non-interactive build --validation`; and
> the section 7 checklist against a running binary and a browser.
> Report what each gate printed and the measured bundle size; if a
> gate fails, say so rather than working around it.
