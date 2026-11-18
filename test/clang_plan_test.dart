// The wapp.build provider's driver runs clang's own plan step by step
// (WASI cannot start a process): this is the reading of that plan.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/editor/wapp_compiler_backend_addon_io.dart';

void main() {
  test('one step per quoted line, after the banner', () {
    const out = 'clang version 22.0.0git\n'
        'Target: wasm32-unknown-wasip1\n'
        'Thread model: posix\n'
        'InstalledDir: /usr/bin\n'
        ' (in-process)\n'
        ' "/usr/bin/clang" "-cc1" "-triple" "wasm32-unknown-wasip1" '
        '"-o" "/tmp/source-1.o" "-x" "c" "/work/source.c"\n'
        ' "/usr/bin/wasm-ld" "--no-entry" "-o" "/work/output.wasm" '
        '"/tmp/source-1.o"\n';
    final steps = parseClangPlan(out);
    expect(steps, hasLength(2));
    expect(steps[0].take(2), ['/usr/bin/clang', '-cc1']);
    expect(steps[0].last, '/work/source.c');
    expect(steps[1].first, '/usr/bin/wasm-ld');
    expect(steps[1].last, '/tmp/source-1.o');
  });

  test('escaped quotes and backslashes stay inside an argument', () {
    final steps = parseClangPlan(r' "clang" "-DMSG=\"hi there\"" "a\\b"');
    expect(steps.single, ['clang', '-DMSG="hi there"', r'a\b']);
  });

  test('an elided driver name is dropped', () {
    final steps = parseClangPlan(' "" "-cc1" "x.c"');
    expect(steps.single, ['-cc1', 'x.c']);
  });

  test('no plan, no steps', () {
    expect(parseClangPlan('clang: error: no input files\n'), isEmpty);
  });
}
