/*
 * xprs_line_stub — the line lane on a platform with no sockets (web). Same
 * names as xprs_line_io.dart, nothing connected, nothing sent: a page
 * reaches an archiver another way (docs/web.md).
 */
import 'xprs_dial.dart';
import 'xprs_packet.dart';

export 'xprs_dial.dart';

class XprsLineClient {
  XprsLineClient({required this.callsign, required this.dial, this.log});
  final String callsign;
  final XprsDial dial;
  final void Function(String)? log;
  String get label => 'line:$callsign';
  bool get connected => false;
  bool get wanted => false;
  DateTime? get connectedAt => null;
  DateTime? get lastRxAt => null;
  void Function(XprsPacket p, String wire)? onPacket;
  void Function()? onUp;
  void Function(String why)? onDown;
  Future<void> open() async {}
  void close([String why = 'closed']) {}
  bool send(String wire) => false;
  Map<String, Object?> get status =>
      {'callsign': callsign, 'dial': dial.toString(), 'connected': false};
}

class XprsLineLane {
  XprsLineLane._();
  static final XprsLineLane instance = XprsLineLane._();
  void Function(XprsLineClient c)? onClientUp;
  Iterable<XprsLineClient> get clients => const [];
  XprsLineClient? clientFor(String callsign) => null;
  bool connectedTo(String callsign) => false;
  bool get anyConnected => false;
  Future<void> wantAll(Map<String, XprsDial> want) async {}
  bool sendTo(String callsign, String wire) => false;
  void closeAll([String why = 'closed']) {}
  List<Map<String, Object?>> get status => const [];
}
