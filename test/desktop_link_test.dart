// A link handed to the desktop app on launch (Linux): offered to the app
// already running over a socket in its data folder, so a second launch never
// becomes a second station on the same profile.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/desktop_link.dart';

void main() {
  test('the link among a launch\'s arguments', () {
    expect(desktopLinkFromArgs(['xprs://in/x5abcd']), 'xprs://in/x5abcd');
    expect(desktopLinkFromArgs(['--flag', 'https://xprs.dev/in/g/lisboa']),
        'https://xprs.dev/in/g/lisboa');
    expect(desktopLinkFromArgs(const []), isNull);
    expect(desktopLinkFromArgs(['https://example.org/x', '/some/file']), isNull);
    expect(isDesktopLink('xprs://in/x5abcd extra'), isFalse);
    expect(isDesktopLink('xprs://${'a' * 600}'), isFalse);
  });

  test('a second launch hands its link to the running app; with nobody '
      'running it keeps it', () async {
    if (!Platform.isLinux) return;
    final tmp = Directory.systemTemp.createTempSync('xprslink');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final sock = '${tmp.path}/link.sock';

    // Nobody running.
    expect(await forwardDesktopLink('xprs://in/x5abcd', sock), isFalse);

    // The app is running and listening.
    final got = <String>[];
    final seen = Completer<void>();
    await listenDesktopLinks(sock, (l) {
      got.add(l);
      if (!seen.isCompleted) seen.complete();
    });
    expect(await forwardDesktopLink('xprs://in/g/lisboa', sock), isTrue);
    await seen.future.timeout(const Duration(seconds: 5));
    expect(got, ['xprs://in/g/lisboa']);

    // What is not a link is not taken, whoever wrote it to the socket.
    final s = await Socket.connect(
        InternetAddress(sock, type: InternetAddressType.unix), 0);
    s.write('rm -rf /\n');
    await s.flush();
    await s.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(got, hasLength(1));
  });
}
