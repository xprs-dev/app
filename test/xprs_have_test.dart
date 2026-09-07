/*
 * `q:have` / `have:` (XPRS.md §8.1): who holds the bytes for a `file:` hash.
 * The hash is public, so the answer is not gated on the file's audience — it
 * moves no bytes, it only says where they are. Held → `have:full`; a directed
 * miss → `code:404 m:try <holders>` from the seeder index; a broadcast miss is
 * silent. In-process: XprsFileServer.onHave, its answer read off the
 * publisher's lastWire.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_ref.dart';

void main() {
  late XprsFileServer server;
  const shaHex =
      'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';
  final ref = '${MediaRef.hexToB64u(shaHex)}.png';

  XprsHeldFile held(String sha) => XprsHeldFile(
      archiveToken: 'file:${MediaRef.hexToB64u(sha)}.png',
      shaHex: sha,
      size: 10,
      name: 'x.png',
      ext: 'png');

  XprsPacket ask({bool directed = true}) => XprsPacket.parse(
      't:request f:X1QZ3N ${directed ? 'd:X3ARC ' : ''}q:have file:$ref')!;

  setUp(() {
    server = XprsFileServer.instance;
    server.resolver = null;
    server.holderIndex = null;
    XprsPublisher.instance.lastWire = null;
  });

  test('held → have:full to the asker', () {
    server.addResolver((s) => s == shaHex ? held(s) : null);
    server.onHave(ask(), selfBase: 'X3ARC', from: 'X1QZ3N', directed: true);
    final w = XprsPublisher.instance.lastWire!;
    expect(w, contains('have:full'));
    expect(w, contains('d:X1QZ3N'));
    expect(w, contains('f:X3ARC'));
  });

  test('directed miss → 404 with m:try naming indexed holders', () {
    server.holderIndex = (_) => ['X3ARC2', 'X3ARC7'];
    server.onHave(ask(), selfBase: 'X3ARC', from: 'X1QZ3N', directed: true);
    final w = XprsPublisher.instance.lastWire!;
    expect(w, contains('code:404'));
    expect(w, contains('m:try X3ARC2,X3ARC7'));
  });

  test('directed miss with an empty index → bare 404', () {
    server.onHave(ask(), selfBase: 'X3ARC', from: 'X1QZ3N', directed: true);
    final w = XprsPublisher.instance.lastWire!;
    expect(w, contains('code:404'));
    expect(w, isNot(contains('m:try')));
  });

  test('broadcast miss stays silent (§8.1)', () {
    server.holderIndex = (_) => ['X3ARC2'];
    server.onHave(ask(directed: false),
        selfBase: 'X3ARC', from: 'X1QZ3N', directed: false);
    expect(XprsPublisher.instance.lastWire, isNull,
        reason: 'a station holding nothing does not reply to the street');
  });

  test('broadcast hit → have:full (we hold it)', () {
    server.addResolver((s) => s == shaHex ? held(s) : null);
    server.onHave(ask(directed: false),
        selfBase: 'X3ARC', from: 'X1QZ3N', directed: false);
    expect(XprsPublisher.instance.lastWire, contains('have:full'));
  });
}
