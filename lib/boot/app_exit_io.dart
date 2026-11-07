/*
 * app_exit — the person asked XPRS to stop, completely.
 *
 * Closing the window is not that on Android: the background service is
 * START_STICKY, and the mesh, the archive and the hubs keep running behind
 * the notification by design. Exit is the one way out:
 *
 *   1. write what the archive holds in memory (it files its rows in batches,
 *      so the last few seconds of received packets would otherwise be lost);
 *   2. stop the background service, so Android does not bring it back;
 *   3. end the process.
 *
 * Not offered on the web: a browser tab is closed by the browser
 * (app_exit_web.dart).
 */
import 'dart:io' show exit;

import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';

import '../wapp/android_foreground_service.dart';

Future<void> exitApp() async {
  LogService.instance.add('app: exit requested by the person');
  try {
    XprsArchive.instance.flush();
  } catch (_) {}
  await AndroidForegroundService.instance.shutdown();
  exit(0);
}
