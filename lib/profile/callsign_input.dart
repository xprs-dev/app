/*
 * The input filter for a field that takes an issued callsign.
 *
 * Reusable by any screen with such a field; pair it with
 * keyboardType: TextInputType.visiblePassword, autocorrect: false,
 * enableSuggestions: false and textCapitalization: characters, and normalise
 * with xprsNormaliseCallsign when the value is used.
 */
import 'package:flutter/services.dart';

/// Keeps out what a callsign can never contain -- and nothing else.
///
/// It does NOT change case, and it never touches text the keyboard is still
/// composing. The one it replaces did both, on every keystroke, which is
/// what made this field impossible to type into on Android: the keyboard
/// held "c" as a word in progress, the formatter turned it into "C" and
/// dropped the composing range, and the keyboard answered by re-sending its
/// own text. Case is the caps keyboard's hint and xprsNormaliseCallsign's
/// job when the callsign is added.
class CallsignInputFormatter extends TextInputFormatter {
  static final RegExp _bad = RegExp('[^A-Za-z0-9/-]');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue old, TextEditingValue next) {
    if (next.composing.isValid && !next.composing.isCollapsed) return next;
    if (!_bad.hasMatch(next.text)) return next;
    final cleaned = next.text.replaceAll(_bad, '');
    final at = next.selection.baseOffset - (next.text.length - cleaned.length);
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: at.clamp(0, cleaned.length)),
    );
  }
}

