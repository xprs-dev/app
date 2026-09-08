# XPRS in a browser

The same Dart source that builds the desktop and phone apps also builds as a
web page (`flutter build web`, dart2js). This page is what that build is, what
it is not, how it is tested without a screen, and what was found while making
it compile and boot again (2026-09-07).

[architecture.md](architecture.md) governs here as everywhere: transports are
CORE and nothing blocks the UI isolate. A browser removes most of the
transports and all of the isolates, so the web build is the one target where
those two rules are tested by absence rather than by discipline.

## What a browser can and cannot do

| | native | web |
|---|---|---|
| GeoUI, launcher, wapp screens, i18n, App Creator | yes | yes, same code |
| wasm wapps (`wasm_run`) | wasmtime over FFI | the browser's own `WebAssembly` API |
| SQLite | `package:sqlite3` over FFI, SQLCipher | the same package's `wasm.dart`: `sqlite3.wasm` over an IndexedDB VFS |
| files | the disk | an in-memory tree persisted to IndexedDB |
| profile encryption | SQLCipher + AES-GCM archive | **no**: a web profile stays plain (see below) |
| NOSTR relays (`wss://`) | yes | yes, same `web_socket_channel` client |
| Reticulum (TCP, UDP, LAN discovery) | yes | **no**: a page cannot open a socket |
| BLE5, GATT/MSP, LoRa, WiFi-Direct | yes | **no** |
| I2P router, torrents, shared folders, bulk spool | yes | **no** |
| `/api/status`, `/api/log`, Blossom and NOSTR **servers** | yes | **no**: a page cannot listen |
| isolates (`rns-crypto`, `rns-transport`, `nostr-engine`) | yes | **no**: everything runs on the main thread |
| video playback (native process / hardware) | optional | **no** |

So a web node today is a leaf with no radio and no mesh: it runs wapps, keeps
a profile across reloads, and can talk to NOSTR relays. It reaches the mesh
once the device that serves the page also lends it a bearer, which is the
design in "Next: Reticulum in the browser, with no proxy" below.

**Verified in headless Chromium** (`tool/web_smoke.py`, fresh profile every
run): the launcher boots in about 2 s; Continue on the welcome page creates a
profile and the launcher appears with hero cards, the wapp list and the quick
launch row; the Chat wapp opens to `#LOCAL`; the background engines of chat,
mail and torrents run their wasm; a reload comes back to the launcher with the
same profile. After that run IndexedDB holds 2696 records in the file tree and
six SQLite files (104 blocks). No uncaught exception, no error toast.

## Building and running

```sh
~/bin/android-build-locked flutter build web --no-tree-shake-icons --pwa-strategy=none
./launch-web.sh            # builds, packs ../wapps, serves on :8080
```

Every `flutter build` goes through the lock (CLAUDE.md); dart2js takes about
55 s here. The bundle is `build/web`: `main.dart.js` (7.8 MB release, 21 MB
`--profile`), `sqlite3.wasm` (0.7 MB, copied from `web/`), CanvasKit and the
assets. `.github/workflows/build-web.yml` builds it on every push and pull
request.

`--pwa-strategy=none` stays: the service worker cached a stale `main.dart.js`
across rebuilds, and `web/index.html` still carries the one-shot purge for
browsers that registered one under an earlier build.

### Testing it without touching the user's screen

Headless Chromium needs no X server, so nothing here goes near `DISPLAY=:0`.
The launcher draws with CanvasKit, so the DOM holds nothing useful, and
Chromium's own `--screenshot` fires on `load`, long before Flutter has
painted. `tool/web_smoke.py` drives a page over the DevTools protocol instead:

```sh
(cd build/web && python3 -m http.server 8099 --bind 127.0.0.1 &)
CDP_FRESH=1 tool/web_smoke.py http://127.0.0.1:8099/ 12 /tmp/run \
    shot:welcome click:304,384 wait:10 shot:launcher reload wait:14 shot:back
```

It streams console lines and uncaught exceptions, clicks, reloads (the
persistence test), evaluates JS and captures screenshots. **On web the browser
console is the log window**: `LogService.add` mirrors every line there,
because there is no `/api/log` to serve it. `flutter build web --profile`
keeps Dart names in stack traces when a minified one is not enough.

Two traps: the snap Chromium can write only under `~/snap/chromium/common`,
and `pkill -f <pattern>` from a shell whose own command line contains the
pattern kills that shell (exit 144); use `fuser -k PORT/tcp`.

## The port, seam by seam

### Measured first

The first build produced 1318 error lines. Every one was `dart:ffi`:

| source | lines | via |
|---|---|---|
| `package:sqlite3/sqlite3.dart` (its FFI half) | 1290 | 22 files: 11 app, 7 reticulum-dart, 4 encrypted_archive |
| `sqlcipher_flutter_libs` | 8 | `profile_db.dart` |
| direct `dart:ffi` in the app | 13 | `folder_export.dart`, `native_process_video_player.dart` (`Abi`) |
| direct `dart:ffi` in reticulum-dart | 4 | `nostr_engine.dart` (isolate library override) |
| `io_stub.dart` drifted from `dart:io` | 8 | `wapp_engine.dart` (`RawSynchronousSocket`, `Socket.listen`) |
| 64-bit integer literals | 4 | `i2p_crypto.dart` SipHash constants |

Two assumptions from the survey turned out false, and they shaped the work:

- **`dart:io` and `dart:isolate` compile under dart2js.** Fifty-five app
  files and thirteen reticulum-dart files import `dart:io` unconditionally
  and not one is a compile error; every call throws `UnsupportedError` at
  runtime. So the compile blocker was FFI alone, and the `dart:io` work is a
  runtime port done file by file, guided by what actually throws in the smoke
  run (`_Namespace` is a `File`/`Directory`, `Platform._operatingSystem` a
  `Platform.isX`, `ReceivePort.listen` an isolate).
- `wasm_run`'s browser path needs no FFI fix: `compileWasmModule` dispatches
  to `wasm_interop` (the browser's `WebAssembly`) and never touches the Rust
  bridge.

### SQLite: one package, two halves

`package:sqlite3` ships an FFI binding and a wasm binding behind one
`CommonDatabase` interface. Every store types its handle as `CommonDatabase`
and imports `package:sqlite3/common.dart`; the FFI import survives in three
files, each compiled only natively:

| seam | native | web |
|---|---|---|
| `lib/profile/profile_db.dart` → | `profile_db_io.dart` (SQLCipher, keyring) | `profile_db_web.dart` (`WasmSqlite3.loadFromUrl`, `IndexedDbFileSystem`) |
| reticulum-dart `db_opener.dart` → | `db_opener_io.dart` (`sqlite3.open`) | `db_opener_stub.dart` (throws until the host injects) |
| encrypted_archive `sqlite_loader.dart` → | `sqlite_loader_flutter.dart` / `_pure.dart` | `sqlite_loader_stub.dart` (throws until the host injects) |

The host injects where it already did (`ProfileService.load`):
`reticulum.dbOpener`, `reticulum.dbMemoryOpener`, and on web
`SQLiteLoader.override`. Natively encrypted_archive keeps its own default,
because a `profile.ear` inside an encrypted profile must not get a SQLCipher
key on top of its own encryption.

`openPlainDb` is new: the mailbox spool and the gossip visit table were opened
with a bare `sqlite3.open` before, deliberately unkeyed even inside an
encrypted profile, and switching them to `openProfileDb` would have tried to
key existing plaintext files. They stay plain, through the seam.

`initProfileDb()` is awaited in `initStorageRoot()`: a no-op natively, the
wasm fetch and VFS open on web. Opening a database before that is a
`StateError`, never a silent in-memory database.

The web opener sets `PRAGMA temp_store = MEMORY` and `journal_mode = MEMORY`.
Without the first, SQLite opens its scratch files (the temporary database an
`ALTER TABLE` uses, statement journals) through the VFS with a NULL name, and
sqlite3 2.4.5's IndexedDB VFS dereferences it: `Cannot read properties of
null (reading 'toString')` from inside the wasm import table, which surfaced
as the wapp mailbox failing to open. WAL needs shared memory the VFS has not.

**`web/sqlite3.wasm` is pinned to the pub version of `package:sqlite3`**
(2.4.5 today: <https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-2.4.5>).
Bump both together.

**Encrypted profiles do not exist on web.** The stock wasm has no SQLCipher.
The multi-cipher build (`sqlite3mc.wasm`) exists only from `sqlite3` 2.7 and
uses a different on-disk format, so a profile encrypted on a phone would not
open in a browser even then. Profile creation on web therefore skips the
device-key step and logs `encryption: not available on web -- profile X stays
plain`; `openProfileDb` on web refuses an encrypted profile with
`UnsupportedError` rather than open it as plaintext; asking for password
encryption from the profile page throws the same.

### Files: one seam, two backing stores

`lib/platform/fs.dart` exports a `package:file` `FileSystem` named `fs`:
`LocalFileSystem` natively, a `MemoryFileSystem` on web. The API is
`dart:io`'s, sync variants included (the WASM HAL callbacks are synchronous),
so a port is `File(p)` → `fs.file(p)`. `ProfileStorage` stays the app-level
door; its one backend (`profile_storage_fs.dart`) sits on `fs` for every
target, and the localStorage backend is gone. reticulum-dart has the same
seam (`reticulum.fileSystem`, injected in `initStorageRoot`) for the files it
keeps itself: follow sets, the relay hub config, partial downloads, the
parents of its SQLite files.

Persistence on web (`fs_web.dart`): a timer stats the tree every 500 ms and
commits what changed (mtime, size, kind) to IndexedDB in one transaction;
`flushFs()` does the same on demand and `pagehide`/`visibilitychange` call it.
No write path is wrapped, so `openWrite`, `RandomAccessFile`, rename and
delete are all caught. A stat on a `MemoryFileSystem` is a map lookup, so the
walk over a few thousand entries costs about a millisecond; it is the one
sub-minute timer this codebase runs on purpose. Blobs from the old
`xprs.storage:*` localStorage keys are carried into the tree once and the
keys removed.

Why this replaced localStorage, measured: the old backend re-serialised the
**entire** file table to base64 JSON on **every** write. With the 14 MB
`mp4player.wapp` in the table the bundled-wapp install stalled the main
isolate for 236 s (`perf: main isolate stalled ~235958ms`), every later
install for 5-8 s, and the 5 MB quota then rejected the whole blob, so
nothing persisted. On IndexedDB the same install is a 650 ms stall, once.

The in-memory tree is the whole "disk", in the heap, at most twice (tree +
the transaction's copy). It is for profiles, wapp packages and settings, not
for a media archive; quota is the browser's
(`navigator.storage.estimate()`).

`Platform.isX` throws on web; services ask `platform.isAndroid` and friends
from `lib/platform/platform.dart` instead, and `nativeBinaryKey()` (which
needs `dart:ffi`'s `Abi`) lives behind `lib/platform/native_abi.dart`.

### What refuses, and how

Nothing on web pretends. `ensureRnsAutostart` logs once, `RNS autostart:
Reticulum is not available on web (no TCP/UDP/BLE transport in a browser)`,
and returns before the hub loop and the BLE fallback; the Blossom server is
not started; `exportArchiveFile` returns null like an archive without the
key. The stores that the autostart wires before that point (hero inbox,
followed media, mailbox, relay store paths) are wired on web too, so a
WebSocket interface later slots in under them.

The remaining unconditional `dart:io` importers are the native-only services
(sockets, I2P, torrents, bulk spool, update mirror, video players,
`open_path`) and reticulum-dart's socket interfaces and isolate workers. They
compile, throw if reached, and are recorded in `tool/arch_baseline.txt` under
the `no-native-import-outside-io-file` rule, which fails the build on any new
one outside a `*_io.dart` file, in `lib/` and in the reticulum-dart sibling.

### wasm_run in a browser

Two patches to the vendored copy, both documented in
`third_party/wasm_run/README.xprs.md`:

- **The i64 boundary.** The browser's WebAssembly API hands an `i64` import
  parameter to JS as a `BigInt` and requires a `BigInt` back for an `i64`
  result; a Dart int is a JS `Number`. `hal_time_epoch` and `hal_time_ms`
  return `i64`, so every wapp raised `TypeError: Cannot convert 1788797831 to
  a BigInt` once a second, as a red toast on the launcher. Imported functions
  whose signature names an `i64` are now converted at the boundary.
- **The WASI shim is vendored.** The loader imported
  `@bjorn3/browser_wasi_shim` from jsdelivr at runtime, so a web build needed
  the internet to start a wapp. The package's `dist/` (Apache-2.0) sits under
  `lib/assets/browser_wasi_shim/`.

`--wasm` (dart2wasm) stays out: `wasm_run`'s web half and `wasm_interop`
use `dart:html` and `dart:js_util`, which dart2wasm does not have.

## Performance on web

Everything the native build puts on `rns-crypto`, `rns-transport` and
`nostr-engine` would run on the main thread in a browser, which is the exact
configuration [performance.md](performance.md) §3.1 describes as having wedged
the app. Today none of them start on web (no transport), and the shedding
caps and the `perf: main isolate stalled` heartbeat stay armed so the cost is
visible in the console when they do. Pure-Dart secp256k1 is slower again
under JavaScript's `BigInt`. A Web Worker port bridge is the follow-up, not
part of this.

Measured on this laptop's headless Chromium (software WebGL): first frame
about 2 s after `main.dart.js` arrives; the bundled-wapp seed 650 ms; profile
creation 1.4 s; opening the Chat wapp 300 ms.

## Next: Reticulum in the browser, with no proxy

Not built. This is the agreed design, written down so it can be picked up
without re-deriving it.

### Why a browser cannot dial a hub, ever

Port 4242 is raw TCP carrying HDLC-framed RNS packets: `0x7E` flag delimiters,
`0x7D` escape with `^0x20` byte-stuffing, one packet per frame (RNS 1.3.5
`TCPInterface.py`; our wire-compatible copy is `rns_hdlc.dart`). There is no
HTTP at any layer of it.

A browser may open `fetch` (needs an HTTP response, and cross-origin needs CORS
headers), `WebSocket` (needs an HTTP `101 Switching Protocols` handshake with a
`Sec-WebSocket-Accept` digest), WebRTC (ICE/DTLS plus signalling) or
WebTransport (HTTP/3). A stock hub answers none of them — it will try to
HDLC-deframe `GET / HTTP/1.1` as garbage and stay silent. Upstream Reticulum
has twelve interface types (Auto, Backbone, TCPServer, TCPClient, UDP, I2P,
RNode, RNodeMulti, Serial, Pipe, KISS, AX25KISS) and not one is HTTP- or
WebSocket-shaped.

So this is the browser sandbox, not a gap in our code. And a relay to fake the
handshake would make an offgrid app depend on infrastructure, which is the one
thing it must not do.

### The design: the device is the endpoint

An XPRS node is already a first-class member of the mesh, and on capacity it
already promotes itself to a transport hub for its neighbours. Teach that hub
to accept a WebSocket and to serve the web bundle, and a browser attaches
through an XPRS device exactly as a BLE-only phone attaches through the phone
beside it. Topology, not a proxy: the same hop a Bluetooth-only device already
depends on.

Because the host is a full node, the browser inherits **everything that node
can reach** — its BLE neighbours, LAN peers, LoRa, and its internet hub
uplinks. The WebSocket is one more `RnsInterface` on the same transport, so a
path learned on any bearer is a path the browser can use.

```
   phone browser ──http──▶ XPRS laptop  ──BLE5──▶ neighbour phone
        │  (page + wapps)      │        ──LAN───▶ peers on the wire
        └──ws:///rns──────────▶│        ──LoRa──▶ station
          (Reticulum uplink)   └────────tcp:4242▶ public hubs
```

Serving the page from the same device is not a convenience. A page served from
`https://xprs.dev` may not open `ws://192.168.1.5` (mixed content), so hosting
the page anywhere else would force TLS onto every node. Served from the node,
the socket is same-origin: no certificate, no DNS, no internet.

### Parts

**1. `RnsWsServerInterface`** — `reticulum-dart/lib/src/services/reticulum/
rns_ws_server_interface_io.dart`, modelled on `rns_tcp_server_interface.dart`
(215 lines), whose shape is already right: a factory that spawns one
`RnsInterface` per accepted connection and registers it itself.

- `HttpServer.bind` + `WebSocketTransformer.upgrade`, the pattern proven in
  `nostr_ws_server.dart:92,154` — including its lesson that a non-upgrade GET
  on the same port must be answered with UTF-8 **bytes**, not a String.
- `class _RnsWsServerConn implements RnsInterface`: the `WebSocket`, one
  `RnsHdlcDeframer` each, `send` = `ws.add(hdlcFrame(raw))`, label
  `ws#<n>:<remote>:<port>`, `edge` false so it is a core interface and gets the
  announce treatment a LAN neighbour gets.
- Registers through `RnsInterfaceRegistry` (`rns_transport.dart:108`), so it
  works against `RnsTransport` or `RnsTransportClient` unchanged.
- The TCP server's first-byte demux is unnecessary: the HTTP upgrade already
  discriminates. Named `*_io.dart` so the guard passes with no baseline entry.

**2. The web host** — `app/lib/services/web_host_service_io.dart` (conditional
export, no-op stub elsewhere): one `HttpServer` serving the built web bundle
for ordinary GETs and upgrading `/rns` to part 1.

It **rides `_applyHubRole`** rather than inventing a second switch.
`rns_service.dart:1420-1460` already promotes a node to a transport hub on a
capacity gate (mains plus wired/Wi-Fi), already opens an `RnsTcpServerInterface`
on `_lanHubPort` for neighbours, and already demotes when capacity drops.

- **Forwarding requires the transport role.** `_maybeForward`
  (`rns_transport.dart:1214`) returns false the moment `transportId` is null, so
  a browser client is reachable, and can route, only while the host holds the
  hub role. That role is deliberately off on phones — `rns_service.dart:3110`
  records why: relaying the hubs' whole announce flood saturates a phone and
  made file transfers stall. Hosting must not add a back door around that gate.
- **BLE peers reach the browser through the bridge that already exists.**
  `edgeBridge` (`rns_service.dart:1487`) relays BLE-only peers up onto the core
  interfaces and `edgeQuiet` keeps the internet flood off BLE air. A browser on
  a non-edge WebSocket sits on the core side of that policy, so it sees BLE
  neighbours with nothing new invented and not one extra frame on the radio.
- Off by default, explicit Settings toggle, configurable bind host and port —
  it exposes the device on the LAN. Static files only: no API, no profile data,
  nothing writable.
- Bundle at `data/web/` in the desktop release, added to the tarball in
  `build-linux.yml`. 54 MB today (27 MB CanvasKit, 18 MB assets, 7 MB
  `main.dart.js`) — trim the CanvasKit variants and leave the 14 MB
  `mp4player.wapp` out of the served copy before this goes near a phone.
  Desktop first; the same service compiles on Android for later.

**3. `RnsWsInterface`** — the client, a near-copy of `rns_tcp_interface.dart`
(144 lines) with `Socket` → `WebSocketChannel`.

- `send(raw)` = `ch.sink.add(hdlcFrame(raw))`; inbound messages feed one
  `RnsHdlcDeframer`, each frame to the `onPacket` callback.
- `WebSocketChannel.connect` plus the guards `nostr_ws_client.dart` already paid
  for: the mandatory `ready` timeout, the post-handshake race guard, the 45 s
  idle watchdog standing in for TCP keepalive.
- `speedRank` 2, `hardwareMtu` `kRnsLinkMtuMax`, `edge` **false**,
  `announceOnly` false. A WebSocket uplink is internet-class, not a BLE edge
  (`rns_transport.dart:56-59`) — the earlier note in this file said `edge: true`
  and that was wrong.
- Label `ws:<host>:<port>`, not the URL: the label is the `via` tag handed back
  to `ingestRaw`, and `_isPrivateHost` (`rns_iface_kind.dart:47`) parses
  `host:port` out of it. Add `ws` to the `tcp`/`udp` branch at `:35` so a host
  on the LAN is coloured local, not internet.
- Not web-only: one desktop can dial another this way, which is how it gets
  tested on Linux before a browser is involved.

On web the default uplink is the page's own origin (`ws://<host>/rns`), so the
ordinary case needs no configuration. `_parseHostPort`
(`rns_autostart.dart:190`) also learns `ws://`/`wss://` entries so one bootstrap
list carries both kinds; `rns_service.dart` gains a `wsclient` mode beside
`tcpclient` at `:4019` with `_attachWsUplink` modelled on `_attachTcpUplink`
(`:1339`), the single door where an uplink is built and registered. `_clients`,
`_dropClient`, `_reconnectUplink` and `_watchdogTick` are typed
`RnsTcpInterface` today and move to a shared supertype rather than growing a
second copy of the 30 s silence rule.

**4. Web Workers for crypto and transport.** Both protocols are already
structured-clonable — crypto exchanges `[id, opIndex, Uint8List, Uint8List?,
Uint8List?]` (`rns_crypto.dart:311`), the engine `List<Object?>` of tags, ints,
bools and `Uint8List` (`rns_transport_engine.dart:409-465`) — so a Worker is a
drop-in for a `SendPort`, not a redesign.

- Seam `lib/src/util/worker_channel.dart`: `send(List<Object?>)`,
  `Stream<List<Object?>> messages`, `kill()`. io side is today's
  `Isolate.spawn`; web side is `Worker(url)` + `postMessage`/`onmessage`.
- Entry points `tool/web_workers/rns_{crypto,transport}_worker.dart`, compiled
  after the Flutter build with `dart compile js -O2 -o build/web/…`, kept out of
  `web/` so Dart source is not copied into the bundle. Added to
  `launch-web.sh` and `build-web.yml`.
- Possible only because `rns_crypto.dart`, `rns_transport.dart`,
  `rns_packet.dart` and `rns_identity.dart` import no `dart:io` and no
  `package:flutter` — verified 2026-09-07. Keeping that true is the maintenance
  risk, so the seam falls back to in-process with a loud log line, never to a
  silently half-working node.
- **`ed25519Verify` needs an inline fallback regardless**
  (`rns_crypto.dart:228-240`): the other six ops fall back when the worker is
  unavailable, but verify returns `out == true`, so a missing worker fails every
  announce signature and the node learns no paths at all. Same inline path as
  its siblings, shed-under-load still failing closed. This is a live bug for any
  target without isolates, not only a web concern.

**5. Later, optional: a WebSocket interface for upstream RNS.** Parts 1-3 give a
browser the whole mesh through an XPRS device. The only way a browser ever dials
`rns.wisco.network` itself is if hubs learn the handshake, so the honest long
game is to write it: `contrib/rns/WebSocketInterface.py` in the upstream plugin
shape, HDLC inside binary WebSocket messages, byte-identical to
`TCPServerInterface` above the framing so our client talks to both unchanged.
Run it on our own hub, offer it upstream. Not on the critical path.

### How it gets verified

1. Desktop to desktop, no browser: node A hosting, node B dialling
   `ws://A:8080/rns`; `/api/status` shows the uplink and an announce from A
   reaches B. Proves both interfaces before any web variable exists.
2. Workers on the VM: reticulum-dart's 418 tests green with the channel seam,
   plus a test that forces the crypto worker unavailable and asserts
   `ed25519Verify` still accepts a good signature and still rejects a forged one.
3. The offgrid case, which is the point: laptop hosting, cable out or on an
   isolated AP, phone browser on `http://<laptop>:8080`; the browser announces
   under its own identity and a message goes browser → laptop → a third device
   over BLE5 with no internet anywhere in the path. Checked with the RNS
   diagnostic endpoints, not by eye.
4. Every bearer, not one: with the laptop's hub uplinks back on, the browser
   sees public-hub announces *and* the BLE neighbour, and `rnsIfaceKind` colours
   each path by the bearer it was learned on.
5. The phone rule is not broken: a battery phone with hosting requested does not
   silently become a transport node — the capacity gate still decides, and the
   log says which way it went.
6. The workers earn their keep: `perf: main isolate stalled` and frame times
   under an announce flood, workers on and forced off, both numbers recorded
   here. If the split does not move them, say so.

### Risks to keep in view

Exposing a device on the LAN (off by default, static files only); transport-node
duty on battery (the existing gate is the guard); 54 MB of bundle in a desktop
release; a `package:flutter` import drifting into the crypto or transport cone,
which silently breaks the worker build.

This is CORE (architecture.md §3: "does it move bytes between devices?"), never
a wapp concern.

## Out of scope for this pass

Everything in "Next: Reticulum in the browser, with no proxy" above, which is
designed but not built: the WebSocket bearer, the per-device web host, and the
Web Workers. Also encrypted profiles on web; `--wasm`; shared
folders, torrents, bulk spool, media archive serving; video playback; the PWA
service worker; a GitHub Pages deployment; multi-tab safety (the IndexedDB
VFS is single-tab; a second XPRS tab on the same origin corrupts the SQLite
files); Firefox and Safari; `flutter_secure_storage` on web is localStorage,
so the device key would not be hardware-backed there, which is one more
reason web profiles stay plain.
