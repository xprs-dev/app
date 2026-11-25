/*
 * Web stub for ShareAppService: a browser has no HttpServer to run a portal
 * with. Same public surface as share_app_service_io.dart so the page compiles
 * everywhere.
 */

import 'package:flutter/foundation.dart';

import 'share_app_types.dart';
import 'share_library.dart';

export 'share_app_types.dart';
export 'share_library.dart' show ShareEntry, ShareLibrary;

class ShareAppService {
  ShareAppService._();
  static final ShareAppService instance = ShareAppService._();

  static const int preferredPort = 8642;

  final ValueNotifier<int> downloads = ValueNotifier<int>(0);
  final ValueNotifier<bool> portal = ValueNotifier<bool>(false);

  bool get running => false;
  Future<void> hostBoot() async {}
  Future<void> restore() async {}
  Future<void> setPortal(bool on) async {}
  Future<bool> openHotspotSettings() async => false;
  int get port => 0;
  String get apkName => 'xprs.apk';
  List<ShareEntry> get files => const [];

  Future<ShareApkInfo?> apkInfo() async => null;
  bool get apkShareable => false;
  int get visitors => 0;
  final ValueNotifier<int> visitorCount = ValueNotifier<int>(0);
  Future<int> start(
          {String apkPath = '',
          String version = '',
          String abi = '',
          int apkSize = 0,
          int? port,
          Object? api,
          Object? chatPage,
          Object? library}) async =>
      throw const ShareAppException('unsupported');
  Future<void> stop() async {}
  Future<List<String>> localAddresses() async => const [];
}
