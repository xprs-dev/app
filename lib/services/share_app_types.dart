/*
 * Plain values shared by share_app_service_io.dart and its web stub.
 */

class ShareApkInfo {
  final String path;
  final int splits;
  final int size;
  final String abi;
  const ShareApkInfo(
      {required this.path,
      required this.splits,
      required this.size,
      required this.abi});
  bool get shareable => path.isNotEmpty && splits == 0;
}

class ShareHotspot {
  final String ssid;
  final String psk;
  final String security;
  const ShareHotspot(
      {required this.ssid, required this.psk, required this.security});
}

class ShareAppException implements Exception {
  final String code;
  const ShareAppException(this.code);
  @override
  String toString() => 'ShareAppException($code)';
}

/// The QR text a phone camera turns into "join this network" (the ZXing
/// WIFI: format; Android 10+ cameras and most QR apps read it).
String wifiQr(ShareHotspot h) {
  String esc(String v) => v.replaceAllMapped(
      RegExp(r'[\\;,:"]'), (m) => '\\${m[0]}');
  final pass = h.security == 'nopass' ? '' : 'P:${esc(h.psk)};';
  return 'WIFI:T:${h.security};S:${esc(h.ssid)};$pass;';
}
