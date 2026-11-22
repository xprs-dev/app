// Who may call the remote-control API: this device always, the local
// network only when its owner opened it and the caller has the key, a web
// page never.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/remote_api_access.dart';

void main() {
  const key = 'abcdefghjkmnpqrstuvw';
  bool ask(String peer,
          {String? host = '192.168.1.20',
          bool browser = false,
          bool lan = true,
          String given = key}) =>
      remoteApiAdmits(
          peer: peer, host: host, browser: browser, lanOpen: lan, key: key, given: given);

  test('this device, as before', () {
    expect(ask('127.0.0.1', host: '127.0.0.1', lan: false, given: ''), isTrue);
    expect(ask('127.0.0.1', host: 'localhost', lan: false, given: ''), isTrue);
    expect(ask('127.0.0.1', host: 'evil.example', lan: false, given: ''), isFalse,
        reason: 'a page that rebound its name to this device');
    expect(ask('127.0.0.1', host: '127.0.0.1', browser: true), isFalse);
  });

  test('the local network: closed unless opened, and then only with the key', () {
    expect(ask('192.168.1.7', lan: false), isFalse);
    expect(ask('192.168.1.7'), isTrue);
    expect(ask('10.0.0.3'), isTrue);
    expect(ask('192.168.1.7', given: ''), isFalse);
    expect(ask('192.168.1.7', given: 'abcdefghjkmnpqrstuvx'), isFalse);
    expect(ask('192.168.1.7', browser: true), isFalse);
    expect(ask('8.8.8.8'), isFalse, reason: 'not a private address');
    expect(
        remoteApiAdmits(
            peer: '192.168.1.7', host: null, browser: false, lanOpen: true, key: '', given: ''),
        isFalse,
        reason: 'no key set is no key matched');
  });

  test('a key is twenty characters with no look-alikes', () {
    final k = newRemoteApiKey(Random(1));
    expect(k.length, 20);
    expect(RegExp(r'^[a-hj-km-np-z2-9]+$').hasMatch(k), isTrue);
  });
}
