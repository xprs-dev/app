# Plan: `xprs-dev/server` — the XPRS server edition

Status: **Phases 0 and 1 done (2026-11-04)**: `reticulum-dart` is plain Dart and the XPRS core lives in `xprs-dev/core`, reached by the app only through `CoreHost` seams (architecture.md §2a). Phase 2 MVP is running (2026-11-05): `../server` (not yet on GitHub) brings up the core headless (Reticulum transport on TCP 4242 with hub uplinks, the LAN bridge, the public archiver) and serves the webchat on HTTP with the core's `WebChatApi`; identity is the server's own X3 callsign (D3), TLS is left to a reverse proxy (D5). Decisions marked **(D1)…(D6)** are open
and listed at the end.

## 1. What it is

A headless XPRS station for Linux machines with mains power and a fixed
internet connection (a VPS, a home server, a Raspberry Pi on a shelf). One
`dart compile exe` binary, run by systemd, no Flutter, no GUI. It does two
jobs:

1. **Reticulum gateway on the internet.** It's a promoted transport node
   (architecture.md §4, "The station as a Reticulum transport node"): it
   accepts standard Reticulum clients on TCP 4242, keeps uplinks to the public
   hubs, answers path requests for everything it holds, and forwards. XPRS
   apps, Sideband/NomadNet and ESP32 stations can all use it as their way in.
2. **Bridge for local devices.** On the server's own network it speaks the
   local bearers (XPRS LAN UDP 4242, Reticulum LAN discovery, later USB serial
   and BLE) and carries what it hears onto the internet path and back. That's
   the same `XprsBridge` + `PacketGateway` logic the phone runs.

Plus it **serves the web chat page** from `xprs-dev/webchat`, so a browser that
reaches the server (LAN or internet) can chat with no install, using the same
`spec/API-HTTP.md` subset the phone's share server answers.

What it is not: no wapps, no launcher, no user profile UI (see D4).

## 2. The blocker: the shared code can't be used from plain Dart today

Two things stand between a pure-Dart server and "one common implementation":

| Problem | Where | Size |
|---|---|---|
| `reticulum-dart` declares `flutter: sdk` because of BLE | 5 files in `lib/src/connections/bluetooth/` (`bluetooth_low_energy`, `ble_peripheral`) | small |
| The **XPRS core lives in the app**, not in a library | `lib/services/xprs` (52 files, ~19.7k lines), plus what it imports from `receive/`, `mesh/`, `social/`, `log_service`, `preferences_service`, `web_chat_api.dart` | large |

The good news: the core barely uses Flutter. Across `xprs/`, `mesh/` and
`social/` the only Flutter symbols are `visibleForTesting` (29×), `compute`
(9×), `ValueNotifier` (7×) and `setEquals`. The real ties are three app
singletons: `PreferencesService` (shared_preferences), `MeshService`
(battery_plus) and `BackgroundService` (power state). The app has done this
move once already: `lib/services/reticulum/*` are now one-line re-export shims
of `package:reticulum`. Phase 1 repeats that pattern.

## 3. Phases

### Phase 0 — make `reticulum-dart` pure Dart (library repo)

- Move the 5 BLE files into a sub-package `reticulum-dart/packages/reticulum_ble`
  (a Flutter package that depends on `reticulum`). Drop `flutter:` from the
  root `pubspec.yaml`; `flutter_test` becomes `test`.
- App: add `reticulum_ble` as a path dependency, fix imports. No behaviour change.
- Check: `dart test` passes in `reticulum-dart` (it can't run today without
  Flutter); the app builds and its tests still pass.

### Phase 1 — extract the XPRS core (app → library), shims left behind

Move bottom-up, one layer per commit, every commit green in the app:

1. Leaves: `xprs_packet`, `xprs_sig`, `xprs_id`, `xprs_vocab`, `xprs_body`,
   `xprs_callsign`, `xprs_parts`, … (no app imports).
2. Seams: replace the three Flutter symbols with plain Dart:
   `visibleForTesting` → `package:meta`, `compute` → `Isolate.run`,
   `ValueNotifier` → a ~30-line `Notifier<T>` in the library (Flutter widgets
   in the app wrap it). Replace the singletons with small interfaces the host
   injects:
   - `KeyValueStore` (app: shared_preferences; server: a JSON file)
   - `PowerSource` (app: battery_plus/PowerState; server: always on mains)
   - `CoreLog` (`LogService` is already pure, so it moves as-is)
3. The middle: `xprs_archive`, `xprs_ingest`, `xprs_bridge`, `xprs_lan`,
   `xprs_tcp`, `xprs_history_server`, `xprs_forwarder`, `xprs_digipeat`,
   `xprs_gateway_dedup`, `PacketGateway`, `WebChatApi`, and the parts of
   `mesh/` and `social/` that the bridge needs.
4. What stays in the app: anything with a widget, `MethodChannel`, Android or
   wapp host (`WappDelivery` becomes a callback the app registers).

`arch_guard` keeps running on the app; the `one-receive-door` rule moves into
the library's own checks. Every moved file stays reachable at its old path
through a shim until the app's imports are rewritten.

Where it goes (**D1**, decided): a new repo, `xprs-dev/core` (package
`xprs_core`), depending on `reticulum-dart`. Phase 0 and the first stage of
Phase 1 (47 files already free of Flutter and app services) are done; the rest
waits on the seams in step 2.

### Phase 2 — the server repo, MVP

```
server/
  bin/xprs_server.dart        entry: args, config, signals, start/stop
  lib/
    config.dart               YAML config → typed settings
    host/                     the server's implementations of the seams:
      kv_store_file.dart        KeyValueStore over a JSON file (atomic write)
      power_mains.dart          PowerSource: always unlimited
      paths.dart                data dir layout (/var/lib/xprs-server)
    station.dart              wires the core: identity, archive, RNS, bridge
    http/
      web_chat_server.dart      static page + WebChatApi over dart:io HttpServer
      admin_api.dart            loopback-only status/log/bearers, token
  web/chat_page.html          built from ../webchat (see below), not hand-edited
  tool/sync_web_chat.sh       same job as the app's: run webchat/tool/build.py
  deploy/xprs-server.service  systemd unit
  deploy/config.example.yaml
  docs/reusable.md            per the house rule; seeded from the app's list
```

What runs in the MVP:

| Function | Comes from | Notes |
|---|---|---|
| Identity / callsign | library (`NostrKeyGenerator`, `XprsSelf`) | generated on first run, stored 0600 in the data dir; import an nsec via CLI |
| RNS transport, hub role | library (`RnsTransport`, `RnsTcpServerInterface`) | always promoted: path answers for others, `edgeQuiet` |
| Uplinks to public hubs | library (`RnsTcpInterface`) | list in config; reuse the app's default hub list |
| RNS LAN discovery | library (`RnsAutoInterface` / LAN interface) | finds phones and stations on the same network |
| XPRS LAN bearer, UDP 4242 | core (`xprs_lan`) | reaches ESP32 stations with no Reticulum config |
| Bridge, dedup, archive | core (`XprsBridge`, `XprsGatewayDedup`, `XprsArchive`) | same rules the phone uses, same receive door |
| Web chat page + API | webchat repo + core `WebChatApi` | `/api/services` says `tabs: [chat, traffic, devices]`, `session: true` |
| Admin API | subset of app's remote API | `/api/status`, `/api/log`, `/api/xprs/bearers`, `/api/rns/status`; 127.0.0.1 only + bearer token |

The web page: the server serves `web/chat_page.html`, built from
`../webchat` by `webchat/tool/build.py`, the same way the app's
`tool/sync_web_chat.sh` does it. A test fails when the bundled copy drifts from
the webchat repo (the app has the same test). The webchat README gets a third
"edition" row for the server.

HTTPS: the server listens on plain HTTP and `deploy/` documents running it
behind Caddy or nginx for TLS (**D5**).

### Phase 3 — gateway duties beyond forwarding

- **Store-and-forward for absent peers.** It holds mail for callsigns that are
  offline and hands it over when they announce (`MeshCourier` custody /
  `xprs_mailbox`), with quotas and expiry in config.
- **Social relay / archiver role** (`RelayNode`, retention tiers) on the
  `unlimited` capacity profile, so phones can offload history to it.
- **NOSTR relays** for the internet side, if the core's publishers come along
  in Phase 1.
- Rate limiting per source on the public HTTP API and the TCP hub.

### Phase 4 — more local bearers

- **USB serial to a station** ("A cable is a lane too", architecture.md):
  plug an ESP32 into the server and it becomes the server's radio.
- **BLE5 via BlueZ** over D-Bus with `package:bluez` (pure Dart). The app's
  `tool/reticulum_ble_linux.dart` already proves extended advertising and
  scanning this way. It gives the server the off-grid broadcast plane when it
  has a Bluetooth adapter.

### Phase 5 — packaging and release

- CI: `dart test`, then `dart compile exe` for linux-x64 and linux-arm64,
  attached to GitHub releases. Releases follow the existing release rules.
- `.deb` with the systemd unit and a dedicated `xprs` user; a Docker image if
  wanted (**D6**).
- Runtime dependency: `libsqlite3` from the OS (the `sqlite3` package loads it
  over FFI). Use `libsqlcipher` if the archive must be encrypted at rest.

## 4. Testing

- Library: the moved core's tests run under plain `dart test` (today they need
  Flutter), so the server repo and CI get them for free.
- Interop: the app's existing tools already speak to a hub —
  `tool/reticulum_chat_client.dart`, `tool/lxmf_peer.py` (reference Python
  LXMF), `tool/reticulum_internet_test.dart`. Point them at the server.
- Web: webchat's `test/smoke.py` and `dm_smoke.py` run against the real server
  instead of `contract/mock_station.py`.
- End to end on hardware: an ESP32 station on the LAN plus a phone on mobile
  data, both reaching each other only through the server.

## 5. Risks

- **Phase 1 is the bulk of the work and touches the app everywhere.** It's
  done layer by layer behind shims so the app never breaks, but it's weeks,
  not days. The MVP needs only parts 1–3 of it.
- Hidden Flutter coupling deeper in the dependency graph (e.g. `media/`,
  `folders/`) may surface while moving. Anything that does gets an interface,
  or stays out of the server.
- The UI-isolate rule still matters on a server: heavy crypto/sqlite in the
  event loop stalls every connection. The same `Isolate.run` discipline
  applies.
- Two identities on one machine (the operator's phone profile vs the server's
  own) must not be confused (**D3**).

## 6. Decisions for you

- **D1** ~~Where the extracted XPRS core lives~~ — decided: `xprs-dev/core`.
- **D2** Repo name: `xprs-dev/server` (as asked), binary `xprs-server`.
- **D3** Identity: the server has its own callsign (recommended; the operator
  is listed as its owner via `xprs_owned_stations`), or it runs under the
  operator's profile.
- **D4** Wapps on the server: none in the MVP (recommended), or a headless
  wapp runner later (needs `wasm_run`'s Rust library on the server).
- **D5** TLS: behind a reverse proxy (recommended), or built in with
  Let's Encrypt.
- **D6** Distribution: binary + systemd + `.deb` (recommended), plus a Docker
  image or not.
