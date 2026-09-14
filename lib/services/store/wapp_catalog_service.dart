/// Fetching a wapp catalog over HTTP and keeping it: the core's side of the
/// Wapp Store. The store wapp names a source (https://xprs.dev/apps by
/// default); this service resolves it to a catalog document, caches it
/// under the support directory, and refreshes it when it is older than an
/// hour. A failed fetch keeps the previous copy, so a phone without
/// internet still lists what it knew (the same discipline as the firmware
/// catalogue in flash_catalog_io.dart). Icons are fetched once per app
/// version and kept beside the catalog.
///
/// The wapp never sees a byte of this: it receives the six-field index it
/// always parsed, and the host keeps the URL, size and sha256 of every
/// package to download and check it on install.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../connections/internet/http_transport.dart';
import 'wapp_catalog.dart';
import 'wapp_catalog_cache.dart';

class WappCatalogService {
  WappCatalogService._();
  static final instance = WappCatalogService._();

  /// The canonical catalog. A store with no configured source reads this.
  static const defaultSource = 'https://xprs.dev/apps';

  static const staleAfter = Duration(hours: 1);
  static const fetchTimeout = Duration(seconds: 20);
  static const iconCap = 256 * 1024;

  final _cache = CatalogCache();
  final _docs = <String, CatalogDoc>{};
  final _fetchedAt = <String, DateTime>{};
  final _icons = <String, Uint8List>{};
  String lastError = '';

  /// True when [source] is an HTTP(S) URL this service serves.
  static bool isHttpSource(String source) {
    final s = source.trim().toLowerCase();
    return s.startsWith('http://') || s.startsWith('https://');
  }

  /// The catalog URL and its directory for [source]: a URL ending in
  /// `.json` is the document itself, anything else is a directory that
  /// holds `catalog.json` (or, for an older store, `index.json`).
  static List<String> candidateUrls(String source) {
    var s = source.trim();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    if (s.toLowerCase().endsWith('.json')) return [s];
    return ['$s/catalog.json', '$s/index.json'];
  }

  static String _dirOf(String url) =>
      url.substring(0, url.lastIndexOf('/') + 1);

  static String _key(String source) {
    var k = source.trim().toLowerCase();
    k = k.replaceAll(RegExp(r'^https?://'), '');
    k = k.replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
    if (k.length > 96) k = k.substring(0, 96);
    return k;
  }

  /// The catalog for [source]: the cached copy when fresh, else a fetch,
  /// else the cached copy however old, else null with [lastError] set.
  Future<CatalogDoc?> fetch(String source, {bool force = false}) async {
    final key = _key(source);
    var doc = _docs[key];
    var at = _fetchedAt[key];
    if (doc == null) {
      final cached = await _cache.read('$key.json');
      final mod = await _cache.modified('$key.json');
      if (cached != null && cached.isNotEmpty) {
        try {
          final url = utf8.decode(await _cache.read('$key.url') ?? const []);
          doc = parseCatalog(utf8.decode(cached),
              sourceBase: url.isEmpty ? source : _dirOf(url));
          at = mod;
          _docs[key] = doc;
          if (at != null) _fetchedAt[key] = at;
        } catch (_) {}
      }
    }
    final fresh = doc != null &&
        at != null &&
        DateTime.now().difference(at) < staleAfter;
    if (fresh && !force) return doc;

    for (final url in candidateUrls(source)) {
      try {
        final res = await HttpTransport.shared.get(Uri.parse(url),
            timeout: fetchTimeout);
        if (!res.isOk) {
          lastError = 'HTTP ${res.statusCode} for $url';
          continue;
        }
        final text = utf8.decode(res.bodyBytes);
        final parsed = parseCatalog(text, sourceBase: _dirOf(url));
        _docs[key] = parsed;
        _fetchedAt[key] = DateTime.now();
        lastError = '';
        unawaited(_cache.write('$key.json', res.bodyBytes));
        unawaited(_cache.write('$key.url', utf8.encode(url)));
        return parsed;
      } on FormatException catch (e) {
        lastError = '$url is not a catalog: ${e.message}';
      } catch (e) {
        lastError = 'could not reach $url: $e';
      }
    }
    return doc;
  }

  /// The icon SVG of [app], fetched once per version and kept. Null when
  /// the catalog names none or it could not be fetched; the caller then
  /// falls back to whatever icon it has.
  Future<Uint8List?> icon(CatalogApp app) async {
    if (app.iconUrl.isEmpty) return null;
    final key = 'icons/${_key(app.name)}-${_key(app.version)}.svg';
    final mem = _icons[key];
    if (mem != null) return mem;
    final disk = await _cache.read(key);
    if (disk != null && disk.isNotEmpty) {
      _icons[key] = disk;
      return disk;
    }
    try {
      final res = await HttpTransport.shared.get(Uri.parse(app.iconUrl),
          timeout: const Duration(seconds: 10));
      if (!res.isOk || res.bodyBytes.isEmpty || res.bodyBytes.length > iconCap) {
        return null;
      }
      _icons[key] = res.bodyBytes;
      unawaited(_cache.write(key, res.bodyBytes));
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
