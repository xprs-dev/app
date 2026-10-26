/// Claiming a board over the cable it was just flashed on (XPRS.md 11.9).
///
/// A freshly flashed station has no owner and asks for one on its local
/// bearers; the first signer who answers owns it. That leaves a window in
/// which anybody in earshot can take a board the person holding the cable
/// just flashed. The cable closes it: whoever holds it can already rewrite
/// the board, which is why 11.9 makes a reflash reclaim a station, so the
/// core that wrote the image also writes the owner, before the board has
/// asked anybody.
///
/// It uses nothing the firmware does not already have. Every published
/// image reads `cfg set <key> <value>` lines on its USB console (xprs_config
/// `xcfg_console`, gathered by the UI task), checks the shape of a key it is
/// handed (a USB line that lost bytes is refused, not saved), and keeps its
/// owner in exactly the keys an over-the-air claim writes (`pol_take_owner`):
/// `own1` the npub a command is verified against, `own1c` the callsign the
/// owner goes by, `own2`..`own4` cleared, because a claim replaces the list.
/// The station stops asking the moment `own1` is set (`pol_owned` reads the
/// config live).
///
/// Written against [SerialPort] alone, so it runs on whichever isolate holds
/// the port (a worker on Linux, the main isolate on Android) and is tested
/// with a fake.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'serial/serial_port.dart';

/// Who the board will belong to: the active profile.
class ConsoleOwner {
  final String npub;
  final String call;
  const ConsoleOwner(this.npub, this.call);

  /// What the console accepts for `own1c` (xprs_config key_shape_error): 4
  /// to 12 letters, digits and '-'. An issued callsign with a '/' is not
  /// one, and the station is then told the X1 the key derives instead,
  /// which names the same key (the station matches owners by key, never by
  /// the label: xauth owner_key).
  static bool callFits(String c) => RegExp(r'^[A-Za-z0-9-]{4,12}$').hasMatch(c);

  Map<String, Object> toMap() => {'npub': npub, 'call': call};
  static ConsoleOwner? fromMap(Object? m) {
    if (m is! Map) return null;
    final n = m['npub'] as String? ?? '';
    final c = m['call'] as String? ?? '';
    if (!n.startsWith('npub1') || n.length != 63 || !callFits(c)) return null;
    return ConsoleOwner(n, c);
  }
}

/// What the claim came to.
class ConsoleClaim {
  /// The station's own callsign, from its boot banner; empty when the
  /// banner went by before the port was listening.
  final String station;
  final bool ok;

  /// It already belonged to this owner (a reflash without a wipe).
  final bool already;
  final String why;
  const ConsoleClaim({this.station = '', this.ok = false, this.already = false, this.why = ''});

  Map<String, Object> toMap() => {'station': station, 'ok': ok, 'already': already, 'why': why};
}

/// Talk to the console of a board that is booting on [port], and make it
/// [owner]'s. Never throws: the image is written whatever happens here, and
/// a board that could not be claimed still asks to be, over the air.
Future<ConsoleClaim> claimOverConsole(
  SerialPort port,
  ConsoleOwner owner, {
  bool Function()? cancelled,
  int bootWaitMs = 15000,
  int answerMs = 2000,
  Future<void> Function(int ms)? sleep,
  void Function(String line)? log,
}) async {
  final c = _Console(port, cancelled ?? () => false,
      sleep ?? (ms) => Future<void>.delayed(Duration(milliseconds: ms)), answerMs, log ?? (_) {});
  try {
    return await c.claim(owner, bootWaitMs);
  } catch (e) {
    return ConsoleClaim(station: c.station, why: '$e');
  }
}

class _Console {
  final SerialPort port;
  final bool Function() cancelled;
  final Future<void> Function(int ms) sleep;
  final int answerMs;
  final void Function(String) _log;
  final int _t0 = DateTime.now().millisecondsSinceEpoch;
  _Console(this.port, this.cancelled, this.sleep, this.answerMs, this._log);

  /// One line for the app log, with the time since the claim began: what
  /// a slow or failed claim is diagnosed from.
  void log(String what) =>
      _log('flash: console +${DateTime.now().millisecondsSinceEpoch - _t0} ms $what');

  /// What was read since the last command went out, as text, its newest
  /// 8 KB: a boot log runs to tens of KB, and this is scanned per read on
  /// whichever isolate holds the port (the main one on Android).
  String _seen = '';
  String station = '';

  void _take(Uint8List got) {
    _seen += latin1.decode(got);
    _learnStation();
    if (_seen.length > 8192) _seen = _seen.substring(_seen.length - 8192);
  }

  static final _bannerCall = RegExp(r'callsign: ([A-Z0-9][A-Z0-9-]{3,11})');
  static final _stationUp = RegExp(r'XPRS station ([A-Z0-9][A-Z0-9-]{3,11})');

  Future<ConsoleClaim> claim(ConsoleOwner owner, int bootWaitMs) async {
    // The ROM loader may have raised the line rate; the firmware's console
    // runs at 115200 (ignored on a native USB CDC).
    await port.setBaud(115200);

    // Wait for the firmware, not the ROM: the app says "XPRS station X..."
    // once it is up, and its console task reads lines from then on. A
    // missed banner is not fatal; the first `cfg get` answers either way.
    await _pump(bootWaitMs, until: () => _stationUp.hasMatch(_seen));
    log(_stationUp.hasMatch(_seen) ? 'firmware up as $station' : 'no banner seen');
    await sleep(800);

    // Is anybody listening, and whose is it now?
    final now = await _ask('cfg get own1', RegExp(r'own1=(\S*)'), tries: 6);
    if (now == null) {
      return ConsoleClaim(station: station, why: 'the board did not answer on its console');
    }
    final mine = now.group(1) == owner.npub;
    if (!mine) {
      final set = await _ask('cfg set own1 ${owner.npub}',
          RegExp('own1=${RegExp.escape(owner.npub)} \\(saved\\)'), tries: 3);
      if (set == null) return ConsoleClaim(station: station, why: 'the board did not take the key');
    }
    final setc = await _ask('cfg set own1c ${owner.call}',
        RegExp('own1c=${RegExp.escape(owner.call)} \\(saved\\)'), tries: 3);
    if (setc == null) return ConsoleClaim(station: station, why: 'the board did not take the callsign');
    if (!mine) {
      // A claim replaces the list (11.9), as pol_take_owner does.
      for (final k in ['own2', 'own3', 'own4']) {
        await _ask('cfg del $k', RegExp('$k cleared'), tries: 2);
      }
    }
    // Read back what it holds now: the answer is the proof.
    final back = await _ask('cfg get own1', RegExp(r'own1=(\S*)'), tries: 3);
    if (back?.group(1) != owner.npub) {
      return ConsoleClaim(station: station, why: 'the board did not keep the key');
    }
    return ConsoleClaim(station: station, ok: true, already: mine);
  }

  void _learnStation() {
    if (station.isNotEmpty) return;
    final m = _stationUp.firstMatch(_seen) ?? _bannerCall.firstMatch(_seen);
    if (m != null) station = m.group(1)!;
  }

  /// Send [line] and wait for [answer]; again up to [tries] times.
  Future<RegExpMatch?> _ask(String line, RegExp answer, {int tries = 3}) async {
    for (var i = 0; i < tries; i++) {
      _seen = '';
      await _send(line);
      RegExpMatch? hit;
      await _pump(answerMs, until: () {
        hit = answer.firstMatch(_seen);
        return hit != null;
      });
      if (hit != null) {
        log('${line.split(' ').take(3).join(' ')}: answered${i > 0 ? ' on try ${i + 1}' : ''}');
        return hit;
      }
    }
    log('${line.split(' ').take(3).join(' ')}: no answer after $tries tries');
    return null;
  }

  /// A console line, a few bytes at a time: an older image reads its
  /// console a character per UI tick, and the USB-JTAG ring drops the tail
  /// of a line written in one go.
  Future<void> _send(String line) async {
    final b = utf8.encode('$line\n');
    for (var o = 0; o < b.length; o += 8) {
      if (cancelled()) throw const SerialException('stopped');
      await port.write(Uint8List.fromList(b.sublist(o, o + 8 > b.length ? b.length : o + 8)));
      await sleep(15);
    }
  }

  /// Read for up to [ms], stopping early when [until] says so. A port that
  /// vanished (a native USB board re-enumerates on reset) is opened again.
  Future<void> _pump(int ms, {required bool Function() until}) async {
    final end = DateTime.now().millisecondsSinceEpoch + ms;
    while (DateTime.now().millisecondsSinceEpoch < end) {
      if (cancelled()) throw const SerialException('stopped');
      Uint8List got;
      try {
        got = await port.read(512, 100);
      } on SerialException catch (e) {
        log('port: $e, opening it again');
        await _reopen(end);
        continue;
      }
      if (got.isNotEmpty) {
        _take(got);
        if (until()) return;
      }
    }
  }

  Future<void> _reopen(int end) async {
    try {
      await port.close();
    } catch (_) {}
    while (DateTime.now().millisecondsSinceEpoch < end) {
      await sleep(300);
      try {
        await port.open(115200);
        return;
      } on SerialException {
        // Not back yet.
      }
    }
    throw const SerialException('the board did not come back after the reset');
  }
}
