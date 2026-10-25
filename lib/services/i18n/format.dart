/*
 * Numbers and units in the person's language, on top of tr().
 *
 * One byte formatter for the whole app. There were four, each with its own
 * cut-offs and decimals (settings, GeoUI gallery, media view, node role API),
 * and all of them printed "1.5 MB" in every language. French writes "1,5 Mo";
 * Portuguese, Spanish and German use the comma too. The unit names and the
 * decimal mark are keys in common.json, so a new language is a translation,
 * not code.
 *
 * Wire formats never come through here: XPRS.md 4 fixes `.` as the decimal
 * separator on the air in every locale. This is for what a person reads.
 */
import 'core_i18n.dart';

/// [n] with [digits] decimals and the language's decimal mark.
String trDecimal(num n, int digits) {
  final s = n.toStringAsFixed(digits);
  final mark = tr('common.decimal');
  return mark == '.' ? s : s.replaceFirst('.', mark);
}

/// A byte count for a person: `512 B`, `1,5 Ko`, `3.2 GB`. [digits] decimals
/// above a kilobyte; [gbDigits] for gigabytes, where one more digit matters.
String trBytes(int b, {int digits = 1, int gbDigits = 1}) {
  if (b < 1024) return tr('common.unit.bytes', {'n': b});
  if (b < 1 << 20) {
    return tr('common.unit.kb', {'n': trDecimal(b / 1024, digits)});
  }
  if (b < 1 << 30) {
    return tr('common.unit.mb', {'n': trDecimal(b / (1 << 20), digits)});
  }
  return tr('common.unit.gb', {'n': trDecimal(b / (1 << 30), gbDigits)});
}
