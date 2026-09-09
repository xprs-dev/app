/*
 * The wire a redacted post travels as (XPRS.md 6.2.1, the `xr:` field).
 *
 * The shape is the whole difference between a redacted message reaching one
 * person and reaching the room: an addressed packet carries `d:`, and the
 * Local room is undirected, so it carries `scope:local` and no `d:` at all
 * (13.11.1). Composing a Local one used to be impossible -- the core wrote
 * `d:LOCAL`, a callsign nobody has -- so the wapp refused to offer it and the
 * marked text went out in the clear instead.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/util/xprs_crypto.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/wapp/wapp_engine.dart';

String _wire(String convo, {String xr = 'AAECAwQFBgcICQoLzz', String barred = 'meet ███'}) =>
    WappEngine.xrRedactedWire(
      self: 'X1QZ3N',
      convo: convo,
      ts: '2026-09-09_14:26:40',
      xr: xr,
      barred: barred,
    );

void main() {
  test('the Local room is undirected: scope:local and no d:', () {
    final w = _wire('#LOCAL');
    expect(w, contains(' scope:local '));
    expect(w, isNot(contains(' d:')));
    final p = XprsPacket.parse(w);
    expect(p, isNotNull);
    expect(p!['d'], isNull);
    expect(p['scope'], 'local');
    expect(p['xr'], isNotNull);
  });

  test('a 1:1 and a closed group are addressed', () {
    expect(XprsPacket.parse(_wire('X1RD89'))!['d'], 'X1RD89');
    // A group's id is "#" + its X5 callsign; the "#" is the wapp's, not the
    // wire's.
    expect(XprsPacket.parse(_wire('#X5ABCD'))!['d'], 'X5ABCD');
  });

  test('m: is last in every shape, xr: before it', () {
    for (final convo in ['#LOCAL', 'X1RD89', '#X5ABCD']) {
      final w = _wire(convo);
      expect(w.indexOf(' m:') > w.indexOf(' xr:'), isTrue, reason: convo);
      expect(w.substring(w.indexOf(' m:') + 3), 'meet ███', reason: convo);
    }
  });

  test('a Local wire still opens with the passphrase', () {
    final red = XprsCrypto.redact('meet ((Max)) at the ((pier2))',
        passphrase: 'hunter2');
    final w = _wire('#LOCAL', xr: red!.$2, barred: red.$1);
    final p = XprsPacket.parse(w)!;
    expect(XprsCrypto.restore(w, p['xr']!, 'hunter2'),
        contains('meet Max at the pier2'));
    // The wrong passphrase leaves the bars standing (the "->" sentinel).
    expect(XprsCrypto.restore(w, p['xr']!, 'wrong'), isNull);
  });
}
