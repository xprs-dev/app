/*
 * Share: the web chat and this installed APK, for a nearby phone.
 *
 * The sending phone serves its own APK over plain HTTP on the local network
 * (an offline LocalOnlyHotspot when the two phones share no Wi-Fi), and the
 * receiving phone opens the URL from a QR code in its browser:
 *
 *   GET /                    -> a small download page
 *   GET /xprs-<version>.apk  -> the APK, Range-capable so a browser resumes
 *
 * Nothing else is served, and the server only runs while the Share app page
 * is open. Conditional export keeps dart:io out of the web build.
 */

export 'share_app_service_stub.dart'
    if (dart.library.io) 'share_app_service_io.dart';
