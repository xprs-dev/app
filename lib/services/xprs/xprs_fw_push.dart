/// Push a firmware image to a station over the 1:1 GATT link — the phone as
/// the pusher the fleet's docs promise (`firmware/FIRMWARE.md` §6.2).
///
/// Same trust model as every other pusher: the OWNER (this profile's key,
/// which must be on the station's `own1..own4` allow-list) signs a
/// `cmd:update` naming version, size and sha256; the PUBLISHER's approval —
/// a signature over `xprsfw1 <board> <version> <size> <sha256>` obtained out
/// of band with the image — rides the XBLOB manifest and is verified by the
/// station before anything installs. The image itself crosses as XBLOB
/// parcels on the connection, not the broadcast plane.
///
/// The same call shares ANY sha-named blob fast with a peer that knows to
/// START it; firmware is just the first user.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../log_service.dart';
import '../mesh/mesh_service.dart';
import '../mesh/xblob_service.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';

class XprsFwPush {
  XprsFwPush._();
  static final XprsFwPush instance = XprsFwPush._();

  /// Compose, sign and send the `cmd:update` for [image], and arm the XBLOB
  /// server so the station's START finds the bytes. Returns the command's
  /// wire on success, null when this profile cannot sign.
  ///
  /// [approvalSig85] is the publisher's 60-character approval for exactly
  /// this (board, version, size, sha) — produced by `tool/sign_firmware.dart`
  /// or delivered alongside the image.
  Future<String?> push({
    required String toCallsign,
    required Uint8List image,
    required String version,
    required String approvalSig85,
  }) async {
    final d = xprsProfileScalar();
    final self = MeshService.instance.tableCallsign;
    if (d == null || self.isEmpty) {
      LogService.instance.add('FwPush: no signing profile');
      return null;
    }
    final sha = Uint8List.fromList(crypto.sha256.convert(image).bytes);
    final shaHex =
        sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final ts = _ts(DateTime.now().toUtc());
    final wire = 't:command f:$self d:$toCallsign ts:$ts '
        'cmd:update ver:$version size:${image.length} sha:$shaHex';
    final p = XprsPacket.parse(wire);
    if (p == null) return null;
    final signed = xprsSign(p, d).encode();

    // The bytes first, so the station's START (which follows its 202 within
    // the same link round-trip) finds them already parked.
    XblobService.instance.serveImage(image, sha, sig85: approvalSig85);

    LogService.instance
        .add('FwPush: cmd:update $version (${image.length} B) -> $toCallsign');
    await XprsPublisher.instance.publishWire(signed);
    return signed;
  }

  static String _ts(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}_${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
