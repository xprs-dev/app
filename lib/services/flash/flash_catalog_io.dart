/// The catalogue's files: boards.json fetched and kept, a board's parts
/// downloaded under the support directory with their sha256 recorded, so a
/// later flash writes exactly what was checked. The native half of
/// flash_catalog.dart (dart:io, dart:isolate), reached only from
/// flash_service_io.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'esp_image.dart';
import 'flash_catalog.dart';

/// sha256 of a file in 64 KiB chunks. Top-level so it can run in Isolate.run.
Future<String> flashSha256OfFile(String path) async {
  final sink = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  final raf = await File(path).open();
  try {
    while (true) {
      final chunk = await raf.read(1 << 16);
      if (chunk.isEmpty) break;
      input.add(chunk);
    }
  } finally {
    await raf.close();
  }
  input.close();
  return sink.value.toString();
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class FlashCatalog {
  static const site = 'https://xprs.dev/firmware';
  static const boardsUrl = '$site/docs/boards.json';
  static const staleAfter = Duration(hours: 1);

  final String? _dirOverride;
  FlashCatalog({String? dir}) : _dirOverride = dir;

  List<FlashBoard> boards = const [];
  DateTime? fetchedAt;
  String lastError = '';

  String? _dir;

  Future<String> dir() async {
    if (_dir != null) return _dir!;
    final base = _dirOverride ?? '${(await getApplicationSupportDirectory()).path}/flash';
    await Directory(base).create(recursive: true);
    return _dir = base;
  }

  /// The cached boards.json, if any. Cheap; called at first use.
  Future<void> load() async {
    if (boards.isNotEmpty) return;
    try {
      final f = File('${await dir()}/boards.json');
      if (!await f.exists()) return;
      boards = parseBoards(await f.readAsString(), site: site);
      fetchedAt = (await f.stat()).modified;
    } catch (e) {
      lastError = 'catalogue unreadable: $e';
    }
  }

  bool get stale =>
      fetchedAt == null || DateTime.now().difference(fetchedAt!) > staleAfter;

  /// Fetch boards.json when stale (or [force]). The old copy stays when the
  /// fetch fails, so a phone without internet still lists what it knew.
  Future<bool> refresh({bool force = false}) async {
    await load();
    if (!force && !stale && boards.isNotEmpty) return true;
    final path = '${await dir()}/boards.json';
    final tmp = '$path.part';
    final ok = await _download(boardsUrl, tmp, null);
    if (!ok) {
      lastError = 'could not reach $boardsUrl';
      return false;
    }
    try {
      final parsed = parseBoards(await File(tmp).readAsString(), site: site);
      if (parsed.isEmpty) {
        lastError = 'boards.json held no boards';
        return false;
      }
      await File(tmp).rename(path);
      boards = parsed;
      fetchedAt = DateTime.now();
      lastError = '';
      return true;
    } catch (e) {
      lastError = 'boards.json unreadable: $e';
      return false;
    }
  }

  FlashBoard? board(String id) {
    for (final b in boards) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// The checked local copy of [id]'s parts, or null when not (fully) here.
  Future<FlashLocal?> local(String id) async {
    try {
      final f = File('${await dir()}/$id/local.json');
      if (!await f.exists()) return null;
      final l = FlashLocal.fromJson(
          (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
      if (l == null) return null;
      for (final p in l.parts) {
        final pf = File(p.path);
        if (!await pf.exists() || await pf.length() != p.size) return null;
      }
      return l;
    } catch (_) {
      return null;
    }
  }

  /// Fetch [id]'s manifest and parts, check each and record them. Progress
  /// is bytes over the whole set once the manifest is in.
  Future<FlashLocal> fetch(String id, void Function(int done, int total) onProgress) async {
    final b = board(id);
    if (b == null) throw StateError('unknown board $id');
    final base = b.manifestUrl.substring(0, b.manifestUrl.lastIndexOf('/'));
    final bdir = '${await dir()}/$id';
    await Directory(bdir).create(recursive: true);
    final mpath = '$bdir/manifest.json';
    if (!await _download(b.manifestUrl, mpath, null)) {
      throw StateError('could not fetch the manifest for ${b.name}');
    }
    final m = parseManifest(await File(mpath).readAsString(), baseUrl: base);
    if (m == null) throw StateError('the manifest for ${b.name} is not one this app reads');
    final want = EspFamily.fromWebTools(b.family);
    if (m.family.isNotEmpty && want != null && m.family != want) {
      throw StateError('the manifest is for ${EspFamily.label(m.family)}, the board is ${EspFamily.label(want)}');
    }
    final vdir = '$bdir/${m.version.isEmpty ? 'latest' : m.version}';
    await Directory(vdir).create(recursive: true);
    // Sizes are not in the manifest: count parts as equal until each one's
    // Content-Length arrives, then bytes.
    final sizes = List<int>.filled(m.parts.length, 0);
    final got = List<int>.filled(m.parts.length, 0);
    void report() {
      final total = sizes.fold(0, (a, x) => a + x);
      onProgress(got.fold(0, (a, x) => a + x), total);
    }

    final parts = <FlashLocalPart>[];
    for (var i = 0; i < m.parts.length; i++) {
      final p = m.parts[i];
      final path = '$vdir/${p.name}';
      final ok = await _download(p.url, '$path.part', (d, t) {
        got[i] = d;
        if (t > 0) sizes[i] = t;
        report();
      });
      if (!ok) throw StateError('could not fetch ${p.name}');
      await File('$path.part').rename(path);
      final size = await File(path).length();
      final sha = await Isolate.run(() => flashSha256OfFile(path));
      if (p.offset >= 0x10000 || p.name.startsWith('firmware')) {
        // The app image: its header must name the board's chip.
        final head = await _head(path, 24);
        final fam = espImageFamily(head);
        if (fam == null) throw StateError('${p.name} is not an ESP-IDF image');
        if (want != null && fam != want) {
          throw StateError('${p.name} is built for ${EspFamily.label(fam)}, not ${EspFamily.label(want)}');
        }
      }
      parts.add(FlashLocalPart(p.name, p.offset, path, size, sha));
      sizes[i] = size;
      got[i] = size;
      report();
    }
    final local = FlashLocal(id, m.version, m.family.isEmpty ? (want ?? '') : m.family,
        m.promptErase, parts);
    await File('$bdir/local.json').writeAsString(jsonEncode(local.toJson()));
    return local;
  }

  static Future<Uint8List> _head(String path, int n) async {
    final raf = await File(path).open();
    try {
      return await raf.read(n);
    } finally {
      await raf.close();
    }
  }

  /// Streamed GET to [dest]; false on any failure (the file is removed).
  static Future<bool> _download(
      String url, String dest, void Function(int, int)? onProgress) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'xprs-flasher';
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      // Content-Length counts the bytes on the wire. GitHub Pages gzips
      // boards.json, and package:http hands the decoded stream over, so the
      // length is only a truncation check when nothing was encoded.
      final encoded = (resp.headers['content-encoding'] ?? '').isNotEmpty;
      final total = encoded ? 0 : (resp.contentLength ?? 0);
      final f = File(dest);
      sink = f.openWrite();
      var got = 0;
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && got != total) {
        await f.delete();
        return false;
      }
      return true;
    } catch (_) {
      try {
        await sink?.close();
        await File(dest).delete();
      } catch (_) {}
      return false;
    } finally {
      client.close();
    }
  }
}
