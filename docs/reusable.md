# xprs (iwi/) reusable components

Shared, Flutter-free components moved to the `core` sibling repo
(`xprs-dev/core`, package `xprs_core`); its own `docs/reusable.md` lists them.
Check there first; code that both the app and the server need belongs there.

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
exists so that the backing store can be swapped for an encrypted zx
store (encrypted profiles), a browser IndexedDB tree (web build), or a
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
  with `dart:io` sync methods. **Non-sync backends** (encrypted zx store,
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

### Renaming a preference key — `PreferencesService._migrateArchiverKeys`

**File:** `lib/services/preferences_service.dart` (called right after
`SharedPreferences.getInstance()` in `load()`).

The pattern for a stored key whose name changes: a `{old: new}` map, walked
once at startup — copy the value if the new key is absent, then remove the
old key, preserving the type (`String` / `List<String>`). Written for the
indexer → archiver rename (2026-11-06); add further pairs to the map rather
than a second migration method, and keep the pairs for a few releases so an
install skipping versions still carries its settings across.

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

**Read state, reusable pieces** (`docs/notifications.md`, "When a
notification is read"):
- `NotificationService.idOf(n)` — the one identity of a notification (bell
  row, card, Android shade entry, tap link). Never derive an id elsewhere.
- `openNotificationTarget(target, convo:, view:, notificationId:)`
  (`lib/wapp/wapp_open.dart`) — the one door for every notification tap;
  passing `notificationId` marks that notification read. A new tap surface
  calls this, it does not mark anything itself.
- `NotificationTargetView(source: 'host:<name>', child: …)` — wrap a host
  page's build in it and that page's notifications are read while it is
  shown. Use it for any new host page registered in `hostNotificationPages`.
- `NotificationService.markSeenById(id, source:)` — one notification is done
  with (opened, or no longer true). Wapps reach it with
  `{"type":"notify.resolve","tag":"…"}`.
- `NotificationService.markSeen(source, all: true)` — a service retires all
  of its own notifications (the updater, once nothing is left to install).

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

### A host notification that opens a page — `hostNotificationPages` / `openNotificationTarget`

**File:** `lib/wapp/wapp_open.dart`

A wapp notification's tap opens its wapp; a host service's notification can
open a page of its own. Register the page under the notification's source at
boot, then raise the notification with that source:

```dart
hostNotificationPages['host:updates'] = () => const UpdatePage(); // main.dart
NotificationService.instance.show(XprsNotification(
    source: 'host:updates', scope: NotificationScope.both, ...));
```

Every tap door (Android shade via `xprs://open?wapp=<source>`, the Linux toast,
the in-app card, the notifications page) calls `openNotificationTarget`, which
opens the registered page or else the wapp. No Kotlin change per page.

### A wapp button that opens a host settings page — `"open": "host:<name>"`

**Files:** `lib/wapp/geoui/geoui_renderer.dart` (`_renderAction`),
`lib/wapp/wapp_page.dart` (`_toolbarButton`), `lib/launcher/position_share_card.dart`
(`PositionSharePage`, target `host:position`)

A wapp that depends on a host setting links to it instead of describing where
it is. The action names a page from the same registry as above:

```json
{"$":"action","name":"share_location","label":"Share my location","open":"host:position"}
```

The host opens the page, and sends the action's own command when the person
comes back, so the wapp re-reads what changed. To offer another settings page
to wapps, give it a `static const target = 'host:<name>'` and register it in
`main.dart`. `PositionSharePage` is the pattern: the existing settings card on
a page of its own.

### Browsing another station from a wapp — `hal_station_read`

**Files:** `lib/wapp/wapp_engine.dart` (`halStationRead`), core
`services/station/` (`StationBrowse`, `StationRoutes`, `StationVisits`,
`StationVisit`; see `../core/docs/reusable.md`), `../apps/mesh/browse.c`

One HAL call reads what another station offers through its visitor API
(spec/API-HTTP.md), the same rooms, galleries, music and files its web page
shows, as this profile: `get:"list"` (the stations by scope and page),
`"offers"` (rooms), `"folders"`, `"items"`, `"ways"` (how a message gets
there, hop by hop). It answers at once from what the last visit learned and
`core.station` says when to read again; the wapp never names a bearer or a
transport. Files come back as media tokens, fetched by the ordinary media
door (`MediaFetch` knows which station listed them). `browse.c` in the Mesh
wapp is the pattern for a paged list and a drill-down built on it.

### Showing a route and showing files — `$type:"route"`, `$type:"media"`

**Files:** `lib/wapp/geoui/widgets/route_field.dart` (`RouteField`),
`lib/wapp/geoui/widgets/media_shelf_field.dart` (`MediaShelfField`)

Two GeoUI field types any wapp can use, set with `ui.field.set`:

- `route`: `{"routes":[{"sure":bool,"hops":[{"from","to","bearer","know":
  "heard|asked|said|guess","age_s","rssi"}]}]}`, drawn station, bearer,
  station. A `guess` hop is dashed and labelled; the widget decides nothing.
  On a people screen it is drawn above the list (`wapp_page.dart`).
- `media`: `{"layout":"grid|list","items":[{"token","preview","title",
  "subtitle"}]}`. A grid of pictures or a list of named files; every tile is
  a `MediaThumbnail`, so fetching, progress and the viewer are the shared ones.

### Settings save as they are typed — `"apply"` on a text field

**Files:** `lib/wapp/geoui/geoui_renderer.dart` (`_applyLater`, `_applyNow`),
`lib/launcher/position_share_card.dart` (`_fixedChanged`, `_saveFixed`)

No Save button. A GeoUI string field with `"apply": "<command>"` sends that
command 800 ms after the typing pauses, on Enter, and when the screen closes
with a change pending (bool and enum fields already applied at once). A host
settings field does the same with a `Timer` cancelled and restarted in
`onChanged`, flushed in `dispose`; an invalid value is pointed out and not
stored.

### Periodic work without a poll — the update scheduler

**Files:** `lib/services/update_models.dart` (`updateCheckDue`,
`updateNextCheckIn`), `lib/services/update_service.dart` (`_arm`,
`didChangeAppLifecycleState`)

Persist the last run's time, arm ONE one-shot `Timer` for
`last + interval` (never sooner than a floor), re-arm after each run, retry
sooner after a failure, and re-arm a few seconds out on resume when overdue.
The two helpers are pure and tested (`test/update_auto_test.dart`); reuse them
for any "every N hours while the app runs" job instead of a `Timer.periodic`.

---

## Widgets

### WidgetRegistry + WidgetBroker — provider-registration system

> **Since 2026-11-19** these are `FunctionalityRegistry` and
> `FunctionalityBroker` (`lib/wapp/`), and a provider may answer later.
> The current contract is in "One wapp serving another" below and in
> `apps/wapp-interfaces.md` 5; what follows is the original description.

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

### PowerState — the one reader of power, screen and the room

**File:** `lib/services/power_state.dart` (singleton, started by `PowerGovernor`).

- `tier` (`ValueNotifier<PowerTier>`: active / idle / battery / low) — what
  the phone may cost right now; `holdActive(reason)` / `releaseActive` pin
  it while delivery is in flight. A hold MUST be released on every exit path
  (the scheduler's early return leaked one for weeks; performance.md 8.19).
- `isPowered`, `powered` (notifier), `batteryLevel` — plugged in means
  charging, full, connected-not-charging or no battery. **Never add another
  `battery_plus` subscription**: three services did, disagreed on
  "connected, not charging", and one never refreshed its percentage.
- `alone` (`ValueNotifier<bool>`), `noteAir(lastFrameMs, lastDiscoveredMs)`
  — no XPRS radio heard for 5 min. Radios read it to run cheaper in an empty
  room; anything periodic that exists to be heard by a neighbour (a beacon,
  a presence advert) should consult it before adding a timer of its own.
- `nativeTickMs` — the native heartbeat period for the tier, for any Dart
  fallback that must tell "the service is driving" from "it stopped".
- `profile` (`ValueNotifier<PowerProfile>`: station / normal), `profileMode`,
  `setProfileMode('auto'|'station'|'normal')` — what the device IS (8.20).
  Anything that only a plugged-in, always-on node should do (hold a public
  hub, publish to the DHT, forward for others, run a periodic pull) keys off
  this, not off `isPowered` directly, so the user's override is honoured.
  A phone STARTS as `normal` and is promoted by its charger; a service that
  reads the profile at boot and then does something slow must re-read it
  afterwards (`ensureRnsAutostart` does; performance.md 8.23).

### XprsLineLane / XprsLineClient / XprsLinePeers — one socket to an archiver

**Files:** `lib/services/xprs/xprs_line.dart` (conditional export),
`xprs_line_io.dart`, `xprs_line_stub.dart` (web), `xprs_dial.dart` (pure
`dial:` parsing), `xprs_tcp.dart` (`XprsLinePeers`, the server's registry).

- `XprsDial.parse('host[:port]')` — the one place `dial:` is read.
- `XprsLineLane.instance.wantAll({callsign: dial})` keeps exactly that set
  of client sockets (backoff, long keepalive, re-dial on a changed address);
  `sendTo(call, wire)`, `connectedTo(call)`; `onClientUp` for the first ask.
- `XprsLinePeers.instance` — who is on a socket to US, registered only after
  a signed line verifies; `sendTo`, `isConnected`.
- Reuse the lane rather than opening sockets: any directed wire goes down a
  socket by itself through the publisher's `line` bearer when the `d:` is
  connected, so a feature that wants "send this to my archiver now" just
  publishes. Received lines enter the funnel as the internet lane.
- The only undirected wires the bearer carries are `t:identity` and
  `t:mailbox` (to every dialled archiver, as `queued` so the radios still
  air them): they are what gets a station onto the archiver's socket.
  `MeshService._onLineUp` sends them, then `q:mail`. Do not add a third
  undirected type without a reason of that weight.
- `XprsPublisher.identityWire(call, npub)`, `ownIdentityWire()`,
  `mailboxWire(holdCsv)` build the signed wires; `XprsCatchup.mailboxHoldCsv()`
  is the one `hold:` list. The airing, the deposit and the handshake all go
  through these — never compose a `t:identity` or `t:mailbox` inline.
- `XprsPublisher.depositArchivers(wires, what:)` tries the socket, then a
  hub; with neither it keeps the copy (bounded, never presence) and
  `flushDeferredDeposits()` places it when a socket or a session arrives.
  A feature that has "something for my archiver" deposits and forgets.

### RnsSession — a hub, on request, for a phone on battery

**File:** `lib/services/reticulum/rns_session.dart`.

`RnsSession.instance.request('reason', hold: Duration)` is idempotent and
cheap: it brings one hub up in the normal profile and holds it for the
duration, a no-op in the station profile. Any feature that needs the shared
transport for a while (a transfer, a Reticulum-only contact) asks at the
moment it knows and never checks `connectedHubs` first; the session's
release is automatic (8.22). Don't connect hubs from a feature directly.

Only MAIL is worth a hub (8.23): the publisher's Reticulum bearer opens a
session for a `t:message` or `t:receipt` and for nothing else. A periodic
ask (a catch-up, a report, a poll) must never request a session — with a
ten-minute cadence and a five-minute hold that is a hub always on. It
sends when a hub is up or a local path exists, and is `refused` otherwise;
design the caller to be asked again on its cadence, not retried at once.

---

### `exitApp()` — stop XPRS completely

`lib/boot/app_exit.dart` (conditional export: `app_exit_io.dart`, a no-op
`app_exit_web.dart`). Flushes the archive's in-memory rows, stops the
START_STICKY background service through
`AndroidForegroundService.shutdown()` (else Android restarts it), then ends
the process. The drawer's "Exit XPRS" calls it after a confirmation; anything
else that must end the app (a profile lock, an update that restarts) should
call it rather than `exit(0)` directly, so nothing received in the last
seconds is lost.

### `PermissionState` — may this feature use X? (Android permissions)

`lib/services/permission_state.dart`. Every Android permission is optional:
the person may refuse any of them at the intro or later in the system
settings, and XPRS runs with the rest. This is the one place a feature asks
what it was allowed: `bluetooth` and `nearbyWifi` (`Observable<bool>`,
synchronous, so the core's `CoreHost.radioAllowed` reads it), `missing` (the
refused intro-row keys) and `locationSwitch`. `refresh()` runs at boot, on
app resume (`watchResume()`) and after a grant; within one run only grants
happen (a revoke kills the process). `PermissionState.capabilities(missing,
sdk)` is the pure rule (Android 11 and older: Bluetooth also needs Location;
WiFi Direct needs Location before 13), unit-tested in
`test/services/permission_state_test.dart`.

A new feature behind a permission: read the matching observable, do nothing
while it is false (no call that fails on every tick, no plugin call that
raises the system dialog), and start on the change to true. A prompt comes
only from the intro, Settings > Permissions, or a tap on the feature itself.
`BleService.radioGranted()` / `RnsService.radioGranted()` show the pattern.

### `PermissionsPanel` / `PermissionsPage` — the permission rows

`lib/launcher/permissions_panel.dart`. The rows of `AndroidPermissionsService`
with live state, what each enables, what stops working without it
(`permissions.<key>.without`) and Grant (Open settings once Android stopped
asking). The first-run intro and Settings > Permissions both embed it; the
home screen's `_PermissionBanner` opens the page while Bluetooth is refused.

## Maps

- **`lib/wapp/geoui/tile_math.dart`** — pure slippy-map arithmetic:
  `tileX`/`tileY`, `tilesForBox` (coarse first, capped), `viewBox` (the
  area a screen shows), `tileUrl`. Any "which tiles cover this" question.
  Also the view under a gesture: `MapView` (whole zoom + top-left world
  pixel + the scale tiles are drawn at), `viewPoint` (the world point under
  a screen position), `viewAt` (the view at any fractional zoom that keeps
  that point under a screen position) and `viewZoom`. Pinch, double tap,
  wheel and fling in `SlippyMap` are all `viewAt`; any other zoomable
  canvas over tiles should reuse it rather than redo the Mercator sums.
- **`SlippyMap` (`lib/wapp/geoui/widgets/slippy_map.dart`)** — the wapp map
  widget in its own library (tiles, pins, clusters, circle, search, gestures);
  `wapp_maps.dart` only wires it to the page. Gestures: one `onScale*` recogniser
  for pan and pinch (never pan callbacks next to it: a pinch then reads as a
  drag of whichever finger moved last), a double tap on the tile layer only
  (so pins and buttons keep instant taps), and `_easeTo` to settle on a whole
  zoom. `slippyMapForTest` builds it bare for widget tests
  (`test/wapp_map_gestures_test.dart` drives a two-finger pinch).
  Markers are grouped as Leaflet.markercluster's map does, by
  `lib/wapp/geoui/map_cluster_index.dart` (pure Dart, supercluster's method):
  the groups of every zoom level built once per set of markers, each node
  with its children one level closer, so a pan never regroups and a zoom
  that crosses a level slides the markers out of their group (or into it).
  A group's tap eases to its expansion zoom, centred on it; markers no zoom
  parts (one point, deepest zoom) fan out on legs (`spiderOffsets`: a
  circle up to 8, a spiral beyond), and over `spiderMax` the wapp gets
  `onMarkersHere(ids)` to list them. `kind: "archive"` markers are the
  portal's yellow square, grouped apart and drawn above the rest (a group
  under one steps aside). `openId`/`openSeq` open a marker's popup (fanned
  first) — `ui.map.locate` with an `id`. A pin's `actions` are buttons in
  its popup (`onMarkerAction`); `test/wapp_map_markers_test.dart`,
  `test/map_cluster_index_test.dart`. Reuse the index for any map of many
  points (it has no Flutter in it).
- **The map with a drawer (`lib/wapp/wapp_drawer.dart`)** — a map screen with
  `"drawer": true` on its map group draws its `$type:"people"` screen (search
  box, chips, list) in a drawer over the map, the xprs.dev portal's layout:
  a bottom sheet of three heights on a phone (laid out at full height and
  shown through a window, so the list never reflows while it moves; Back
  folds it), a folding side panel on a wide screen. `ui.drawer` moves it,
  `ui.map.locate` folds it. `_buildChipsField` there is the `$type:"chips"`
  field any list screen can carry. Mesh's Stations tab uses both.
- **Map framing in a wapp (`fit_box` in `apps/checkin/main.c`)** — a box
  of positions to a `ui.map.viewport` that fits it on a phone (about 340 px,
  latitude stretch allowed for). Frame "near me" first, "Show all" on demand.
- **`xprsCoarsePos` / `XprsSharedPosition` (core `xprs_shared_position.dart`)**
  — a position snapped to the centre of a fixed grid cell of the owner's
  radius, written with the decimals that size supports (XPRS.md 15.1) plus
  `acc:`. Use it for ANY position a station states about itself: a fixed cell
  leaks nothing more on the hundredth airing (a random offset would average
  out). A wapp gets the same value with `hal_xprs_position`.
- **`hal_xprs_follow_kind(kind, on)`** — a wapp that needs a packet type from
  anyone (check-in events, polls, offers) follows the TYPE: the core keeps it
  from every lane and asks archivers for what is new, merged in one archive;
  the wapp reads `hal_xprs_history`. Never a wapp-side copy, never a wapp
  asking archivers (docs/architecture.md, 2026-11-14).
- **`ui.map.locate` (wapp → host)** — switch to the map's screen and centre on
  one place: the "Show on map" of any list.
- **`ui.prompt` with `copy`** — a sheet with a Copy button: coordinates to
  paste into a navigation app, a file token, a link. `chips` add choices that
  come back as a `prompt` command (`prompt_id`, `prompt_value`). `confirm`
  and `cancel` name the two buttons when "OK" and "Cancel" are not what they
  mean (an invitation is "Join" / "Not now").
- **`ui.prompt` with `cycle`** — `{"label","values":[...],"next","back"}`:
  one value shown at a time with ↻ (next, wraps) and ↶ (back to the one
  shown before, a real history). The value on screen when the person
  confirms comes back as `prompt_cycle`. With `"more":true` the list has
  no end: near its end the host sends `prompt_more` (`prompt_id`), the wapp
  answers `{"type":"ui.prompt.cycle","id":<prompt id>,"values":[...]}` and the
  values are appended (never a loop). First used for a new group's X5
  callsign (`hal_xprs_group_candidates`, negative count = more, +
  `hal_xprs_group_create_as`).
- **`lib/wapp/geoui/tile_recolor.dart`** — `recolorDark(rgba)` repaints an
  OpenStreetMap-carto raster tile in the Protomaps "dark" palette (hue picks
  water/park/sand/road, a luminance ramp maps the rest). Pure Dart on an RGBA
  buffer; `tileImageProvider(url, style: 'dark')` runs it off the UI isolate.
  Another palette is another ramp and target set in the same shape.
- **`prefetchTiles` (`lib/wapp/geoui/tile_cache.dart`)** — saves tiles into
  the same disk cache the map reads, two at a time with a pause, with an
  identifying User-Agent. Wapps reach it through `ui.map.prefetch`.
- **`tile-style` on a map group** (`_tileFilter` in `wapp_maps.dart`) —
  `mono` / `mono-dark` colour matrices over any tile source.

## Wapp building blocks (C, `../apps`)

- **`apps/alerts/util.c` / `util.h`** — strings, `YYYY-MM-DD_HH:MM:SS` time
  both ways, the little JSON the host speaks, one wire field (`al_field`) and
  the section 5 identifier (`al_id`, SHA-256 included), with no libc. The
  Check-in wapp builds the same file (`MODULE_SRCS := ... ../alerts/util.c`,
  `CFLAGS += -I../alerts`) instead of keeping a copy: reuse it the same way
  rather than copying it again.
- **`apps/checkin/tests/native/hal_mock.c`** — a mock HAL with a real
  zx store behind `hal_db_*` (`sdk/hal_db_zx.c`), an event queue, captures of
  `hal_xprs_send` / `hal_xprs_message` / `hal_media_fetch`, a station list and
  an archive answer, and a switchable callsign so one process plays both ends
  of an exchange. A start for any wapp test that needs storage and two sides.
- **`ChatViewField.nameOf` / `senderLabel(call)`** (`lib/wapp/geoui/widgets/
  chat_view_field.dart`) — the name a sender gave themselves, "Bea (X13SUZ)";
  set once by the wapp page from `XprsProfiles`. The rooms list uses it for
  its "CALL: text" previews.
- **`apps/hal/people_finder.h`** — the "find a callsign" picker every wapp
  includes (`pf_render`, `pf_pick`). A person's own name leads each row
  ("Bea (X13SUZ)") and a search matches it. `pf_hide_groups` drops X5 groups;
  `pf_people_only` keeps only people (`kind:user`), for a picker whose choice
  must sign something itself, such as an invitation to a closed group.
  Rows sort into three tabs, `People`, `Stations` and `Groups` (the screen's
  `tabs`), and besides who was heard, every tab has a "Found by name"
  section from `hal_xprs_names`: everybody known by a verified identity,
  which the core also asks its archivers for. `pf_names_on = 0` for a picker
  that wants only who is in earshot; `pf_t_*` are the section words.
- **`hal_xprs_names` / `XprsNames.find` / `core.names`** — the one way to find
  a person, station or group by name. Never build a finder on
  `hal_xprs_stations` alone: that is who THIS device heard in the last hour,
  and the archivers know everybody else (XPRS.md 12.9.4, 12.12.2).
- **`apps/checkin/ci.c`** — an operator command and its signed `t:result`
  as packets: build an ask, decide on an `xprs.command` row (signature verdict,
  `inRange`, freshness, rules), build a result whose optional fields go in
  order of worth while they still fit signed (`opt`). The pattern for any
  "ask a nearby station, get a signed answer" feature.

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

**Files:** `lib/editor/wapp_compiler_service.dart`,
`lib/editor/wapp_compiler_backend_io.dart`

**What it is.** Thin singleton in front of a `CompilerBackend`
abstraction. A backend takes a source string + the calling wapp's
`pkg` and `workStorage`, produces a `CompileResult { ok, wasmBytes,
stdout, stderr, exitCode, durationMs, error }`. The service wraps
every call in a `MonitoredTask` (`compiler.compile`) so it appears
in the tasks wapp with wall-clock timing and success/fail counts.

**Backend:** `BundledCompilerBackend` on every native platform: the
app's bundled xcc (`assets/compiler/cc.wasm` + `usr.zip`, built by
`tool/build_compiler.sh`) on a worker isolate through `wasm_run`, with
`/usr`, `/work`, `/tmp`, `/hal` and `/sdk` mounted. Web gets a stub.

**Running any WASI command through `wasm_run`** (reuse this pattern, see
`BundledCompiler`): hand its bytes from `rootBundle` to a worker isolate
as `TransferableTypedData`; export its entry under another name than
`_start` (the builder runs `_start` itself, inside `build()`, before you
can listen); have it write its output to a file in a mounted folder
(captured stdio arrives only some time after the call returns); read the
exit code from the trap text (`exit status N`).

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

`XprsMailbox` (`sendTo`, `reachable`, `held`, `holdersOf`, `publish`; now in
`../core`) is the original; `XprsForwarder` (`lib/services/xprs/xprs_forwarder.dart`) follows
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

`requestKey(call)` is the same walk for a station's `t:identity`
(`cmd:history kind:identity`, XPRS.md 12.12.1): one page, not skipped in
earshot, keyed apart from the message fetch so both can be open. Anything that
needs ONE kind of record about a station from the archivers (a mailbox
declaration, a service announcement) is a new `kind` on `_request`, not a new
fetcher.

### `XprsKeyWait` — words that wait in the core for something to arrive

`../core/lib/src/services/xprs/xprs_key_wait.dart`. A direct message that
cannot be sealed yet (no key) is kept in the profile's encrypted store under
a HELD id of the §5 shape, the key is looked for (seam `ask`), and on
`keyLearned` it is sealed and sent (seam `seal`), the wapp hearing
`xprs.status.tx` with `newId` so its bubble moves. `release(id)` takes it
back without airing anything (reached through `hal_xprs_withdraw`). Reuse the
shape for any send that is blocked on a fact the core will learn later: hold
under a provisional id, report the real one when it goes, persist, bound,
expire, and let the person take it back.

### `MessageInfoPage` + `MessageInfoBus` — a message's Info, as a page

`lib/wapp/geoui/widgets/message_info_page.dart`. Opens at once from the
bubble's map and fills in when the wapp answers `ui.convo.info` (the host's
`_drainOutbox` publishes it on `MessageInfoBus`). Sections: privacy, the
words and their versions (`EditHistoryList`), who and when, the route (the
relays in `via:` as a chain), signature and sealing, delivery, the raw wire.
Any view that shows a message (`ChatViewField` does) opens it with
`MessageInfoPage.open(context, m, ...)`; a wapp that sends no details still
gets the page from the bubble alone. The wapp side is `info_publish` in
`apps/chat/main.c`: its stored row and versions, plus the core's archived
packet by id (`hal_xprs_history {"id":...}`).

### A conversation's notifications switch — the row's `muted` flag

A wapp that lets a person silence a conversation states it as `"muted"` on
its `ui.convo.upsert` row. `ConversationStore.upsert` takes it, and the
existing gates do the rest in both engines: `mayNotifyFor` drops the
`notify`, `totalUnread` leaves the room out of the app badge, and its own
row still shows its count. `RoomsField(onToggleNotify:)` draws the switch,
in the row menu and as the open room's header bell (`_notifyButton`), and
the page sends `<field>_notify` with `<field>_convo`. Chat keeps the choice
in `rooms.notify`, where NULL means the room's default (`NOTIFY_ON` in
`apps/chat/room.c`: on everywhere but `#GLOBAL`). Any other wapp gets the
same switch by stating the flag and answering the command.

## Archive admission

- **`XprsIngest._isRoomTalk(p, bearer)`** -- "is this a room's conversation,
  heard within its scope": undirected message or reaction, and
  `xprsReachAdmits(xprsScopeReach(p), xprsBearerReach(bearer))`. The same
  test `XprsArchive._reachOf` applies on read; anything that decides whether
  a row belongs to Local/Regional/Global should call one of these two rather
  than parse `scope:` itself (the firmware's `xprs_scope_reach_wire` and the
  web page's `scopeRoom` are the same rule in C and JS).
- **`XprsArchive.query(room:)`** -- one chat room by the scope before `m:`,
  reached from the web chat as `room=` and from a wapp as
  `hal_xprs_history {"scope": ...}`. Ask a room at a time; never ask for the
  newest N of everything and sieve.

## Drawing in the order things were said

- **`_placeOf(messages, row)` in `conversation_store.dart`** -- where a bubble
  that states its `ts` goes: after the last row said no later than it, never
  past a row that states no time. The web chat's `render()` does the same with
  `data-ts`, and the Chat wapp opens a room `ORDER BY ts, seq`. Any list that
  can receive rows out of order (an archive replays newest first) should place
  by the sender's time this way rather than append.
- **The same rule for a list's summary line**: any "latest" preview over
  sender-time ordering follows the newest said, not the newest arrived. The
  Chat wapp's `room_admit` lets a live arrival set the room's `last_line` only
  when nothing newer is held.
- **Late words: marks and a jump** -- a live arrival said before the newest
  message held is counted and rung like any other, and its room keeps a mark
  on it (`marks` table, `room_marks_emit` -> `ui.convo.marks`). Any wapp that
  draws with `ChatViewField` gets the rest by sending that message:
  `ChatViewField.marks` shows an up-arrow button over the list that jumps to
  the oldest unseen mark, `onAround` asks the wapp for the rows down to one it
  does not hold (chat: `rooms_around`, `room_around`), `onMarksSeen` reports a
  marked bubble once it has been on screen (`rooms_seen`), and `takeJump`
  lands on one message (`ui.convo.jump`, from a notification whose `view` is
  `msg:<mid>`). `_scrollToMid` is the bounded scroll-to-a-lazily-built-item
  loop to reuse for any "jump to message" (replies, search hits, mentions).

## Folders the format can find (XPRS.md 7.7.2, 7.7.3)

- **`lib/services/xprs/xprs_folder.dart`** -- `xprsListingBuild/Parse` (the
  XFL1 listing, deterministic), `xprsDescribeMember` and `xprsDescribeFolder`
  (the signed `t:file` packets), `xprsFileRefOf`/`xprsFileShaOf` (both forms
  of a reference), `xprsBytesOf` (a byte `qty`), and `XprsFolderPublisher`,
  which stores, holds, airs and deposits with every effect injected. Anything
  that publishes a set of files for others to find by a person's key goes
  through it; the firmware folder is the first user
  (`POST /api/xprs/folder/publish`).
- **`xprsFmtTs`** in `xprs_vocab.dart` (now in `../core`): the inverse of `xprsParseTs`.
  `XprsCatchup._ts` and `XprsFetch` predate it and could use it.
- **`RnsService.addFileSource`** -- serve a `DiskFolderSource` (or any
  `FileSource`) over the `xprs/files` link lane without restarting the node.
- **`FirmwareMirrorService`** (`lib/services/firmware_mirror_service.dart`)
  -- the shape for "keep a published set of files and offer them":
  `FirmwareFeed.parse` believes a document only through signatures, the
  service's fetch, download, hash, hold, air and deposit are seams, and the
  images are served through `RnsService.addFileSource(DiskFolderSource)`.
  The next mirrored set (wapps, maps tiles) should reuse it rather than copy
  `UpdateMirrorService`.

- **`XprsHistoryServer.freelyServed`** -- a host-supplied predicate over a
  digest that lifts the 31.2 stranger budget for `cmd:file` on files held for
  everyone (the firmware mirror sets it in `main.dart`). Reuse it for any
  other public, content-addressed set a device offers on purpose, instead of
  a second budget or a special-cased command.

## Talking to a station over its USB cable

### `claimOverConsole` — a line-oriented session on a booting station's console

**File:** `lib/services/flash/station_console.dart`

Written against `SerialPort` alone, so it runs on whichever isolate holds the
port (the flash worker on Linux, the main isolate on Android). It waits for
the firmware's banner (`XPRS station <call>`), sends `cfg` lines a few bytes
at a time (an older image reads its console a character per UI tick and the
USB-JTAG ring drops a line written in one go), matches each answer the way
`xcfg_console` prints it, retries a line the board refused, and reopens a port
that vanished on the reset. Its text buffer is bounded at 8 KB because it is
scanned per read.

Anything else the core needs to tell a station over the cable it already
holds (WiFi for a board no radio can reach yet, a pinned key) should be one
more `_ask` here, not a second console reader. `FakeConsole` in
`test/flash_console_claim_test.dart` answers like the firmware and is the
fixture to reuse.

## The app's half of the core (lib/boot/)

The core (`../core`) asks this app for platform things only through
`CoreHost`; these are the answers. Reuse them; add a new answer here, never a
Flutter import in the core.

- **`lib/boot/core_host_app.dart` `wireCoreHost()`** — the one place every
  seam is wired, at boot before any core service starts.
  `routeCoreNotification()` maps a core topic (`core:nostr`) to the wapp that
  shows it; extend `coreNotificationWapps` rather than naming a wapp in core.
- **`lib/boot/core_stores_app.dart`** — `SharedPreferencesStore`
  (KeyValueStore), `FlutterSecureStore` (SecureStore), `BundleAssets`
  (AssetSource). Tests get the first and last through
  `test/flutter_test_config.dart`.
- **`lib/boot/power_app.dart`** — `BatteryPlusSource`, the tier push to the
  native service, and the lifecycle observer that feeds `PowerState`.
- **`lib/boot/radio_app.dart`** — `AppAdvertRadio` (Ble5Bus + BleService).
- **`lib/util/observable_listenable.dart`** — `observable.listenable`: a core
  `Observable` as a Flutter `ValueListenable` for `ValueListenableBuilder`
  (one cached adapter per value, so builders see a stable object).
- **`lib/wapp/wapp_notes.dart` `publishWappNote()`** — a wapp's `social.note`,
  for the page and the headless engine alike; the page asks for the preview
  thumbnail.
- **`lib/services/i18n/flutter_locales.dart`** — CoreI18n's language as
  Flutter `Locale`s for MaterialApp.

## Browser interop that compiles under dart2js AND dart2wasm

- **`third_party/wasm_run/lib/src/web/js_helpers.dart`** — `dart:js_interop`
  helpers used by wasm_run's browser half: `jsifyMixed` (Dart lists/maps/
  primitives/typed data to JS, JS values passed through, other Dart objects
  boxed), `dartifyJson` (JSON-like JS to Dart, numbers to `int` when integral,
  a `BigInt` kept as the JS value), `jsNumberToDart`, `jsBigInt`, `jsString`
  (works on primitives such as a BigInt), `objectAssign`, `objectKeys`,
  `jsIsArray`. Reuse these patterns (or lift the file) for any new web-only
  code instead of `dart:html` / `dart:js_util` / `package:js`, which dart2wasm
  cannot compile. Key a conditional import on `dart.library.js_interop`, not
  `dart.library.html` (false under dart2wasm), and put any
  `if (dart.library.io)` first.
- **`third_party/wasm_run/lib/src/wasm_bindings/_wasm_js_web.dart`** —
  extension-type bindings of the WebAssembly JS API
  (`WebAssembly.Module/Instance/Memory/Table/Global`, `compile`,
  `instantiate`).

- **This phone as a station** (Mesh wapp, core `StationHost`/`StationShare`):
  the wapp reads `hal_station_read {"get":"host"}`, flips
  `hal_xprs_set_pref("hostStation=…")` and asks the host to pick and share
  with the message `station.share {kind}` (`_handleStationShare` in
  wapp_page.dart: the system file picker, a name for the folder, `StationShare.add`).
  Reuse the message from any wapp that wants "share this folder".

## One writer for a setting the API and a page both change

`applyArchiverSettings(Map data, {legacy})` (`lib/services/xprs/
archiver_settings.dart`) is the only place the archiver's preferences are
written; the Archiver page and `POST /api/xprs/archiver` both call it with the
keys they change. Copy the shape for any setting with side effects (a service
to restart, a policy snapshot to reload): a page and an API that each did the
writes themselves drifted apart within weeks.

## Retiring a bundled wapp whose job moved into the app

`_retireWapp(name)` (`lib/launcher/seeding.dart`) removes an installed copy,
its data and its autostart, keeps a user-modified copy, and leaves the name in
the offered sets so seeding never reinstalls it. Register a one-line wrapper
as a sequential boot task (see `retireArchiverWapp` in `lib/main.dart`).
Removing the `.wapp` from `assets/wapps/` alone only stops new installs.

## The black-and-white theme (`lib/launcher/app_theme.dart`)

`xprsTheme()` is the app's only ThemeData and `xprsMonochrome` its scheme,
written by hand (no seed, so no lavender tints): white accent, grey
containers, red only for errors. Painters and charts take their inks from
`Theme.of(context).colorScheme`, never from their own greys.

## Charts without a library (`lib/launcher/archiver_charts.dart`)

`BarChart`, `LineChart`, `Sparkline` and `SplitBar`: CustomPainter charts in
theme inks, one series each, with touch-to-read values. Reuse them for any
small stats panel before adding a chart dependency.

## A daily log of live counters (`lib/services/xprs/archiver_stats.dart`)

`foldArchiverReading` turns in-memory counters (which reset at every launch)
into one persisted row per day: deltas within a process, a reset counted
whole, snapshots overwritten, at most N rows. Copy the pattern for any other
"last 14 days" view; sample hourly, never per event.

## A pinned app card on the home hero (`lib/services/hero/archiver_hero_source.dart`)

`ArchiverHeroCard.card()` is inserted at the hero's second slot after
ranking (HeroFeedService.refresh) instead of joining the ranked pool; the
tap is routed by `sourceId` in `launcher_page._openHeroItem`.

## Formatted text and tappable links (XPRS.md 4.11)

- **`lib/util/xprs_md.dart`**: the ONE Dart reader for the Flutter app
  (Android, desktop). `parseXprsMd(text)` -> blocks of styled spans
  (bold/italic/strike/code, `url`, `ref`+`image`, `mention`), `xprsMdToHtml`,
  `xprsMdHasMarkup` (keep a plain `Text` for plain words), `xprsMdToWire` /
  `xprsMdFromWire` for a composer. Never write another Markdown regex in
  Dart; cases in `test/xprs_md_cases.json`. (The web portal's JavaScript has
  its own reader in `portal/page/xprs_md.js` and stays independent.)
- **`XprsMdText`** (`lib/wapp/geoui/widgets/xprs_md_text.dart`): draws those
  spans as one `Text.rich` (shrink-wraps in a bubble, `maxLines` for a card
  preview); links tap through `onLink` or **`openExternalLink(url)`**
  (http/https only, system browser via url_launcher). Used by the chat bubble
  (`_bodyText`), the cards' description (forum posts) and the release notes
  on the Updates page.

## Picking the station callsign (`changeStationCallsign`, device_identity_card.dart)

`changeStationCallsign(context)` is the whole flow: a dialog with a fresh X3
candidate, "another one" (autorenew), "back" (undo through the ones shown) and
Save, then an offer to exit so every connection uses it. `DeviceIdentityCard`
(Settings > This device) and the Archiver page's station row both call it.
Reuse it wherever the station's name is shown with an edit action.

## One XPRS post, one row (`ActivityArchive.isXprsMid`)

An XPRS post is one (author, ts) (XPRS.md 7.6) but can arrive under several
6-hex identifiers (as sent, rebuilt from parts, heard again). Anything that
lists posts matches on author + time for XPRS ids (`ActivityArchive.isXprsMid`)
and on the id alone for NOSTR (64 hex). The archive merges old copies on open
(`_mergeXprsCopies`); the feed buffer in wapp_page.dart skips a twin and lets
a withdrawal of any copy withdraw the post shown.

## Finding a wapp by what it provides (`lib/editor/edit_provider.dart`)

`provider(functionality)` returns the first installed wapp whose manifest lists
the functionality under `provides.functionalities`, from the launcher's scan
(`FunctionalityRegistry`), so it reads no disk. Use it whenever host code needs
"a wapp that can do X": never compare a wapp id or folder (architecture.md,
`no-wapp-special-case-in-host`). `wapp.edit` (the AI add-on) is the first.

## One wapp serving another (`lib/wapp/functionality_broker.dart`)

A wapp that needs something another wapp can do sends `widget.request` and
gets a `widget.response`, whenever the provider is ready
(`apps/wapp-interfaces.md` 5). Use this before adding a `hal_*` for anything
a wapp could provide: the AI (`ai.chat`, C helper `apps/sdk/wapp_ai.h`) is
the first service built on it. The broker opens the provider headless with
its own storage, id and permissions, names the caller, enforces the
functionality's `timeout_ms`, and is woken by the engine's outbox hook, so
nothing polls. Host code that wants the same service calls
`FunctionalityBroker.instance.handleRequest` with an engine to answer to.
`test/functionality_broker_test.dart` shows how to test a provider/caller
pair with no wasm (`WappEngine.debugEmit`, `debugInbox`).

## Waking a wapp when its request is answered (`WappEngine._httpStart`)

`hal_http_request2` hands the wapp `{"type":"http.done","id":N}` and calls
`handleEvent` when the response is in, the same way the event broker wakes a
subscriber. Any new asynchronous hal verb should do the same instead of letting
the wapp poll from `module_tick`.


## Per-room permissions on the rail (`ui.rooms.set`)

`RoomsField` (`lib/wapp/geoui/widgets/rooms_field.dart`) offers an action on a
room only where the wapp's rail entry says this station may do it, and hands
the room's id back as a command; the wapp still judges the act. `nest: true`
offers "New folder" on the row menu and in the open room's header
(`onNewRoom` → `rooms_new`, chat's `folder_ask`). The rail is restated whole on
every change, so a flag there cannot go stale the way a row upsert's can. A
new per-room action (pin, rename, ...) should be one more flag on the same
entry, read through a helper like `_nests(id)`.

## Is this wapp part of the app? (`isBundledWapp`, `lib/launcher/seeding.dart`)

`isBundledWapp(name)` says whether the app ships `assets/wapps/<name>.wapp`.
Use it wherever host code must treat a person's own wapps (installed from a
file, passed on by someone) differently from the app's: the wapp page offers
Uninstall only for the former (`_uninstallThisWapp`). It answers true when it
cannot tell, so nothing destructive is offered by mistake.

## A composer that counts down to a size limit

`lib/wapp/geoui/widgets/compose_counter.dart`: `composeRoomLeft(max, text,
extra)` is the room left in UTF-8 bytes (what a packet holds) for the text plus
any attachment tokens sent with it, and `ComposeCounter(left)` draws it, amber
in the last 20 and red past zero. The Status feed's post and reply composers
use it, with the limit from the wapp's field (`"max"` on the `activity` field
in `apps/social/screens/home.ui.json`); past zero they refuse to send. Another
limited composer should take a `"max"` from its field the same way and reuse
these two.

## Walking a tree of rooms on a phone (`rooms_field.dart`, `wapp_page.dart`)

`roomsKids(rows, id)`, `roomsPath(rows, id)` and `roomsLeaf(name)` read the
rooms layout's rows (`ui.rooms.set`, each naming its `parent`) as a tree: the
folders directly under a group, the path from the root down to a room, and a
folder's own name out of its "Group › Folder" title. `roomAvatar(id, name,
size)` is the one drawing of a room's face (a group's picture, else its
initials). Together they are how the host's ONE bar is the navigation on a
phone (`_roomsCrumbs`, `_roomsUp`, `_roomsBarActions`): the path is the title,
its steps are buttons, and back goes up a level read off the tree. Any other
nested list a wapp shows on a phone should use these rather than drawing a
second header under the bar. `test/rooms_phone_nav_test.dart` is the contract.

## A room this station cannot write in (`nopost`, `ChatViewField.closedNote`)

A wapp that owns its conversations states `"nopost":true` on a room's row
(`ui.convo.upsert`) when this station may read it but not write there; the
rooms layout then shows a note where the message box was
(`ChatViewField.closedNote`). Chat uses it for a group closed to new posts
(XPRS.md 10.4.2; the core's `XprsGroups.mayPostNow` / `postStands` are the
rule, `hal_xprs_group_closed` the act). Use the same flag for any read-only
room rather than refusing the send after the person has typed.

## Counting distinct things across stations (`XprsSketch`, core `xprs_group_index.dart`)

A 64-register HyperLogLog: `add(item)`, `merge(other)` (register-wise max),
`estimate()`, and a 64-character text form. Two stations that each saw part
of something, with overlap, combine their sketches and count each thing once:
neither a sum nor an average. XPRS.md 12.9.7 fixes the hash and the encoding,
so the ESP32 and any other implementation produce the same sketch. Use it for
any "how many distinct X, network-wide" question (posts, people, devices)
before inventing a protocol to exchange lists. `XprsGroupRanking` is the
example of merging several stations' views.

`xprsGroupRankRows(by)` (core `xprs_group_rank_rows.dart`) is that ranking
as rows to show (names, folders as `Group › Folder`, private groups left
out). The app's `hal_xprs_group_rank` and the web chat's
`GET /api/xprs/groups` both answer with it: a third consumer calls it too.

## Settings topics

`IwiSettingsPage` (`lib/launcher/settings_page.dart`) is a short menu of topics
(`_menu`), and `IwiSettingsPage(topic: SettingsTopic.x)` is one topic's page
(`_topicBody`), built from the same state and section methods (`_secLang`,
`_secHosting`, ...). A new setting goes into the section of its topic; a new
topic is one `SettingsTopic` value, one `_entry` on the menu and one case in
`_topicTitle` and `_topicBody`. A page that is already its own screen (Groups,
Hardware, Permissions) is an `_entry` straight to it. Each topic page loads only
what it shows (the wapp-data walk for Storage, hosted usage for Network).
`CoverageCard` (`lib/launcher/coverage_card.dart`) is the Coverage switch, kept
beside location sharing so both read the same location, GPS or typed.

### Archiver page building blocks — `_section` / `_switch` / `_choice` / `_tiles`

`lib/launcher/archiver_page.dart`. Everything this device stores or serves for
others is set on the Archiver page, never in Settings: a new control is one
`_switch(title, help, value, onChanged)` or `_choice<T>(title, value, options,
onChanged)` inside a `_section(context, title, [...], help:)`. `_hostSection`
(Files tab) is the pattern for a group that writes preferences directly and
then calls a core `apply…()`: pass `null` as `onChanged` to grey a row out.
The hosting switches (`hostEnabled`, `hostCapacityGated`, `hostCeilingGb`)
moved here from Settings > Network on 2026-11-20; they fill the same hosted
store the Files tiles count and "Free space" empties, so no second
"used / clear" pair is needed.

A widget test that opens the page must touch `NodeRoleApi.instance.serveRings`
in `setUpAll` first: its minute timer otherwise starts inside the test's fake
clock and is reported as pending (`test/settings_topics_test.dart`).

### Recipe steps that never change — `tool/fdroid_deps.sh`

F-Droid's `checkupdates` copies the last build block to each new version, so
anything that differs between versions must live in the repository, not in
the recipe. `tool/fdroid_deps.sh` is the pattern: the recipe says only
`sh tool/fdroid_deps.sh`, and the script (versioned with the release) decides
which `deps/` submodules exist and where they go, and checks each gitlink
against its `.*-commit` pin file. A new source dependency is a submodule, a
pin file, one `place` line there and one `link` entry in `release.sh`; no
fdroiddata change. Do the same for any future per-version build logic.

## Found on the phone, 2026-11-22

- `roomsBarOffers(rows, at, open:, canFolder:)` (`lib/wapp/geoui/widgets/rooms_field.dart`):
  what a room's menu offers, read from what the wapp states on its rail entry
  (`page`, `share`, `nest`). A new menu item for a room is a word on the rail
  entry plus a line here, never a test on the room's id in the host.
- A form row with a picker and a text field: stack them on a phone and give
  the field `errorMaxLines` (`other_identities_editor.dart`); side by side the
  error is cut off.
- `remoteApiAdmits` / `newRemoteApiKey` / `remoteApiUrls`
  (`lib/services/remote_api_access.dart`): the rule for a local service that
  its owner may open to the LAN (private address, a key, never a browser).
  Reuse it for any other listener that should be reachable from the network
  only on request.
- `messageKeptRows(...)` (`message_info_page.dart`): the Info page's "Where it
  is kept" rows from the outbox's record, the reader's mailboxes and the
  relays. `ChatViewField.onRepeat` -> `<field>_repeat`: the wapp sends the
  stored packet again through `hal_xprs_send`, no new call into the core.

## Release changelog from the commits

`tool/changelog_auto.sh <previous-tag> [core-pin] [rd-pin] [wapps-pin]`:
the commit subjects since the last release across the app and the three
pinned siblings, newest first, without docs/test/tool-only commits, capped
at 80 words and 500 characters. `release.sh` always uses it; `release.yml`
publishes it as the release text (the update centre's "What's new"). Since
the subject IS the changelog, write commit subjects for the person using
the app.

## Asking a wapp's functionality from host code

`FunctionalityBroker.instance.ask(id, args, caller: 'name')`
(`lib/wapp/functionality_broker.dart`): a host screen or service asks a
functionality a wapp provides and gets the provider's `result` back as a
Future (a `FunctionalityError` for every failure). Same provider choice,
time limit and log line as a wapp's `widget.request`. The chat box's link
cards are the first user (`lib/wapp/link_cards.dart`).

## Link cards in a composer

`LinkCards` (`lib/wapp/link_cards.dart`): `firstUrl(text)` finds the link a
sentence carries (without its trailing punctuation), `cardFor(url)` asks the
`link.card` provider once per address, and `withCard(text, card)` writes the
title and summary as a plain line after the words, cut to fit. `ChatViewField` shows it above the
box (`_cardPreview`) and sends it. Any other composer (posts, forum) reuses
the three calls.

## A wapp bounding an HTTP answer

A `Range: bytes=0-N` header on `hal_http_request2` caps the answer at N+1
bytes whatever the server does (`WappEngine._rangeCap`, `HttpTransport.request
maxBytes`). Any wapp reading an address it did not vet sends one.

## Wapp UI bridges (2026-11-24)

- **`CallsignPickerPage`** (`lib/profile/callsign_picker.dart`): THE screen
  for choosing a callsign by letters, for every kind. Pass a
  `CallsignKeySource`: `IsolateCallsignSource(prefix)` searches on a worker
  isolate (`callsign_search_io.dart`, web stub behind `callsign_search.dart`)
  and returns the key with the callsign, reporting every 250 ms so the page
  needs no timer. For a group the caller hands the chosen key to
  `XprsGroupKeys.offer(kp)` (core), which keeps it in its pool and returns
  the callsign; never search with `candidates()`, which mints on the
  caller's isolate. Users: the welcome page (X1), `ui.callsign.pick` from a wapp
  (Firmwares, X3), and the `search: "X5"` button of a prompt's `cycle`
  (Chat's new group). Do not write another search; add a source if a new
  kind keeps its keys somewhere else.
- **`ui.callsign.pick`** {field, prefix, length, current} (`wapp_page.dart`
  `_pickCallsign`): a wapp opens that screen; the answer is the command
  `<field>_picked` with `<field>_call`, plus the secret `<field>_nsec` unless
  the kind keeps its key in the core (X5).
- **An image field takes a web URL** (`_imageForPicture`): `https://` goes
  through `bannerImage`, decoded bounded like every network picture.

## A setting on by default, said once (`launcher/position_share_card.dart`)

- `sharePositionByDefault()`: a default that changes for people who never
  chose (`PreferencesService.positionShareChosen`, i.e. the key is absent) is
  written once and announced with a notification whose `source` is the page
  that holds the switch (`hostNotificationPages`). Reuse the three steps for
  any default turned on later: never-chosen test, write, notice that opens it.
- The code field in `PositionShareCard` (text field, copy and new-code icons
  in `suffixIcon`, saved when the typing pauses): the shape for any secret a
  person shares by hand.

## Fetching a release artifact by its sha256 (`lib/services/artifact_fetch.dart`)

`ArtifactFetch.overMesh` / `overReticulum` / `overWeb` move one feed asset
(`ReleaseAsset`: name, url, size, sha256) into a folder the caller names, each
lane checking the sha256 before it answers. Try them in that order: a station
in earshot (BLE bulk lane, straight to disk), an always-on archiver or this
device's own mirror over Reticulum, then the feed's URL. The caller keeps its
own progress state; the lanes only move and verify bytes. Users: the updater
(`UpdateService._downloadOverMesh` / `_downloadOverReticulum`) and Share's
installers (`ShareLibrary.add`). Anything else that needs "a release binary,
offline if possible" (a wapp bundle, a firmware image named in a feed) should
call these rather than grow a fourth lane. `UpdateNative.download` and
`writeBytes` take a `dir:` for the same reason.

## A switch that outlives its page (`ShareAppService.setPortal` / `restore`)

A service a person leaves on (the Share web portal) keeps its state in one
preference, flips it with `setPortal(on)`, and re-reads it with `restore()`
from two places: the page's `initState`, and `hostBoot()` (called by
`PermissionGate.startGatedServices`, which also runs on the headless boot
engine). The native side it needs lives in `NativeBridgeRegistry`, never in
`MainActivity`, or the service comes back at boot without its channel.
The page shows the switch first, as a `SwitchListTile` bound to the service's
`ValueNotifier<bool>`.

## Which network a visitor can reach us on (`shareInterfaceRank`)

`lib/services/share_app_types.dart`: ranks an interface name from Android,
Linux, macOS or Windows (hotspot, Wi-Fi, wired, other) and drops cellular,
tunnels, VPNs and virtual bridges. Use it for any "scan this QR from the
device next to you" address.
