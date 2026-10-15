// The web chat page the share server hands out is built in the sibling repo
// `webchat` (the same page the firmware serves) and bundled gzipped. This
// fails when the bundled copy has drifted from it: run tool/sync_web_chat.sh.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final asset = File('assets/web_chat/chat_page.html.gz');

  test('the bundled page is there and is the chat', () {
    expect(asset.existsSync(), isTrue);
    final html = utf8.decode(gzip.decode(asset.readAsBytesSync()));
    expect(html, contains('/api/xprs/history'));
    expect(html, contains('applyServices'),
        reason: 'the page adapts to what the station offers');
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
          File('${out.path}/chat_page.html.gz').readAsBytesSync(),
          reason: 'run tool/sync_web_chat.sh');
    } finally {
      out.deleteSync(recursive: true);
    }
  });
}
