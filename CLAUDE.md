# nuntius

Narrow HTTP and websocket client transports for Ada 2022 — tiny ports
(`Nuntius.Http`, `Nuntius.Ws`), production adapters (libcurl via utilada
for HTTP, a hand-rolled RFC 6455 client over `GNAT.Sockets` for the
websocket), a SPARK-proven bounded frame FIFO (`Nuntius.Frame_Fifo`) and a
SPARK-proven wire codec (`Nuntius.Rfc6455`) doing the websocket adapter's
buffering and framing, packaged as a reusable, independently proven crate.

The ports are the product: exactly the shapes a REST-and-streaming
application needs, and nothing else, so consumers test against scripted
fakes fully offline and swap adapters without touching callers. Every
operation reports `Ok : out Boolean` rather than raising; `Ok` False on the
websocket port always means "reconnect-worthy".

## Commands

- `make build`   — build the library (`alr build`)
- `make test`    — AUnit suite in BOTH modes (release -O3, debug -O0);
  no network beyond loopback connection-refusals
- `make prove`   — SPARK proof, `--checks-as-errors=on`; must exit 0
- `make format`  — `gnatformat --check` over all committed Ada sources
- `make example` — build the demo mains both ways (CI builds, never runs them:
  they talk to real endpoints)
- `make run`     — build and run the release `http_get` example (needs network)
- `alr --non-interactive build --validation` — warnings-as-errors gate (CI)

## Layout

- `src/core/` — the SPARK core (`Nuntius.Frame_Fifo`, `Nuntius.Rfc6455`):
  every unit carries `SPARK_Mode`, does zero IO, and may `with` only other
  core units (and `Sml.*` where a unit is machine-backed).
- `src/app/`  — the ports and adapters: `Nuntius.Http` + `.Curl`,
  `Nuntius.Ws` + `.Native_Client`. All libcurl specifics stay behind `.Curl`
  (including `Register`, so consumers never `with Util.*`); all socket and
  RFC 6455 framing specifics stay behind `.Native_Client`.
- `tests/` — AUnit suite (`test_nuntius.gpr`, driver `test_runner.adb`).
- `example/` — standalone demo mains (`http_get`, `ws_listen`) showing the
  consumer story end to end; built in CI, run manually against real
  endpoints.
- `proof/` — gnatprove harness (`proof.gpr`; sources `../src/core` directly
  and withs nothing, keeping foreign code out of the proof tree).
- `docs/tdd-log.md` — git-ignored TDD audit log.

## SPARK

- Every `src/core` unit carries `SPARK_Mode`. After any core change,
  `make prove` must exit 0 (level 2, checks-as-errors). CI enforces the same.
- Prefer `Ok : out Boolean` results over exceptions; document and prove
  behavior with contracts (`Pre`, `Post`, loop invariants).
- gnatprove reasons about a generic only through a concrete instance:
  `proof/src/frame_fifo_proof.ads` instantiates `Nuntius.Frame_Fifo` at a
  production-scale and a tiny bound, and consumers are expected to prove
  their own instance at their exact numbers.

## TDD protocol (strict)

- Red/green/refactor, always: failing test first (RED = compile error or
  failed assertion), then the minimal code (GREEN), then refactor under
  green. No production code without a preceding failing test.
- Log every cycle in `docs/tdd-log.md` (git-ignored, newest entries on top):
  date, what changed, exact RED output, GREEN pass counts.
- One `<unit>_tests.ads/.adb` pair per library unit under `tests/src/`,
  registered in `nuntius_suite.adb`. Test routines use
  `AUnit.Assertions.Assert` and are wired via `Register_Routine`.
- Tests stay off the network: adapter tests use loopback
  connection-refusals only; everything else is pure.

## Programming best practices

- Lean hard into the type system; keep code DRY.
- Extract pure functions whenever possible — it forces naming and generality.
- Keep functions and procedures short and focused; move any second code block
  into its own named subprogram.
- Push exceptions and defensive programming into contracts and let the proof
  system do the heavy lifting; `SPARK_Mode => On` as much as possible.

## Style

- Formatting is `gnatformat`-enforced; wrap hand-aligned tables in
  `--!format off` / `--!format on`.
- Follow the Alire validation-profile switch set; fix warnings, never
  suppress them without a comment saying why.

## Commit style

- gitmoji `:code:` shortcode prefix + capitalized, imperative subject, no
  trailing period (`:sparkles:` feature, `:bug:` fix, `:recycle:` refactor,
  `:white_check_mark:` tests, `:wrench:` tooling, `:memo:` docs, `:fire:`
  removal).
- Never put test / prove / format result counts in commit messages.

## Port contracts (do not break)

- `Nuntius.Ws.Receive` with `Ok` False always means reconnect-worthy:
  closed, errored, oversized inbound frame, a frame too large for the
  caller's buffer, or a stream silent past the adapter's idle limit.
- A *full* inbound ring drops the newest frame and KEEPS the connection —
  a transient burst must never trigger a reconnect.
- `Nuntius.Frame_Fifo.Pop` consumes a non-empty fifo even when the frame
  does not fit the caller's buffer — an undeliverable frame must not wedge
  the queue. These semantics are proved by the Posts in
  `nuntius-frame_fifo.ads`; change the contracts only with the proof green.
- `Nuntius.Http` adapters never raise: transport failures come back as
  `Ok` False with `Status` 0, and every request carries a timeout so a
  black-holed connection cannot wedge a synchronous caller.
