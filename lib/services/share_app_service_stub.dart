/*
 * Web stub for ShareAppService: a browser has no APK to hand out and no
 * HttpServer to hand it out with. Same public surface as
 * share_app_service_io.dart so the page compiles everywhere.
 */

import 'package:flutter/foundation.dart';

import 'share_app_types.dart';

export 'share_app_types.dart';

class ShareAppService {
  ShareAppService._();
  static final ShareAppService instance = ShareAppService._();

  static const int preferredPort = 8642;

  final ValueNotifier<int> downloads = ValueNotifier<int>(0);
  final ValueNotifier<bool> hotspotUp = ValueNotifier<bool>(false);

  bool get running => false;
  int get port => 0;
  String get apkName => 'xprs.apk';

  Future<ShareApkInfo?> apkInfo() async => null;
  Future<ShareHotspot> startHotspot() async =>
      throw const ShareAppException('unsupported');
  Future<void> stopHotspot() async {}
  Future<int> start(
          {required String apkPath,
          required String version,
          String abi = '',
          int? port}) async =>
      throw const ShareAppException('unsupported');
  Future<void> stop() async {}
  Future<List<String>> localAddresses() async => const [];

}
