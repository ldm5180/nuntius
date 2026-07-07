# nuntius

Narrow HTTP and websocket client transports for Ada 2022, with SPARK-proven
buffering.

`nuntius` (Latin: *messenger*) packages the transport edge of a hexagonal
application as reusable ports and adapters. The ports are deliberately tiny —
exactly the shapes a REST-and-streaming application needs — so tests plug in
scripted fakes and stay fully offline, while production plugs in the adapters
shipped here.

## What's in it

- **`Nuntius.Http`** — the HTTP client port: a form-encoded `POST` (OAuth
  token endpoints), a JSON `POST` that captures the `Location` header (REST
  APIs that return a created resource's id there), and Bearer-authorized
  `GET` / `DELETE`. Every call reports `Ok : out Boolean` instead of raising.
- **`Nuntius.Http.Curl`** — the production adapter over libcurl
  ([utilada](https://github.com/stcarrez/ada-util)), with request timeouts so
  a black-holed connection can never wedge a synchronous caller.
- **`Nuntius.Ws`** — the websocket client port: dial, send one text frame,
  block for the next inbound text frame, hang up.
- **`Nuntius.Ws.Aws_Client`** — the production adapter over the
  [AWS](https://github.com/AdaCore/aws) crate's client-side websocket,
  generic over its ring bounds. Inbound frames are pumped into a bounded
  FIFO; close/error callbacks and an idle limit (a silent TCP partition
  never fires a callback) mark the connection reconnect-worthy.
- **`Nuntius.Frame_Fifo`** — the bounded, heap-free FIFO of text frames
  behind the websocket adapter, in the SPARK core: its ring arithmetic and
  refusal semantics are *proved*, not unit-tested.

## Use it

Add the dependency (via a git pin until it is in the community index):

```toml
[[depends-on]]
nuntius = "*"
```

```ada
with Nuntius.Ws.Aws_Client;

package My_Ws_Client is new
  Nuntius.Ws.Aws_Client (Ring_Depth => 1_024, Max_Frame_Bytes => 2_048);
--  My_Ws_Client.Client implements Nuntius.Ws.Transport.
```

Consumers that prove their own core are expected to instantiate
`Nuntius.Frame_Fifo` in their proof harness at the exact numbers their
adapter uses — gnatprove analyses a generic only through its instances.

## Develop

```sh
make build    # build the library
make test     # AUnit suite, both -O modes (loopback refusals only, no network)
make prove    # SPARK proof, --checks-as-errors=on
make format   # gnatformat --check
make example  # build the demo mains both ways (CI builds them, running is manual)
make run      # build and run the http_get example (needs a network)
make help     # all targets
```

The demo mains live in [example/src](example/src): `http_get [URL]` fetches a
page over the curl adapter; `ws_listen WS_URL [PAYLOAD]` dials a websocket,
optionally sends one subscribe frame, and prints the first inbound frames.

Conventions (SPARK, strict TDD, commit style) live in [CLAUDE.md](CLAUDE.md).
