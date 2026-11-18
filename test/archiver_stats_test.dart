// The archiver's daily log (lib/services/xprs/archiver_stats.dart): process
// counters fold into one row per day as deltas, a restart's reset counts
// whole, snapshots overwrite, and the log is bounded.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/archiver_stats.dart';

ArchiverReading r(int answered,
        {int refused = 0, int mail = 0, int own = 0, int bytes = 0}) =>
    (
      answered: answered,
      refused: refused,
      mail: mail,
      own: own,
      fol: 0,
      str: 0,
      bytes: bytes,
      cared: 2,
    );

void main() {
  test('counters add up as deltas within a day; snapshots overwrite', () {
    var days = foldArchiverReading(const [], r(5, own: 10, bytes: 100), null,
        '2026-11-18');
    days = foldArchiverReading(
        days, r(12, mail: 3, own: 11, bytes: 150), r(5, own: 10), '2026-11-18');
    expect(days, hasLength(1));
    expect(days.single.ans, 12);
    expect(days.single.mail, 3);
    expect(days.single.own, 11);
    expect(days.single.bytes, 150);
    expect(days.single.cared, 2);
  });

  test('a new day starts a new row; a reset counter counts whole', () {
    var days = foldArchiverReading(const [], r(40), null, '2026-11-17');
    // The app restarted overnight: the counter is back at 3.
    days = foldArchiverReading(days, r(3), r(40), '2026-11-18');
    expect(days.map((d) => d.d), ['2026-11-17', '2026-11-18']);
    expect(days.last.ans, 3);
  });

  test('the log keeps at most maxDays rows, newest last', () {
    var days = <ArchiverDay>[];
    for (var i = 1; i <= 5; i++) {
      days = foldArchiverReading(
          days, r(i), null, '2026-11-0$i', maxDays: 3);
    }
    expect(days.map((d) => d.d), ['2026-11-03', '2026-11-04', '2026-11-05']);
  });

  test('rows survive the JSON round trip', () {
    final d = ArchiverDay('2026-11-18', ans: 4, mail: 1, own: 9, bytes: 77);
    final back = ArchiverDay.fromJson(d.toJson())!;
    expect(back.toJson(), d.toJson());
    expect(ArchiverDay.fromJson({'d': 'bad'}), isNull);
  });
}
