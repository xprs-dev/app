import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'desktop_link.dart' show isDesktopLink;

/// Linux only: where a browser's `xprs://` reaches the app through the
/// desktop entry.
bool get desktopLinksSupported => Platform.isLinux;

/// This launch handed its link over and has nothing else to do.
void endThisLaunch() => exit(0);

/// Offer [link] to the app already running on this data folder. True when it
/// took it; false when nobody is listening (this launch is the app).
Future<bool> forwardDesktopLink(String link, String socketPath) async {
  if (!desktopLinksSupported || !isDesktopLink(link)) return false;
  try {
    final s = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix), 0,
        timeout: const Duration(seconds: 1));
    s.write('$link\n');
    await s.flush();
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Take links from later launches. A socket file left by an app that died
/// is replaced: nobody answered on it, or this launch would have exited.
Future<void> listenDesktopLinks(
    String socketPath, void Function(String link) onLink) async {
  if (!desktopLinksSupported) return;
  try {
    final f = File(socketPath);
    if (f.existsSync()) f.deleteSync();
    final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    server.listen((client) {
      final buf = BytesBuilder();
      // One short line, then the client is done with, whatever it sent.
      final t = Timer(const Duration(seconds: 3), client.destroy);
      client.listen((data) {
        buf.add(data);
        if (buf.length > 1024) client.destroy();
      }, onDone: () {
        t.cancel();
        final line = utf8
            .decode(buf.takeBytes(), allowMalformed: true)
            .split('\n')
            .first
            .trim();
        if (isDesktopLink(line)) onLink(line);
        client.destroy();
      }, onError: (_) {
        t.cancel();
        client.destroy();
      });
    });
  } catch (_) {
    // No socket: links from a second launch are not taken, nothing else.
  }
}
