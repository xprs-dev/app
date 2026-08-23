// What a pocket device is willing to write down.
//
// Measured on a phone with two stations in earshot: 89% of everything it
// archived was presence chatter and 3% was messages, at roughly twenty thousand
// sqlite writes an hour for rows nothing reads. The responder had already
// decided it would not serve those rows -- a `cmd:history` naming no `kind:`
// is answered from kXprsTalk -- so the archive was paying to store, prune and
// carry traffic it would never hand to anyone.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _self = 'X1A67X';

void main() {
  _countSemantics();
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> admitted;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance();
    XprsMonitor.instance.debugReset();
    // These tests are the POCKET case. The default resolves from the platform
    // and the suite runs on a desktop, where keeping the spool is right, so it
    // is stated rather than inherited.
    await PreferencesService.instanceSync!.setXprsKeepChatter(false);
    admitted = [];
    XprsArchive.instance.debugOnAdmit = (p) => admitted.add(p.type);
  });

  tearDown(() => XprsArchive.instance.debugOnAdmit = null);

  void heard(String wire) => XprsIngest.heard(XprsPacket.parse(wire)!,
      bearer: 'ble', selfCallsign: _self);

  test('a stranger\'s presence is not written down', () {
    heard('t:observation f:X3R8XX link:ble peers:4');
    heard('t:identity f:X3R8XX ts:2026-08-22_06:00:00 k:npub1zzz');
    heard('t:service f:X3R8XX serve:archive count:212');
    expect(admitted, isEmpty,
        reason: 'presence repeats forever and nothing reads it');
  });

  test("a stranger's conversation still is", () {
    heard('t:message f:X3R8XX ts:2026-08-22_06:00:00 scope:local m:hello');
    expect(admitted, ['message']);
  });

  test('presence addressed to US survives the filter', () {
    // The forUs bypass is what keeps our own mail safe whatever shape it takes.
    heard('t:observation f:X3R8XX d:$_self link:ble peers:4');
    expect(admitted, ['observation']);
  });

  test('our own conversation is kept, our own beacons are not', () {
    XprsIngest.own('t:message f:$_self ts:2026-08-22_06:00:00 m:said it',
        bearer: 'ble');
    XprsIngest.own('t:observation f:$_self link:ble peers:0', bearer: 'ble');
    expect(admitted, ['message'],
        reason: 'section 36.5 keeps our log, not our heartbeat');
  });

  test('a desktop archiver can still spool presence', () async {
    await PreferencesService.instanceSync!.setXprsKeepChatter(true);
    heard('t:observation f:X3R8XX link:ble peers:4');
    expect(admitted, ['observation'],
        reason: 'an indexer answering for somebody else wants the spool');
  });

  test('presence still reaches the live view either way', () {
    heard('t:observation f:X3R8XX link:ble peers:4');
    expect(XprsMonitor.instance.stations.containsKey('X3R8XX'), isTrue,
        reason: 'the graph and the station list read the monitor, not sqlite');
  });
}

// `count:` means records on an archiver's announcement and files on a folder
// listing (XPRS.md 24.0.1 and 6.7.3). Reading the second as the first would
// have a folder announcement move a station's news counter and trigger a
// metered history replay for nothing.
void _countSemantics() {
  test('count: is read from an archive announcement, not a folder listing', () {
    const call = 'X3ARC1';
    XprsMonitor.instance.offer(
        XprsPacket.parse('t:service f:$call serve:archive count:1234')!,
        bearer: 'ble', selfCallsign: _self);
    expect(XprsMonitor.instance.stations[call]?.count, 1234);

    XprsMonitor.instance.offer(
        XprsPacket.parse('t:file f:$call kind:folder count:34 file:abc.xfl')!,
        bearer: 'ble', selfCallsign: _self);
    expect(XprsMonitor.instance.stations[call]?.count, 1234,
        reason: 'a folder listing is not an archive size');
  });

  test('a station that says nothing has a null count, which is not zero', () {
    const call = 'X3QUIET';
    XprsMonitor.instance.offer(
        XprsPacket.parse('t:observation f:$call link:ble peers:2')!,
        bearer: 'ble', selfCallsign: _self);
    expect(XprsMonitor.instance.stations[call]?.count, isNull);
  });
}
