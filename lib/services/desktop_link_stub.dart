// No sockets here (the web build): a link is never handed over this way.
Future<bool> forwardDesktopLink(String link, String socketPath) async => false;

Future<void> listenDesktopLinks(
    String socketPath, void Function(String link) onLink) async {}

bool get desktopLinksSupported => false;

void endThisLaunch() {}
