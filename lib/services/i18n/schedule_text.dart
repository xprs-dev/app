/*
 * A listening schedule, worded in the person's language.
 *
 * `describeSchedule()` in reticulum-dart builds an English sentence, and it
 * stays: it is the library's, it feeds logs, and the library knows nothing
 * of the app's languages. The terms it reads are public types, so the app
 * words them itself here, term for term the same sentence, from keys in
 * hardware.json. Durations keep their symbols (`30m`, `2h`) because they are
 * what the person types in the schedule field.
 */
import 'package:reticulum/src/services/social/listening_schedule.dart';

import 'core_i18n.dart';

String trSchedule(ListeningSchedule s) {
  if (s.isAlways) return tr('hardware.schedule.always');
  final bits = <String>[];
  for (final t in s.terms) {
    if (t is DutyTerm) {
      bits.add(tr('hardware.schedule.duty', {
        'awake': _span(t.awake),
        'period': _span(t.period),
        'pct': (t.dutyFraction * 100).round(),
      }));
    } else if (t is WindowTerm) {
      final when = t.startIsDawn && t.endIsDusk
          ? tr('hardware.schedule.sun_up')
          : tr(t.local ? 'hardware.schedule.window.local' : 'hardware.schedule.window.utc',
              {'start': _hhmm(t.startMin ?? 0), 'end': _hhmm(t.endMin ?? 0)});
      final days = t.days.isEmpty
          ? tr('hardware.schedule.every_day')
          : (t.days.toList()..sort())
              .map((d) => tr('hardware.day.$d'))
              .join(', ');
      bits.add(tr('hardware.schedule.term', {'when': when, 'days': days}));
    }
  }
  return tr('hardware.schedule.sentence',
      {'text': bits.join(tr('hardware.schedule.or'))});
}

String _span(Duration d) => d.inMinutes % 60 == 0 && d.inHours >= 1
    ? '${d.inHours}h'
    : '${d.inMinutes}m';

String _hhmm(int minutes) {
  final h = (minutes ~/ 60) % 24;
  final m = minutes % 60 < 0 ? 0 : minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}
