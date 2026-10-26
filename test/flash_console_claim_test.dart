// The cable claim (lib/services/flash/station_console.dart): a board that
// was just flashed is made the active profile's over its USB console, with
// the `cfg` lines every published image reads (xprs_config xcfg_console).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/flash/serial/serial_port.dart';
import 'package:xprs/services/flash/station_console.dart';

const npub = 'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f00';

/// A booting station's console: a banner, then `cfg` lines answered the
/// way xcfg_console answers them.
class FakeConsole implements SerialPort {
  final Map<String, String> cfg;
  final List<String> lines = [];
  String banner;
  bool silent;
  int refuseSets;          // answer this many `cfg set own1` as refused
  int vanishReads;         // throw on this many reads (a re-enumeration)
  int reopens = 0;
  bool _open = true;
  final List<int> _rx = [];
  String _line = '';

  FakeConsole({Map<String, String>? cfg, this.banner = '', this.silent = false,
      this.refuseSets = 0, this.vanishReads = 0})
      : cfg = cfg ?? {} {
    _rx.addAll(utf8.encode(banner));
  }

  void _say(String s) => _rx.addAll(latin1.encode('$s\n'));

  void _line_(String l) {
    lines.add(l);
    if (silent) return;
    final w = l.split(' ');
    if (w.length >= 3 && w[1] == 'get') {
      _say('${w[2]}=${cfg[w[2]] ?? ''}');
    } else if (w.length >= 4 && w[1] == 'set') {
      if (w[2] == 'own1' && refuseSets > 0) {
        refuseSets--;
        _say('cfg set own1: refused, an npub is 63 chars starting npub1');
        return;
      }
      cfg[w[2]] = w.sublist(3).join(' ');
      _say('${w[2]}=${cfg[w[2]]} (saved)');
    } else if (w.length >= 3 && w[1] == 'del') {
      cfg[w[2]] = '';
      _say('${w[2]} cleared (saved)');
    }
  }

  @override
  Future<void> open(int baud) async {
    _open = true;
    reopens++;
  }

  @override
  Future<Uint8List> read(int max, int timeoutMs) async {
    if (!_open) throw const SerialException('port closed');
    if (vanishReads > 0) {
      vanishReads--;
      throw const SerialException('device unplugged');
    }
    if (_rx.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return Uint8List(0);
    }
    final n = _rx.length < max ? _rx.length : max;
    final out = Uint8List.fromList(_rx.sublist(0, n));
    _rx.removeRange(0, n);
    return out;
  }

  @override
  Future<void> write(Uint8List data) async {
    for (final c in data) {
      if (c == 10) {
        _line_(_line);
        _line = '';
      } else {
        _line += String.fromCharCode(c);
      }
    }
  }

  @override
  Future<void> close() async => _open = false;
  @override
  bool get isOpen => _open;
  @override
  Future<void> setDtr(bool on) async {}
  @override
  Future<void> setRts(bool on) async {}
  @override
  Future<void> setBaud(int baud) async {}
  @override
  Future<void> flushInput() async => _rx.clear();
  @override
  Future<Uint8List?> transact(Uint8List data, int timeoutMs) async => null;
  @override
  Future<List<Uint8List>?> transactMany(List<Uint8List> frames, int timeoutMs) async => null;
}

const boot = 'I (418) nostr_keys: npub: npub1sqs62k8rca4ag0k...\n'
    '\x1b[0;32mI (418) nostr_keys: NOSTR keys initialized - callsign: X3SQS6\x1b[0m\n'
    'I (978) xprs: esp32c3-mini XPRS station X3SQS6 — ESP-NOW + LAN + BLE5\n';

Future<ConsoleClaim> run(FakeConsole c, {String call = 'X1WATT'}) => claimOverConsole(
    c, ConsoleOwner(npub, call),
    bootWaitMs: 200, answerMs: 150, sleep: (_) async {});

void main() {
  test('the owner shape is what the console accepts', () {
    expect(npub.length, 63);
    expect(ConsoleOwner.callFits('X1WATT'), isTrue);
    expect(ConsoleOwner.callFits('EA/CT1ABC'), isFalse);
    expect(ConsoleOwner.fromMap({'npub': npub, 'call': 'X1WATT'})?.call, 'X1WATT');
    expect(ConsoleOwner.fromMap({'npub': 'npub1short', 'call': 'X1WATT'}), isNull);
  });

  test('a fresh board is made yours: own1, own1c, the rest of the list cleared', () async {
    final c = FakeConsole(banner: boot, cfg: {'own2': 'npub1other'});
    final r = await run(c);
    expect(r.ok, isTrue, reason: r.why);
    expect(r.already, isFalse);
    expect(r.station, 'X3SQS6');
    expect(c.cfg['own1'], npub);
    expect(c.cfg['own1c'], 'X1WATT');
    expect(c.cfg['own2'], '');
    expect(c.lines.where((l) => l.startsWith('cfg del')).length, 3);
    expect(c.lines.last, 'cfg get own1', reason: 'it reads back what it holds');
  });

  test('a board already yours keeps its co-owners and is not rewritten', () async {
    final c = FakeConsole(banner: boot, cfg: {'own1': npub, 'own1c': 'X1WATT', 'own2': 'npub1other'});
    final r = await run(c);
    expect(r.ok && r.already, isTrue, reason: r.why);
    expect(c.lines.any((l) => l.startsWith('cfg set own1 ')), isFalse);
    expect(c.cfg['own2'], 'npub1other');
  });

  test('a line the board refused (bytes lost on the USB line) is sent again', () async {
    final c = FakeConsole(banner: boot, refuseSets: 1);
    final r = await run(c);
    expect(r.ok, isTrue, reason: r.why);
    expect(c.lines.where((l) => l.startsWith('cfg set own1 ')).length, 2);
  });

  test('a port that vanished on the reset is opened again', () async {
    final c = FakeConsole(banner: boot, vanishReads: 1);
    final r = await run(c);
    expect(r.ok, isTrue, reason: r.why);
    expect(c.reopens, 1);
  });

  test('a missed banner still claims, with no station name', () async {
    final c = FakeConsole();
    final r = await run(c);
    expect(r.ok, isTrue, reason: r.why);
    expect(r.station, '');
  });

  test('a silent console is reported, never thrown', () async {
    final c = FakeConsole(banner: boot, silent: true);
    final r = await run(c);
    expect(r.ok, isFalse);
    expect(r.station, 'X3SQS6');
    expect(r.why, contains('did not answer'));
  });
}
