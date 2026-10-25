# xprs (iwi/) reusable components

Catalog of reusable libraries inside the xprs Flutter launcher (`iwi/`).
Each entry should describe what the component does, where it lives, and the
non-obvious constraints a future caller needs to know.

> The wider xprs repo has its own `../docs/reusable.md` covering the
> parent app's components. This file is scoped to `iwi/lib/` only.

> **Prefer the wapp layer to the core engine.** Updating a wapp is cheap — it
> ships as a small `.wapp` through the Wapp Store with no reinstall. Updating the
> core engine means a **whole new APK** the user must download and install (a signed
> Android update, versionCode bump, slow rollout). So new functionality belongs in a
> **wapp** unless it genuinely cannot: a new transport, a HAL primitive, or a
> cross-cutting host service that many wapps share. The services catalogued below
> exist precisely so a wapp can reuse them instead of forcing a change into the
> engine — reach for one of these (or add a *generic* one) before growing the core.
> App-specific logic (APRS/Chat conventions, social rules) never goes in `lib/`; it
> lives in the wapp's C + GeoUI. When in doubt, the change goes in the wapp.

---

## Storage

### ProfileStorage — filesystem abstraction

**Files:**
- `lib/services/profile_storage.dart` — `ProfileStorage` (abstract),
  `StorageEntry`, `FilesystemProfileStorage`, `ScopedProfileStorage`
- `lib/services/storage_paths.dart` — helpers that hand back ready-to-use
  storages: `xprsRootStorage()`, `installedAppsStorage()`,
  `wappsDataStorage(prefs)`, `wappDataStorageFor(prefs, wappId)`,
  `wappPackageStorage(absPath)`

**What it is.** Every filesystem operation in xprs (iwi) goes through
`ProfileStorage`. No `dart:io` `File` / `Directory` calls anywhere else in
`lib/` — that rule is enforced by code review and the analyser will catch
slips because the storage call sites do not import `dart:io`. The pillar
exists so that the backing store can be swapped for an encrypted SQLite
archive (encrypted profiles), a browser IndexedDB tree (web build), or a
plain filesystem (today's desktop) without touching call sites.

**API surface** (mirrors the parent repo's
`lib/services/profile_storage.dart` so a shared package can be extracted
later with a single import change):

- Async file ops: `readString`, `readBytes`, `writeString`, `writeBytes`,
  `appendString`, `exists`, `delete`, `copyFromExternal`, `copyToExternal`
- Async directory ops: `listDirectory`, `createDirectory`,
  `directoryExists`, `deleteDirectory`
- JSON convenience: `readJson`, `writeJson`
- **Sync variants for WASM HAL callbacks**: `readBytesSync`,
  `writeStringSync`, `writeBytesSync`, `existsSync`. These exist only
  because WASM imports run synchronously and Dart `Future`s cannot be
  awaited from inside them. `FilesystemProfileStorage` implements them
  with `dart:io` sync methods. **Non-sync backends** (encrypted SQLite,
  browser IndexedDB) **must throw** `UnsupportedError` for these — and
  callers must fall back to a message-based async API in that case.

**Storage layout under the user home:**

```
~/.local/share/xprs/
  apps/<wapp-id>/    extracted .wapp packages (installed wapps)
  wapps/<wapp-id>/   per-wapp runtime data (kv.json, future hal_file_*)
```

The previous "iwi" codename left data under `~/.local/share/iwi/`. There
is no auto-migration; copy manually if needed.

**How wapps use it.**

- `WappEngine.setStorage(ProfileStorage)` — call before `load()`. The
  engine persists KV via the storage's sync variants from inside HAL
  callbacks.
- `wappPackageStorage(wappDir)` — wrap any wapp package directory
  (built-in `wapps/archive/<name>/` or installed) and use it to read
  `manifest.json`, `app.wasm`, `screens/*.ui.json`, and `media/*`.
- `wappDataStorageFor(prefs, wappName)` — per-wapp scoped storage for
  KV + future `hal_file_*` writes.

**Open question — `hal_file_*` (currently stubbed in `wapp_engine.dart`).**
The HAL declares synchronous `hal_file_open/read/write/close`. On
`FilesystemProfileStorage` this could be implemented with the sync
variants, but that locks `hal_file_*` to native filesystem backends. The
alternative is to redesign `hal_file_*` to be async with polling
(matching `hal_http_*`), which works on every backend but requires
updating `apps/hal/xprs_wasm_hal.h` and any wapp that touches files.
This decision is deferred until a real wapp needs file I/O on encrypted
or browser backends.

**Don't forget:**
- Use `ScopedProfileStorage(inner, 'subpath')` when a subsystem only
  needs a sub-tree — it auto-prefixes every operation and keeps call
  sites unaware of the absolute layout.
- For arbitrary external absolute paths (a user-typed source directory,
  for example) wrap the directory in a transient
  `FilesystemProfileStorage(absDir)` and use the basename as the
  relative path. Don't drop back to raw `File`.
- For tools like `unzip` that need a real on-disk path, use
  `storage.getAbsolutePath(rel)` to extract one — this works today
  because `installedAppsStorage()` is filesystem-backed. When an
  encrypted/IndexedDB backend lands the install flow will need to
  unzip into a temp dir then `copyFromExternal` each entry.

---

## Events

### EventBus — host-side type-safe broadcast bus

**File:** `lib/services/event_bus.dart`

**What it is.** Singleton broadcast channel for `AppEvent` subclasses.
Type-safe — `EventBus().on<MyEvent>(handler)` only fires for that
concrete type. Dispatch uses `event.runtimeType` so subclass events
route correctly even when fired via the base type. API mirrors parent
xprs's `lib/util/event_bus.dart`.

**Built-in events:**
- `AppStartedEvent` — fired once after launcher startup completes
  (after `_scanArchive` finishes). Background services that should run
  post-init subscribe to this.
- `WappLoadedEvent { wappId, wappName }` — wapp finished
  `module_init`.
- `WappUnloadedEvent { wappId, wappName }` — wapp page disposed.
- `WappCrashedEvent { wappId, phase, error }` — `phase` is `'load'`,
  `'init'`, `'tick'`, or `'handle_event'`.
- `WappEventBridgeEvent { fromEngineId, topic, data }` — bridged from
  the cross-wapp `WappEventBroker` so host observers can watch wapp
  pub/sub traffic.
- `ErrorEvent { source, message, error }` — generic error channel.
  `NotificationService` subscribes to this and auto-surfaces each
  `ErrorEvent` as an error-level notification.
- `NotificationShownEvent { notification }` — fired by
  `NotificationService.show` after a notification has been dispatched
  to backends. Use this to build a history / debug UI.

**Usage:**
```dart
final sub = EventBus().on<WappLoadedEvent>((e) {
  print('${e.wappName} loaded');
});
// ...later
sub.cancel();
```

Add new event types as subclasses of `AppEvent` directly in
`event_bus.dart` — keep them in one place so the catalogue is easy to
scan.

### WappEventBroker — cross-wapp pub/sub on top of `hal_event_*`

**File:** `lib/services/wapp_event_broker.dart`

**What it is.** Singleton router that backs the WASM HAL event
imports (`hal_event_subscribe`, `hal_event_unsubscribe`,
`hal_event_publish`, `hal_event_available`, `hal_event_recv`). Each
`WappEngine` registers itself with a stable `engineId` on
construction and unregisters on dispose; the broker holds
`{engineId → (subscribed topics, pending event queue)}`.

**Wire-up:** `WappEngine` constructor calls
`WappEventBroker.instance.registerEngine(engineId)`; the HAL function
imports in the engine's load() call into the broker. Already wired —
nothing for callers to do.

**Delivery model:**
- `publish(fromEngineId, topic, data)` fans out to every engine
  subscribed to the exact topic string (including the publisher
  itself if it subscribed). Each delivery appends a `_PendingEvent`
  to the recipient's queue.
- Wapps drain their own queue from inside `module_tick` /
  `module_handle_event` by polling `hal_event_available()` and then
  calling `hal_event_recv(topic_buf, topic_len, data_buf, data_len)`.
- The host can observe every published event by subscribing to
  `WappEventBridgeEvent` on the host `EventBus`.

**Backpressure:** each engine queue is capped at
`maxQueuePerEngine = 1024` events. When full, the **oldest** event is
dropped. Wapps that need lossless delivery must drain on every tick.

**Topic strings are exact-match.** No wildcards or hierarchy yet —
add later only if a real wapp needs it. Convention: dot-separated
namespacing (`chat.message.received`, `transfer.completed`).

**Don't forget:**
- Multiple wapp instances of the same wapp will get unique
  `engineId`s — the broker treats them independently. There is no
  per-wapp-name routing.
- The broker is **process-local**. Cross-process or cross-host event
  routing (mesh, BLE) is out of scope.

### HostEventBridge — host events → wapp topics

**File:** `lib/services/host_event_bridge.dart`

**What it is.** Subscribes to key host `AppEvent`s on `EventBus` and
republishes each one on `WappEventBroker` under a stable `system.*`
topic name. This is what lets wapps react to host-level events
(app started, wapp loaded, task failed, error fired) through the
normal `hal_event_subscribe` / `hal_event_recv` path — without this
bridge, host and wapp event namespaces would be fully isolated.

**Installed as a boot task.** `main.dart` registers
`HostEventBridge.instance.install()` as a `BootStart.parallel` task
on `BootOrchestrator`; once `runAll()` finishes the bridge is live.
Uninstall is only for tests.

**Bridged topics and payloads** (payloads are JSON strings):

| Topic                  | Fires when                              | Payload                                                             |
|------------------------|-----------------------------------------|---------------------------------------------------------------------|
| `system.app.started`   | launcher finishes boot (AppStartedEvent)| `{}`                                                                |
| `system.wapp.loaded`   | wapp finished `module_init`             | `{"wappId":"...","wappName":"..."}`                                 |
| `system.wapp.unloaded` | wapp page disposed                      | `{"wappId":"...","wappName":"..."}`                                 |
| `system.wapp.crashed`  | wapp threw during load/init/tick/event  | `{"wappId":"...","phase":"...","error":"..."}`                      |
| `system.error`         | `ErrorEvent` fired on host bus          | `{"source":"...","message":"..."}`                                  |

A wapp that wants to react to any of these calls
`hal_event_subscribe("system.wapp.loaded")` (or similar) and drains
events from `module_handle_event` / `module_tick` via
`hal_event_recv`. The `fromEngineId` on the bridged
`WappEventBridgeEvent` is always the literal string `"host"`.

**Working end-to-end example.** The **Tester** wapp
(`apps/tester/`) has an **Events** screen with buttons that
exercise every part of the pipeline:

- *Local pub/sub* — Subscribe `test.hello`, Publish `test.hello`,
  Unsubscribe `test.hello`, Full echo (subscribe + publish in one
  click).
- *Host triggers* — Subscribe `system.wapp.loaded` /
  `system.wapp.unloaded` / `system.error`. Open another wapp from
  the launcher after subscribing and a notification card pops out
  of the Tester wapp as the event arrives.

The Tester wapp drains its event queue in both `module_tick` (every
500 ms) and `module_handle_event` (so an `event-echo` click
produces a notification within one command round-trip). Each
received event is emitted as a `{"type":"notify",...}` message and
the host routes it through `NotificationService` → `NotificationLayer`
→ the stacking overlay. This is the simplest template for any new
wapp that wants to consume events.

**HAL subtlety — `hal_event_recv` null-terminates both buffers.**
Before writing to each destination buffer the host reserves one byte
for a `\0` terminator so that C wapps can `strlen()` the topic. The
return value is bytes written to the **data** buffer, not counting
the terminator — matching the `hal_msg_recv` convention. If you
call this from a non-C wapp that tracks lengths explicitly, just
ignore the terminator byte.

**One-way.** Wapp events do **not** get republished on the host
`EventBus` by this bridge. That direction is already covered by
`WappEventBroker.publish` firing `WappEventBridgeEvent` on every
publish — host observers can subscribe to that directly.

**Don't forget:**
- Adding a new bridged event = add a `_bridge<T>(...)` call inside
  `install()` AND a row in the table above. Schema changes to the
  JSON payload are breaking — bump the topic (e.g.
  `system.wapp.loaded.v2`) if a field needs to be renamed or
  removed.

---

## Notifications

### NotificationService — unified notification surface

**File:** `lib/services/notification_service.dart`

**What it is.** Singleton that every user-visible notification must
go through — from host services AND from wapps. Wraps multiple
`NotificationBackend` implementations and fans out each
`XPRSNotification` to the backends whose `handlesScope` matches.
Also subscribes to `ErrorEvent` on `EventBus` and auto-shows each
error as an error-level in-app notification.

**In-app display + backends shipped today:**
- In-app cards are drawn by `NotificationLayer` (in
  `notification_service.dart`), a **stacking overlay** installed via
  `MaterialApp.builder` (see `launcher/launcher_app.dart`) — *not* a
  `ScaffoldMessenger` snackbar. It subscribes to `NotificationShownEvent`
  on the EventBus and stacks up to 5 level-coloured cards top-right,
  auto-dismiss 3s (info/success) / 6s (error). It deliberately skips
  `scope == system` (those go only to the OS). There is **no**
  `InAppNotificationBackend` — an earlier snackbar/`rootMessengerKey`
  design was replaced by this overlay.
- `SystemTrayNotificationBackend` — handles `scope` `system`/`both`;
  delegates to `platform.showSystemNotification(...)`: `notify-send` on
  Linux (`--urgency=critical` for errors), `osascript` on macOS, and on
  Android a `MethodChannel` `com.xprs.app/bg_service` `notify` call
  → `BgBridge` → `NotificationManager`. Windows is not implemented yet;
  Web is a no-op.

See `docs/notifications.md` for the full developer guide.

**Wapp wire protocol** (messages the wapp sends via `hal_msg_send`):

```
{"type":"notify",
 "level":"info|success|warning|error",
 "title":"...",
 "body":"...",
 "tag":"optional dedupe key",
 "scope":"app|system|both"}
```

`wapp_page.dart`'s `_drainOutbox` translates this into
`NotificationService.instance.show(XPRSNotification(...))` with
`source="wapp:<wappName>"`. The legacy `ui.toast` message shape is
also routed through the service so old wapps inherit system-tray
delivery + history for free.

**Host-side usage:**
```dart
NotificationService.instance.show(XPRSNotification(
  level: NotificationLevel.warning,
  title: 'Low memory',
  body: 'Pausing non-critical tasks',
  source: 'host:watchdog',
  scope: NotificationScope.both,
));
```

**Scope routing.** Each backend declares which scopes it handles
(`NotificationScope.app | system | both`). The service skips
backends whose `handlesScope` returns false. Default scope is `app`.

**History.** `NotificationService` keeps a rolling in-memory list capped
at 200. Persistence is a separate `NotificationStore` (writes
`notifications/history.jsonl` in the active profile, cap 300) that drives
the bell-badge `unreadCount` and the `NotificationsPage` notification
center. See `docs/notifications.md`.

**Don't forget:**
- `NotificationService.init()` must be called exactly once, before
  `runApp`. It is wired as a `BootStart.parallel` task in
  `main.dart`; don't duplicate.
- In-app display is NOT a backend — it is handled by
  `NotificationLayer` subscribing to `NotificationShownEvent` on
  `EventBus`. The layer is installed via `MaterialApp.builder` so it
  sits above the `Navigator` and its stacking overlay renders on
  top of every route.
- Backend exceptions are **swallowed** — one broken backend cannot
  starve the others. Failures do not fire another notification to
  avoid loops.
- Never call `ScaffoldMessenger.showSnackBar` directly from wapp
  code or from services; always go through `NotificationService` so
  the behaviour stays uniform.

---

## Widgets

### WidgetRegistry + WidgetBroker — provider-registration system

**Files:**
- `lib/services/widget_registry.dart` — `WidgetRegistry` singleton,
  `{widgetId → [WappManifest]}`
- `lib/services/widget_broker.dart` — `WidgetBroker` singleton that
  routes `widget.request` / `widget.response` between caller and
  provider wapps

**What it is.** Android-intent-style resolution for wapp-to-wapp
widget calls. A wapp declares which widgets it can provide in its
`manifest.json` — one wapp can provide any number of widgets:

```json
"provides": {
  "widgets": ["text.greet", "text.shout"]
}
```

`LauncherPage._scanArchiveBody` rebuilds `WidgetRegistry` after
every scan. Widget IDs are free-form dot-separated strings
(`file.pick`, `image.gallery`, `text.greet`). Exact match only —
no wildcards today.

**Wire protocol — caller side (wapp → host):**

```
{"type":"widget.request",
 "widget":"<widget-id>",
 "req_id":"<opaque caller-chosen token>",
 "args":{...}}
```

**Wire protocol — host → provider (injected into provider's inbox):**

```
{"type":"widget.request",
 "widget":"<widget-id>",
 "req_id":"<opaque>",
 "reply_to":"<caller engineId>",
 "args":{...}}
```

**Wire protocol — provider → host:**

```
{"type":"widget.response",
 "req_id":"<matching caller token>",
 "result":{...}}         // on success
{"type":"widget.response",
 "req_id":"<matching caller token>",
 "error":"<message>"}     // on failure
```

**Wire protocol — host → caller (delivered to caller's inbox):**

Same shape as the provider response, plus `widget_provider: "<wapp id>"`
so the caller can tell which provider answered when preferences
change.

**Resolution rules.** When multiple wapps register for the same
widget ID, the broker picks one in this order:

1. `PreferencesService.getPreferredProvider(widgetId)` — if a
   stored preference exists AND that wapp is still installed, use
   it.
2. Otherwise, the first provider in registration order (scan order).

`PreferencesService.setPreferredProvider(widgetId, wappId)` stores
the preference; no settings UI yet (reserved for a later pass).

**Execution model — headless.** `WidgetBroker.handleRequest`
spins up a **fresh** `WappEngine` for the provider, loads the
provider's `app.wasm`, calls `module_init`, injects the request,
calls `module_handle_event`, scrapes the outbox for the matching
`widget.response`, and disposes the engine. The response is then
delivered to the caller via `WappEngine.lookup(callerEngineId)`
+ `sendMessage` + `handleEvent` — so the caller's
`module_handle_event` runs with the response in its inbox within
the same Dart microtask. Any outbox messages the caller emits in
response (e.g., a notification) drain on the caller's next tick
(≤ one tick interval of latency).

**No UI providers yet.** Providers that need to render UI (file
picker, gallery) cannot use the headless path — the WASM module
would have to emit `widget.response` without any user interaction.
A windowed-provider code path (route push + widget.response
interception) is planned for when a real UI widget lands; the
broker's `handleRequest` signature is stable so the switch will be
internal.

**Error handling.** Every failure mode in the broker produces a
`widget.response` with an `error` field so the caller always gets a
response and never hangs:

- Widget id not declared by any installed wapp
- Provider has no `app.wasm`
- Provider threw during load / init / handle_event
- Provider did not emit a matching `widget.response`

**Working end-to-end example.** The `widget_demo` wapp
(`apps/widget_demo/`) is a provider that declares both
`text.greet` and `text.shout` in a single manifest — the
canonical example of one wapp providing multiple widgets. The
**Tester** wapp's **Widgets** screen has Call buttons for each of
those widget IDs plus a "Call nonexistent widget" button that
exercises the error path. Each received response surfaces as an
in-app notification with the raw response JSON in the body.

**Don't forget:**
- Caller wapps MUST pick a unique `req_id` per request. The broker
  matches responses to requests by `req_id`. Collisions lose
  responses silently.
- The provider's `app.wasm` is re-loaded on every request. For a
  hot-path widget this is expensive — cache the engine across
  requests as a follow-up optimisation once we have a real
  workload.
- Adding a new widget id = add it to the provider's manifest +
  handle it in the provider's `module_handle_event`. Nothing else
  to register — the launcher scan picks it up on next boot.

---

## Tasks

### TaskMonitorService + MonitoredTask — process monitor

**Files:**
- `lib/models/monitored_task.dart` — `MonitoredTask`, `TaskStatus`,
  `TaskPriority`, `TaskType` enums, `TaskStateChangedEvent`
- `lib/services/task_monitor_service.dart` — `TaskMonitorService`
  singleton + `runMonitoredStartup` helper

**What it is.** Single registry of every background task in the
host. Solves the previous-implementation pain point of "threads
spawning everywhere with no visibility, no scheduling, no CPU
budget". Mirrors parent xprs's
`lib/services/task_monitor_service.dart` for future merge.

**Lifecycle:**
1. Owner constructs a `MonitoredTask` and calls
   `TaskMonitorService.instance.register(task)`.
2. Around each execution, owner calls `reportStart(id)`, then either
   `reportSuccess(id)` or `reportFailure(id, error)`. Wall-clock
   duration is added to `totalCpuMs` automatically.
3. Owner calls `unregister(id)` on disposal.

**Pause/resume.** `pause(id)` flips a non-critical task to
`TaskStatus.paused`; the periodic timer must check
`task.status == TaskStatus.paused` and skip its body. Critical tasks
refuse to pause. `pauseAllNonCritical()` / `resumeAll()` are the bulk
operations to hit on memory/thermal pressure.

**Wired today:**
- Every wapp's tick timer in `wapp_page.dart` registers a
  `wapp.<wappName>.<engineId>` task (`type=periodic`,
  `priority=normal`, `interval` from manifest), reports start/success/
  failure on every tick, and skips ticking when paused. Failures also
  fire `WappCrashedEvent` on `EventBus`.
- The launcher's `_scanArchive` is wrapped in `runMonitoredStartup`
  as `startup.launcher.scan` — example of the "template process
  method" pattern that every startup task should use.

**`runMonitoredStartup(id, name, init)` — the template.** Use this
helper for every one-shot startup step. It registers a
`startup.<id>` task, calls `reportStart`, runs `init`, records wall
time as `initWallMs`/`initCpuMs`, and reports success or failure.
Failures rethrow so the caller still sees them. Do **not** roll your
own try/catch around init steps — go through this helper so the
monitor sees every startup phase.

**Observing.** `TaskMonitorService.instance.tasks` returns the full
list. `stateChanges` is a `Stream<TaskStateChangedEvent>` for live UI
updates. `toJson()` produces a debug-API-friendly summary. Failures
also fire `ErrorEvent` on `EventBus`.

**Don't forget:**
- Always pair `register` with `unregister` — leaked tasks accumulate
  in the registry forever.
- `reportFailure` does **not** rethrow — the caller still has to
  decide what to do with the error.
- For `type=periodic` tasks, the `interval` field is metadata for
  the UI; the actual scheduling is done by whatever `Timer.periodic`
  the owner created. The monitor doesn't drive timers.

---

## App authoring

These components exist so the **App Creator** wapp
(`apps/app-creator/`) can let a user write, compile, and
install a new wapp without leaving xprs. They are deliberately
reusable: any future wapp that needs a syntax-highlighted editor, a
log surface, a compile pipeline, or a "write this into
`installedAppsStorage()` and rescan the launcher" step gets to drop
in the existing pieces instead of re-implementing them.

### CodeEditorField + LogViewField — GeoUI field types

**Files:**
- `lib/geoui/widgets/code_editor_field.dart`
- `lib/geoui/widgets/log_view_field.dart`
- `lib/widgets/syntax_highlight_controller.dart` (ported from the
  parent repo's `lib/widgets/syntax_highlight_controller.dart` — all
  languages the `highlighting` package supports are available,
  including `c`, `cpp`, `dart`, `javascript`)

**What they are.** Two new GeoUI field types wired into
`geoui_renderer.dart` at the `_renderFieldWidget` switch:

- `$type:"code"` → `CodeEditorField`: a monospaced `TextField` whose
  controller is a `SyntaxHighlightController`, wrapped in a dark
  container with a line-number gutter. The `language` attribute on
  the field block picks the highlight.js language id (`c`, `cpp`,
  `dart`, ...). `default` sets the initial source text.
- `$type:"log"` → `LogViewField`: a scrollable monospace list view
  backed by a `List<String>` stored in the GeoUI bindings map under
  the field name. Auto-scrolls to the bottom on each new line.

**Backed by a shared mutable list.** The list lives in the wapp
page's `_fieldValues` map under the field name. The host side
appends to it via `_drainOutbox` (`ui.log.append` handler) or
directly via the `_resolveLogBuffer(fieldName)` helper on
`_WappPageState`. The widget reads but does not mutate.

**Wapp → host protocol for log appends:**

```
{"type":"ui.log.append","field":"<field-name>","line":"..."}
```

The `field` key defaults to `output` if omitted, so most wapps can
just emit `{"type":"ui.log.append","line":"..."}` and rely on the
convention that the log group is called `output`.

**Seed defaults at load time, not at render time.** `_loadWapp`
walks every screen's block tree (`_seedFieldDefaults`) and writes
default values for every `field` descendant into `_fieldValues`
**before** the first build. `_renderCodeField` and `_renderLogField`
are therefore pure reads — they never call `widget.bindings.setValue`
from inside a `build` method (doing so would throw "setState during
build"). New field types that want defaults must either add them to
`_seedFieldDefaults` or rely on the existing string/num/bool /
`List<String>` paths.

**Don't forget:**
- `ui.log.append` lines render one per `List<String>` entry — pass
  the message pre-split, don't cram newlines in. `_logMultiline` in
  `wapp_page.dart` splits on `LineSplitter` for you if you have a
  multi-line blob.
- The log view's max height is hard-coded in
  `log_view_field.dart`. Bump it there if a log surface needs more
  screen real estate.

### WappCompilerService + CompilerBackend — the compile pipeline

**Files:** `lib/services/wapp_compiler_service.dart`

**What it is.** Thin singleton in front of a `CompilerBackend`
abstraction. A backend takes a source string + the calling wapp's
`pkg` and `workStorage`, produces a `CompileResult { ok, wasmBytes,
stdout, stderr, exitCode, durationMs, error }`. The service wraps
every call in a `MonitoredTask` (`compiler.compile`) so it appears
in the tasks wapp with wall-clock timing and success/fail counts.

**Active backend today (Phase 2a, dev-only):**
`NativeWasiSdkBackend` — shells out to `$HOME/wasi-sdk/bin/clang`
via `Process.run`. Writes the source to
`<wappData>/compile-tmp/source.c`, invokes clang with the exact
flag set the existing wapps use (`--target=wasm32-wasi -O2 -flto
-I<hal-dir> -Wl,--no-entry -Wl,--export=module_{init,tick,...}
-nostartfiles -o output.wasm source.c`), reads the output from
`<wappData>/compile-tmp/output.wasm`. The HAL header is located by
walking up from `Directory.current.path` looking for
`apps/hal/xprs_wasm_hal.h`.

**Phase 2b todo:** add `InWasmClangBackend` that reads a bundled
wasm-clang binary from `pkg.readBytes('media/compilers/cpp.wasm')`
and runs it under a custom `WappWasiHost` (still unwritten).
`WappCompilerService.backend` becomes a runtime pick: prefer
in-wasm when the wapp package ships a compiler, fall back to native
for developers. The public API stays the same — `compile(source,
pkg, workStorage)` returns a `CompileResult` either way — so no
caller needs to change.

**Don't forget:**
- `CompileResult.failure` is the only error path — the service
  never throws. Callers check `result.ok` and surface
  `result.error` / `result.stderr`.
- The service caches nothing itself — callers are responsible for
  writing `result.wasmBytes` somewhere durable (the App Creator
  handler writes it to `<workStorage>/last_compiled.wasm`).
- `CompilerBackend.isAvailable` gates actual use; when the only
  backend is unavailable, the service returns a failure with a
  human-readable message. Don't silently fall back to a stub.

### WappInstallerService — install compiled wasm as a launcher wapp

**Files:** `lib/services/wapp_installer_service.dart`

**What it is.** Writes a new wapp directory under
`installedAppsStorage()` (`~/.local/share/xprs/apps/<folder>/`),
matching the on-disk layout the launcher's `_scanArchiveBody`
already knows how to read. Fires `WappLoadedEvent` on `EventBus`
so the launcher rescans without a restart.

**API:**

```dart
final result = await WappInstallerService.instance.installFromCompiled(
  id: 'user.xprs.my-first',
  name: 'My first wapp',
  description: 'A wapp I wrote inside xprs.',
  wasmBytes: compiledBytes,
  version: '1.0.0',          // default
  homeScreenJson: null,      // default: auto-generate a label screen
  overwrite: false,          // reject collisions unless explicit
);
```

Returns `InstallResult { ok, wappId, error }`. Collisions fail by
default — pass `overwrite: true` to replace an existing install.
Folder name is derived from the id's last dot-separated segment,
sanitised to `[A-Za-z0-9_-]`.

**Writes three files per install:**
- `manifest.json` — id, version, kind, description, tags, tick
  interval, `permissions: []` (sandboxed by default),
  `requires.hal: [log]`.
- `app.wasm` — the compiled bytes verbatim.
- `screens/home.ui.json` — caller-supplied or a default label
  screen that just says "Created with App Creator" so the wapp
  renders without errors when opened.

**Don't forget:**
- The installer does **not** validate the wasm. A broken
  `app.wasm` installs fine and fails at wapp-open time with the
  normal `WappEngine.load` error path. If that turns out to be
  painful, pre-validate by spinning up a throwaway `WappEngine` and
  calling `load`+`init` before the install (same trick the plan's
  "Run preview" follow-up will use).
- `WappLoadedEvent` is slightly overloaded — it originally fired
  when a wapp finished `module_init`, and the launcher subscribes
  to it for a different reason there. Using it for "rescan the
  launcher" works today but a dedicated `WappInstalledEvent` would
  be cleaner if we ever need to distinguish the two in the same
  handler.

### `_sendCommand` field forwarding — how actions reach compile/install

`wapp_page.dart` `_sendCommand(cmd)` now bundles a **scalar**
projection of `_fieldValues` under a `fields` key alongside the
command name:

```json
{"command":"compile","fields":{"source":"...","wapp_id":"...",...}}
```

Non-scalar entries (`List<String>` log buffers, etc.) are dropped
so log history isn't carried with every action click. Existing
wapps that only read `data['command']` ignore the extra `fields`
key harmlessly — backward-compatible.

Wapps that need the field values (App Creator is the first) parse
the nested object with the same C-side helpers `tester/main.c`
uses (`find_substr`, `extract_json_string_field`). The escaped
string values can be re-embedded verbatim into outgoing JSON
messages without un-escaping — host-side `jsonDecode` handles the
unescape on the other end. See `apps/app-creator/main.c`
for the reference implementation of a field extractor.

## Radio

### A three-valued capability probe — `Ble5Bus.supported()` / `supportKnown`

`reticulum-dart/lib/src/connections/bluetooth/ble5_bus.dart`,
`android/.../Ble5.kt` (`isSupportedOrUnknown`), re-asked by
`BleService._supportWatchdog` (`lib/connections/bluetooth/ble_service_io.dart`).

A permanent question ("does this chip do extended advertising?") asked of a
subsystem that is switched off gets a wrong answer, not no answer: Android
returns `false` to every LE capability call while the adapter is not ON. The
pattern is: native answers `true` / `false` / `null`, the Dart side caches only
a non-null answer and exposes `supportKnown`, and one existing heartbeat
re-asks while it is unknown, paced (a platform-channel round trip, 10 s) and
logged once. The same shape fits any plugin-backed capability that depends on
a radio or service being up at the moment it is asked: WiFi-Direct support,
the USB host, location providers. Do not add a timer for it — hang it on the
tick that already exists (`_onServiceTick` / `_dartTick`), as the scan and
GATT watchdogs do.

### Keep the best wish while waiting — `MeshService.start` / `_wishAdvertise`

`lib/services/mesh/mesh_service.dart`. A start that has to wait (here: for a
callsign) and is called several times meanwhile must remember the strongest
request, not the latest argument, and consume it once when it finally runs.
Capturing the argument in the retry timer, or a listener passing the current
state back in, both started the node weaker than the radio could do. Reuse the
shape anywhere a retry timer captures a boolean that another path may raise
before the timer fires.

### Once per off episode — `RadioEnvironment`

`lib/connections/bluetooth/radio_environment.dart`, driven by
`BleService._environmentWatchdog`. A system switch the app cannot flip
(Location Services, the Bluetooth adapter) is probed on a paced heartbeat and
the person is told once when it goes off, nothing while it stays off, and
again only after it has been seen on; an unanswered probe (null) changes
nothing, so a timeout mid-episode is not read as good news. Pure, no platform
code, three tests. Reuse it for any "tell them once" on a boolean the app
polls: a lost uplink, a full disk, a revoked permission. The message itself
goes through `NotificationService` with a `tag` per switch, scope `both`, so a
headless phone shows it in the tray.

## Languages

### `tr()` / `trn()` and `CoreI18n` — the core's translations in the wapps' shape

`lib/services/i18n/core_i18n.dart`, resolver `lib/services/i18n/i18n_context.dart`
(moved from `lib/wapp/`; a shim keeps the old import working), files under
`assets/lang/<code>/<area>.json`, checked by `tool/i18n_check.dart`, guarded by
`arch_guard`'s `no-raw-ui-string`. Plan and conventions: `docs/plan-i18n-core.md`.

- A screen reads `tr('area.subject')`; placeholders are `{name}` passed as a
  map; plurals are `trn('area.subject', n)` over a `.one`/`.other` pair.
- The language is the Settings choice, else the OS locale; the tables load
  once at boot and reload on `LocaleChangedEvent`; the root widget rebuilds
  once per change via `CoreI18n.instance.revision`.
- Adding a language is a folder under `assets/lang/` plus one line in
  `pubspec.yaml`; Settings lists the folders it finds. A language names
  itself (`settings_page.dart` `_languageName`), never translated.
- Converting a screen: every person-facing literal to a key whose first
  segment is the area file; English verbatim into `en/<area>.json`; the four
  translations with `_meta.reviewed: false` until a person reads them; then
  add the file to the `no-raw-ui-string` rule's `appliesTo` so it cannot
  regress. Rows named by a runtime key (`tr('permissions.${item.key}.title')`)
  are listed by the checker as dynamic, so keep their prefix stable.
- Logs stay English (diagnostics); notifications, dialogs, SnackBars and
  labels are translated at the call site.

### `trBytes()` / `trDecimal()` — one byte formatter, in the person's language

`lib/services/i18n/format.dart`. Replaced four private copies (settings, the
GeoUI gallery, the media view, the node-role API); those keep their names as
one-line delegates so callers did not change. Unit names (`Ko`, `Mo` in
French) and the decimal mark are `common.unit.*` and `common.decimal` keys.
Never for the wire: XPRS.md 4 fixes `.` on the air. Write any new size or
decimal shown to a person through these, not with `toStringAsFixed`.

### `trSchedule()` — wording a library's structured value in the app

`lib/services/i18n/schedule_text.dart`. reticulum-dart's `describeSchedule()`
builds English and stays (it is the library's, and it feeds logs); the app
words the same public `DutyTerm`/`WindowTerm` values from `hardware.json`
keys. The pattern for any library that returns a sentence: read its
structured value, keep the library free of the app's languages.

## Identity

### `XprsSelf` — which of the operator's names a packet goes out under

`lib/services/xprs/xprs_self.dart`. An operator holds the X1 their key
derives (the profile's base and folder, never changes) plus up to four issued
callsigns, one per jurisdiction (`IwiProfile.licenceCallsigns`), one of which
is active (`licenceCallsign`, kept as the name for "the one on the air").
Ask `XprsSelf`, never compare against `wireCallsign` by hand:

- `isMine(call)` — one of our names (signing, receipts, "addressed to us").
- `forPeer(peer)` — the `f:` for a 1:1: the callsign that conversation keeps,
  else the active one. A conversation keeps an issued callsign it began
  under; one addressed to the X1 follows the active.
- `noteInbound` / `noteOutbound` — called at ingest delivery and at send.

Storage is per profile (`PreferencesService.xprsConversationCallsigns`),
bounded at 256 peers, least recently used first; the rule is tested with an
injected profile (`test/xprs_self_test.dart`). Wapps never see any of this.

### `CallsignInputFormatter` — a callsign field an Android keyboard can type into

`lib/profile/callsign_input.dart`. Never rewrite text the keyboard is still
composing, and never change case in a formatter: that made the profile's
callsign field untypeable on Android. Pair it with
`keyboardType: TextInputType.visiblePassword`, `autocorrect: false`,
`enableSuggestions: false`, `textCapitalization: characters`, and normalise
with `xprsNormaliseCallsign` when the value is used.
`test/callsign_input_test.dart` drives a field with composing updates.

## Routing

### Injected sends — `XprsMailbox`, `XprsForwarder` (and the simulation that runs them)

A core routine that decides WHERE a packet goes must not reach for
`RnsService` or a bearer itself: it takes its sends and its evidence as
function fields with device defaults, so the whole decision runs in
`test/support/mail_relay_sim.dart` against a virtual air.

```dart
class XprsForwarder {
  Future<bool> Function(String call, String wire)? sendTo;  // the lane
  bool Function(String call)? canDeliver;                   // the evidence
  List<String> Function(String call)? holdersOf;
  List<GossipSighting> Function(String call)? sightingsOf;
  Future<bool> _send(String g, String w) => (sendTo ?? _deviceLane)(g, w);
  void debugReset();                       // forgets state AND the seams
}
```

`XprsMailbox` (`sendTo`, `reachable`, `held`, `holdersOf`, `publish`) is the
original; `XprsForwarder` (`lib/services/xprs/xprs_forwarder.dart`) follows
it, and `mesh_service.dart` is the one place both are wired to the device.
Reuse this shape for anything whose failure only shows between machines (a
fetch that follows `m:try`, a deposit, a release): test it on the bench first,
and keep `debugReset()` clearing the seams so one test's lane never leaks into
the next.

### `GossipSighting.live` — the two layers, told apart on the read

`XprsGossip.whereIs(call)` returns L3 rows (`live: true`, inside the 24 h TTL,
applied on the read) before L2 visits (`live: false`). A router sends to EVERY
live gateway and to only the freshest visit, and only when nothing is live;
anything else that routes by gossip should read the flag rather than re-derive
it from timestamps.

### `xprsComposeObservation` + `XprsHearsReporter` — one reachability claim, and when to say it

`lib/services/xprs/xprs_observation.dart`. The composer builds this station's
`t:observation` for one radio (`link:`, `hears:` cut to a budget with `peers:`
the true count, `mail:`, `lx:`, uptime, `serve:`, signed, signature room
reserved before the fit). `MeshService._observation` wraps it with the
device's values; the LAN beacon and the archiver deposit are the same packet
against different budgets. The BLE beacon still has its own builder because
its placeholders are sized to the advert ceiling — fold it in when touching
it. The reporter is a pure "is a report due" (new station at our ear → now;
else on a period; never under a minute), reusable for any claim that should
go out on change-or-period without a timer per station.

### `XprsFetch` — ask the archivers for one station's words, following the answers

`lib/services/xprs/xprs_fetch.dart`. `requestStation(call)` opens one fetch
per callsign (ten-minute throttle, skipped in earshot), asks the archiver that
answered last time, then the chosen ones, follows a `404 m:try` one hop,
continues a `206` a few pages, and closes. Three things to reuse rather than
rewrite:

- **"what you asked for, you keep"**: `XprsIngest.askedFor` is a predicate the
  funnel consults at admission; a row it claims goes on the followed shelf.
  Any other on-demand ask (a device's readings, a group's log) can plug the
  same predicate instead of inventing a shelf.
- **the poller/fetch handshake**: `XprsCatchup.busyWith(archiver)` and
  `externalBusy` keep two askers on one station from superseding each other's
  replay at the responder.
- **one-shot wakes, never a poll** (`_wake`): a fetch schedules one Timer per
  ask (its grace) and nothing while nothing is open — the shape the
  `no-sub-minute-poll` guard rule wants for any user-triggered exchange.
