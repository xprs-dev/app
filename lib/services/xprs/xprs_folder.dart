/*
 * xprs_folder — a folder as the format publishes it (XPRS.md 7.7.2, 7.7.3).
 *
 * A folder is a LISTING: a UTF-8 text file, `XFL1` then one `ref size name`
 * line per member, sorted bytewise by name, so the same members always make
 * the same bytes and therefore the same hash. The listing is itself an
 * ordinary content-addressed file: held, fetched with `cmd:file`, verified
 * against its reference. Publishing the folder is describing that listing
 * with a signed `t:file ... kind:folder`, and each member with its own signed
 * `t:file` (7.7.1), deposited with the archivers (12.3) so a reader anywhere
 * finds them by asking `cmd:history only:<publisher> kind:file` (12.6).
 *
 * This is the packet-layer form of the folders lane the app already has
 * (the op-log folders, the DHT, the resources that move bytes): nothing here
 * moves a byte or indexes anything. It writes down, in the format's own
 * words, what a person is publishing, signed by them, so a station that
 * speaks only XPRS and Reticulum -- an ESP32 on a roof looking for its next
 * firmware -- can find the folder by the person's key, read the names and
 * sizes inside, and ask for the one it wants.
 *
 * Pure: the listing builder and parser touch no store; XprsFolderPublisher
 * takes its store, its holder and its sends as functions, with device
 * defaults wired by the caller, so the whole publish runs under test.
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart' show xprsFmtTs;

/// One member of a folder: its digest, its size in bytes, and its name.
class XprsFolderEntry {
  const XprsFolderEntry(
      {required this.shaHex, required this.size, required this.name});

  /// Lowercase hex SHA-256 of the bytes.
  final String shaHex;
  final int size;

  /// The filename, 1 to 64 characters. A name may contain spaces in a
  /// listing line (it runs to the end of the line); in a `t:file`'s `name:`
  /// it may not (the value rule of section 4), and the publisher replaces
  /// them with `_` there.
  final String name;

  /// The type the name advises, 1 to 8 lowercase alphanumerics, or ''.
  String get ext {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return '';
    final e = name.substring(i + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(e) ? e : '';
  }

  /// The `file:` reference: 43 base64url characters, a dot, the type.
  String get ref => xprsFileRefOf(shaHex, ext);

  @override
  String toString() => '$ref $size $name';
}

/// `file:` reference for a digest: base64url of the 32 bytes, no padding,
/// then `.ext` when there is one (7.7).
String xprsFileRefOf(String shaHex, String ext) {
  final bytes = Uint8List.fromList([
    for (var i = 0; i < 64; i += 2) int.parse(shaHex.substring(i, i + 2), radix: 16)
  ]);
  final b = base64Url.encode(bytes).replaceAll('=', '');
  return ext.isEmpty ? b : '$b.$ext';
}

/// The digest behind a reference or a bare hash, as lowercase hex, or null.
/// Accepts the 43-character base64url form and the earlier 64-hex form, with
/// or without a type (7.7: "treats the two as the same reference").
String? xprsFileShaOf(String ref) {
  var r = ref.trim();
  final dot = r.indexOf('.');
  if (dot > 0) r = r.substring(0, dot);
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(r)) return r.toLowerCase();
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(r)) return null;
  try {
    final bytes = base64Url.decode('$r=');
    if (bytes.length != 32) return null;
    return bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  } catch (_) {
    return null;
  }
}

/// A `qty` of bytes: a bare count, or a count with k, M or G (and an
/// optional B). The same reading XprsFiles gives `size:`.
int xprsBytesOf(String? v) {
  final s = (v ?? '').trim();
  final m = RegExp(r'^(\d+)\s*([kKmMgG]?)[bB]?$').firstMatch(s);
  if (m == null) return 0;
  final n = int.tryParse(m.group(1)!) ?? 0;
  return switch (m.group(2)!.toLowerCase()) {
    'k' => n * 1024,
    'm' => n * 1024 * 1024,
    'g' => n * 1024 * 1024 * 1024,
    _ => n,
  };
}

const String kXprsListingMagic = 'XFL1';

/// The listing for [entries]: `XFL1`, then `ref size name` per line, LF
/// terminated, lines sorted bytewise by name (7.7.2). Sizes are written as
/// exact byte counts, because a reader verifies against them.
String xprsListingBuild(Iterable<XprsFolderEntry> entries) {
  final rows = entries.toList()
    ..sort((a, b) => _bytewise(a.name, b.name));
  final b = StringBuffer('$kXprsListingMagic\n');
  for (final e in rows) {
    b.write('${e.ref} ${e.size} ${e.name}\n');
  }
  return b.toString();
}

int _bytewise(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// Read a listing. Null when the magic is wrong; a line that does not parse
/// is skipped (a reader fetches what it can name, and nothing else).
List<XprsFolderEntry>? xprsListingParse(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trim() != kXprsListingMagic) return null;
  final out = <XprsFolderEntry>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final sp1 = line.indexOf(' ');
    if (sp1 <= 0) continue;
    final sp2 = line.indexOf(' ', sp1 + 1);
    if (sp2 <= sp1) continue;
    final sha = xprsFileShaOf(line.substring(0, sp1));
    final size = xprsBytesOf(line.substring(sp1 + 1, sp2));
    final name = line.substring(sp2 + 1).trim();
    if (sha == null || name.isEmpty || name.length > 64) continue;
    out.add(XprsFolderEntry(shaHex: sha, size: size, name: name));
  }
  return out;
}

/// `name:` as a packet value: no spaces (section 4), at most 64 characters.
String xprsNameValue(String name) {
  final v = name.replaceAll(RegExp(r'\s+'), '_');
  return v.length > 64 ? v.substring(0, 64) : v;
}

/// The signed description of one member (7.7.1):
/// `t:file f: ts: file: size: name: sig:`. Null when it cannot be built or
/// does not fit; a name is dropped before the description is.
XprsPacket? xprsDescribeMember({
  required String self,
  required XprsFolderEntry entry,
  required String ts,
  BigInt? key,
  /// `tag:` files the member under a topic (7.7.1). A firmware folder
  /// tags each image with its channel, `stable` or `beta`, so a station
  /// reading the descriptions alone knows which it is offered.
  String? tag,
}) {
  var base = XprsPacket.parse(
      't:file f:$self ts:$ts file:${entry.ref} size:${entry.size}');
  if (base == null) return null;
  if (tag != null && tag.trim().isNotEmpty) {
    base = base.with_('tag', xprsNameValue(tag.trim()));
  }
  var p = base.with_('name', xprsNameValue(entry.name));
  if (key != null) p = xprsSign(p, key);
  if (p.fits) return p;
  p = key != null ? xprsSign(base, key) : base;
  return p.fits ? p : null;
}

/// The signed description of the folder (7.7.3): the listing's reference
/// with `kind:folder`, how many members, their total size, and the folder's
/// name in `m:`.
XprsPacket? xprsDescribeFolder({
  required String self,
  required String listingShaHex,
  required int count,
  required int totalSize,
  required String name,
  required String ts,
  BigInt? key,
}) {
  final p0 = XprsPacket.parse('t:file f:$self ts:$ts '
      'file:${xprsFileRefOf(listingShaHex, 'xfl')} kind:folder '
      'count:$count size:$totalSize');
  if (p0 == null) return null;
  var p = name.trim().isEmpty ? p0 : p0.with_('m', name.trim());
  if (key != null) p = xprsSign(p, key);
  return p.fits ? p : null;
}

/// Is this packet a folder description, and whose listing does it name?
/// Returns the listing's sha hex, or null.
String? xprsFolderListingSha(XprsPacket p) {
  if (p.type != 'file' || p['kind'] != 'folder') return null;
  final f = p['file'];
  return f == null ? null : xprsFileShaOf(f);
}

/// Publish a folder: store and hold its listing, say what it is, say what
/// each member is, and leave copies with the archivers.
///
/// Every side effect is a function, so the publish runs on the bench and on
/// a device alike; the device wires them at start-up (MediaArchive.putBytes,
/// XprsFiles.hold, the publisher's air and deposit).
class XprsFolderPublisher {
  XprsFolderPublisher({
    required this.self,
    required this.store,
    required this.air,
    required this.deposit,
    this.key,
    this.now,
  });

  /// This station's callsign, the `f:` on every description.
  final String self;

  /// Keep these bytes under this type and HOLD them for `cmd:file`.
  /// Returns the sha hex of what was stored.
  final String Function(Uint8List bytes, String ext, String name) store;

  /// Put one wire on the air, on every bearer the station has.
  final Future<void> Function(String wire) air;

  /// Leave these wires with the chosen archivers (12.3).
  final void Function(List<String> wires) deposit;

  /// The publisher's signing key. Null publishes nothing: an unsigned folder
  /// is a folder nobody can trust (7.7.3 signs both packets).
  final BigInt? key;

  /// The clock, for tests.
  final DateTime Function()? now;

  /// What the last publish said, for the station's own records and for a
  /// re-announce: the listing's sha and the wires.
  String? listingSha;
  List<String> wires = const [];

  /// Publish [entries] as the folder called [name], each member tagged
  /// [tag] when given. Returns the listing's sha hex, or null when there was
  /// no key or nothing fitted.
  Future<String?> publish(String name, Iterable<XprsFolderEntry> entries,
      {String? tag}) async {
    final k = key;
    if (k == null) return null;
    final rows = entries.toList();
    final listing = xprsListingBuild(rows);
    final bytes = Uint8List.fromList(utf8.encode(listing));
    final sha = store(bytes, 'xfl', '${xprsNameValue(name)}.xfl');
    final ts = xprsFmtTs((now ?? DateTime.now)().toUtc());
    final total = rows.fold<int>(0, (s, e) => s + e.size);
    final out = <String>[];
    final folder = xprsDescribeFolder(
        self: self,
        listingShaHex: sha,
        count: rows.length,
        totalSize: total,
        name: name,
        ts: ts,
        key: k);
    if (folder == null) return null;
    out.add(folder.encode());
    for (final e in rows) {
      final d = xprsDescribeMember(self: self, entry: e, ts: ts, key: k, tag: tag);
      if (d != null) out.add(d.encode());
    }
    listingSha = sha;
    wires = out;
    for (final w in out) {
      await air(w);
    }
    deposit(out);
    return sha;
  }
}
