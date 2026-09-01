/// The XBLOB endpoint on the phone's GATT link — one session at a time,
/// server or receiver, bound to whichever side of the link is up.
///
/// Serving: [serveImage] parks a blob (a firmware image, any sha-named file);
/// when the peer's START names its sha, the blast begins on the same link the
/// START arrived on. Receiving: [expectBlob] arms the receiver for a blob the
/// caller has been promised (sha + size from a signed command or an offer);
/// verified bytes land in the [MeshBulkSpool] and complete as a normal
/// inbound spool entry.
///
/// The wire and the rules live in `xprs_blob.dart` (the C mirror). This file
/// is only the binding: transport hooks in, spool out, a 100 ms tick while a
/// session is alive, and nothing else.
library;

import 'dart:async';
import 'dart:typed_data';

import '../log_service.dart';
import 'mesh_bulk_spool.dart';
import 'mesh_custody.dart';
import 'xprs_blob.dart';

class _ServeDelegate extends XblobDelegate {
  _ServeDelegate(this._send, this._image, this._onDone);
  final Future<void> Function(Uint8List) _send;
  final Uint8List _image;
  final void Function(bool ok) _onDone;
  @override
  int send(Uint8List frame) {
    // The native queues (write pump / notify pump) flow-control per frame;
    // the XBLOB window bounds how far we run ahead of the receiver's ACK.
    unawaited(_send(frame));
    return xblobSendOk;
  }

  @override
  Uint8List? blockRead(int off, int cap) {
    if (off >= _image.length) return Uint8List(0);
    final end = off + cap > _image.length ? _image.length : off + cap;
    return Uint8List.sublistView(_image, off, end);
  }

  @override
  void done(bool ok) => _onDone(ok);
}

class _RecvDelegate extends XblobDelegate {
  _RecvDelegate(this._send, this._sha, this._onDone);
  final Future<void> Function(Uint8List) _send;
  final Uint8List _sha;
  final void Function(bool ok) _onDone;
  @override
  int send(Uint8List frame) {
    unawaited(_send(frame));
    return xblobSendOk;
  }

  @override
  bool blockWrite(int off, Uint8List data) =>
      MeshBulkSpool.instance.writeAt(_sha, off, data);

  @override
  void done(bool ok) => _onDone(ok);
}

/// The callsign on the other end of the current client GATT link, when the
/// dialer said who it was dialling. Lets the publisher route a directed wire
/// over the link automatically instead of broadcasting it.
class GattPeer {
  static String callsign = '';
}

class XblobService {
  XblobService._();
  static final XblobService instance = XblobService._();

  XblobSession? _session;
  Timer? _tick;

  // A parked image, served when a START names its sha.
  Uint8List? _imgSha;
  Uint8List? _image;
  String _imageSig = '';

  bool get active => _session != null && !_session!.dead;

  /// Park [image] for serving. The next START whose sha matches begins the
  /// blast on the link it arrived on. [sig85] rides in the manifest (for
  /// firmware, the xprsfw1 approval).
  void serveImage(Uint8List image, Uint8List sha, {String sig85 = ''}) {
    _image = image;
    _imgSha = Uint8List.fromList(sha);
    _imageSig = sig85;
    LogService.instance
        .add('XBLOB: serving armed, ${image.length} B sha ${_hex(sha, 8)}');
  }

  void clearServe() {
    _image = null;
    _imgSha = null;
    _imageSig = '';
  }

  /// Arm the receiver: pull the blob named by [sha]/[size] from the peer on
  /// the current link (we send START; the peer must be serving it). Bytes
  /// land in the bulk spool; on ok the caller finishes via the spool.
  void expectBlob(Uint8List sha, int size,
      {required bool serverSide, void Function(bool ok)? onDone}) {
    final send = _sendFor(serverSide);
    if (send == null) {
      onDone?.call(false);
      return;
    }
    _start(XblobSession.receiver(
      _RecvDelegate(send, sha, (ok) => _finish(ok, onDone)),
      sha,
      size,
      DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// The GATT demux entry: a 0x42 frame from either side of the link.
  /// Returns true when consumed.
  bool onFrame(Uint8List data, {required bool serverSide}) {
    if (!xblobIsFrame(data)) return false;
    final startSha = xblobStartSha(data);
    if (startSha != null && _session == null) {
      final img = _image, sha = _imgSha;
      final send = _sendFor(serverSide);
      if (img == null || sha == null || send == null || !_shaEq(startSha, sha)) {
        LogService.instance.add('XBLOB: START for a blob we do not hold');
        return true;
      }
      LogService.instance.add('XBLOB: START -> serving ${img.length} B');
      _start(XblobSession.server(
        _ServeDelegate(send, img, (ok) => _finish(ok, null)),
        sha,
        img.length,
        sig85: _imageSig,
      ));
      return true;
    }
    _session?.rx(data, DateTime.now().millisecondsSinceEpoch);
    return true;
  }

  /// The link dropped: a live session cannot continue (the spool keeps the
  /// receiver's bytes; a re-dial re-STARTs and NEED fills only the gap).
  void onLinkDown() {
    if (_session != null) {
      LogService.instance.add('XBLOB: link down mid-session');
      _stopTick();
      _session = null;
    }
  }

  Future<void> Function(Uint8List)? _sendFor(bool serverSide) => serverSide
      ? MeshSessionManager.instance.hooks.serverSend
      : MeshSessionManager.instance.hooks.clientSend;

  void _start(XblobSession s) {
    _session = s;
    _tick ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final ses = _session;
      if (ses == null) return _stopTick();
      ses.tick(DateTime.now().millisecondsSinceEpoch);
      ses.txReady();
      if (ses.dead) {
        _session = null;
        _stopTick();
      }
    });
  }

  void _finish(bool ok, void Function(bool ok)? onDone) {
    LogService.instance.add('XBLOB: session ${ok ? "complete" : "gave up"}');
    _stopTick();
    _session = null;
    onDone?.call(ok);
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  static bool _shaEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(Uint8List b, int n) =>
      b.take(n).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
