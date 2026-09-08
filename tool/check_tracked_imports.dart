// Every relative import in the COMMITTED tree must name a COMMITTED file.
//
// This is the one class of breakage that is invisible on the machine that
// causes it: the file is there on disk, so the app builds, the tests pass and
// the analyzer is silent — while the tree that CI checks out does not contain
// it. It happens when a rename or a new file is staged in a working tree that
// more than one person (or session) is using, and a commit takes half of it.
//
// It cost a release: v1.2.9 was tagged and every platform failed on
// "Error when reading 'lib/services/folders/folder_export.dart'", an import
// that had not changed since the release before it. The file had been renamed
// out of the tree by a commit that meant to change something else.
//
// Run it against HEAD (the default) or any tree-ish:
//   dart tool/check_tracked_imports.dart [HEAD]
// Exit 1 and a list on failure. release.sh runs it before it tags anything.
import 'dart:io';

void main(List<String> args) {
  final rev = args.isEmpty ? 'HEAD' : args.first;

  final ls = Process.runSync('git', ['ls-tree', '-r', '--name-only', rev]);
  if (ls.exitCode != 0) {
    stderr.writeln('git ls-tree $rev failed: ${ls.stderr}');
    exit(2);
  }
  final tracked = (ls.stdout as String)
      .split('\n')
      .where((l) => l.isNotEmpty)
      .toSet();

  // One pass for every import/export directive and every conditional branch.
  final grep = Process.runSync('git', [
    'grep', '-n', '-E',
    r"""^\s*(import|export)\s+['"]|^\s*if\s*\(\s*dart\.library\.[a-z]+\s*\)\s*['"]""",
    rev, '--', '*.dart',
  ]);
  // grep exits 1 when nothing matches, which is not an error here.
  if (grep.exitCode > 1) {
    stderr.writeln('git grep failed: ${grep.stderr}');
    exit(2);
  }

  final quoted = RegExp("""['"]([^'"]+)['"]""");
  final broken = <String>[];
  for (final line in (grep.stdout as String).split('\n')) {
    if (line.isEmpty) continue;
    // <rev>:<path>:<lineno>:<text>
    final parts = line.split(':');
    if (parts.length < 4) continue;
    final file = parts[1];
    // Vendored code carries its own examples and its own broken references.
    if (file.startsWith('third_party/')) continue;
    final text = parts.sublist(3).join(':');
    final target = quoted.firstMatch(text)?.group(1);
    if (target == null || target.contains(':')) continue; // package:, dart:
    final resolved = _normalise('${_dirOf(file)}/$target');
    if (!tracked.contains(resolved)) {
      broken.add('$file:${parts[2]} -> $target   (not in $rev: $resolved)');
    }
  }

  if (broken.isEmpty) {
    stdout.writeln('imports: every relative import in $rev resolves');
    return;
  }
  stderr.writeln('imports: ${broken.length} import(s) name a file that is '
      'NOT in $rev — the build will fail where the file is not on disk:');
  for (final b in broken) {
    stderr.writeln('  $b');
  }
  stderr.writeln('\nUsually a rename or a new file that is staged or untracked '
      'in the working tree but was never committed.');
  exit(1);
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '.' : path.substring(0, i);
}

String _normalise(String path) {
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(seg);
    }
  }
  return out.join('/');
}
