// i18n_check — the core's translation files against the code that reads them.
//
// No dependencies, like arch_guard.dart, so it runs from the pre-commit hook
// in milliseconds. docs/plan-i18n-core.md section 6.
//
//   dart tool/i18n_check.dart          # exit 1 on a defect in en or the code
//   dart tool/i18n_check.dart --quiet  # only defects and the summary line
//
// Fails (exit 1) on:
//   - a key used by `tr('x.y')` / `trn('x.y', n)` in lib/ that en does not have
//     (for trn: both `x.y.one` and `x.y.other`)
//   - a key whose first segment is not the file it sits in
//   - a key defined twice across en's files, or an empty English string
//   - a language file that is not valid JSON, or not a flat object
// Warns (exit 0) on:
//   - a language missing a file or a key en has (it falls back to English)
//   - a translation whose `{placeholders}` differ from the English ones
//   - a translation file whose `_meta.reviewed` is false
// Keys built at runtime (`tr('permissions.${item.key}.title')`) cannot be
// checked and are listed as dynamic, so the reader knows what was not proven.
import 'dart:convert';
import 'dart:io';

const langRoot = 'assets/lang';

void main(List<String> args) {
  final quiet = args.contains('--quiet');
  var failures = 0;
  var warnings = 0;
  void fail(String m) {
    failures++;
    stderr.writeln('i18n: ERROR $m');
  }

  void warn(String m) {
    warnings++;
    if (!quiet) stdout.writeln('i18n: warn  $m');
  }

  // ── the files ─────────────────────────────────────────────────────────────
  final root = Directory(langRoot);
  if (!root.existsSync()) {
    fail('$langRoot does not exist');
    exit(1);
  }
  final languages = <String, Map<String, Map<String, String>>>{}; // lang → file → keys
  final meta = <String, Map<String, Map<String, dynamic>>>{};
  for (final d in root.listSync().whereType<Directory>()) {
    final code = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final files = <String, Map<String, String>>{};
    final metas = <String, Map<String, dynamic>>{};
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final area = f.uri.pathSegments.last.replaceAll('.json', '');
      dynamic json;
      try {
        json = jsonDecode(f.readAsStringSync());
      } catch (e) {
        fail('$code/$area.json is not valid JSON: $e');
        continue;
      }
      if (json is! Map) {
        fail('$code/$area.json is not an object');
        continue;
      }
      final keys = <String, String>{};
      for (final e in json.entries) {
        final k = e.key as String;
        if (k == '_meta') {
          if (e.value is Map) metas[area] = Map<String, dynamic>.from(e.value);
          continue;
        }
        final v = e.value;
        if (v is! String) {
          fail('$code/$area.json: "$k" is not a string');
          continue;
        }
        final first = k.split('.').first;
        if (first != area) {
          fail('$code/$area.json: "$k" belongs in $first.json');
        }
        keys[k] = v;
      }
      files[area] = keys;
    }
    languages[code] = files;
    meta[code] = metas;
  }
  final en = languages['en'];
  if (en == null) {
    fail('no $langRoot/en folder');
    exit(1);
  }
  final enAll = <String, String>{};
  for (final e in en.entries) {
    for (final k in e.value.entries) {
      if (enAll.containsKey(k.key)) fail('en: "${k.key}" defined twice');
      if (k.value.trim().isEmpty) fail('en/${e.key}.json: "${k.key}" is empty');
      enAll[k.key] = k.value;
    }
  }

  // ── the code ──────────────────────────────────────────────────────────────
  final used = <String, String>{}; // key → first file seen
  final usedPlural = <String, String>{};
  final dynamicKeys = <String>[];
  // The argument list of each tr( / trn( call, found by counting parentheses
  // from the opening one (string contents are skipped, so a ')' inside a
  // key or a hint does not close the call). Every quoted dotted key inside
  // counts, which covers `tr(cond ? 'a.b' : 'a.c')`; a dotted literal
  // outside the call, such as a `hintText: 'rns.example.net'` beside it,
  // does not. A nested call's key is collected twice, once by each visit,
  // which changes nothing.
  final call = RegExp(r'\b(trn?)\(');
  final lit = RegExp(r"'([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)'");
  final dyn = RegExp(r"'[a-z][a-z0-9_]*(?:\.[a-z0-9_]*)*\$\{?[^']*'");
  String argsOf(String src, int open) {
    var depth = 1;
    var i = open;
    String? quote;
    while (i < src.length && depth > 0) {
      final c = src[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
      } else if (c == "'" || c == '"') {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
      }
      i++;
    }
    return src.substring(open, i);
  }

  for (final f in Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    final src = f.readAsStringSync();
    for (final m in call.allMatches(src)) {
      final w = argsOf(src, m.end);
      final plural = m.group(1) == 'trn';
      var any = false;
      for (final k in lit.allMatches(w)) {
        any = true;
        (plural ? usedPlural : used).putIfAbsent(k.group(1)!, () => f.path);
      }
      if (!any || dyn.hasMatch(w)) {
        final d = dyn.firstMatch(w)?.group(0);
        if (d != null) dynamicKeys.add('${f.path}: $d');
      }
    }
  }
  for (final e in used.entries) {
    if (!enAll.containsKey(e.key)) {
      fail('${e.value} uses "${e.key}", which en does not define');
    }
  }
  for (final e in usedPlural.entries) {
    for (final suf in ['.one', '.other']) {
      if (!enAll.containsKey('${e.key}$suf')) {
        fail('${e.value} uses trn("${e.key}"), en lacks "${e.key}$suf"');
      }
    }
  }
  final unused = enAll.keys.where((k) {
    if (used.containsKey(k)) return false;
    final base = k.replaceFirst(RegExp(r'\.(one|other)$'), '');
    if (usedPlural.containsKey(base)) return false;
    // Rows named by a runtime key share a prefix with a dynamic use.
    return !dynamicKeys.any((d) {
      final prefix = RegExp(r"'([a-z0-9_.]+)\$").firstMatch(d)?.group(1);
      return prefix != null && k.startsWith(prefix);
    });
  }).toList();

  // ── the other languages ───────────────────────────────────────────────────
  final ph = RegExp(r'\{[a-z_]+\}');
  for (final code in languages.keys.where((c) => c != 'en')) {
    final files = languages[code]!;
    for (final area in en.keys) {
      final mine = files[area];
      if (mine == null) {
        warn('$code has no $area.json (${en[area]!.length} keys fall back to English)');
        continue;
      }
      final missing = en[area]!.keys.where((k) => !mine.containsKey(k)).length;
      final extra = mine.keys.where((k) => !en[area]!.containsKey(k)).toList();
      if (missing > 0) warn('$code/$area.json: $missing missing');
      for (final k in extra) {
        warn('$code/$area.json: "$k" is not in en (dead)');
      }
      for (final k in mine.keys) {
        final want = ph.allMatches(enAll[k] ?? '').map((m) => m.group(0)).toSet();
        final have = ph.allMatches(mine[k]!).map((m) => m.group(0)).toSet();
        if (want.isNotEmpty && !have.containsAll(want) || have.length > want.length) {
          warn('$code/$area.json: "$k" placeholders $have, en has $want');
        }
      }
      if (meta[code]?[area]?['reviewed'] == false) {
        warn('$code/$area.json: not reviewed by a person yet');
      }
    }
  }

  if (!quiet) {
    for (final d in dynamicKeys) {
      stdout.writeln('i18n: dynamic $d');
    }
    for (final k in unused) {
      stdout.writeln('i18n: unused $k');
    }
  }
  stdout.writeln('i18n_check: ${failures == 0 ? 'clean' : '$failures error(s)'} '
      '(${enAll.length} keys in ${en.length} files, '
      '${languages.length - 1} translations, ${used.length + usedPlural.length} '
      'keys read by lib/, ${dynamicKeys.length} dynamic, ${unused.length} '
      'unused, $warnings warning(s))');
  exit(failures == 0 ? 0 : 1);
}
