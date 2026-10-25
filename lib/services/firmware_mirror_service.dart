// =============================================================================
// firmware_mirror_service.dart — every XPRS app keeps the released station
// firmware and offers it on the mesh, so a station on a roof updates itself
// from whatever app is near it and never from the internet.
//
// The chain (firmware/docs/plan-firmware-folders.md): a release puts the
// images on GitHub and, through the maintainer's app, publishes them as a
// folder the format can find -- an XFL1 listing and one signed `t:file`
// description per image (XPRS.md 7.7.3), signed by the project's firmware
// publisher key, written beside the images into docs/firmware.json. This
// service, on EVERY app:
//
//   1. reads that document over HTTPS (the one place the web is used);
//   2. believes a description only when it verifies against the publisher's
//      key, and a member only when a verified description names its digest
//      and size;
//   3. downloads each image it does not hold yet, verifies the digest, and
//      keeps the newest set (about 1.5 MB a board) under the support
//      directory;
//   4. serves them by digest over Reticulum (the same `xprs/files` lane the
//      owner folders use) and Bluetooth (`cmd:file`), so a station's
//      GET_FILE lands on bytes;
//   5. re-airs the publisher's signed descriptions verbatim on the local
//      bearers and deposits them with this station's archivers (12.9.1:
//      a signed original may be relayed by anyone), so the archivers near
//      every station hold the answer to `cmd:history kind:file only:<publisher>`.
//
// It signs nothing: the trust is the publisher's signature on each
// description, carried unchanged. It needs nobody to do anything: on by
// default, six-hourly, a few megabytes once per release.
//
// Pure where it can be: FirmwareFeed.parse is a function of the document and
// the key; the service's fetch, download, hold, air and deposit are injected,
// so the whole tick runs under test with no network.
// =============================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file/file.dart' show Directory;
import 'package:hex/hex.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../platform/fs.dart';
import 'background_service.dart';
import 'flash/flash_catalog_io.dart' show flashSha256OfFile;
import 'folders/disk_folder.dart' show DiskFolderSource;
import 'log_service.dart';
import 'preferences_service.dart';
import 'reticulum/rns_service.dart';
import 'xprs/xprs_files.dart';
import 'xprs/xprs_folder.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_publisher.dart';
import 'xprs/xprs_sig.dart';

/// The project's firmware publisher: the maintainer's identity key, x-only,
/// the same value the station firmware pins as `fwkey`
/// (firmware/common/xprs_ota/fw_publisher.h). A description of an image
/// that does not verify against it is not firmware, whatever site served it.
const String kXprsFirmwarePublisherKey =
    '7756ba1e8d04b9eea1bd7e8be8e573b93add4cbfd388abe7bb1bf6673e7b47e9';

/// One image of a channel, as the document and a verified description agree.
class FirmwareMember {
  const FirmwareMember(
      {required this.name,
      required this.shaHex,
      required this.size,
      required this.url,
      required this.wire});
  final String name; // <board>-<version>.bin
  final String shaHex;
  final int size;
  final String url;
  /// The publisher's signed `t:file` naming this member, verbatim.
  final String wire;
}

class FirmwareChannel {
  const FirmwareChannel(
      {required this.name, required this.wires, required this.members});
  final String name; // stable | beta
  /// Every wire of the channel that verified: the folder and its members.
  final List<String> wires;
  final List<FirmwareMember> members;
}

/// docs/firmware.json read with the publisher's key in hand.
class FirmwareFeed {
  const FirmwareFeed(this.channels, {this.dropped = 0});
  final List<FirmwareChannel> channels;
  /// Wires or members the document offered and this reader refused.
  final int dropped;

  /// A document to channels. Nothing is believed on the document's say-so:
  /// a wire is kept when it is a `t:file` that verifies against
  /// [publisherPub]; a member when a kept wire names its digest and size.
  static FirmwareFeed parse(Map<String, dynamic> doc, Uint8List publisherPub) {
    final out = <FirmwareChannel>[];
    var dropped = 0;
    for (final e in doc.entries) {
      final v = e.value;
      if (v is! Map || v['wires'] is! List) continue;
      final kept = <String>[];
      final bySha = <String, XprsPacket>{};
      for (final w in v['wires'] as List) {
        final p = w is String ? XprsPacket.parse(w) : null;
        if (p == null ||
            p.type != 'file' ||
            xprsVerify(p, publisherPub) != XprsSigState.verified) {
          dropped++;
          continue;
        }
        kept.add(w as String);
        final sha = xprsFileShaOf(p['file'] ?? '');
        if (sha != null && p['kind'] != 'folder') bySha[sha] = p;
      }
      final members = <FirmwareMember>[];
      for (final m in (v['members'] as List?) ?? const []) {
        if (m is! Map) continue;
        final sha = '${m['sha256'] ?? ''}'.toLowerCase();
        final size = (m['size'] as num?)?.toInt() ?? 0;
        final url = '${m['url'] ?? ''}';
        final desc = bySha[sha];
        if (desc == null ||
            xprsBytesOf(desc['size']) != size ||
            size <= 0 ||
            url.isEmpty) {
          dropped++;
          continue;
        }
        final name = desc['name'] ?? '${m['name'] ?? ''}';
        if (name.isEmpty || name.contains('/') || name.contains('..')) {
          dropped++;
          continue;
        }
        members.add(FirmwareMember(
            name: name, shaHex: sha, size: size, url: url, wire: desc.encode()));
      }
      if (kept.isNotEmpty) {
        out.add(FirmwareChannel(name: e.key, wires: kept, members: members));
      }
    }
    return FirmwareFeed(out, dropped: dropped);
  }
}

class FirmwareMirrorService extends BackgroundService {
  FirmwareMirrorService._()
      : super(
          id: 'firmware.mirror',
          name: 'Firmware mirror',
          interval: pollInterval,
          description: 'Keeps the released station firmware and offers it '
              'over Reticulum and Bluetooth, so stations update from here.',
        );
  static final FirmwareMirrorService instance = FirmwareMirrorService._();

  /// Six hours, the same reasoning as the update mirror: a release is rare,
  /// and what a tick produces is bytes a station asks for later.
  static const Duration pollInterval = Duration(hours: 6);
  static const String feedUrl = 'https://xprs.dev/firmware/docs/firmware.json';

  // ── seams ──────────────────────────────────────────────────────────────
  /// The document's text, or null when the web is out of reach.
  Future<String?> Function(String url)? fetchText;
  /// Bytes of [url] into the file at [path]; true when it completed.
  Future<bool> Function(String url, String path)? download;
  /// sha256 hex of a file.
  Future<String> Function(String path)? hashFile;
  /// Where the images live (a directory path). Default: <support>/firmware.
  Future<String> Function()? dirOf;
  /// Offer a file by digest (both lanes).
  void Function(FirmwareMember m, String path)? hold;
  /// Put a wire on the local bearers, verbatim.
  Future<void> Function(String wire)? air;
  /// Leave wires with this station's archivers.
  void Function(List<String> wires)? deposit;
  /// The key descriptions must verify against (hex, x-only).
  String publisherKeyHex = kXprsFirmwarePublisherKey;

  bool get enabled =>
      PreferencesService.instanceSync?.firmwareMirrorEnabled ?? true;

  // ── state, for /api/firmware/mirror ────────────────────────────────────
  int ticks = 0, downloaded = 0, verifiedOk = 0, refused = 0, aired = 0, failed = 0;
  String? lastError;
  DateTime? lastTick;
  final Map<String, String> held = {}; // name -> sha
  DiskFolderSource? _source;
  bool _ticking = false;

  @override
  Future<void> onTick() async {
    if (!enabled || _ticking) return;
    _ticking = true;
    try {
      await tick();
    } finally {
      _ticking = false;
    }
  }

  /// One pass: read, verify, fetch what is missing, prune, serve, re-air.
  Future<void> tick() async {
    ticks++;
    lastTick = DateTime.now();
    final text = await (fetchText ?? _fetchText)(feedUrl);
    if (text == null) {
      lastError = 'feed unreachable';
      return;
    }
    Map<String, dynamic> doc;
    try {
      doc = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      lastError = 'feed unreadable';
      return;
    }
    final feed = FirmwareFeed.parse(
        doc, Uint8List.fromList(HEX.decode(publisherKeyHex)));
    refused += feed.dropped;
    if (feed.channels.isEmpty) {
      lastError = 'nothing in the feed verified';
      return;
    }
    final dirPath = await (dirOf ?? _defaultDir)();
    final dir = fs.directory(dirPath);
    final wanted = <String, FirmwareMember>{};
    for (final c in feed.channels) {
      for (final m in c.members) {
        wanted[m.name] = m;
      }
    }
    // Fetch what is not here or not what it should be.
    for (final m in wanted.values) {
      final path = '${dir.path}/${m.name}';
      final f = fs.file(path);
      if (await f.exists() && held[m.name] == m.shaHex) continue;
      if (await f.exists() && await f.length() == m.size) {
        final sha = await (hashFile ?? _hash)(path);
        if (sha == m.shaHex) {
          held[m.name] = sha;
          continue;
        }
      }
      final tmp = '$path.part';
      final ok = await (download ?? _download)(m.url, tmp);
      if (!ok) {
        failed++;
        lastError = 'download failed: ${m.name}';
        try {
          await fs.file(tmp).delete();
        } catch (_) {}
        continue;
      }
      downloaded++;
      final sha = await (hashFile ?? _hash)(tmp);
      if (sha != m.shaHex) {
        refused++;
        lastError = 'digest mismatch: ${m.name}';
        try {
          await fs.file(tmp).delete();
        } catch (_) {}
        continue;
      }
      await fs.file(tmp).rename(path);
      held[m.name] = sha;
      verifiedOk++;
      LogService.instance.add('firmware mirror: holding ${m.name} (${m.size} B)');
    }
    // Prune what no channel names any more: one set per board, the newest.
    try {
      await for (final e in dir.list()) {
        if (e is Directory) continue;
        final n = e.uri.pathSegments.last;
        if (n.endsWith('.part') || !wanted.containsKey(n)) {
          held.remove(n);
          await e.delete();
        }
      }
    } catch (_) {}
    // Serve, on both lanes, and say so.
    final have = <FirmwareMember>[
      for (final m in wanted.values)
        if (held[m.name] == m.shaHex) m
    ];
    for (final m in have) {
      (hold ?? _hold)(m, '${dir.path}/${m.name}');
    }
    if (hold == null) await _serveDir(dir.path);
    final wires = <String>{for (final c in feed.channels) ...c.wires}.toList();
    for (final w in wires) {
      await (air ?? _air)(w);
      aired++;
    }
    (deposit ?? _deposit)(wires);
    // A download that failed this tick stays visible until a tick in which
    // nothing failed: the next tick tries it again.
    if (lastError != null && !lastError!.startsWith('download failed') &&
        !lastError!.startsWith('digest mismatch')) {
      lastError = null;
    }
  }

  Map<String, dynamic> statusJson() => {
        'enabled': enabled,
        'running': isRunning,
        'ticks': ticks,
        'lastTick': lastTick?.toIso8601String(),
        'held': held,
        'downloaded': downloaded,
        'verified': verifiedOk,
        'refused': refused,
        'aired': aired,
        'failed': failed,
        'error': lastError,
      };

  // ── device defaults ────────────────────────────────────────────────────
  static Future<String?> _fetchText(String url) async {
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      return r.statusCode == 200 ? r.body : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _download(String url, String path) async {
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) return false;
      final sink = fs.file(path).openWrite();
      await resp.stream.pipe(sink);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<String> _hash(String path) =>
      BackgroundService.runOffThread(() => flashSha256OfFile(path));

  static Future<String> _defaultDir() async {
    final base = await getApplicationSupportDirectory();
    final d = fs.directory('${base.path}/firmware');
    await d.create(recursive: true);
    return d.path;
  }

  static void _hold(FirmwareMember m, String path) {
    final dot = m.name.lastIndexOf('.');
    XprsFileServer.instance.hold(XprsHeldFile(
        path: path,
        shaHex: m.shaHex,
        size: m.size,
        name: m.name,
        ext: dot > 0 ? m.name.substring(dot + 1) : 'bin'));
  }

  Future<void> _serveDir(String dir) async {
    var s = _source;
    if (s == null) {
      s = DiskFolderSource(dir);
      _source = s;
      await s.scanAsync();
      RnsService.instance.addFileSource(s);
    } else {
      await s.scanAsync();
    }
  }

  static Future<void> _air(String w) =>
      XprsPublisher.instance.publishWire(w, verbatim: true).then((_) {});

  static void _deposit(List<String> wires) =>
      XprsPublisher.instance.depositArchivers(wires, what: 'firmware');
}
