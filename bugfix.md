# Bugs to fix

Found in the bug hunt of 2026-10-06 on the Linux desktop build (station
X16JK8, phone X1ARKL on the same LAN). The ones fixed that day are in the git
log (`d0f7902`, `bc7ebd8`, `3362c6f`; `../apps` `8fe0f1b`, `70d436d`). These
are the ones that were not.

## Core

1. **A LAN message is heard 5 to 15 times.** Two messages sent from the phone
   (`POST /api/xprs/send`) reached the desktop with `heard` counts of 7, 12, 15
   and 13 in `/api/xprs/history`. Each copy costs airtime on a shared bearer.
   One lead: the third station KO6JZI carries custody copies of the same
   message ("Mesh: custody delivery from KO6JZI ... (x2)"). Find which sender
   repeats it, and fix it in the core bearer (architecture.md section 4), not
   in a wapp. The XPRS wapp now shows one row per packet with "heard xN", so
   the count is visible there.

1b. **The C61 re-airs the public hubs' announce flood onto LAN (and BLE5).**
   On 2026-10-07 the log showed every hub announce rebroadcast to `lan` and
   `ble5` at hops=2, about three a second each, with the BLE GATT queue full
   and dropping. `rns_transport.dart` has `edgeQuiet`/`edgeBridge` modes that
   keep the internet flood off edge bearers; check which mode the phone runs
   in and whether a station should carry hub announces onto a shared radio at
   all (performance.md 8.11, 8.14). Now visible as `announcesRebroadcast` on
   `/api/rns/status`.

1c. **The C61's native heap is 140 MB twenty minutes after start** (170 MB at
   ten hours). Not the announce leak (that was Dart heap, fixed in `576d5c0`),
   and present from start-up, so likely baseline: sqlite page caches (the
   archive holds 217k backfilled messages), 18 wapp engines' linear memory,
   decoded images. Attribute it with a profile build and heapprofd by mapping
   (performance.md, "Profiling native memory on a stock device"), then soak
   for hours to see whether it grows.

## Wapps

2. **Archiver: "Mine: 74.8k packets".** Far more than one station plausibly
   wrote. Check what the archive counts as "mine" (own receipts, commands and
   beacons, or rows that are not ours at all).
3. **Indexer: "36 links, 0 authors".** The Authors tile is the authors this
   station advertises (`advertisedAuthors`), while Links are pointers it stores
   for others, so the pair reads as a contradiction. Rename the tile, or show
   the authors behind the links.
4. **Mesh: the legend says "LAN/WiFi 0" beside a LAN link on the graph.** The
   chips count only our own XPRS devices (`isDevice`), not phones or hubs. Make
   the label say so, or count what the graph draws.
5. **Firmwares: a station that is "not heard" carries a "WiFi up" tag.** A
   last-known state shown as current. Age it, or say "was WiFi up".

## Host UI

6. **Settings, storage: folder names instead of wapp names** ("social" for
   Status, "app-creator"). Needs a folder to title lookup from the manifests.
7. **System folder: "Functionality Demo" and "Functionalities" share one
   icon**, and the names barely differ.
8. **Switches use the theme's lavender**, not the app's accent (Archiver,
   Indexer, Settings).
9. **A chat row with no last message keeps its name at the top**, a few pixels
   off the avatar's centre (Chat list, X5WAUC).

## Devices, not the app

10. **The front-door camera (X49HRF, 192.168.178.142:8080) stalls.** Its
    snapshot sent 1 KB in 8 s and stopped; Things correctly gives up after 35 s
    with "It did not answer".

## Hidden wapps, if they come back

Terminal, Circles and the Wapp Store were hidden from the launcher on
2026-10-06 (`_kHiddenWapps` in `lib/launcher/launcher_page.dart`). Before
unhiding any of them:

11. **Terminal: output is not monospaced on Linux**, so the help table's
    columns do not line up. Adding `fontFamilyFallback` to the `'monospace'`
    styles in `wapp_page.dart` and `log_view_field.dart` did not change it, so
    the output is drawn somewhere else; find that widget first.
12. **Terminal greets with "Geogram Terminal v1.0"**, an old product name.
13. **Circles: list and message times are hh:mm:ss in UTC**, not local time
    (`fmt_time` in `apps/circles/circle.c`). The list should show an age ("3h",
    "yd") like Chat.
14. **Wapp Store lists one app.** `../apps/catalog.list` publishes only
    `widget_demo` ("One app for now"). Publish the real set first.

Circles and Terminal install from the catalog, not with the app, so a fix to
either ships only once the catalog is published.
