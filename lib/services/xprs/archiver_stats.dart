/*
 * The archiver's daily log: what this device gave the network, day by day.
 *
 * The live counters (asks answered, mail handed over) live in memory and
 * start from zero at every launch, and the archive's counts are a snapshot.
 * Neither can draw "the last two weeks", which is what makes contributing
 * storage feel like something. This keeps ONE small row per day:
 *
 *   d      yyyy-mm-dd (local)
 *   ans    asks answered that day       (sum of counter deltas)
 *   ref    asks refused that day
 *   mail   held mail handed over that day
 *   own/fol/str/bytes/cared   the archive at the day's last sample
 *
 * Cost (docs/performance.md 8): one sample an hour on a Timer, plus one when
 * the Archiver page opens; a sample is a few counter reads and the archive's
 * counts table (no scan), and one preference write. At most [maxDays] rows.
 */
import 'dart:async';
import 'dart:convert';

import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_history_server.dart';
import 'xprs_mailbox.dart';

class ArchiverDay {
  ArchiverDay(this.d,
      {this.ans = 0,
      this.ref = 0,
      this.mail = 0,
      this.own = 0,
      this.fol = 0,
      this.str = 0,
      this.bytes = 0,
      this.cared = 0});

  final String d;
  int ans, ref, mail;
  int own, fol, str, bytes, cared;

  int get records => own + fol + str;

  Map<String, Object> toJson() => {
        'd': d,
        'ans': ans,
        'ref': ref,
        'mail': mail,
        'own': own,
        'fol': fol,
        'str': str,
        'bytes': bytes,
        'cared': cared,
      };

  static ArchiverDay? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = '${j['d'] ?? ''}';
    if (d.length != 10) return null;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ArchiverDay(d,
        ans: n('ans'),
        ref: n('ref'),
        mail: n('mail'),
        own: n('own'),
        fol: n('fol'),
        str: n('str'),
        bytes: n('bytes'),
        cared: n('cared'));
  }
}

/// One reading of the live counters and the archive.
typedef ArchiverReading = ({
  int answered,
  int refused,
  int mail,
  int own,
  int fol,
  int str,
  int bytes,
  int cared,
});

/// Fold [now] into [days]. [last] is the previous reading in THIS process
/// (null on the first): counters only ever grow inside a process, so a
/// reading below the last one means they were reset and counts whole.
/// Pure, so the tests drive it without timers.
List<ArchiverDay> foldArchiverReading(List<ArchiverDay> days,
    ArchiverReading now, ArchiverReading? last, String day,
    {int maxDays = ArchiverStats.maxDays}) {
  int delta(int cur, int? prev) =>
      prev == null || cur < prev ? cur : cur - prev;
  final out = List<ArchiverDay>.of(days);
  var today = out.isNotEmpty && out.last.d == day ? out.last : null;
  if (today == null) {
    today = ArchiverDay(day);
    out.add(today);
  }
  today
    ..ans += delta(now.answered, last?.answered)
    ..ref += delta(now.refused, last?.refused)
    ..mail += delta(now.mail, last?.mail)
    ..own = now.own
    ..fol = now.fol
    ..str = now.str
    ..bytes = now.bytes
    ..cared = now.cared;
  while (out.length > maxDays) {
    out.removeAt(0);
  }
  return out;
}

class ArchiverStats {
  ArchiverStats._();
  static final ArchiverStats instance = ArchiverStats._();

  static const int maxDays = 60;
  static const Duration every = Duration(hours: 1);

  Timer? _timer;
  ArchiverReading? _last;

  /// Start sampling. Idempotent. The first sample waits a few minutes so it
  /// does not land on the busy launch.
  void start() {
    if (_timer != null) return;
    _timer = Timer(const Duration(minutes: 3), () {
      sample();
      _timer = Timer.periodic(every, (_) => sample());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The log, oldest first.
  List<ArchiverDay> get days {
    final raw = PreferencesService.instanceSync?.xprsArchiverStats ?? '';
    if (raw.isEmpty) return const [];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return const [];
      return [
        for (final e in l)
          if (ArchiverDay.fromJson(e) case final d?) d,
      ];
    } catch (_) {
      return const [];
    }
  }

  static String dayOf(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Take a reading now and fold it into today's row.
  void sample() {
    final prefs = PreferencesService.instanceSync;
    final archive = XprsArchive.instance;
    if (prefs == null || !archive.ready) return;
    final c = archive.countsByTier();
    final hs = XprsHistoryServer.instance;
    final now = (
      answered: hs.answered,
      refused: hs.refused429,
      mail: XprsMailboxCounters.sweepDelivered,
      own: c.own,
      fol: c.followed,
      str: c.stranger,
      bytes: archive.spoolBytes,
      cared: archive.caredFor(),
    );
    final folded =
        foldArchiverReading(days, now, _last, dayOf(DateTime.now()));
    _last = now;
    prefs.xprsArchiverStats =
        jsonEncode([for (final d in folded) d.toJson()]);
  }
}
