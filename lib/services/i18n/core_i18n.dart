/*
 * CoreI18n — the core app's own translations, in the wapps' shape.
 *
 * The wapps already translate through `I18nContext`: a flat JSON map per
 * language, `@key` sentinels, and the chain exact tag → language → English →
 * the key itself. The core adopts exactly that, with one difference in where
 * the files live: a wapp is one area and ships one `lang/<code>.json`; the
 * core is many areas and ships `assets/lang/<code>/<area>.json`, one file per
 * screen family (docs/plan-i18n-core.md section 2). The loader merges the
 * area files, so a key's file is a fact about the repository, not about the
 * code: `settings.language` lives in `settings.json` because its first
 * segment says so, and tool/i18n_check.dart holds everyone to it.
 *
 * Loaded once at boot (a boot task in main.dart), reloaded on
 * LocaleChangedEvent. `tr()` is a map lookup after that: no asset read, no
 * JSON decode, nothing on a build pass (docs/performance.md).
 *
 * The language is chosen the way the wapps' already is: the stored
 * preference when the person picked one in Settings, else the operating
 * system's locale (`PreferencesService.activeLocale`). A tag with no folder
 * falls to its language (`pt_BR` → `pt`), then to English.
 */
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../event_bus.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'i18n_context.dart';

/// Where the language folders live, relative to the asset bundle.
const String kLangRoot = 'assets/lang/';

/// Translate [key] for the person's language, with `{name}` placeholders
/// filled from [args]. A missing key falls back to English, then to the key
/// itself, so a screen never shows nothing.
String tr(String key, [Map<String, Object?>? args]) =>
    CoreI18n.instance.tr(key, args);

/// Plural form: `key.one` when [n] is 1, `key.other` otherwise, with `{n}`
/// filled in. Two keys per plural is what the wapps do and what every one of
/// the shipped languages needs; nothing more is pretended.
String trn(String key, num n, [Map<String, Object?>? args]) =>
    CoreI18n.instance.trn(key, n, args);

class CoreI18n {
  CoreI18n._();
  static final CoreI18n instance = CoreI18n._();

  I18nContext _ctx = I18nContext.empty();
  List<String> _languages = const ['en'];
  Map<String, List<String>>? _files; // language → asset paths
  bool _ready = false;
  bool _subscribed = false;

  /// Bumped on every (re)load. The root widget listens and rebuilds once, so
  /// every `tr()` in a build method sees the new language without anything
  /// else subscribing.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get ready => _ready;

  /// The effective language tag the tables were loaded for (`pt_PT`, `en`).
  String get locale => _ctx.locale;

  /// The language folders this build ships, `en` first.
  List<String> get languages => _languages;

  /// What the loaded tag resolved to among [languages]: the folder whose
  /// files are the primary table, or `en` when none matched.
  String get resolved => _resolved;
  String _resolved = 'en';

  /// For MaterialApp: the locale Flutter's own widgets should use.
  Locale get flutterLocale => _toLocale(_resolved);

  /// For MaterialApp.supportedLocales.
  List<Locale> get supportedLocales =>
      [for (final l in _languages) _toLocale(l)];

  static Locale _toLocale(String tag) {
    final i = tag.indexOf(RegExp('[_-]'));
    if (i < 0) return Locale(tag);
    return Locale(tag.substring(0, i), tag.substring(i + 1));
  }

  /// Boot: find the folders, load the tables, follow the Settings row.
  Future<void> init() async {
    if (!_subscribed) {
      _subscribed = true;
      EventBus().on<LocaleChangedEvent>((_) => reload());
    }
    await reload();
  }

  /// Load (again) for the language that is active now.
  Future<void> reload() async {
    try {
      final files = await _discover();
      final prefs = await PreferencesService.instance();
      final tag = prefs.activeLocale();
      final lang = prefs.activeLanguageCode();
      final exact = files.containsKey(tag) ? tag : null;
      final langOnly =
          lang != tag && files.containsKey(lang) ? lang : null;
      final primary = <String, String>{
        if (langOnly != null) ...await _loadFolder(files[langOnly]!),
        if (exact != null) ...await _loadFolder(files[exact]!),
      };
      _resolved = exact ?? langOnly ?? 'en';
      final fallback = _resolved == 'en'
          ? const <String, String>{}
          : await _loadFolder(files['en'] ?? const []);
      // English with no other folder matched: the primary IS the English
      // table, as I18nContext.loadFromPackage does for the wapps.
      _ctx = I18nContext(
        locale: tag,
        primary: _resolved == 'en' && primary.isEmpty
            ? await _loadFolder(files['en'] ?? const [])
            : primary,
        fallback: fallback,
      );
      _ready = true;
      revision.value++;
      LogService.instance.add(
          'i18n: $tag → $_resolved (${_ctx.primary.length} strings'
          '${fallback.isEmpty ? '' : ', ${fallback.length} fallback'})');
    } catch (e) {
      LogService.instance.add('i18n: load failed ($e) — English keys');
    }
  }

  /// Every `assets/lang/<code>/*.json` in the bundle, grouped by code. Read
  /// once; the bundle does not change while the app runs.
  Future<Map<String, List<String>>> _discover() async {
    final cached = _files;
    if (cached != null) return cached;
    final out = <String, List<String>>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final a in manifest.listAssets()) {
        if (!a.startsWith(kLangRoot) || !a.endsWith('.json')) continue;
        final rest = a.substring(kLangRoot.length);
        final slash = rest.indexOf('/');
        if (slash <= 0) continue;
        out.putIfAbsent(rest.substring(0, slash), () => []).add(a);
      }
    } catch (e) {
      debugPrint('i18n: asset manifest unavailable: $e');
    }
    final langs = out.keys.toList()..sort();
    if (langs.remove('en')) langs.insert(0, 'en');
    _languages = langs.isEmpty ? const ['en'] : langs;
    return _files = out;
  }

  /// Merge one folder's area files into a flat map. Strings only: a
  /// `"_meta"` object, or anything else that is not a string, is skipped.
  static Future<Map<String, String>> _loadFolder(List<String> paths) async {
    final out = <String, String>{};
    for (final p in paths) {
      try {
        final text = await rootBundle.loadString(p);
        final json = jsonDecode(text);
        if (json is! Map) continue;
        for (final e in json.entries) {
          final v = e.value;
          if (v is String) out[e.key as String] = v;
        }
      } catch (e) {
        debugPrint('i18n: $p unreadable: $e');
      }
    }
    return out;
  }

  String tr(String key, [Map<String, Object?>? args]) {
    var s = _ctx.resolve('@$key');
    if (args != null) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    }
    return s;
  }

  String trn(String key, num n, [Map<String, Object?>? args]) =>
      tr(n == 1 ? '$key.one' : '$key.other', {'n': n, ...?args});

  /// Test seam: install tables without an asset bundle.
  @visibleForTesting
  void installForTest(I18nContext ctx, {List<String>? languages}) {
    _ctx = ctx;
    _resolved = ctx.locale;
    if (languages != null) _languages = languages;
    _ready = true;
    revision.value++;
  }
}
