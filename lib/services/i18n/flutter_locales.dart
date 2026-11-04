/*
 * CoreI18n's language as Flutter Locales, for MaterialApp. The translation
 * tables are the core's (plain Dart); turning a tag into a Flutter Locale is
 * the app's.
 */
import 'dart:ui' show Locale;

import 'core_i18n.dart';

extension FlutterLocales on CoreI18n {
  /// For MaterialApp: the locale Flutter's own widgets should use.
  Locale get flutterLocale => _toLocale(resolved);

  /// For MaterialApp.supportedLocales.
  List<Locale> get supportedLocales => [for (final l in languages) _toLocale(l)];
}

Locale _toLocale(String tag) {
  final i = tag.indexOf(RegExp('[_-]'));
  if (i < 0) return Locale(tag);
  return Locale(tag.substring(0, i), tag.substring(i + 1));
}
