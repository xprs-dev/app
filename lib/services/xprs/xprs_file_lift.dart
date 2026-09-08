/*
 * xprs_file_lift — a shared file's reference belongs in the envelope, not in
 * the sentence.
 *
 * A person types a caption and attaches a picture; the composer appends the
 * `file:<sha>.<ext>` token to the text, because that is where a token can ride
 * with no protocol at all. On the wire the specification puts it elsewhere:
 * `t:message … file:<ref> size:<n> [name:…] m:<caption>` (XPRS.md §7.7, the
 * worked packet at §7.7), and `size:` is the field that earns its bytes —
 * "knowing the size first is how a station declines politely instead of
 * starting something it cannot finish" (§7.7.1).
 *
 * Two things follow from lifting it here rather than leaving it in the body:
 *
 *   - A SEALED 1:1 hides `m:` inside `x:`. A reference left in the caption is
 *     invisible to every station on the way, including the receiver's own core
 *     until it decrypts. As a field it is readable by the parts of the system
 *     that must read it, which is what §11.2 already assumes when it says the
 *     hash is public and only the bytes are gated.
 *   - `size:` reaches the receiver, so the core can choose a lane and refuse a
 *     large unasked transfer over a shared radio.
 *
 * One file per message on the wire: the first token is lifted, later ones stay
 * in the caption. A message that carries two pictures is a message that costs
 * two packets, and the format has no plural here.
 *
 * Pure: no store, no I/O. The size and name come from a lookup the caller
 * injects, so this is testable on its own and the core owns the archive.
 */
import '../../util/media_ref.dart';
import 'xprs_packet.dart';

/// What a lift found: the text with the token removed, and the fields to put
/// on the packet. [file] is null when the text carried no reference.
class XprsFileLift {
  const XprsFileLift({required this.text, this.file, this.size, this.name});

  /// The caption with the lifted token (and any legacy `sz:` hint) removed.
  final String text;

  /// The `file:` value — `<43-char base64url sha>.<ext>` — or null.
  final String? file;

  /// Bytes, for `size:`. Null when the store does not know the file.
  final int? size;

  /// The filename for `name:`, when it fits §7.7.1's shape (1–64 characters,
  /// no space). Null when there is none or it does not.
  final String? name;

  bool get found => file != null;

  /// What the store knows about a hash: its size in bytes and its filename.
  /// Injected so this file needs no archive.
  static ({int size, String? name})? Function(String shaB64u)? meta;
}

final RegExp _szRe = RegExp(r'\bsz:\d+\b');

/// A filename fit for `name:` (§7.7.1: 1 to 64 characters, and §4's value rule
/// — no space). Anything else is dropped rather than mangled: the extension in
/// `file:` already advises presentation.
String? xprsFileName(String? raw) {
  final n = raw?.trim() ?? '';
  if (n.isEmpty || n.length > 64) return null;
  if (n.contains(' ') || n.contains('\t')) return null;
  return n;
}

/// Take the first `file:` token out of [text] and describe it.
XprsFileLift xprsLiftFile(String text) {
  final refs = MediaRef.findAll(text);
  if (refs.isEmpty) {
    return XprsFileLift(text: text.trim());
  }
  final ref = refs.first;
  final rest = text
      .replaceFirst(ref.token, '')
      .replaceAll(_szRe, '') // the old in-body size hint; `size:` replaces it
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final m = XprsFileLift.meta?.call(ref.sha256);
  return XprsFileLift(
    text: rest,
    file: '${ref.sha256}.${ref.ext}',
    size: m?.size,
    name: xprsFileName(m?.name),
  );
}

/// Put the reference on [p] as fields, moving it out of `m:`.
///
/// A no-op when the packet already carries `file:` (a caller that composed it
/// properly), when it is not a message, or when the caption holds no token.
/// `name:` is dropped before `size:` if the packet would not fit: the size is
/// what a receiver decides with, the name is a convenience.
XprsPacket xprsLiftFileOnPacket(XprsPacket p) {
  if (p.type != 'message' || p.has('file')) return p;
  final body = p['m'] ?? '';
  if (body.isEmpty) return p;
  final lift = xprsLiftFile(body);
  if (!lift.found) return p;

  var out = p.with_('file', lift.file!);
  out = lift.text.isEmpty ? out.without(const {'m'}) : out.with_('m', lift.text);
  if (lift.size != null) {
    final withSize = out.with_('size', '${lift.size}');
    if (withSize.fits || !out.fits) out = withSize;
  }
  if (lift.name != null) {
    final withName = out.with_('name', lift.name!);
    if (withName.fits) out = withName;
  }
  return out;
}
