/*
 * A link handed to the desktop app (Linux): `xprs xprs://in/x5abcd`, which is
 * what the desktop entry runs when a browser opens an `xprs://` address.
 *
 * The desktop app is not a single-instance application: starting it a second
 * time starts a second one, on the same profile, as the same station. So a
 * launch that carries a link first offers it to the app already running,
 * over a socket in the app's own data folder, and exits when it was taken.
 * Only when nobody is running does the launch go on and open the link
 * itself.
 */
export 'desktop_link_stub.dart'
    if (dart.library.io) 'desktop_link_io.dart';

/// The link among a launch's arguments, or null: an `xprs://` address, or an
/// `https://xprs.dev/` one (a desktop that hands those over too).
String? desktopLinkFromArgs(List<String> args) {
  for (final a in args) {
    final v = a.trim();
    if (isDesktopLink(v)) return v;
  }
  return null;
}

/// Whether [v] is something this app opens. Checked on both ends of the
/// socket: what arrives there is whatever a local process wrote.
bool isDesktopLink(String v) {
  if (v.length > 512 || v.contains(RegExp(r'\s'))) return false;
  final l = v.toLowerCase();
  return l.startsWith('xprs://') || l.startsWith('https://xprs.dev/');
}
