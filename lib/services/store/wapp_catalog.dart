/// The app catalog a wapp store reads: what is published, at which version,
/// where the package is and what it should hash to. Pure Dart, no I/O, so it
/// is testable without a device and runs on the web build.
///
/// Two shapes are understood:
///
///  - `xprs.apps.catalog/1`, the object at https://xprs.dev/apps/catalog.json
///    written by build-catalog.py in the apps repository: one entry per app,
///    newest packaged version, with text per language, icon, screenshots,
///    package path, size and sha256. Paths are relative to its `base`.
///  - The older flat `index.json` list (every version ever packaged, six
///    fields). Collapsed here to the newest version per app so both shapes
///    come out as the same list.
library;

import 'dart:convert';

/// One app as the store sees it.
class CatalogApp {
  /// The folder slug and install directory name, e.g. `widget_demo`.
  final String name;
  final String id;
  final String version;
  final String kind;
  final String title;

  /// The one-liner.
  final String description;

  /// The longer text.
  final String summary;

  /// Text per language code (`en`, `pt`, ...): title, summary, body.
  final Map<String, Map<String, String>> descriptions;

  /// Absolute URL of the icon SVG, or empty.
  final String iconUrl;

  /// Absolute URLs of the screenshots.
  final List<String> screenshots;
  final List<String> tags;

  /// Absolute URL of the `.wapp` package.
  final String url;

  /// The package leaf name, e.g. `widget_demo-1.0.2.wapp`.
  final String file;
  final int size;

  /// Hex sha256 of the package, or empty when the catalog did not say.
  final String sha256;
  final String changelog;
  final String sourceUrl;

  const CatalogApp({
    required this.name,
    required this.id,
    required this.version,
    required this.kind,
    required this.title,
    required this.description,
    required this.summary,
    required this.descriptions,
    required this.iconUrl,
    required this.screenshots,
    required this.tags,
    required this.url,
    required this.file,
    required this.size,
    required this.sha256,
    required this.changelog,
    required this.sourceUrl,
  });

  /// The title in [lang], then English, then the manifest title.
  String titleFor(String lang) =>
      _text(lang, 'title', title).trim().isEmpty ? title : _text(lang, 'title', title);

  /// The one-liner in [lang], then English, then the manifest one.
  String descriptionFor(String lang) => _text(lang, 'summary', description);

  String _text(String lang, String key, String fallback) {
    final d = descriptions[lang] ?? descriptions['en'];
    final v = d?[key] ?? '';
    return v.isEmpty ? fallback : v;
  }

  /// The six-field entry the store wapp parses: `file` is
  /// `<name>/<leaf>` so the wapp derives the slug from its first segment
  /// the way it always has, and nothing else about the wire changes.
  Map<String, dynamic> toIndexEntry() => {
        'file': '$name/$file',
        'id': id,
        'version': version,
        'size': size,
        'title': title,
        'description': description,
      };
}

/// A parsed catalog: the apps and the base every URL was resolved against.
class CatalogDoc {
  final String base;
  final List<CatalogApp> apps;
  final DateTime? generated;
  const CatalogDoc(this.base, this.apps, this.generated);

  CatalogApp? app(String name) {
    for (final a in apps) {
      if (a.name == name) return a;
    }
    return null;
  }
}

/// Compare two dotted version strings numerically: positive when [a] is
/// newer than [b], zero when equal, negative when older. A non-numeric
/// suffix (`-beta.4`) is reduced to its leading integer per segment.
int catalogVersionCmp(String a, String b) {
  List<int> parts(String v) => v.split(RegExp(r'[.\-+]')).map((s) {
        final m = RegExp(r'^\d+').firstMatch(s);
        return m != null ? int.parse(m.group(0)!) : 0;
      }).toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The slug of a package leaf or id: `aprs-0.2.60.wapp` gives `aprs`.
String catalogSlug(String fileOrId) {
  var s = fileOrId.split('/').last;
  if (s.toLowerCase().endsWith('.wapp')) s = s.substring(0, s.length - 5);
  final m = RegExp(r'^(.+)-(\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z.]+)?)$').firstMatch(s);
  return m != null ? m.group(1)! : s;
}

/// Join [rel] onto [base]. An absolute URL passes through.
String catalogResolve(String base, String rel) {
  if (rel.isEmpty) return '';
  final lower = rel.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return rel;
  final b = base.endsWith('/') ? base : '$base/';
  return b + (rel.startsWith('/') ? rel.substring(1) : rel);
}

/// Parse [text] as either catalog shape. [sourceBase] is where the file was
/// fetched from (its directory), used when the document names no `base`
/// and for the flat list. Throws [FormatException] on anything else.
CatalogDoc parseCatalog(String text, {required String sourceBase}) {
  final decoded = jsonDecode(text);
  if (decoded is Map) {
    final schema = '${decoded['schema'] ?? ''}';
    final list = decoded['apps'];
    if (!schema.startsWith('xprs.apps.catalog/') || list is! List) {
      throw const FormatException('not an xprs.apps.catalog document');
    }
    final base = '${decoded['base'] ?? ''}'.isEmpty ? sourceBase : '${decoded['base']}';
    DateTime? generated;
    try {
      generated = DateTime.tryParse('${decoded['generated'] ?? ''}');
    } catch (_) {}
    final apps = <CatalogApp>[];
    for (final e in list) {
      if (e is! Map) continue;
      final a = _fromCatalogEntry(Map<String, dynamic>.from(e), base);
      if (a != null) apps.add(a);
    }
    return CatalogDoc(base, apps, generated);
  }
  if (decoded is List) {
    return CatalogDoc(sourceBase, _fromIndexList(decoded, sourceBase), null);
  }
  throw const FormatException('not a catalog');
}

CatalogApp? _fromCatalogEntry(Map<String, dynamic> e, String base) {
  final file = '${e['file'] ?? ''}';
  final version = '${e['version'] ?? ''}';
  var name = '${e['name'] ?? ''}';
  if (name.isEmpty) name = catalogSlug(file);
  if (name.isEmpty || version.isEmpty || file.isEmpty) return null;

  final descriptions = <String, Map<String, String>>{};
  final d = e['descriptions'];
  if (d is Map) {
    d.forEach((k, v) {
      if (v is Map) {
        descriptions['$k'] = {
          'title': '${v['title'] ?? ''}',
          'summary': '${v['summary'] ?? ''}',
          'body': '${v['body'] ?? ''}',
        };
      }
    });
  }
  final shots = <String>[];
  final s = e['screenshots'];
  if (s is List) {
    for (final x in s) {
      final rel = x is Map ? '${x['file'] ?? ''}' : '$x';
      if (rel.isNotEmpty) shots.add(catalogResolve(base, rel));
    }
  }
  final tags = <String>[];
  final t = e['tags'];
  if (t is List) tags.addAll(t.map((x) => '$x'));

  return CatalogApp(
    name: name,
    id: '${e['id'] ?? name}',
    version: version,
    kind: '${e['kind'] ?? 'app'}',
    title: '${e['title'] ?? name}',
    description: '${e['description'] ?? ''}',
    summary: '${e['summary'] ?? ''}',
    descriptions: descriptions,
    iconUrl: catalogResolve(base, '${e['icon'] ?? ''}'),
    screenshots: shots,
    tags: tags,
    url: catalogResolve(base, file),
    file: file.split('/').last,
    size: (e['size'] is num) ? (e['size'] as num).toInt() : 0,
    sha256: '${e['sha256'] ?? ''}'.toLowerCase(),
    changelog: '${e['changelog'] ?? ''}',
    sourceUrl: '${e['source_url'] ?? ''}',
  );
}

/// The flat list, newest version per slug.
List<CatalogApp> _fromIndexList(List list, String base) {
  final newest = <String, CatalogApp>{};
  for (final e in list) {
    if (e is! Map) continue;
    final file = '${e['file'] ?? ''}';
    final version = '${e['version'] ?? ''}';
    if (file.isEmpty || version.isEmpty) continue;
    final name = file.contains('/') ? file.split('/').first : catalogSlug(file);
    var title = '${e['title'] ?? ''}';
    var description = '${e['description'] ?? ''}';
    // Pre-title indexes put the launcher label in `description`.
    if (title.isEmpty && description.isNotEmpty) {
      title = description;
      description = '';
    }
    final app = CatalogApp(
      name: name,
      id: '${e['id'] ?? name}',
      version: version,
      kind: 'app',
      title: title.isEmpty ? name : title,
      description: description,
      summary: '',
      descriptions: const {},
      iconUrl: '',
      screenshots: const [],
      tags: const [],
      url: catalogResolve(base, file),
      file: file.split('/').last,
      size: (e['size'] is num) ? (e['size'] as num).toInt() : 0,
      sha256: '${e['sha256'] ?? ''}'.toLowerCase(),
      changelog: '',
      sourceUrl: '',
    );
    final have = newest[name];
    if (have == null || catalogVersionCmp(version, have.version) > 0) {
      newest[name] = app;
    }
  }
  final out = newest.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return out;
}
