/// XBLOB — the fast 1:1 bulk-transfer protocol, mirrored line-for-line from
/// the firmware's `common/xprs_blob/xprs_blob.c` (see `xprs_blob.h` there for
/// the wire and the flow, and the firmware's `docs/ble5-gatt.md` for why it
/// exists and what it measured: a 168 KB image in ~20 s over a GATT link).
///
/// BitTorrent-shaped: a MANIFEST carrying the whole-file sha256 and a 4-byte
/// truncated sha256 per 240-byte block, a READY barrier so no block flies
/// before the receiver holds every hash, a windowed blast of raw parcels with
/// no per-block ack, and one NEED bitmap that re-requests exactly the blocks
/// that are missing or corrupt. Every control frame is retried on a stall
/// timer; every counter resets at a pass boundary. XBLOB itself carries no
/// trust: the caller hands the receiver the sha it must accept (from a signed
/// `cmd:update` or equivalent), and whole-file verification stays with the
/// caller on completion.
///
/// One frame per ATT PDU, magic 0x42 ('B') — distinct from XPRS text (`t:` =
/// 0x74) and MSP (0x4D), so a link demuxes the three on the first byte.
///
/// KEEP IN LOCKSTEP with the C. Any wire change lands in BOTH files and in
/// the shared expectations of `test/xblob_test.dart`.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

// ── Wire ────────────────────────────────────────────────────────────────
const int kXblobMagic = 0x42;
const int kXblobVersion = 1;

const int xblobTManifest = 0x01;
const int xblobTBlock = 0x02;
const int xblobTNeed = 0x03;
const int xblobTHashes = 0x04;
const int xblobTDone = 0x06;
const int xblobTOk = 0x07;
const int xblobTFail = 0x08;
const int xblobTBye = 0x09;
const int xblobTStart = 0x0A;
const int xblobTAck = 0x0B;
const int xblobTReady = 0x0C;

const int xblobFailSha = 1;
const int xblobFailBig = 2;
const int xblobFailRounds = 3;
const int xblobFailIo = 4;

const int kXblobHashLen = 4;
const int kXblobMaxBlocks = 1200;
const int kXblobBlockSize = 240;

/// Send returns: 0 queued; -2 transport busy (retry on [XblobSession.txReady]);
/// any other negative = link dead.
const int xblobSendOk = 0;
const int xblobSendBusy = -2;

const int kXblobStallMs = 750;
const int kXblobMaxRounds = 12;
const int kXblobWindow = 24;
const int kXblobAckEvery = 8;

const int _hdr = 2;
const int _frameMax = 244;

/// True when [d] is an XBLOB frame — the GATT rx demux test.
bool xblobIsFrame(List<int> d) => d.length >= 2 && d[0] == kXblobMagic;

/// The START sha, for a server whose app must look the image up before it can
/// bind a session. Null unless [d] is a START frame.
Uint8List? xblobStartSha(List<int> d) {
  if (d.length < _hdr + 32 || d[0] != kXblobMagic || d[1] != xblobTStart) {
    return null;
  }
  return Uint8List.fromList(d.sublist(_hdr, _hdr + 32));
}

// ── Host-supplied operations (the C's xblob_ops_t) ──────────────────────
abstract class XblobDelegate {
  /// Queue one frame on the link: [xblobSendOk], [xblobSendBusy], or other
  /// negative = link dead.
  int send(Uint8List frame);

  /// SERVER: read up to [cap] bytes of the blob at byte [off]. Empty/short
  /// only at the end; null = IO error.
  Uint8List? blockRead(int off, int cap) => null;

  /// RECEIVER: persist one VERIFIED block. Only called after the block's
  /// manifest hash matched. Return true on success.
  bool blockWrite(int off, Uint8List data) => false;

  /// Transfer ended. Receiver ok=true: every block present and verified —
  /// the caller now does whole-file sha / approval / install. ok=false:
  /// XBLOB gave up (fall back to the slow lane).
  void done(bool ok);
}

// ── Session ─────────────────────────────────────────────────────────────
enum _St { rManifest, rRecv, rDone, rDead, sManifest, sHashes, sWaitReady, sBlocks, sWaitNeed, sDead }

class XblobSession {
  XblobSession.receiver(this._d, Uint8List sha, this.size, int nowMs)
      : role = 0,
        _state = _St.rManifest,
        sha = Uint8List.fromList(sha),
        _lastRxMs = nowMs {
    _sendStart();
  }

  XblobSession.server(this._d, Uint8List sha, this.size,
      {this.blockSize = kXblobBlockSize, String sig85 = ''})
      : role = 1,
        _state = _St.sManifest,
        sha = Uint8List.fromList(sha),
        sig = sig85 {
    nblocks = (size + blockSize - 1) ~/ blockSize;
    for (var i = 0; i < nblocks; i++) {
      _sendBm[i] = true;
    }
    _pump();
  }

  final XblobDelegate _d;
  final int role; // 0 receiver, 1 server
  final Uint8List sha;
  final int size;
  int blockSize = kXblobBlockSize;
  int nblocks = 0;
  String sig = '';
  _St _state;

  bool get complete => role == 0 && _manifestOk && _got >= nblocks;
  bool get dead => _state == _St.rDead || _state == _St.sDead;

  // receiver
  final List<bool> _have = List.filled(kXblobMaxBlocks, false);
  final List<bool> _hbits = List.filled(kXblobMaxBlocks, false);
  final Uint8List _bhash = Uint8List(kXblobMaxBlocks * kXblobHashLen);
  int _got = 0, _hashesGot = 0, _rounds = 0;
  int _lastRxMs = 0;
  bool _manifestOk = false;
  int _consumed = 0, _lastAckSent = 0;

  // server
  final List<bool> _sendBm = List.filled(kXblobMaxBlocks, false);
  int _cursor = 0, _hashesSent = 0, _framesSent = 0, _ack = 0;
  bool _doneSent = false;

  // ── helpers ──
  static void _w16(BytesBuilder b, int v) =>
      b..addByte(v & 0xFF)..addByte((v >> 8) & 0xFF);
  static void _w32(BytesBuilder b, int v) => b
    ..addByte(v & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 24) & 0xFF);
  static int _r16(List<int> d, int o) => d[o] | (d[o + 1] << 8);
  static int _r32(List<int> d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  static Uint8List _blockHash(List<int> data) => Uint8List.fromList(
      crypto.sha256.convert(data).bytes.sublist(0, kXblobHashLen));

  BytesBuilder _frame(int type) =>
      BytesBuilder()..addByte(kXblobMagic)..addByte(type);

  void _fail(int reason, bool tellPeer) {
    if (tellPeer) {
      final f = _frame(xblobTFail)..addByte(reason);
      _d.send(f.toBytes());
    }
    _state = role == 1 ? _St.sDead : _St.rDead;
    _d.done(false);
  }

  // ── SERVER ── (mirrors server_pump / server_rx)
  void _pump() {
    if (_state == _St.sManifest) {
      final f = _frame(xblobTManifest)..addByte(kXblobVersion);
      f.add(sha);
      _w32(f, size);
      _w16(f, blockSize);
      _w16(f, nblocks);
      f.addByte(kXblobHashLen);
      final sb = sig.codeUnits;
      f.addByte(sb.length > 63 ? 63 : sb.length);
      f.add(sb.length > 63 ? sb.sublist(0, 63) : sb);
      final rc = _d.send(f.toBytes());
      if (rc == xblobSendBusy) return;
      if (rc < 0) return _fail(xblobFailIo, false);
      _state = _St.sHashes;
      _hashesSent = 0;
    }
    if (_state == _St.sHashes) {
      final per = (_frameMax - (_hdr + 3)) ~/ kXblobHashLen;
      while (_hashesSent < nblocks) {
        if (_framesSent - _ack >= kXblobWindow) return; // credit spent
        var count = nblocks - _hashesSent;
        if (count > per) count = per;
        final f = _frame(xblobTHashes);
        _w16(f, _hashesSent);
        f.addByte(count);
        for (var j = 0; j < count; j++) {
          final idx = _hashesSent + j;
          final off = idx * blockSize;
          var want = blockSize;
          if (off + want > size) want = size - off;
          final blk = _d.blockRead(off, want);
          if (blk == null || blk.isEmpty) return _fail(xblobFailIo, true);
          f.add(_blockHash(blk));
        }
        final rc = _d.send(f.toBytes());
        if (rc == xblobSendBusy) return;
        if (rc < 0) return _fail(xblobFailIo, false);
        _hashesSent += count;
        _framesSent++;
      }
      // THE SYNC POINT: no block before the receiver says READY.
      _state = _St.sWaitReady;
      return;
    }
    if (_state == _St.sBlocks) {
      while (_cursor < nblocks) {
        if (!_sendBm[_cursor]) {
          _cursor++;
          continue;
        }
        if (_framesSent - _ack >= kXblobWindow) return;
        final off = _cursor * blockSize;
        var want = blockSize;
        if (off + want > size) want = size - off;
        final f = _frame(xblobTBlock);
        _w16(f, _cursor);
        final blk = _d.blockRead(off, want);
        if (blk == null || blk.isEmpty) return _fail(xblobFailIo, true);
        f.add(blk);
        final rc = _d.send(f.toBytes());
        if (rc == xblobSendBusy) return;
        if (rc < 0) return _fail(xblobFailIo, false);
        _cursor++;
        _framesSent++;
      }
      if (!_doneSent) {
        final rc = _d.send(_frame(xblobTDone).toBytes());
        if (rc == xblobSendBusy) return;
        if (rc < 0) return _fail(xblobFailIo, false);
        _doneSent = true;
        _state = _St.sWaitNeed;
      }
    }
  }

  void _serverRx(List<int> d) {
    final type = d[1];
    if (type == xblobTAck) {
      if (d.length >= _hdr + 4) {
        final a = _r32(d, _hdr);
        if (a > _ack) _ack = a;
        _pump();
      }
      return;
    }
    if (type == xblobTReady) {
      if (_state != _St.sWaitReady && _state != _St.sBlocks) return;
      _cursor = 0;
      _doneSent = false;
      _framesSent = 0;
      _ack = 0; // new pass, fresh window
      _state = _St.sBlocks;
      _pump();
      return;
    }
    if (type == xblobTNeed) {
      if (d.length < _hdr + 2) return;
      final nb = _r16(d, _hdr);
      final bmBytes = (nb + 7) ~/ 8;
      if (d.length < _hdr + 2 + bmBytes || nb != nblocks) return;
      for (var i = 0; i < nb; i++) {
        _sendBm[i] = (d[_hdr + 2 + (i >> 3)] >> (i & 7)) & 1 == 1;
      }
      _cursor = 0;
      _doneSent = false;
      _framesSent = 0;
      _ack = 0; // per-pass window
      _state = _St.sBlocks;
      _pump();
      return;
    }
    if (type == xblobTStart) {
      // Receiver restarted (a HASHES gap): resend everything, fresh pass.
      for (var i = 0; i < nblocks; i++) {
        _sendBm[i] = true;
      }
      _cursor = 0;
      _hashesSent = 0;
      _doneSent = false;
      _framesSent = 0;
      _ack = 0;
      _state = _St.sManifest;
      _pump();
      return;
    }
    if (type == xblobTOk) {
      _state = _St.sDead;
      _d.done(true);
      return;
    }
    if (type == xblobTFail || type == xblobTBye) {
      _state = _St.sDead;
      _d.done(false);
    }
  }

  // ── RECEIVER ── (mirrors recv_rx / recv_progress / tick)
  void _sendStart() {
    final f = _frame(xblobTStart)..add(sha);
    _d.send(f.toBytes());
  }

  void _sendAck() {
    final f = _frame(xblobTAck);
    _w32(f, _consumed);
    if (_d.send(f.toBytes()) == xblobSendOk) {
      _lastAckSent = _consumed; // else the next frame retries
    }
  }

  void _maybeAck() {
    if (_consumed - _lastAckSent >= kXblobAckEvery) _sendAck();
  }

  void _sendNeed() {
    final f = _frame(xblobTNeed);
    _w16(f, nblocks);
    final bm = Uint8List((nblocks + 7) ~/ 8);
    for (var i = 0; i < nblocks; i++) {
      if (!_have[i]) bm[i >> 3] |= 1 << (i & 7);
    }
    f.add(bm);
    _d.send(f.toBytes());
  }

  void _progress(int nowMs) {
    if (_state != _St.rRecv) return;
    _lastRxMs = nowMs;
    if (_hashesGot < nblocks) {
      if (++_rounds > kXblobMaxRounds) return _fail(xblobFailRounds, true);
      _consumed = 0;
      _lastAckSent = 0;
      _sendStart();
      return;
    }
    if (_got >= nblocks) {
      _d.send(_frame(xblobTOk).toBytes());
      _state = _St.rDone;
      _d.done(true);
      return;
    }
    if (_got == 0) {
      // Hashes complete, nothing arrived: the READY (or the first blocks)
      // went missing. Say READY again — idempotent on the server.
      if (++_rounds > kXblobMaxRounds) return _fail(xblobFailRounds, true);
      _consumed = 0;
      _lastAckSent = 0;
      _d.send(_frame(xblobTReady).toBytes());
      return;
    }
    if (++_rounds > kXblobMaxRounds) return _fail(xblobFailRounds, true);
    _consumed = 0;
    _lastAckSent = 0; // the re-blast is a new pass
    _sendNeed();
  }

  void _recvRx(List<int> d, int nowMs) {
    final type = d[1];
    if (type == xblobTManifest) {
      var o = _hdr;
      if (d.length < o + 1 + 32 + 4 + 2 + 2 + 1 + 1) return;
      o += 1; // ver
      for (var i = 0; i < 32; i++) {
        if (d[o + i] != sha[i]) return _fail(xblobFailSha, true);
      }
      o += 32;
      final msize = _r32(d, o);
      o += 4;
      blockSize = _r16(d, o);
      o += 2;
      nblocks = _r16(d, o);
      o += 2;
      final hashlen = d[o++];
      var sl = d[o++];
      if (nblocks > kXblobMaxBlocks || hashlen != kXblobHashLen || msize != size) {
        return _fail(xblobFailBig, true);
      }
      if (sl > 63) sl = 63;
      if (d.length < o + sl) return;
      sig = String.fromCharCodes(d.sublist(o, o + sl));
      for (var i = 0; i < kXblobMaxBlocks; i++) {
        _have[i] = false;
        _hbits[i] = false;
      }
      _got = 0;
      _hashesGot = 0;
      _manifestOk = true;
      _consumed = 0;
      _lastAckSent = 0;
      _state = _St.rRecv;
      _lastRxMs = nowMs;
      return;
    }
    if (!_manifestOk) return;

    if (type == xblobTHashes) {
      _consumed++; // pacing counts arrivals, not acceptance
      _lastRxMs = nowMs;
      _maybeAck();
      if (d.length < _hdr + 3) return;
      final start = _r16(d, _hdr);
      final count = d[_hdr + 2];
      if (start + count > nblocks) return;
      if (d.length < _hdr + 3 + count * kXblobHashLen) return;
      for (var j = 0; j < count; j++) {
        final idx = start + j;
        if (!_hbits[idx]) {
          for (var k = 0; k < kXblobHashLen; k++) {
            _bhash[idx * kXblobHashLen + k] = d[_hdr + 3 + j * kXblobHashLen + k];
          }
          _hbits[idx] = true;
          _hashesGot++;
        }
      }
      if (_hashesGot >= nblocks && _got < nblocks) {
        // Everything verifiable is in hand: cross the sync point, fresh pass.
        _consumed = 0;
        _lastAckSent = 0;
        _d.send(_frame(xblobTReady).toBytes());
      }
      return;
    }
    if (type == xblobTBlock) {
      _consumed++; // even a discarded block used the link
      _lastRxMs = nowMs;
      _maybeAck();
      if (d.length < _hdr + 2) return;
      final idx = _r16(d, _hdr);
      final data = Uint8List.fromList(d.sublist(_hdr + 2));
      if (idx >= nblocks || data.isEmpty) return;
      if (_have[idx]) return; // already have it
      if (!_hbits[idx]) return; // no hash to check against yet
      final h = _blockHash(data);
      for (var k = 0; k < kXblobHashLen; k++) {
        if (h[k] != _bhash[idx * kXblobHashLen + k]) return; // corrupt
      }
      if (!_d.blockWrite(idx * blockSize, data)) return;
      _have[idx] = true;
      _got++;
      // Completion is the last block, not the DONE frame: a dropped DONE
      // must not strand a receiver that already holds everything.
      if (_got >= nblocks && _hashesGot >= nblocks) _progress(nowMs);
      return;
    }
    if (type == xblobTDone) {
      _progress(nowMs);
      return;
    }
    if (type == xblobTFail || type == xblobTBye) {
      _state = _St.rDead;
      _d.done(false);
    }
  }

  // ── dispatch ──
  void rx(List<int> d, int nowMs) {
    if (d.length < _hdr || d[0] != kXblobMagic) return;
    if (role == 1) {
      _serverRx(d);
    } else {
      _recvRx(d, nowMs);
    }
  }

  /// The transport can take more: resume a blast paused on busy.
  void txReady() {
    if (role == 1 &&
        (_state == _St.sManifest ||
            _state == _St.sHashes ||
            _state == _St.sBlocks)) {
      _pump();
    }
  }

  /// Call ~10 Hz: drives the receiver's stall→retry timer.
  void tick(int nowMs) {
    if (role != 0) return;
    if (nowMs - _lastRxMs < kXblobStallMs) return;
    if (_state == _St.rManifest) {
      // Waiting for the MANIFEST and hearing nothing: the START is retried
      // like everything else, bounded by the same round count.
      if (++_rounds > kXblobMaxRounds) return _fail(xblobFailRounds, true);
      _lastRxMs = nowMs;
      _sendStart();
      return;
    }
    if (_state != _St.rRecv || !_manifestOk) return;
    if (_got >= nblocks) return;
    _progress(nowMs);
  }
}
