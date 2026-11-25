/*
 * Share: the web portal. An HTTP server on the local network that serves the
 * web chat at `/` (any browser, nothing to install) and the installers this
 * device can hand on at `/app`: its own APK on Android, plus whatever
 * ShareLibrary fetched for other systems.
 *
 * A switch its owner leaves on or off (`share.portal`); on, it outlives the
 * Share page and comes back at boot. Conditional export keeps dart:io out of
 * the web build.
 */

export 'share_app_service_stub.dart'
    if (dart.library.io) 'share_app_service_io.dart';
