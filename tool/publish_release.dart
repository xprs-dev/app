// =============================================================================
// publish_release.dart — write the xprs.dev update feed for a built release.
//
// The feed ANNOUNCES; it does not host. Two small channel documents:
//   updates/stable.json   — newest stable release
//   updates/beta.json     — newest release including pre-releases
// each naming the version, the notes, and for every artifact its absolute
// download URL, size and sha256. No binaries are copied anywhere, so the site
// repo stays a few KB however many releases ship.
//
// The sha256 is the load-bearing field. It is the content address an XPRS
// phone fetches the artifact by over Reticulum from a super-archiver that has
// already mirrored it — which is how an ordinary phone updates without ever
// making an HTTPS request for the binary. The URL is there for the mirror, and
// as the fallback for a device with no Reticulum path.
//
// Usage:
//   dart run tool/publish_release.dart \
//       --site <path-to-website-repo> \
//       --version <X.Y.Z[-beta.N]> \
//       --base-url <https://host/path/to/v1.2.3> \
//       [--notes <notes-file>] [--name "<title>"] [--date <ISO8601>] \
//       <artifact> [<artifact> ...]
//
// Channel is derived from the version: a pre-release (contains '-') publishes
// to beta.json only; a stable version publishes to BOTH stable.json and
// beta.json (so the beta channel always tracks the newest build).
//
// `--site` defaults to ../website relative to the repo root (the local
// checkout of the GitHub Pages repo serving xprs.dev).
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

void main(List<String> argv) {
  String? site;
  String? version;
  String? notesFile;
  String? name;
  String? date;
  String? baseUrl;
  final artifacts = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '--site':
        site = argv[++i];
      case '--version':
        version = argv[++i];
      case '--notes':
        notesFile = argv[++i];
      case '--name':
        name = argv[++i];
      case '--date':
        date = argv[++i];
      case '--base-url':
        baseUrl = argv[++i];
      default:
        artifacts.add(a);
    }
  }

  if (version == null || version.isEmpty) {
    stderr.writeln('error: --version <X.Y.Z[-beta.N]> is required');
    exit(2);
  }
  if (artifacts.isEmpty) {
    stderr.writeln('error: at least one artifact path is required');
    exit(2);
  }

  if (baseUrl == null || baseUrl.isEmpty) {
    stderr.writeln('error: --base-url <https://.../v1.2.3> is required — the '
        'feed announces where the binaries are, it does not host them');
    exit(2);
  }
  final root = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  // Default site path: ../website relative to this repo's root.
  final repoRoot = Directory.current.path;
  site ??= '$repoRoot/../website';
  final updatesDir = Directory('$site/updates');
  updatesDir.createSync(recursive: true);

  final v = version; // promoted non-null
  final isPre = v.contains('-');
  final assets = <Map<String, dynamic>>[];
  for (final path in artifacts) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('error: artifact not found: $path');
      exit(1);
    }
    final base = path.split('/').last;
    // sha256 is load-bearing, not a nicety: it is the address the artifact is
    // fetched by over Reticulum, and the only thing a mirror can verify an
    // HTTPS download against. Streamed, so publishing never holds an APK.
    final sha = _sha256OfFile(f);
    assets.add({
      'name': base,
      'url': '$root/$base', // absolute — the feed hosts nothing
      'size': f.lengthSync(),
      'sha256': sha,
    });
    stdout.writeln('${base.padRight(40)} ${f.lengthSync()} bytes  $sha');
  }

  String? notes;
  if (notesFile != null && File(notesFile).existsSync()) {
    notes = File(notesFile).readAsStringSync().trim();
  }

  final feed = <String, dynamic>{
    'version': v,
    'tagName': 'v$v',
    'name': name ?? 'XPRS $v',
    'body': notes ?? '',
    'publishedAt': date ?? DateTime.now().toUtc().toIso8601String(),
    'prerelease': isPre,
    'assets': assets,
  };
  final json = const JsonEncoder.withIndent('  ').convert(feed);

  // Beta always tracks the newest build; stable only when not a pre-release.
  final targets = <String>['beta.json', if (!isPre) 'stable.json'];
  for (final t in targets) {
    final out = File('${updatesDir.path}/$t');
    out.writeAsStringSync('$json\n');
    stdout.writeln('wrote ${out.path}');
  }

  stdout.writeln('done. Published v$v to ${updatesDir.path} '
      '(${isPre ? 'beta' : 'stable + beta'}).');
}



/// sha256 of [f], read in 64 KiB chunks — an artifact is 47-61 MB and is never
/// held whole.
String _sha256OfFile(File f) {
  final sink = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  final raf = f.openSync();
  try {
    const chunkSize = 1 << 16;
    while (true) {
      final chunk = raf.readSync(chunkSize);
      if (chunk.isEmpty) break;
      input.add(chunk);
    }
  } finally {
    raf.closeSync();
  }
  input.close();
  return sink.value!.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
