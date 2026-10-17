// The web chat page the share server hands out is built in the sibling repo
// `webchat` (the same page the firmware serves) and bundled as plain HTML:
// F-Droid's scanner refuses any archive in the source tree, so it is not the
// .gz the build also produces (the server gzips it when it starts). This fails
// when the bundled copy has drifted from the source: run tool/sync_web_chat.sh.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final asset = File('assets/web_chat/chat_page.html');

  test('the bundled page is there and is the chat', () {
    expect(asset.existsSync(), isTrue);
    final html = asset.readAsStringSync();
    expect(html, contains('/api/xprs/history'));
    expect(html, contains('applyServices'),
        reason: 'the page adapts to what the station offers');
  });

  test('no archive is bundled with it (F-Droid scans the tree)', () {
    final others = asset.parent
        .listSync()
        .map((e) => e.path.split('/').last)
        .where((n) => n != 'chat_page.html')
        .toList();
    expect(others, isEmpty, reason: 'assets/web_chat holds the page only');
  });

  test('it matches what ../webchat builds, when that is checked out', () {
    final build = File('../webchat/tool/build.py');
    if (!build.existsSync()) {
      markTestSkipped('webchat is not checked out next to this repo');
      return;
    }
    final out = Directory.systemTemp.createTempSync('webchat_build');
    try {
      final r = Process.runSync('python3', [build.path, '--out', out.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(asset.readAsBytesSync(),
          File('${out.path}/chat_page.html').readAsBytesSync(),
          reason: 'run tool/sync_web_chat.sh');
    } finally {
      out.deleteSync(recursive: true);
    }
  });
}
