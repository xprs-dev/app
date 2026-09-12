/// The firmware catalogue the website serves.
///
/// `https://xprs.dev/firmware/docs/boards.json` lists every board the
/// firmware repo publishes; each board's `prebuilt/manifest.json` (the ESP
/// Web Tools shape) names its parts and their offsets.
///
/// This file is the pure half (models, parseBoards, parseManifest,
/// matchBoards), which the tests read fixtures into; the fetching and the
/// files are in flash_catalog_io.dart.
library;

import 'dart:convert';

import 'esp_image.dart';

class FlashBoard {
  final String id;
  final String name;
  final String vendor;
  final String family; // boards.json silicon.family
  final int flashMb;
  final int psramMb;
  final String port; // native-usb | usb-serial | uf2
  final String env;
  final String image; // the CMake project name, when the catalogue says
  final String version;
  final String manifestUrl;
  final String status;
  final String photoUrl; // the catalogue's first product picture

  const FlashBoard({
    required this.id,
    required this.name,
    this.vendor = '',
    required this.family,
    this.flashMb = 0,
    this.psramMb = 0,
    this.port = '',
    this.env = '',
    this.image = '',
    this.version = '',
    required this.manifestUrl,
    this.status = '',
    this.photoUrl = '',
  });

  /// An ESP family with a serial loader and a published prebuilt.
  bool get flashable =>
      port != 'uf2' && EspFamily.fromWebTools(family) != null && version.isNotEmpty;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'vendor': vendor,
        'family': family,
        'flashMb': flashMb,
        'psramMb': psramMb,
        'port': port,
        'env': env,
        'image': image,
        'version': version,
        'status': status,
        'flashable': flashable,
        'photo': photoUrl,
      };
}

class FlashPartRef {
  final String name; // bootloader.bin
  final int offset;
  final String url;
  const FlashPartRef(this.name, this.offset, this.url);
}

class FlashManifest {
  final String name;
  final String version;
  final String family;
  final bool promptErase;
  final List<FlashPartRef> parts;
  const FlashManifest(this.name, this.version, this.family, this.promptErase, this.parts);
}

/// A part on disk, checked.
class FlashLocalPart {
  final String name;
  final int offset;
  final String path;
  final int size;
  final String sha256;
  const FlashLocalPart(this.name, this.offset, this.path, this.size, this.sha256);

  Map<String, Object> toJson() =>
      {'name': name, 'offset': offset, 'path': path, 'size': size, 'sha256': sha256};

  static FlashLocalPart fromJson(Map<String, dynamic> m) => FlashLocalPart(
        m['name'] as String? ?? '',
        (m['offset'] as num?)?.toInt() ?? 0,
        m['path'] as String? ?? '',
        (m['size'] as num?)?.toInt() ?? 0,
        m['sha256'] as String? ?? '',
      );
}

class FlashLocal {
  final String boardId;
  final String version;
  final String family;
  final bool promptErase;
  final List<FlashLocalPart> parts;
  const FlashLocal(this.boardId, this.version, this.family, this.promptErase, this.parts);

  int get totalBytes => parts.fold(0, (a, p) => a + p.size);

  Map<String, Object> toJson() => {
        'board': boardId,
        'version': version,
        'family': family,
        'promptErase': promptErase,
        'parts': [for (final p in parts) p.toJson()],
      };

  static FlashLocal? fromJson(Map<String, dynamic> m) {
    final parts = (m['parts'] as List?)
        ?.whereType<Map>()
        .map((e) => FlashLocalPart.fromJson(e.cast<String, dynamic>()))
        .toList();
    if (parts == null || parts.isEmpty) return null;
    return FlashLocal(
      m['board'] as String? ?? '',
      m['version'] as String? ?? '',
      m['family'] as String? ?? '',
      m['promptErase'] as bool? ?? false,
      parts,
    );
  }
}

/// What a probe learned, the input to [matchBoards].
class FlashProbe {
  final String family;
  final int flashBytes;
  final String project;
  final String version;
  const FlashProbe(this.family, this.flashBytes, {this.project = '', this.version = ''});
}

class FlashMatch {
  final FlashBoard? suggested;
  final List<FlashBoard> likely;
  const FlashMatch(this.suggested, this.likely);
}

/// The boards that fit a probed chip, the best first. Family first, flash
/// size next, and the project name the board's own firmware wrote at
/// 0x20020 settles it when one board's image says its name.
FlashMatch matchBoards(FlashProbe p, List<FlashBoard> boards) {
  var c = boards
      .where((b) => b.flashable && EspFamily.fromWebTools(b.family) == p.family)
      .toList();
  if (p.flashBytes > 0) {
    final mb = p.flashBytes ~/ (1024 * 1024);
    final sized = c.where((b) => b.flashMb == mb).toList();
    if (sized.isNotEmpty) c = sized;
  }
  FlashBoard? named;
  if (p.project.isNotEmpty) {
    for (final b in c) {
      if (boardOwnsImage(b, p.project)) {
        named = b;
        break;
      }
    }
  }
  final suggested = named ?? (c.length == 1 ? c.first : null);
  if (suggested != null) {
    c.remove(suggested);
    c.insert(0, suggested);
  }
  return FlashMatch(suggested, c);
}

/// Does [project] (an esp_app_desc_t project_name) name [b]'s firmware?
/// The catalogue may say so outright (`image`); otherwise the project is the
/// env or the id with `_xprs` dropped, which is how the CMake projects are
/// named (tdongle_xprs, esp32c3_xprs, heltec_v3_xprs).
bool boardOwnsImage(FlashBoard b, String project) {
  final p = project.toLowerCase();
  if (p.isEmpty) return false;
  if (b.image.isNotEmpty) return p == b.image.toLowerCase();
  var stem = p.endsWith('_xprs') ? p.substring(0, p.length - 5) : p;
  if (stem.startsWith('xprs_')) stem = stem.substring(5);
  final env = b.env.toLowerCase();
  final id = b.id.toLowerCase().replaceAll('-', '_');
  if (stem == env || stem == id) return true;
  // esp32c3_xprs on esp32c3-mini, esp32_generic_xprs on generic.
  if (id.startsWith('${stem}_') || stem.endsWith('_$env') || stem.endsWith('_$id')) return true;
  return false;
}

List<FlashBoard> parseBoards(String json, {required String site}) {
  final raw = jsonDecode(json);
  if (raw is! List) return const [];
  final out = <FlashBoard>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final id = e['id'] as String? ?? '';
    if (id.isEmpty) continue;
    final sil = (e['silicon'] as Map?) ?? const {};
    final fw = (e['firmware'] as Map?) ?? const {};
    out.add(FlashBoard(
      id: id,
      name: e['name'] as String? ?? id,
      vendor: e['vendor'] as String? ?? '',
      family: sil['family'] as String? ?? '',
      flashMb: (sil['flash_mb'] as num?)?.toInt() ?? 0,
      psramMb: (sil['psram_mb'] as num?)?.toInt() ?? 0,
      port: fw['flash_port'] as String? ?? '',
      env: fw['env'] as String? ?? '',
      image: fw['image'] as String? ?? '',
      version: fw['version']?.toString() ?? '',
      manifestUrl: '$site/models/$id/prebuilt/manifest.json',
      status: e['status'] as String? ?? '',
      photoUrl: _firstPhoto(e['images']),
    ));
  }
  return out;
}

/// The first product picture of a board's `images`, as an absolute URL.
String _firstPhoto(Object? images) {
  if (images is! List) return '';
  for (final im in images) {
    if (im is Map) {
      final u = im['image_url'] as String? ?? '';
      if (u.startsWith('http')) return u;
    }
  }
  return '';
}

FlashManifest? parseManifest(String json, {required String baseUrl}) {
  final raw = jsonDecode(json);
  if (raw is! Map) return null;
  final builds = raw['builds'];
  if (builds is! List || builds.isEmpty) return null;
  final b = builds.first;
  if (b is! Map) return null;
  final parts = <FlashPartRef>[];
  for (final p in (b['parts'] as List?) ?? const []) {
    if (p is! Map) continue;
    final path = p['path'] as String? ?? '';
    final off = p['offset'];
    final offset = off is num ? off.toInt() : int.tryParse('$off') ?? -1;
    if (path.isEmpty || offset < 0) return null;
    final url = path.contains('://') ? path : '$baseUrl/$path';
    parts.add(FlashPartRef(path.split('/').last, offset, url));
  }
  if (parts.isEmpty) return null;
  parts.sort((x, y) => x.offset.compareTo(y.offset));
  return FlashManifest(
    raw['name'] as String? ?? '',
    raw['version']?.toString() ?? '',
    EspFamily.fromWebTools(b['chipFamily'] as String? ?? '') ?? '',
    raw['new_install_prompt_erase'] as bool? ?? false,
    parts,
  );
}
