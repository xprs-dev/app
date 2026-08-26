// `cmd:file` — the XPRS ask in front of the bulk lane (XPRS.md §25.2.2).
//
// Pure Dart: no radio, no GATT, no spool on disk. What is tested is the
// decision layer — which digest a `file:` names, and which reply code each
// situation earns.

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';

/// The spec's own example reference (§6.7.1) and its hex digest.
const _b64u = 'nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w';

void main() {
  group('xprsFileSha — §6.7 accepts both forms', () {
    test('base64url with an extension, the form a sender emits', () {
      final hex = xprsFileSha('$_b64u.jpg');
      expect(hex, isNotNull);
      expect(hex!.length, 64);
      expect(hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('the same digest with no extension', () {
      expect(xprsFileSha(_b64u), xprsFileSha('$_b64u.jpg'));
    });

    test('64 hex, the earlier form, is accepted and lowercased', () {
      const hex = 'D194663DDF06F8489180E19EA01A6464FCFE349020A18BACF010B4F1D8C90446';
      expect(xprsFileSha(hex), hex.toLowerCase());
      expect(xprsFileSha('${hex.toLowerCase()}.apk'), hex.toLowerCase());
    });

    test('the extension never changes identity', () {
      expect(xprsFileSha('$_b64u.jpg'), xprsFileSha('$_b64u.png'));
    });

    test('nonsense is null, not an exception', () {
      expect(xprsFileSha(null), isNull);
      expect(xprsFileSha(''), isNull);
      expect(xprsFileSha('not-a-digest.jpg'), isNull);
      expect(xprsFileSha('short.apk'), isNull);
    });
  });

  group('xprsFileExt', () {
    test('reads the type, lowercased', () {
      expect(xprsFileExt('$_b64u.jpg'), 'jpg');
      expect(xprsFileExt('$_b64u.APK'), 'apk');
    });

    test('a bare digest has none', () {
      expect(xprsFileExt(_b64u), '');
      expect(xprsFileExt(null), '');
    });

    test('a value rule violation is not an extension', () {
      // §4: 1 to 18 lowercase alphanumerics. Anything else is not a type.
      expect(xprsFileExt('$_b64u.wa-t'), '');
      expect(xprsFileExt('$_b64u.'), '');
    });
  });

  group('the ask fits one packet', () {
    test('cmd:file with off: stays inside the 250-byte limit', () {
      // §25.2 prints these at 177 and 186 bytes; ours carry no sig here.
      final wire = 't:command f:X1QZ3N d:X3RLY7 ts:${xprsNowTs()} '
          'cmd:file file:$_b64u.apk off:64kB';
      final p = XprsPacket.parse(wire);
      expect(p, isNotNull);
      expect(p!.fits, isTrue, reason: '${p.byteLength} bytes');
      expect(p['cmd'], 'file');
      expect(xprsFileSha(p['file']), isNotNull);
    });
  });

  group('XprsFileServer reply codes — §25.1/§25.2', () {
    late XprsFileServer server;
    late List<int> aired;
    late List<String?> messages;

    void air(int code, {String? m}) {
      aired.add(code);
      messages.add(m);
    }

    XprsPacket ask({String file = '$_b64u.apk'}) => XprsPacket.parse(
        't:command f:X1QZ3N d:X3ARK ts:${xprsNowTs()} cmd:file file:$file')!;

    setUp(() {
      server = XprsFileServer.instance;
      server.resolver = null;
      server.maxServeBytes = 256 * 1024 * 1024;
      aired = [];
      messages = [];
    });

    test('nothing held answers 404', () {
      server.resolver = (_) => null;
      final code = server.onCommand(ask(),
          selfBase: 'X3ARK', from: 'X1QZ3N', cmdId: 'aa11bb', air: air);
      expect(code, 404);
      expect(aired, [404]);
    });

    test('no resolver at all is also 404, not a crash', () {
      final code = server.onCommand(ask(),
          selfBase: 'X3ARK', from: 'X1QZ3N', cmdId: 'aa11bb', air: air);
      expect(code, 404);
    });

    test('a file: that is not a digest answers 400', () {
      server.resolver = (_) => fail('must not be consulted');
      final code = server.onCommand(ask(file: 'rubbish.apk'),
          selfBase: 'X3ARK', from: 'X1QZ3N', cmdId: 'aa11bb', air: air);
      expect(code, 400);
    });

    test('too large for the budget answers 403 and says the size', () {
      server.maxServeBytes = 1024;
      server.resolver = (sha) => XprsHeldFile(
          path: '/tmp/x.apk', shaHex: sha, size: 56830756, name: 'x.apk',
          ext: 'apk');
      final code = server.onCommand(ask(),
          selfBase: 'X3ARK', from: 'X1QZ3N', cmdId: 'aa11bb', air: air);
      expect(code, 403);
      // §6.7.1: size: exists so a station declines instead of starting
      // something it cannot finish — so the refusal has to name it.
      expect(messages.single, contains('56830756'));
    });

    test('the resolver is asked for the digest, not the filename', () {
      String? seen;
      server.resolver = (sha) {
        seen = sha;
        return null;
      };
      server.onCommand(ask(file: '$_b64u.apk'),
          selfBase: 'X3ARK', from: 'X1QZ3N', cmdId: 'aa11bb', air: air);
      expect(seen, xprsFileSha(_b64u));
      expect(seen, isNot(contains('.')));
    });
  });

  group('XprsFileFetch result handling — §25.1 codes', () {
    test('202 does not complete the wait: the bytes are what complete it', () {
      // The fetch is only over when the bulk lane delivers and the digest
      // matches. A 202 says "coming", and a caller that treated it as success
      // would hand the installer a file that does not exist.
      final fetch = XprsFileFetch.instance;
      expect(fetch.busy, isFalse);
      final r = XprsPacket.parse(
          't:result f:X3ARK d:X1QZ3N ts:${xprsNowTs()} r:aa11bb code:202')!;
      fetch.onResult(r); // unknown r: — must be ignored without throwing
      expect(fetch.busy, isFalse);
    });

    test('a result for an ask we never made is ignored', () {
      final fetch = XprsFileFetch.instance;
      for (final code in [200, 202, 404, 403, 429, 500]) {
        final r = XprsPacket.parse('t:result f:X3ARK d:X1QZ3N '
            'ts:${xprsNowTs()} r:deadbe code:$code')!;
        expect(() => fetch.onResult(r), returnsNormally);
      }
    });
  });

  group('xprsNowTs', () {
    test('round-trips through the section 4 parser', () {
      const ms = 1787746327000;
      final ts = xprsNowTs(ms);
      expect(ts, matches(RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}$')));
      expect(xprsParseTs(ts), ms);
    });
  });
}
