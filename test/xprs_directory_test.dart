/*
 * The directory archivers exchange (XPRS.md 12.9): the XDIR1 listing, its
 * announcement, the pointers a consumer keeps, and who a miss names first.
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show XprsCrypto;
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_directory.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';

int _ts(String s) => xprsParseTs(s)!;

void main() {

  group('the listing', () {
    test('compose: sorted by callsign, one line each, the freshest time wins', () {
      final text = XprsDirectory.compose([
        XprsDirectoryEntry('X1QZ3N', _ts('2026-08-17_14:05:02')),
        XprsDirectoryEntry('CT1ABC-9', _ts('2026-08-17_13:40:11')),
        XprsDirectoryEntry('X1BOA3', _ts('2026-08-17_14:02:36')),
        XprsDirectoryEntry('X1BOA3', _ts('2026-08-17_13:00:00')),
      ]);
      expect(
          text,
          'XDIR1\n'
          'CT1ABC-9 2026-08-17_13:40:11\n'
          'X1BOA3 2026-08-17_14:02:36\n'
          'X1QZ3N 2026-08-17_14:05:02\n');
    });

    test('parse round-trips, refuses another kind of file, skips a bad line', () {
      final entries = [
        XprsDirectoryEntry('CT1ABC-9', _ts('2026-08-17_13:40:11')),
        XprsDirectoryEntry('X1BOA3', _ts('2026-08-17_14:02:36')),
      ];
      expect(XprsDirectory.parse(XprsDirectory.compose(entries)), entries);
      expect(XprsDirectory.parse('XFOLDER1\nX1BOA3 2026-08-17_14:02:36\n'), isNull);
      expect(XprsDirectory.parse(''), isNull);
      expect(
          XprsDirectory.parse('XDIR1\nX1BOA3 not-a-time\n\nX1QZ3N 2026-08-17_14:05:02\n'),
          [XprsDirectoryEntry('X1QZ3N', _ts('2026-08-17_14:05:02'))]);
    });

    test('the digest is the identity, and the reference is 7.7\'s with .xdir', () {
      final a = XprsDirectory.compose([XprsDirectoryEntry('X1BOA3', _ts('2026-08-17_14:02:36'))]);
      final b = XprsDirectory.compose([XprsDirectoryEntry('X1BOA3', _ts('2026-08-17_14:02:36'))]);
      expect(XprsDirectory.shaOf(a), XprsDirectory.shaOf(b));
      final ref = XprsDirectory.refOf(XprsDirectory.shaOf(a))!;
      expect(ref, matches(RegExp(r'^[A-Za-z0-9_-]{43}\.xdir$')));
      expect(XprsDirectory.shaOfRef(ref), XprsDirectory.shaOf(a));
      final p = XprsPacket.parse('t:service f:X3ARC1 serve:archive count:212 file:$ref')!;
      expect(XprsDirectory.announces(p), isTrue);
      expect(XprsDirectory.announces(XprsPacket.parse('t:service f:X3ARC1 serve:relay file:$ref')!),
          isFalse, reason: 'not an archiver');
      expect(XprsDirectory.announces(XprsPacket.parse('t:service f:X3ARC1 serve:archive')!), isFalse,
          reason: 'no file: a small station omits it and the ask-form carries the load');
    });
  });

  group('pointers in the gossip table', () {
    late Directory tmp;
    final g = XprsGossip.instance;
    final now = DateTime.now().millisecondsSinceEpoch;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xprsdir-gossip');
      g.init('${tmp.path}/gossip.zx');
      g.debugReset();
    });
    tearDown(() {
      XprsGossip.directoryMaxRows = 50000;
      g.close();
      tmp.deleteSync(recursive: true);
    });

    test('keepersOf: the archiver with the freshest hearing first; never the content', () {
      g.notePointers('X3ARC1', [('X1AAAA', now - 60000), ('X1BBBB', now - 120000)]);
      g.notePointers('X3ARC2', [('X1AAAA', now)]);
      expect(g.keepersOf('X1AAAA'), ['X3ARC2', 'X3ARC1']);
      expect(g.keepersOf('X1BBBB'), ['X3ARC1']);
      expect(g.keepersOf('X1CCCC'), isEmpty);
      expect(g.statusJson()['pointers'], 3);
      // A later listing from the same archiver only moves a time forward.
      g.notePointers('X3ARC1', [('X1AAAA', now + 5000)]);
      expect(g.keepersOf('X1AAAA'), ['X3ARC1', 'X3ARC2']);
      expect(g.statusJson()['pointers'], 3);
    });

    test('the table is bounded: the stalest pointers leave', () {
      XprsGossip.directoryMaxRows = 3;
      g.notePointers('X3ARC1', [('X1AAAA', now - 60000), ('X1BBBB', now - 120000)]);
      g.notePointers('X3ARC2', [('X1CCCC', now), ('X1DDDD', now - 1000)]);
      expect(g.statusJson()['pointers'], 3);
      expect(g.keepersOf('X1BBBB'), isEmpty, reason: 'the stalest went');
      expect(g.keepersOf('X1CCCC'), ['X3ARC2']);
      // One listing larger than the whole cap is cut to its freshest lines.
      g.notePointers('X3ARC3', [for (var i = 0; i < 10; i++) ('X1E$i', now - i * 1000)]);
      expect(g.statusJson()['pointers'], 3);
      expect(g.keepersOf('X1E0'), ['X3ARC3']);
      expect(g.keepersOf('X1E9'), isEmpty);
    });
  });

  group('the announcer', () {
    final key = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    const t0 = 1760000000000;

    tearDown(() => XprsDirectoryAnnouncer.instance.debugReset());

    test('a signed t:service naming the file, only when the listing changed, every ten minutes',
        () async {
      final ann = XprsDirectoryAnnouncer.instance..debugReset();
      var entries = [const XprsDirectoryEntry('X1AAAA', t0)];
      final stored = <(String sha, String? previous)>[];
      final aired = <String>[];
      final deposited = <String>[];
      ann
        ..isPublic = (() => true)
        ..entries = (() => entries)
        ..count = (() => 212)
        ..selfCallsign = (() => 'X3ARC1')
        ..signingKey = (() => key)
        ..serve = (() => 'archive,files')
        ..dial = (() => 'arc1.example.org')
        ..room = (() => null)
        ..store = ((bytes, sha, previous) => stored.add((sha, previous)))
        ..air = ((w) async => aired.add(w))
        ..deposit = deposited.add;

      final wire = await ann.tick(nowMs: t0);
      expect(wire, isNotNull);
      final p = XprsPacket.parse(wire!)!;
      expect(p.type, 'service');
      expect(p['f'], 'X3ARC1');
      expect(p['serve'], 'archive,files');
      expect(p['count'], '212', reason: 'records held, never callsigns (13.0.1)');
      expect(p['dial'], 'arc1.example.org');
      expect(p.has('room'), isFalse);
      expect(p['ts'], xprsNowTs(t0));
      expect(xprsVerify(p, XprsCrypto.publicKeyXOnly(key)), XprsSigState.verified);
      expect(XprsDirectory.announces(p), isTrue);
      final sha = XprsDirectory.shaOf(XprsDirectory.compose(entries));
      expect(XprsDirectory.shaOfRef(p['file']), sha);
      expect(stored, [(sha, null)]);
      expect(aired, [wire]);
      expect(deposited, [wire]);

      // Unchanged: nothing goes out, however long it has been.
      expect(await ann.tick(nowMs: t0 + 11 * 60000), isNull);
      expect(ann.unchanged, 1);
      // Changed, but inside ten minutes of the last look: not yet.
      entries = [...entries, const XprsDirectoryEntry('X1BBBB', t0 + 1000)];
      expect(await ann.tick(nowMs: t0 + 12 * 60000), isNull);
      // Due again: the new listing replaces the old one.
      final second = await ann.tick(nowMs: t0 + 22 * 60000);
      expect(second, isNotNull);
      expect(stored, hasLength(2));
      expect(stored.last.$2, sha, reason: 'the previous listing is dropped');
      expect(ann.published, 2);
      // Not a public archiver: a directory is nobody's business.
      ann.isPublic = () => false;
      entries = [const XprsDirectoryEntry('X1CCCC', t0)];
      expect(await ann.tick(nowMs: t0 + 60 * 60000, force: true), isNull);
    });
  });

  group('the consumer', () {
    late Directory tmp;
    final g = XprsGossip.instance;
    const t0 = 1760000000000;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xprsdir-consume');
      g.init('${tmp.path}/gossip.zx');
      g.debugReset();
      XprsDirectoryConsumer.instance.debugReset();
    });
    tearDown(() {
      XprsDirectoryConsumer.instance.debugReset();
      g.close();
      tmp.deleteSync(recursive: true);
    });

    test('fetches once per (archiver, digest), from a named archiver only, keeps pointers', () async {
      final c = XprsDirectoryConsumer.instance;
      final text = XprsDirectory.compose([const XprsDirectoryEntry('X1AAAA', t0)]);
      final ref = XprsDirectory.refOf(XprsDirectory.shaOf(text))!;
      final fetched = <String>[];
      c
        ..named = (() => ['X3ARC1'])
        ..fetchText = ((archiver, sha) async {
          fetched.add('$archiver|$sha');
          return text;
        });
      final ann = XprsPacket.parse(
          't:service f:X3ARC1 serve:archive count:5 file:$ref ts:2026-08-17_15:00:00')!;
      c.offer(ann);
      c.offer(ann); // the same announcement again, as every beacon is
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fetched, hasLength(1), reason: 'one fetch per (archiver, digest)');
      expect(c.fetched, 1);
      expect(g.keepersOf('X1AAAA'), ['X3ARC1'], reason: 'the default store is the gossip table');

      // An archiver this station does not lean on: its listing is not read.
      c.offer(XprsPacket.parse('t:service f:X3OTHR serve:archive file:$ref')!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fetched, hasLength(1));
      expect(c.ignored, 1);

      // Bytes that do not hash to the reference feed nothing.
      c.fetchText = (a, s) async => 'XDIR1\nX1ZZZZ 2026-01-01_00:00:00\n';
      final other = XprsDirectory.refOf(XprsDirectory.shaOf('something else'))!;
      c.offer(XprsPacket.parse('t:service f:X3ARC1 serve:archive file:$other')!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.failed, 1);
      expect(g.keepersOf('X1ZZZZ'), isEmpty);
    });
  });

  group('the archive\'s lines and the served visitors', () {
    late Directory tmp;
    final a = XprsArchive.instance;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xprsdir-archive');
      a
        ..selfCallsign = 'X3SELF'
        ..keyResolver = null
        ..maxBytes = 500 * 1024 * 1024
        ..maxAgeDays = 3650
        ..init('${tmp.path}/archive.zx');
    });
    tearDown(() {
      a.close();
      tmp.deleteSync(recursive: true);
    });

    test('directoryEntries: every author with its freshest ts, plus the served visitors', () {
      void put(String w) => a.admit(XprsPacket.parse(w)!, bearer: 'lan', nowMs: 1000);
      put('t:status f:X1AAAA ts:2026-10-15_10:00:00 m:one');
      put('t:status f:X1AAAA ts:2026-10-15_11:00:00 m:two');
      put('t:status f:X1BBBB ts:2026-10-15_09:00:00 m:three');
      a.flush(nowMs: 2000);
      final seen = _ts('2026-10-15_12:00:00');
      a.noteServed('X1VIS', nowMs: seen);
      expect(a.directoryEntries(), [
        XprsDirectoryEntry('X1AAAA', _ts('2026-10-15_11:00:00')),
        XprsDirectoryEntry('X1BBBB', _ts('2026-10-15_09:00:00')),
        XprsDirectoryEntry('X1VIS', seen),
      ]);
      expect(a.directoryEntries(limit: 2), hasLength(2));
    });

    test('a served visitor is held here until it declares; it counts as cared for', () {
      expect(a.servesVisitor('X1VIS'), isFalse);
      expect(a.holdersFor('X1VIS'), isEmpty);
      a.noteServed('X1VIS', nowMs: 5000);
      expect(a.servesVisitor('X1VIS'), isTrue);
      expect(a.servesVisitor('X1VIS-2'), isTrue, reason: 'a device of the same station');
      expect(a.holdersFor('X1VIS'), ['X3SELF']);
      expect(a.hasActiveDecl('X1VIS'), isTrue);
      expect(a.caredFor(), 1);
      a.touchServed('X1VIS', nowMs: 9000);
      a.touchServed('X1OTHR', nowMs: 9000);
      expect(a.servedVisitors().single.lastMs, 9000);
      expect(a.servedVisitors().single.sinceMs, 5000);
      expect(a.servesVisitor('X1OTHR'), isFalse, reason: 'a touch is not an offer');
      // The visitor's own declaration replaces the offer (the recipient's word).
      final key = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
      a.keyResolver = (c) => c == 'X1VIS' ? XprsCrypto.publicKeyXOnly(key) : null;
      final decl = xprsSign(
          XprsPacket.parse('t:mailbox f:X1VIS ts:2026-10-15_12:00:00 hold:X3ELSE,X3SELF')!, key);
      expect(a.recordMailboxDecl(decl), isTrue);
      expect(a.holdersFor('X1VIS'), ['X3ELSE', 'X3SELF']);
      expect(a.caredFor(), 1, reason: 'one station, declared and served, counted once');
      a.forgetServed('X1VIS');
      expect(a.servesVisitor('X1VIS'), isFalse);
      // Survives a reopen: the served set is read back from the table.
      a.noteServed('X1AGAIN', nowMs: 5000);
      a.close();
      a.init('${tmp.path}/archive.zx');
      expect(a.servesVisitor('X1AGAIN'), isTrue);
    });
  });
}
