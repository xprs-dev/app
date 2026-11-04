// Architecture guard — the rules in docs/architecture.md, machine-checked.
//
// Reviews do not catch these. A feature built in the wrong layer works, and a
// blocking call on the UI isolate is invisible until the device is busy. Both
// mistakes have been made here more than once, months apart, by people who knew
// the rule. So the rule is checked instead of remembered.
//
//   dart tool/arch_guard.dart              check; exit 1 on a NEW violation
//   dart tool/arch_guard.dart --list       every violation, baseline included
//   dart tool/arch_guard.dart --baseline   re-record the baseline (deliberate)
//
// Baseline, not zero-tolerance: what already exists is recorded in
// tool/arch_baseline.txt and does not fail the build; anything new does. A
// guard that fails on day one gets disabled on day two.
//
// No dependencies, on purpose — one file, plain Dart, so it keeps working.
import 'dart:io';

/// One thing we refuse to let back into the codebase.
class Rule {
  const Rule({
    required this.id,
    required this.why,
    required this.appliesTo,
    required this.pattern,
    this.exempt = const [],
    this.message,
    this.window = 1,
  });

  /// Stable id — appears in the baseline, in `// arch-ignore:` and in docs.
  final String id;

  /// Why this rule exists. Printed with every violation, because a rule whose
  /// reason is unknown is a rule someone will delete.
  final String why;

  /// Path globs (simple `**`/`*` matching) this rule looks at.
  final List<String> appliesTo;

  /// What a violation looks like (compiled on use — `const` cannot hold a
  /// RegExp, and keeping the rule table const is what makes it readable).
  final String pattern;

  /// Paths inside [appliesTo] that are allowed to match.
  final List<String> exempt;

  /// Extra guidance for this specific hit.
  final String? message;

  /// How many lines the pattern is matched across. A call split over lines
  /// (`Timer.periodic(\n  const Duration(...)`) escapes a one-line regex, and
  /// that is how several sub-minute timers got past the first version of this
  /// guard. With a window > 1 the lines are joined with a space, and a hit
  /// counts only if it STARTS on the current line, so it is reported once.
  final int window;
}

// ── the web build ───────────────────────────────────────────────────────────
const webBuildRule = Rule(
  id: 'no-native-import-outside-io-file',
  why: 'lib/ also compiles with dart2js (flutter build web). dart:ffi and '
      'the FFI half of package:sqlite3 are hard compile errors there; '
      'dart:io and dart:isolate compile and then throw on every call. Put '
      'the native half in a *_io.dart behind a conditional export '
      '(lib/platform/fs.dart, lib/profile/profile_db.dart are the pattern) '
      'and reach files through `fs`, databases through openProfileDb '
      '(docs/web.md).',
  appliesTo: ['lib/**'],
  exempt: ['lib/**/*_io.dart'],
  // An unconditional import: the URI and its show/hide/as on ONE line ending
  // in `;`. A conditional one continues on the next line with `if (...)`, so
  // it does not end here and is not matched.
  pattern: r'''^\s*import\s+'(dart:io|dart:ffi|dart:isolate|package:sqlite3/sqlite3\.dart|package:sqlite3/open\.dart)'(\s+(show|hide|as)\s+[^;]*)?;''',
);

const rules = <Rule>[
  // ── isolates ──────────────────────────────────────────────────────────────
  Rule(
    id: 'no-blocking-io-on-ui',
    why: 'The UI isolate must never block: a synchronous read or a sleep is a '
        'dropped frame at best and an ANR on a loaded phone. Use the async '
        'form, or move the work to an isolate (docs/performance.md).',
    appliesTo: ['lib/ui/**', 'lib/wapp/**', 'lib/launcher/**', 'lib/profile/**'],
    pattern: r'\b(readAsStringSync|readAsBytesSync|writeAsStringSync|'
        r'writeAsBytesSync|readAsLinesSync|sleep)\s*\(',
  ),
  // ── the receive path ──────────────────────────────────────────────────────
  Rule(
    id: 'one-receive-door',
    why: 'Every received packet enters through PacketGateway, whatever bearer '
        'carried it. Reaching past it to the funnel, the courier or the inbox '
        'is how four lanes came to deliver to a person without the core ever '
        'seeing the packet -- an XPRS 1:1 over Reticulum was archived and '
        'never delivered, and the chat wapp acknowledged messages it then '
        'dropped. Nothing errored in either case, which is why this is a rule '
        'and not a habit (docs/message-receive.md).',
    appliesTo: ['lib/**'],
    exempt: [
      // The door itself, and the two funnels it is the door for.
      'lib/services/receive/packet_gateway.dart',
      'lib/services/xprs/xprs_ingest.dart',
      'lib/services/mesh/mesh_courier.dart',
      // RnsService owns the LXMF inbox, which is the door for messages that
      // arrive already decoded rather than as a packet. Different layer, and
      // it is fenced by being named here rather than by being forgotten.
      'lib/services/reticulum/rns_service.dart',
    ],
    pattern: r'\b(XprsIngest\.(heard|reticulum)|MeshCourier\.instance\.ingest|'
        r'\.deliverXprs|injectLxmf)\s*\(',
    message: 'Call PacketGateway.instance.receive(bytes, bearer:, lane:) and '
        'let the core decide what the packet is.',
  ),
  Rule(
    id: 'no-platform-channel-off-main',
    why: 'Platform channels only exist on the main isolate. Called from a '
        'spawned isolate they fail silently, which looks like a radio problem '
        'and is not.',
    appliesTo: ['lib/**/*_isolate.dart', 'lib/services/isolates/**'],
    pattern: r'\b(MethodChannel|EventChannel|Ble5Bus\.instance)\b',
  ),
  Rule(
    id: 'no-platform-channel-off-main',
    why: 'BackgroundIsolateBinaryMessenger hands a worker isolate a platform '
        'channel, which is the rule above evaded rather than followed: the '
        'worker then stalls on the platform thread and the radio bridges '
        'lose their one owner (docs/performance.md 1.2, 8.1). Bridge bytes to '
        'main for the I/O instead. Added the day the USB flasher tried it.',
    appliesTo: ['lib/**'],
    pattern: r'\bBackgroundIsolateBinaryMessenger\b',
  ),

  // ── layering: transports belong to the core ───────────────────────────────
  Rule(
    id: 'no-transport-in-wapp-layer',
    why: 'The wapp layer hands the core a payload and is called back. Reaching '
        'into a radio or the mesh internals from lib/wapp is how '
        'store-and-forward ended up inside the chat wapp '
        '(docs/architecture.md §1).',
    appliesTo: ['lib/wapp/**'],
    pattern: r'''import\s+['"][^'"]*(?:ble5_bus|ble_service_io|ble_gatt_|'''
        r'''ble_rns_radio|mesh_courier|mesh_store|mesh_session|mesh_custody|'''
        r'''rns_transport|rns_link|rns_packet)[^'"]*['"]''',
    message: 'Go through a service facade (RnsService, MeshService, '
        'BleService) instead.',
  ),
  Rule(
    id: 'no-app-logic-in-core',
    why: 'A core service must not know a wapp exists. Give the core a generic '
        'capability and let the wapp use it — otherwise every wapp needs its '
        'own special case in lib/. The first version of this rule matched only '
        "`id == 'tools.xprs.x'`, and the core went on writing straight into "
        "the Social wapp's database (wappDataStorageFor(prefs, 'social')) and "
        "carrying a Circles-only rendezvous (kRvWappTag = 'circles') unseen "
        '(audit 2026-11-04).',
    appliesTo: ['lib/services/**', 'lib/connections/**'],
    pattern: r'''\b(?:wappId|appId|id)\s*==\s*['"]tools\.xprs\.\w+['"]'''
        r'''|wappDataStorageFor\([^,]+,\s*['"]'''
        r'''|\b(?:_?wapp\w*|appId|wappId)\s*[!=]=\s*['"]'''
        r'''|\bk\w*Wapp\w*\s*=\s*['"]'''
        // A notification raised as one wapp's (`source: 'wapp:social'`):
        // the core says what it is about (`core:nostr`), the host routes it.
        r'''|\bsource:\s*['"]wapp:[a-z]''',
    message: 'Give the core a capability any wapp can use, and let the wapp '
        'name itself through the HAL.',
  ),
  Rule(
    id: 'core-imports-ui',
    why: 'The core sits UNDER the wapps and the screens (architecture.md §1). '
        'A core service that imports lib/wapp, lib/launcher, lib/ui or '
        'lib/editor cannot move to the shared core package, cannot run in the '
        'server edition, and drags the UI into every test of it. The media '
        'store was defined in a widget file (media_view.dart) and three core '
        'services imported it to reach their own storage (audit 2026-11-04).',
    appliesTo: [
      'lib/services/**', 'lib/connections/**', 'lib/profile/**',
      'lib/platform/**', 'lib/util/**', 'lib/models/**',
    ],
    exempt: [
      'lib/profile/*_page.dart', 'lib/profile/*avatar*.dart',
      'lib/profile/callsign_input.dart',
    ],
    pattern: r'''^\s*(?:import|export)\s+'(?:package:xprs/|(?:\.\./)+)'''
        r'''(?:wapp|launcher|ui|editor)/''',
    message: 'Move the thing the core needs down into the core, or give the '
        'core an interface the app implements (core/lib/src/platform/).',
  ),
  Rule(
    id: 'no-wapp-special-case-in-host',
    why: "The host renders whatever wapp it is given. A branch on one wapp's "
        "name (`_wappName == 'social'`) is that wapp's logic living in the "
        'host: wapp_page.dart carried about twenty for Social, including the '
        'choice of lane for a reaction (architecture.md §3, §4 "The host does '
        "not publish on a named wapp's behalf\").",
    appliesTo: ['lib/wapp/**', 'lib/launcher/**', 'lib/ui/**'],
    pattern: r'''\b(?:_?wappName|wappId|wapp\.name|entry\.name)\s*[!=]=\s*'''
        r'''['"](alerts|app-creator|archiver|atm|chat|circles|files|firmwares|forum|install|mail|maps|mediapack|mesh|movies|mp4player|social|tasks|terminal|tester|things|torrents|wallet|xprs)['"]''',
    message: 'Give every wapp the capability (a manifest flag, a HAL verb, a '
        'field type) and let this wapp use it.',
  ),
  Rule(
    id: 'no-core-calls-from-screen',
    why: "A screen renders state and forwards the person's intent; it does "
        'not choose lanes, publish, fetch, follow or judge reachability. '
        'wapp_page.dart published NOSTR notes, chose "Reticulum FIRST, wss '
        'best-effort" for a reaction and decided whether a message "leaves '
        'now or waits" (architecture.md §3.1). None of that can run on the '
        'server edition, which has no screen.',
    appliesTo: [
      'lib/wapp/wapp_page.dart', 'lib/wapp/geoui/**', 'lib/launcher/**',
      'lib/ui/**',
    ],
    window: 2,
    pattern: r'''\b(?:RnsService|MeshService|MeshCourier|XprsPublisher|'''
        r'''XprsSend|XprsArchive|XprsCatchup|XprsFetch|MediaFetch)'''
        r'''\.instance\s*\.\s*(?:publish\w*|relay\w*|reachable\w*|fetch\w*|'''
        r'''send\w*|setPassive|disconnect\w*|connect\w*|follow\w*|'''
        r'''unfollow\w*|deposit\w*|air\w*|request\w*|announce\w*|'''
        r'''buildSigned\w*)\b''',
    message: 'Send the intent to the wapp engine / a HAL verb; the core '
        'service decides how.',
  ),

  // ── the HAL surface ───────────────────────────────────────────────────────
  Rule(
    id: 'hal-budget',
    why: 'Every hal_* verb widens the wapp/core contract forever. If a wapp '
        'needs one to make a TRANSPORT decision, the logic is on the wrong '
        'side of the line — that is exactly how hal_lxmf_pending was born.',
    appliesTo: ['lib/wapp/functionality_registry.dart'],
    // The distinction is DECIDING vs LOOKING UP. "Is there a path", "how many
    // are pending", "should this be carried" are the core's calls to make.
    // Naming things — who is reachable, which relays exist, where an address
    // points — is a directory lookup, and a wapp is allowed to ask: hal_relay_
    // reachable was reviewed under this rule and kept, because the chat wapp
    // uses it to TELL peers where its DM backups live, not to steer delivery.
    // Widened 2026-11-04: Circles and Mail had grown their own delivery on
    // verbs this pattern never named (rns_send_to, rns_pull, rv_*, relay_*),
    // and Files schedules reachability discovery (lan_scan). The
    // hal_relay_reachable exemption above was granted for a use that no
    // longer exists; only the deprecated Mail called it.
    pattern: r"EndpointDef\('hal_\w*(has_path|_pending|_custody|_forward|"
        r"should_send|carrier|relay_decide|rns_send_to|rns_pull|"
        r"rns_broadcast|_rv_|rns_delivery_dest|rns_prop_dest|relay_for|"
        r"relay_dm_|relay_resolve|relay_reachable|lan_scan)\w*'",
    message: 'Read-only diagnostics are fine but must be documented as such; '
        'a wapp must not steer delivery.',
  ),

  // ── cost (docs/performance.md) ────────────────────────────────────────────
  // These are not style. Each one is a shape that has already put a phone into
  // swap or an isolate at 100%, and each one READS as free at the call site,
  // which is why review does not catch it.
  Rule(
    id: 'no-page-fetch-to-count',
    why: 'Counting by materialising rows. query()/select() build an object per '
        'row -- here, a Map of thirteen entries including the whole wire -- so '
        'asking one for .length allocates the page to throw it away. On a poll '
        'that is megabytes a minute on the main isolate, on the device with '
        'the biggest store. Use a COUNT (XprsArchive.countOf) '
        '(docs/performance.md 4.2, 8.7).',
    appliesTo: ['lib/**'],
    pattern: r'\.(query|select)\([^;]*\)\s*\.(length|isEmpty|isNotEmpty)\b',
    message: 'Ask the database for the number, not for the rows.',
  ),
  Rule(
    id: 'no-whole-file-read',
    why: 'readAsBytes() puts the ENTIRE file on the heap. Correct for a '
        'thumbnail, wrong for anything a user picked or anything we ship: an '
        'app update is 47-61 MB and the station serving it usually has the '
        'least RAM. This exact call was found in four places on the file-'
        'transfer path -- serving a window, verifying a digest, completing an '
        'inbound transfer, and checking a downloaded APK -- each correct for '
        'the photo it was written for. Stream it: openSync + readSync in 64 '
        'KiB chunks, or rename the file instead of copying it through memory '
        '(docs/performance.md 8.9).',
    appliesTo: ['lib/**'],
    // The size that is fine for the median case is not a design. If the biggest
    // legitimate input is "a file somebody chose", it has to stream.
    exempt: [
      'lib/platform/io_stub.dart',
    ],
    pattern: r'\.readAsBytes(Sync)?\(\s*\)',
    message: 'Stream it in chunks, or move the file instead of reading it.',
  ),
  Rule(
    id: 'no-sub-minute-poll',
    why: 'A poll interval is a battery setting, not a freshness setting: the '
        'phone spends its life with the screen off and nobody reading. A '
        'sub-minute Timer.periodic runs 1,440+ times a day for a result no one '
        'is awake to see. Justify it as cost-per-hour-screen-off, and fire '
        'once immediately then settle (docs/performance.md 6.5, 8.5).',
    appliesTo: ['lib/**'],
    // Across 3 lines: `Timer.periodic(\n  const Duration(seconds: 5),` is
    // the formatter's own output and slipped past the one-line version.
    window: 3,
    pattern: r'Timer\.periodic\(\s*(?:const\s+)?Duration\('
        r'\s*(?:milliseconds|seconds)\s*:',
    message: 'If it must be this fast, say what it costs per hour with the '
        'screen off, and gate it on something being awake to read it.',
  ),
  Rule(
    id: 'no-sub-minute-interval-constant',
    why: 'The same battery rule as no-sub-minute-poll, for an interval kept '
        'in a named constant and handed to Timer.periodic elsewhere. The '
        'Circles rendezvous re-announced every 8 s (signing three announces '
        'per tick) through `_rvReannounceEvery`, invisible to the call-site '
        'rule (docs/performance.md 6.5, audit 2026-11-04). Core layers only: '
        'a launcher animation that runs while its widget is on screen is not '
        'a poll.',
    appliesTo: ['lib/services/**', 'lib/connections/**', 'lib/profile/**'],
    pattern: r'''\b(?:static\s+)?(?:const|final)\s+(?:Duration\s+)?_?\w*'''
        r'''(?:[Ee]very|[Ii]nterval|[Tt]ick|[Pp]oll|[Pp]eriod|[Cc]adence)\w*'''
        r'''\s*=\s*(?:const\s+)?Duration\(\s*(?:milliseconds\s*:\s*\d+|'''
        r'''seconds\s*:\s*[1-5]?\d)\s*\)''',
    message: 'Ride the native heartbeat (BackgroundService), fire once then '
        'settle, or justify the cost per hour with the screen off.',
  ),
  Rule(
    id: 'no-content-in-log',
    why: "The log ring is served by /api/log. A message's words in it are a "
        'privacy leak, and a line per message is the per-event logging that '
        'fills the ring with itself (docs/performance.md 8.10).',
    appliesTo: ['lib/**'],
    window: 2,
    pattern: r'''(?:LogService\.(?:instance\.)?add|debugPrint|\b_?log)\([^;]*'''
        r'''(?:contentString|\.content\b)''',
    message: 'Count it in a perf: line; never log what a person wrote.',
  ),
  Rule(
    id: 'no-store-work-in-ui-layer',
    why: 'sqlite is pure CPU with no plugin behind it, so it belongs to a '
        'service or a worker, never to a widget or a wapp-engine tick. On the '
        'UI isolate it is a dropped frame; on a tick it is a dropped frame '
        'every tick (docs/performance.md 8.1).',
    appliesTo: ['lib/ui/**', 'lib/launcher/**', 'lib/wapp/**'],
    // A module whose NAME says it owns a store is where the statements
    // belong, wherever it happens to sit in the tree. The rule is about a
    // widget reaching for sqlite, not about a directory.
    exempt: [
      'lib/**/*_db.dart',
      'lib/**/*_store.dart',
      'lib/**/*_archive.dart',
    ],
    pattern: r'\.(select|execute)\(\s*[\x27"]\s*(SELECT|INSERT|UPDATE|DELETE)',
    message: 'Move the statement behind a service that owns the store.',
  ),
  Rule(
    id: 'no-scan-for-one-row',
    why: 'Fetching a whole recent() page and looping it to find one row by '
        'key is a 300-row table scan through Dart maps, per lookup, on the UI '
        'isolate. The archives keep a unique index for exactly this: use '
        'byMid() (or add the keyed lookup to the owner). Found twice in '
        'wapp_page.dart before this rule existed (docs/performance.md 4.2).',
    appliesTo: ['lib/**'],
    exempt: [
      'lib/**/*_db.dart',
      'lib/**/*_store.dart',
      'lib/**/*_archive.dart',
    ],
    pattern: r'\bin\s+\w+[?!]?\.recent\(',
    message: 'Looping recent() to find a key -- ask the store with byMid() '
        'or a keyed lookup instead.',
  ),
  Rule(
    id: 'no-unbounded-select',
    why: 'A SELECT with no LIMIT returns however many rows the biggest '
        'device has accumulated, materialised as Dart maps on whatever '
        'isolate ran it. The store owner may page deliberately; anyone else '
        'gets a bound or a COUNT. (Single-line literals only -- a multi-line '
        'query lives in a store owner, where this rule does not look.)',
    appliesTo: ['lib/**'],
    exempt: [
      'lib/**/*_db.dart',
      'lib/**/*_store.dart',
      'lib/**/*_archive.dart',
    ],
    pattern: r'\.select\(\s*[\x27"]\s*SELECT\b(?:(?!LIMIT)[^\x27"])*[\x27"]',
    message: 'Bound it: LIMIT, a COUNT, or a keyed lookup behind the owner.',
  ),
  // ── languages ─────────────────────────────────────────────────────────────
  Rule(
    id: 'no-raw-ui-string',
    why: 'The core reads its words from assets/lang/<code>/<area>.json '
        'through tr() (docs/plan-i18n-core.md). An English sentence typed '
        'straight into a Text(), a label or a tooltip in a converted screen '
        'is a word four languages never see, and nothing else notices. '
        'Directories join this list as their phase lands; a screen not yet '
        'converted is not here, so the rule never fails on old text.',
    appliesTo: [
      'lib/launcher/**',
      'lib/profile/welcome_page.dart',
      'lib/profile/unlock_page.dart',
      'lib/profile/vanity_callsign_page.dart',
      'lib/profile/profile_edit_page.dart',
      'lib/editor/wapp_editor.dart',
      'lib/wapp/wapp_page.dart',
      'lib/wapp/wapp_maps.dart',
      'lib/wapp/file_folder_picker.dart',
      'lib/wapp/wapp_graph.dart',
      'lib/wapp/geoui/**',
      'lib/wapp/native/**',
      'lib/wapp/coin/**',
    ],
    // A capitalised word followed by a space inside a quoted Text() or one
    // of the common text slots: a sentence, not an identifier or a callsign.
    // Single words (Text('OK')) and anything built from a variable pass.
    pattern: r'''(?:\bText\(\s*|\b(?:labelText|hintText|helperText|tooltip|title|label|semanticsLabel)\s*:\s*(?:const\s+)?(?:Text\(\s*)?)['"][A-Z][a-z]+[ ,.!?:;][^'"]*['"]''',
    message: 'Move the sentence to assets/lang/en/<area>.json and read it '
        'with tr(\'<area>.<subject>\'); dart tool/i18n_check.dart verifies '
        'the key.',
  ),
  webBuildRule,
];

/// Rules also checked in the reticulum-dart sibling (scanned with its own
/// lib/ as the root, so the same globs apply). The app cannot build for web
/// unless the library does.
const siblingRules = <Rule>[
  webBuildRule,
];

const wappRules = <Rule>[
  Rule(
    id: 'no-transport-logic-in-wapps-repo',
    why: 'A wapp must not reimplement delivery: retries, custody, best-hope '
        'airing and reachability guessing are core concerns (MeshCourier). '
        'This exact code lived in apps/chat/main.c and had to be removed.',
    appliesTo: ['*/main.c', '*/*.c'],
    // The same logic came back under new names in Circles and Mail
    // (deliver_to_members / pull_from_members, relay polling): the verbs
    // that let a wapp address, pull or pick relays are matched too.
    pattern: r'\b(best_hope|bh_arm|bh_pump|store_and_forward|custody_|'
        r'hal_lxmf_pending|hal_rns_has_path|hal_rns_send_to|hal_rns_pull|'
        r'hal_rns_rv_\w+|hal_relay_(?:for|reachable|dm_send|dm_fetch|resolve)|'
        r'hal_lan_scan|deliver_to_members|pull_from_members)\w*\s*\(',
  ),
];

const baselinePath = 'tool/arch_baseline.txt';

void main(List<String> args) {
  final list = args.contains('--list');
  final rewrite = args.contains('--baseline');

  final root = Directory.current;
  final found = <String>[];
  final detail = <String, String>{};

  // [dir] is scanned; [rel] is what the globs match against — for this repo
  // that is the path as written in the rules ("lib/ui/x.dart"), for the sibling
  // wapps repo it is the path inside that repo ("chat/main.c").
  //
  // [globAs], when set, is put in front of [rel] for glob matching only: the
  // core sibling mirrors the app's lib/ under lib/src/, so its files are
  // matched as "lib/services/x.dart" and the app's rules apply unchanged,
  // while the reported path stays the real one.
  void scan(Directory dir, List<Rule> rs, String prefix,
      {bool inner = false, String? globAs}) {
    if (!dir.existsSync()) return;
    final base = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      var rel = f.path;
      if (inner) {
        rel = rel.startsWith(base) ? rel.substring(base.length) : rel;
      } else if (rel.startsWith('${root.path}/')) {
        rel = rel.substring(root.path.length + 1);
      } else if (rel.startsWith('./')) {
        rel = rel.substring(2);
      }
      if (rel.contains('/.') || rel.startsWith('.')) continue;
      if (!(rel.endsWith('.dart') || rel.endsWith('.c'))) continue;
      List<String> lines;
      try {
        lines = f.readAsLinesSync();
      } catch (_) {
        continue;
      }
      final globRel = globAs == null ? rel : '$globAs$rel';
      for (final r in rs) {
        if (!_matchesAny(globRel, r.appliesTo)) continue;
        if (_matchesAny(globRel, r.exempt)) continue;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//') ||
              line.trimLeft().startsWith('*') ||
              line.trimLeft().startsWith('/*')) {
            continue; // a rule name inside prose is not a violation
          }
          if (r.window <= 1) {
            if (!_re(r.pattern).hasMatch(line)) continue;
          } else {
            final end = (i + r.window) < lines.length ? i + r.window : lines.length;
            final joined = lines.sublist(i, end).join(' ');
            final m = _re(r.pattern).firstMatch(joined);
            if (m == null || m.start >= line.length) continue;
          }
          if (_ignored(lines, i, r.id)) continue;
          // Keyed on the offending LINE, not on file+rule: a baseline that
          // forgives a whole file also forgives the next violation added to
          // it, which is how a guard quietly stops guarding. Not keyed on the
          // line NUMBER either — those churn with every edit above them.
          var code = line.trim();
          if (code.length > 120) code = '${code.substring(0, 117)}...';
          final key = '$prefix$rel :: ${r.id} :: $code';
          found.add(key);
          detail[key] = '$prefix$rel:${i + 1}  $code';
        }
      }
    }
  }

  scan(Directory('lib'), rules, '');
  scan(Directory('tool'), rules, '');
  final sibling = Directory('../reticulum-dart');
  if (sibling.existsSync()) {
    scan(sibling, siblingRules, '../reticulum-dart/', inner: true);
  }
  // The shared core (xprs-dev/core) is code that moved out of lib/: it keeps
  // every app rule, not just the web-build one.
  final core = Directory('../core/lib/src');
  if (core.existsSync()) {
    scan(core, rules, '../core/lib/src/', inner: true, globAs: 'lib/');
  }
  final wapps = Directory('../apps');
  if (wapps.existsSync()) scan(wapps, wappRules, '../apps/', inner: true);

  final uniq = found.toSet().toList()..sort();

  if (rewrite) {
    File(baselinePath).writeAsStringSync(
        '# Architecture-guard baseline — violations that predate the guard.\n'
        '# NEW violations fail the build; these do not. Shrink this file.\n'
        '# Regenerate deliberately: dart tool/arch_guard.dart --baseline\n'
        '${uniq.join('\n')}\n');
    stdout.writeln('baseline: ${uniq.length} entries -> $baselinePath');
    return;
  }

  final baseline = File(baselinePath).existsSync()
      ? File(baselinePath)
          .readAsLinesSync()
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toSet()
      : <String>{};

  final fresh = uniq.where((k) => !baseline.contains(k)).toList();
  final byId = <String, Rule>{
    for (final r in [...rules, ...siblingRules, ...wappRules]) r.id: r,
  };

  if (list) {
    stdout.writeln('all violations (${uniq.length}, '
        '${baseline.length} baselined):');
    for (final k in uniq) {
      stdout.writeln('  ${baseline.contains(k) ? "base" : "NEW "} '
          '${detail[k] ?? k}');
    }
  }

  if (fresh.isEmpty) {
    stdout.writeln('arch_guard: clean '
        '(${uniq.length} known, ${baseline.length} baselined)');
    return;
  }

  stderr.writeln('\narch_guard: ${fresh.length} NEW violation'
      '${fresh.length == 1 ? "" : "s"} of docs/architecture.md\n');
  final seen = <String>{};
  for (final k in fresh) {
    final id = k.split(' :: ').length > 1 ? k.split(' :: ')[1] : k;
    stderr.writeln('  ${detail[k] ?? k}');
    if (seen.add(id)) {
      final r = byId[id];
      if (r != null) {
        stderr.writeln('      rule: $id');
        stderr.writeln('      why:  ${r.why}');
        if (r.message != null) stderr.writeln('      fix:  ${r.message}');
      }
    }
    stderr.writeln('');
  }
  stderr.writeln('If this is genuinely right, annotate the line:');
  stderr.writeln('    // arch-ignore: <rule-id> <the reason>');
  stderr.writeln('or re-baseline deliberately and say why in the commit '
      'message:');
  stderr.writeln('    dart tool/arch_guard.dart --baseline');
  exit(1);
}

final _reCache = <String, RegExp>{};
RegExp _re(String p) => _reCache.putIfAbsent(p, () => RegExp(p));

/// `// arch-ignore: <rule> <reason>` on the line or the one above it.
bool _ignored(List<String> lines, int i, String id) {
  bool hit(String s) =>
      s.contains('arch-ignore:') &&
      s.contains(id) &&
      s.trim().length > 'arch-ignore:'.length + id.length + 8; // needs a reason
  if (hit(lines[i])) return true;
  if (i > 0 && hit(lines[i - 1])) return true;
  return false;
}

bool _matchesAny(String path, List<String> globs) {
  for (final g in globs) {
    final re = RegExp('^${RegExp.escape(g).replaceAll(r'\*\*', '.*').replaceAll(r'\*', '[^/]*')}\$');
    if (re.hasMatch(path)) return true;
  }
  return false;
}
