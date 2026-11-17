/*
 * A closed group's reading key (xprs_group_read): what keeps its words
 * private without handing its authority to every member. The admin's device
 * mints it, hands it to each member sealed from the group, and mints a new one
 * when somebody leaves or is removed; a member's post sealed to it opens for
 * every holder, the older keys included.
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs_core/src/services/events/wapp_event_broker.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_group_keys.dart';
import 'package:xprs/services/xprs/xprs_group_read.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/util/nostr_crypto.dart';

({BigInt d, String pubHex}) _person() {
  final kp = NostrCrypto.generateKeyPair();
  var d = BigInt.zero;
  for (final b in HEX.decode(kp.privateKeyHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return (d: d, pubHex: kp.publicKeyHex);
}

void main() {
  late Directory tmp;
  late String g;
  late BigInt gd;
  final keys = <String, String>{};
  final aired = <String>[];
  const admin = 'X1ADMN';
  final bea = _person();
  final cai = _person();
  final now = DateTime.now().millisecondsSinceEpoch;
  String at(int secondsAgo) => xprsNowTs(now - secondsAgo * 1000);

  void act(String rest, String when) => XprsGroups.instance.offer(
      xprsSign(XprsPacket.parse('t:moderate f:$g d:$g ts:$when $rest')!, gd));

  void join(String who, BigInt d, int grantAgo) {
    final grant =
        xprsSign(XprsPacket.parse('t:moderate f:$g d:$g ts:${at(grantAgo)} grant:$who')!, gd);
    XprsGroups.instance.offer(grant);
    XprsGroups.instance.offer(xprsSign(
        XprsPacket.parse('t:moderate f:$who d:$g ts:${at(grantAgo - 10)} '
            'r:${xprsIdentifier(grant)} accept:member')!,
        d));
  }

  /// What [member] reads in a key message: the `nsec:` line, opened with
  /// their own key against the group's.
  String opened(String wire, BigInt member) {
    final p = XprsPacket.parse(wire)!;
    return xprsReadBody(p, ownKey: member, senderKeyHex: keys[g]).clear ?? '';
  }

  List<String> to(String call) =>
      aired.where((w) => w.contains(' d:$call ')).toList();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsgroupread');
    XprsGroupKeys.instance.init('${tmp.path}/g.zx');
    final own = XprsGroupKeys.instance.create(nick: 'Family')!;
    g = own.callsign;
    gd = XprsGroupKeys.instance.scalarFor(g)!;
    keys
      ..clear()
      ..[g] = NostrCrypto.decodeNpub(own.npub)
      ..['X1BEA'] = bea.pubHex
      ..['X1CAI'] = cai.pubHex;
    XprsGroups.instance
      ..clear()
      ..keyResolver = (c) =>
          keys[c] == null ? null : Uint8List.fromList(HEX.decode(keys[c]!));
    aired.clear();
    XprsGroupRead.instance
      ..init('${tmp.path}/r.zx')
      ..self = (() => admin)
      ..keyOf = ((c) => keys[c])
      ..air = ((w) async => aired.add(w))
      ..autoTend = false;
    // Family is private: these tests are about its reading keys.
    XprsGroupRead.instance.setPrivate(g, true);
  });

  tearDown(() {
    XprsGroupRead.instance.close();
    XprsGroupKeys.instance.close();
    XprsGroups.instance.clear();
    tmp.deleteSync(recursive: true);
  });

  test('the admin mints a reading key and hands it to a member, sealed from '
      'the group', () async {
    join('X1BEA', bea.d, 120);
    await XprsGroupRead.instance.tend();
    final mine = to('X1BEA');
    expect(mine, hasLength(1));
    expect(mine.single, startsWith('t:message f:$g d:X1BEA '));
    expect(mine.single, contains(' x:'));
    expect(mine.single, isNot(contains('nsec')), reason: 'never in the clear');
    final body = opened(mine.single, bea.d);
    expect(body, startsWith('nsec:'));
    expect(opened(mine.single, cai.d), isEmpty,
        reason: 'sealed to the member it names');
    // And the group says its name again, for a member who never heard it.
    expect(aired.where((w) => w.startsWith('t:identity f:$g ') && w.contains('nick:Family')),
        hasLength(1));
    // Once handed over, not again.
    aired.clear();
    await XprsGroupRead.instance.tend();
    expect(aired, isEmpty);
  });

  test('a member post sealed to the reading key opens for every holder',
      () async {
    join('X1BEA', bea.d, 120);
    await XprsGroupRead.instance.tend();
    final post = xprsBuildDirect(
      head: XprsPacket.parse('t:message f:X1BEA d:$g ts:${at(5)}')!,
      text: 'the spare key is under the blue pot',
      private: true,
      recipientKeyHex: XprsGroupRead.instance.currentPubHex(g),
      signingKey: bea.d,
    ).packets.single;
    expect(post.encode(), isNot(contains('blue pot')));
    expect(
        XprsGroupRead.instance
            .open(post, Uint8List.fromList(HEX.decode(bea.pubHex))),
        'the spare key is under the blue pot');
  });

  test('somebody removed: a new key, handed only to who remains; the old '
      'words still open', () async {
    join('X1BEA', bea.d, 300);
    join('X1CAI', cai.d, 200);
    await XprsGroupRead.instance.tend();
    final first = XprsGroupRead.instance.currentPubHex(g)!;
    final before = xprsBuildDirect(
      head: XprsPacket.parse('t:message f:X1CAI d:$g ts:${at(100)}')!,
      text: 'before',
      private: true,
      recipientKeyHex: first,
      signingKey: cai.d,
    ).packets.single;

    act('revoke:X1BEA', at(60));
    aired.clear();
    await XprsGroupRead.instance.tend();
    final second = XprsGroupRead.instance.currentPubHex(g)!;
    expect(second, isNot(first));
    expect(to('X1BEA'), isEmpty, reason: 'the removed member is not told');
    expect(to('X1CAI'), hasLength(1));
    expect(opened(to('X1CAI').single, cai.d), startsWith('nsec:'));
    // What was said before stays readable to whoever holds the old key.
    expect(
        XprsGroupRead.instance
            .open(before, Uint8List.fromList(HEX.decode(cai.pubHex))),
        'before');
  });

  test('a newcomer is handed the older keys too, the newest last', () async {
    join('X1BEA', bea.d, 300);
    await XprsGroupRead.instance.tend();
    XprsGroupRead.instance.mint(g); // a renewal before Cai came
    join('X1CAI', cai.d, 100);
    aired.clear();
    await XprsGroupRead.instance.tend();
    final mine = to('X1CAI');
    expect(mine, hasLength(2));
    final last = opened(mine.last, cai.d).substring(5);
    expect(XprsGroupRead.instance.keysOf(g).first.nsec, last);
  });

  test('a sealed post reaches the wapp door as words for a holder, and as a '
      'sealed row for anyone else', () async {
    join('X1BEA', bea.d, 120);
    await XprsGroupRead.instance.tend();
    XprsArchive.instance.keyResolver = (c) =>
        keys[c] == null ? null : Uint8List.fromList(HEX.decode(keys[c]!));
    final rows = <Map<String, dynamic>>[];
    WappDelivery.onPublish = (topic, row) => rows.add(row);
    addTearDown(() => WappDelivery.onPublish = null);
    final post = xprsBuildDirect(
      head: XprsPacket.parse('t:message f:X1BEA d:$g ts:${at(5)}')!,
      text: 'lunch on sunday',
      private: true,
      recipientKeyHex: XprsGroupRead.instance.currentPubHex(g),
      signingKey: bea.d,
    ).packets.single;

    WappDelivery.instance.deliverPacket(post, bearer: 'lan', forUs: false);
    expect(rows.single['content'], 'lunch on sunday');
    expect(rows.single['title'], '#$g');
    expect(rows.single['sealed'], isTrue);
    expect(rows.single['id'], xprsIdentifier(post));

    // A station holding no reading key sees only that a sealed post passed.
    XprsGroupRead.instance.close();
    XprsGroupRead.instance.init('${tmp.path}/other.zx');
    rows.clear();
    WappDelivery.instance.deliverPacket(post, bearer: 'lan', forUs: false);
    expect(rows.where((r) => r['content'] != null), isEmpty);
  });

  // 10.7.1: a group is public until its admin says otherwise. Members are
  // told so with `nsec:-`; making it private hands out a key; public again
  // tells them `nsec:-` once more.
  test('public by default, private on the switch, public again', () async {
    XprsGroupRead.instance.close();
    XprsGroupRead.instance.init('${tmp.path}/pub.zx');
    XprsGroupRead.instance.autoTend = false;
    final fresh = XprsGroupKeys.instance.create(nick: 'Choir')!;
    final c = fresh.callsign;
    final cd = XprsGroupKeys.instance.scalarFor(c)!;
    keys[c] = NostrCrypto.decodeNpub(fresh.npub);
    final grant = xprsSign(
        XprsPacket.parse('t:moderate f:$c d:$c ts:${at(100)} grant:X1BEA')!, cd);
    XprsGroups.instance.offer(grant);
    XprsGroups.instance.offer(xprsSign(
        XprsPacket.parse('t:moderate f:X1BEA d:$c ts:${at(90)} '
            'r:${xprsIdentifier(grant)} accept:member')!,
        bea.d));
    String read(String wire) => xprsReadBody(XprsPacket.parse(wire)!,
                ownKey: bea.d, senderKeyHex: keys[c])
            .clear ??
        '';
    List<String> toBea() =>
        aired.where((w) => w.startsWith('t:message f:$c d:X1BEA ')).toList();

    expect(XprsGroupRead.instance.isPublic(c), isTrue);
    await XprsGroupRead.instance.tend();
    expect(toBea().map(read), ['nsec:-']);
    expect(XprsGroupRead.instance.currentPubHex(c), isNull);

    aired.clear();
    expect(XprsGroupRead.instance.setPrivate(c, true), isTrue);
    await XprsGroupRead.instance.tend();
    expect(read(toBea().single), startsWith('nsec:nsec1'));
    expect(XprsGroupRead.instance.currentPubHex(c), isNotNull);

    aired.clear();
    XprsGroupRead.instance.setPrivate(c, false);
    await XprsGroupRead.instance.tend();
    expect(toBea().map(read), ['nsec:-']);
  });

  test('a member told nsec:- knows the group is public', () {
    expect(XprsGroupRead.instance.takeKeyMessage(g, 'nsec:-'), isTrue);
    expect(XprsGroupRead.instance.isPublic(g), isTrue);
    final kp = NostrCrypto.generateKeyPair();
    XprsGroupRead.instance.takeKeyMessage(g, 'nsec:${kp.nsec}');
    expect(XprsGroupRead.instance.isPublic(g), isFalse);
  });

  // 10.4: a message is judged by its author's role when they wrote it. A
  // request to join, replayed after its author was let in, stays a request
  // for the admin, and is not a post.
  test('a request to join replayed after acceptance is still a request', () {
    XprsArchive.instance.keyResolver = (c) =>
        keys[c] == null ? null : Uint8List.fromList(HEX.decode(keys[c]!));
    final rows = <Map<String, dynamic>>[];
    WappDelivery.onPublish = (topic, row) => rows.add(row);
    addTearDown(() => WappDelivery.onPublish = null);
    WappEventBroker.instance.registerEngine('test');
    WappEventBroker.instance.subscribe('test', 'xprs.message');
    addTearDown(() => WappEventBroker.instance.unregisterEngine('test'));
    final ask = xprsSign(
        XprsPacket.parse('t:message f:X1CAI d:$g ts:${at(300)} m:may I join?')!,
        cai.d);
    join('X1CAI', cai.d, 200); // let in afterwards
    WappDelivery.instance.deliverPacket(ask, bearer: 'lan', forUs: false);
    expect(rows.single['request'], isTrue);
  });

  // Somebody outside is never told a group's mode; what they read tells
  // them, newest post first.
  test('an outsider learns public or private from what it reads', () {
    const other = 'X5OTHR';
    final r = XprsGroupRead.instance;
    expect(r.modeOf(other), isNull);
    r.noteSeen(other, sealed: false, tsMs: 100000);
    expect(r.isPublic(other), isTrue);
    r.noteSeen(other, sealed: true, tsMs: 50000);
    expect(r.isPublic(other), isTrue, reason: 'an older post changes nothing');
    r.noteSeen(other, sealed: true, tsMs: 200000);
    expect(r.modeOf(other), 'private');
    r.noteSeen(g, sealed: false, tsMs: 300000);
    expect(r.modeOf(g), 'private', reason: "the admin's own say stands");
  });

  test('a key message is taken only from a group, and only as nsec:', () {
    expect(XprsGroupRead.instance.takeKeyMessage('X1BEA', 'nsec:x'), isFalse);
    expect(XprsGroupRead.instance.takeKeyMessage(g, 'hello'), isFalse);
    expect(XprsGroupRead.instance.takeKeyMessage('X5ZZZZ', 'nsec:x'), isFalse,
        reason: 'a group this station knows nothing of');
    final kp = NostrCrypto.generateKeyPair();
    expect(XprsGroupRead.instance.takeKeyMessage(g, 'nsec:${kp.nsec}'), isTrue);
    expect(XprsGroupRead.instance.currentPubHex(g), kp.publicKeyHex);
  });
}
