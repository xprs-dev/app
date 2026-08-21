/*
 * sign_command.dart -- sign one XPRS command so a station will act on it
 * (XPRS.md 25.4).
 *
 * A station discards an unsigned command in silence, which is correct and
 * makes the bench awkward: there is no way to hand-type an actuating
 * packet. This builds one, stamps it with the current UTC second so it
 * lands inside the 300-second freshness window, and signs it with the
 * operator's nsec -- the same key whose npub the station carries in its
 * own1..own4 allow-list.
 *
 *   dart run tool/sign_command.dart --to X3WWAJ --cmd update \
 *       --nsec-file ~/.xprs/owner.nsec --from X1Q3Q5 ver=1.4.2
 *
 * It prints the wire and nothing else, so it drops into a header:
 *
 *   curl -H "X-XPRS-Auth: $(dart run tool/sign_command.dart ...)" ...
 *
 * Deliberately built from strings rather than from XprsPacket: that class
 * pulls in Flutter, and this has to run under a bare `dart run`. The key
 * order below is the order section 4 states and the order the station
 * rebuilds when it strips sig: and via: to check the signature.
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/xprs_crypto.dart';
import 'package:hex/hex.dart';

String _arg(List<String> a, String n, {String? or}) {
  final i = a.indexOf('--$n');
  if (i >= 0 && i + 1 < a.length) return a[i + 1];
  if (or != null) return or;
  stderr.writeln('missing --$n');
  exit(2);
}

String _stamp() {
  final t = DateTime.now().toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(t.year, 4)}-${p(t.month)}-${p(t.day)}_'
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

void main(List<String> argv) {
  final to = _arg(argv, 'to');
  final cmd = _arg(argv, 'cmd');
  final from = _arg(argv, 'from');
  final nsec = File(_arg(argv, 'nsec-file')).readAsStringSync().trim();

  BigInt d = BigInt.zero;
  for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
    d = (d << 8) | BigInt.from(b);
  }

  final extra = argv.where((a) => a.contains('=') && !a.startsWith('--'));
  final body = StringBuffer('t:command f:$from d:$to ts:${_stamp()} cmd:$cmd');
  for (final a in extra) {
    final i = a.indexOf('=');
    body.write(' ${a.substring(0, i)}:${a.substring(i + 1)}');
  }

  final digest =
      NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(body.toString())));
  stdout.write('$body sig:'
      '${XprsCrypto.b85encode(XprsCrypto.sign(digest, d))}');
}
