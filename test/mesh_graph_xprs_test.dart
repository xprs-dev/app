// XPRS stations heard over the air join the Mesh wapp's graph snapshot as
// kind:"xprs" nodes edged to self — and stay OUT of it by default, so the
// localOnly consumers (the Chat wapp's nearby list) never see them.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/reticulum/rns_service.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an XPRS beacon becomes a graph node with its stability account', () {
    XprsMonitor.instance.clear();
    final beacon = XprsPacket.parse(
        't:observation f:X3JS7Y link:ble peers:2 mail:3 uptime:26h lifetime:38day');
    expect(beacon, isNotNull);
    XprsMonitor.instance.offer(beacon!,
        bearer: 'ble', selfCallsign: 'X1TEST', rssi: -49);

    final snap = RnsService.instance.graphSnapshot(includeXprs: true);
    final nodes = (snap['nodes'] as List).cast<Map<String, dynamic>>();
    final st =
        nodes.where((n) => n['id'] == 'xprs:X3JS7Y').toList();
    expect(st, hasLength(1), reason: 'the station must appear exactly once');
    expect(st.first['kind'], 'xprs');
    expect(st.first['via'], 'ble');
    expect(st.first['xprs'], true);
    final meta = st.first['meta'] as Map;
    expect(meta['rssi'], -49);
    expect(meta['uptime'], '26h');
    expect(meta['lifetime'], '38day');
    expect(meta['mail'], 3);

    final edges = (snap['edges'] as List).cast<Map<String, dynamic>>();
    expect(
        edges.any((e) => e['to'] == 'xprs:X3JS7Y' && e['kind'] == 'xprs'), true,
        reason: 'the station is edged to self — it was heard HERE');

    // Default off: the same snapshot without the opt-in carries no xprs nodes.
    final plain = RnsService.instance.graphSnapshot();
    expect(
        (plain['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['kind'] == 'xprs'),
        false);

    // localOnly (the Chat nearby list) never sees them, even when asked.
    final local = RnsService.instance
        .graphSnapshot(localOnly: true, includeXprs: true);
    expect(
        (local['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['kind'] == 'xprs'),
        false);

    XprsMonitor.instance.clear();
  });

  test('a station that says serve:archive reads as an indexer', () {
    XprsMonitor.instance.clear();
    // Section 24's vocabulary. `archive` is one claim covering all of it:
    // keeping a spool, re-airing it on cmd:history, and holding mail for
    // stations that named this one. There is no separate `index`, `history`
    // or `mailbox` word -- a packet claiming those claims nothing, because
    // xprsServices drops anything section 24 does not define.
    final svc = XprsPacket.parse('t:service f:X3WWAJ '
        'serve:relay,archive count:212 ts:2026-08-17_15:00:00');
    XprsMonitor.instance
        .offer(svc!, bearer: 'lan', selfCallsign: 'X1TEST');

    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3WWAJ');
    expect((node['services'] as List), containsAll(['relay', 'archive']));
    expect((node['meta'] as Map)['role'], 'indexer',
        reason: 'serve:archive is the whole difference from a passing phone');
    expect((node['meta'] as Map)['count'], 212);

    // A service filter now SELECTS these stations instead of dropping them.
    final indexers = (RnsService.instance.graphSnapshot(
        includeXprs: true, service: 'archive')['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(indexers.any((n) => n['id'] == 'xprs:X3WWAJ'), true);
    final files = (RnsService.instance
            .graphSnapshot(includeXprs: true, service: 'files')['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(files.any((n) => n['id'] == 'xprs:X3WWAJ'), false,
        reason: 'it never claimed files');

    XprsMonitor.instance.clear();
  });

  test('serve:archive,super survives parsing and reads as a super-archiver',
      () {
    XprsMonitor.instance.clear();
    // The word is section 24 vocabulary and this device AIRS it (MeshService
    // puts `serve:archive,super` on both beacons when super-archiver mode is
    // on). It used to be missing from kXprsServices, so our own receiver threw
    // away a word our own transmitter sent, and nothing downstream could ever
    // answer "is this a super-archiver".
    expect(kXprsServices.contains('super'), true);
    final p = XprsPacket.parse('t:service f:X3SUPR serve:archive,super');
    expect(xprsServices(p!), ['archive', 'super']);
    // The whitelist still holds for everything else.
    expect(
        xprsServices(XprsPacket.parse('t:service f:X3SUPR serve:archive,bogus')!),
        ['archive']);

    XprsMonitor.instance.offer(p, bearer: 'lan', selfCallsign: 'X1TEST');
    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3SUPR');
    expect((node['services'] as List), containsAll(['archive', 'super']));
    expect((node['meta'] as Map)['role'], 'super-archiver');
    XprsMonitor.instance.clear();
  });

  test('the role filter buckets supers, archivers and normal nodes', () async {
    PreferencesService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance();
    XprsMonitor.instance.clear();
    void hear(String wire) => XprsMonitor.instance
        .offer(XprsPacket.parse(wire)!, bearer: 'lan', selfCallsign: 'X1TEST');
    hear('t:service f:X3SUPR serve:archive,super');
    hear('t:service f:X3ARCH serve:archive');
    hear('t:observation f:X3PHON link:lan peers:1');

    List<String> idsFor(String? role) => (RnsService.instance
            .graphSnapshot(includeXprs: true, role: role)['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .map((n) => n['id'] as String)
        .toList();

    // Each bucket answers a question the others do not, so assert what each
    // one EXCLUDES too -- a predicate that accidentally matches everything
    // passes every "contains" check ever written.
    expect(idsFor(null),
        containsAll(['xprs:X3SUPR', 'xprs:X3ARCH', 'xprs:X3PHON']));

    final supers = idsFor('super');
    expect(supers, contains('xprs:X3SUPR'));
    expect(supers, isNot(contains('xprs:X3ARCH')));
    expect(supers, isNot(contains('xprs:X3PHON')));

    // Disjoint on purpose: a super announces `archive,super`, so an archivers
    // bucket holding every super would answer nothing new.
    final archivers = idsFor('archive');
    expect(archivers, contains('xprs:X3ARCH'));
    expect(archivers, isNot(contains('xprs:X3SUPR')));
    expect(archivers, isNot(contains('xprs:X3PHON')));

    final normal = idsFor('normal');
    expect(normal, contains('xprs:X3PHON'));
    expect(normal, isNot(contains('xprs:X3SUPR')));
    expect(normal, isNot(contains('xprs:X3ARCH')));

    // Hubs and self are emitted before the filter and survive every bucket:
    // a role filter asks which of these CLAIMS to be a super, and a gateway
    // claims nothing.
    for (final r in [null, 'super', 'archive', 'normal']) {
      final nodes = (RnsService.instance
              .graphSnapshot(includeXprs: true, role: r)['nodes'] as List)
          .cast<Map<String, dynamic>>();
      expect(nodes.any((n) => n['kind'] == 'self'), true,
          reason: 'self is the centre the scene is built around ($r)');
    }
    XprsMonitor.instance.clear();
  });

  test('an operator-named super counts even with no beacon claim', () async {
    // The case the whole design turns on: a super reached only over the
    // internet is never heard on a radio, so it has no `serve:` list at all.
    // The device suffix must not hide it either (section 3.1).
    // resetForTest first: the singleton caches its SharedPreferences, so a
    // mock set after it exists would be read by nobody.
    PreferencesService.resetForTest();
    SharedPreferences.setMockInitialValues({
      'xprs.superArchivers': ['X3WWAJ'],
    });
    await PreferencesService.instance();
    XprsMonitor.instance.clear();
    XprsMonitor.instance.offer(
        XprsPacket.parse('t:service f:X3WWAJ-2 serve:archive')!,
        bearer: 'lan',
        selfCallsign: 'X1TEST');

    final supers = (RnsService.instance
            .graphSnapshot(includeXprs: true, role: 'super')['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .map((n) => n['id'] as String);
    // The node keeps the callsign it aired (suffix and all -- that IS the
    // device); what the suffix must not do is stop the match.
    expect(supers, contains('xprs:X3WWAJ-2'),
        reason: 'named by the operator, and the -2 suffix is the same station');

    // ...and it must NOT also show up under archivers.
    final archivers = (RnsService.instance
            .graphSnapshot(includeXprs: true, role: 'archive')['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .map((n) => n['id'] as String);
    expect(archivers, isNot(contains('xprs:X3WWAJ-2')));

    PreferencesService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance();
    XprsMonitor.instance.clear();
  });

  test('a station is badged by the spool\'s verdict, and a forgery sticks', () {
    XprsMonitor.instance.clear();
    final beacon =
        XprsPacket.parse('t:observation f:X3WWAJ link:lan peers:1');
    XprsMonitor.instance
        .offer(beacon!, bearer: 'lan', selfCallsign: 'X1TEST');

    Map meta() => ((RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
                as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((n) => n['id'] == 'xprs:X3WWAJ')['meta'] as Map);

    // Nothing judged yet says nothing — which is not the same as "unsigned".
    expect(meta().containsKey('sig'), false);

    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.verified);
    expect(meta()['sig'], 'verified');

    // One forgery outranks any number of good packets, and does not wash out.
    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.forged);
    XprsMonitor.instance.recordVerdict('X3WWAJ', XprsSigState.verified);
    expect(meta()['sig'], 'forged',
        reason: 'a later good packet must not clear a forgery');
    expect(meta()['sigForged'], 1);

    // A verdict for a station the air view never heard is not a sighting.
    XprsMonitor.instance.recordVerdict('X9GHOST', XprsSigState.verified);
    expect(
        (RnsService.instance.graphSnapshot(includeXprs: true)['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .any((n) => n['id'] == 'xprs:X9GHOST'),
        false);

    XprsMonitor.instance.clear();
  });

  test('hears: carries through to the snapshot, and a relayed copy does not '
      'count as directly heard', () {
    XprsMonitor.instance.clear();
    final beacon = XprsPacket.parse(
        't:observation f:X3WWAJ link:lan peers:3 hears:X1TEST,X1BOA3');
    XprsMonitor.instance
        .offer(beacon!, bearer: 'lan', selfCallsign: 'X1TEST');

    final meta = ((RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
                as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((n) => n['id'] == 'xprs:X3WWAJ')['meta'] as Map);
    expect(meta['hears'], ['X1TEST', 'X1BOA3'],
        reason: 'our own callsign in here is the station saying it hears us');
    expect(meta['peers'], 3);

    // A station known ONLY through a digipeater is not directly heard, so it
    // must never enter our own hears: list (section 10.6.3).
    final relayed =
        XprsPacket.parse('t:observation f:X5FAR1 link:lan via:X3WWAJ');
    XprsMonitor.instance
        .offer(relayed!, bearer: 'lan', selfCallsign: 'X1TEST');
    final direct = XprsMonitor.instance.directlyHeard();
    expect(direct, contains('X3WWAJ'));
    expect(direct, isNot(contains('X5FAR1')));

    XprsMonitor.instance.clear();
  });

  // ── Reachability and readings, the two things the node panel asks for ──

  test('a station heard on two bearers is reachable on both, not the last one',
      () {
    XprsMonitor.instance.clear();
    final p = XprsPacket.parse('t:observation f:X3DUAL link:lan peers:1')!;
    // Same station, two radios. Before bearers were a set, the second offer
    // simply overwrote the first and the station claimed only ESP-NOW -- so a
    // device you could reach two ways showed one, and the BLE5 legend chip
    // could read 0 with a BLE5 device on the canvas.
    XprsMonitor.instance.offer(p, bearer: 'ble', selfCallsign: 'X1TEST');
    XprsMonitor.instance.offer(p, bearer: 'espnow', selfCallsign: 'X1TEST');

    final st = XprsMonitor.instance.stations['X3DUAL']!;
    expect(st.bearers.keys, containsAll(['ble', 'espnow']));
    expect(st.bearer, 'espnow', reason: 'still the most recent, for one-word readers');

    final now = DateTime.now().millisecondsSinceEpoch;
    expect(st.bearersFresh(now, 600000), containsAll(['ble', 'espnow']));
    // Each bearer ages on its own clock: BLE5 going quiet is not the LAN
    // going quiet.
    st.bearers['ble'] = now - 900000;
    expect(st.bearersFresh(now, 600000), ['espnow']);

    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3DUAL');
    expect((node['meta'] as Map)['bearers'], contains('espnow'));
    XprsMonitor.instance.clear();
  });

  test('what a station measured reaches the panel, unit and all', () {
    XprsMonitor.instance.clear();
    final wx = XprsPacket.parse('t:observation f:X3WX01 link:lan '
        'temp:14.2C hum:78% batt:64% supply:solar')!;
    XprsMonitor.instance.offer(wx, bearer: 'lan', selfCallsign: 'X1TEST');

    final st = XprsMonitor.instance.stations['X3WX01']!;
    // The TEXT, never a parsed number: the unit is part of the value
    // (section 4.4), and 14.2 alone has lost what it measured.
    expect(st.readings['temp'], '14.2C');
    expect(st.readings['hum'], '78%');
    expect(st.readings['batt'], '64%');
    expect(st.readings['supply'], 'solar');

    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3WX01');
    expect(((node['meta'] as Map)['readings'] as Map)['temp'], '14.2C');
    XprsMonitor.instance.clear();
  });

  test('a station that measured nothing carries no readings key', () {
    XprsMonitor.instance.clear();
    final b = XprsPacket.parse('t:observation f:X3BARE link:lan peers:1')!;
    XprsMonitor.instance.offer(b, bearer: 'lan', selfCallsign: 'X1TEST');
    final node = (RnsService.instance.graphSnapshot(includeXprs: true)['nodes']
            as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == 'xprs:X3BARE');
    expect((node['meta'] as Map).containsKey('readings'), isFalse,
        reason: 'absent is not the same as empty; the panel shows no section');
    XprsMonitor.instance.clear();
  });
}
