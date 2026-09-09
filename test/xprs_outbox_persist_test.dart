/*
 * What this station sent, remembered across a restart.
 *
 * The bench case, 2026-09-09: the desktop sent a message to a phone that was
 * off, was itself closed, and came back to an archiver handing it the receipt.
 * The pocket was session-lived, so there was no row to advance — the log said
 * "status only, no outbox row". Two costs, and the visible one is the smaller:
 * the tick is a nicety, but `stateOf` answering null for a message that IS
 * delivered makes the mailbox leave ANOTHER copy with an archiver and leaves
 * the retry ladder with nothing to stop it.
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprs_outbox');
    path = '${tmp.path}/xprs_outbox.sqlite3';
    XprsOutbox.debugReset();
    XprsOutbox.instance.init(path);
  });

  tearDown(() {
    XprsOutbox.debugReset();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Close and reopen the store, which is what a restart is.
  void restart() {
    XprsOutbox.instance.close();
    XprsOutbox.debugReset();
    XprsOutbox.instance.init(path);
  }

  test('a message we sent is still ours after a restart', () {
    XprsOutbox.instance.noteSent('4bd6b9', 'X1WATT');
    restart();
    expect(XprsOutbox.instance.stateOf('4bd6b9'), 'sent');
    expect(XprsOutbox.restored, 1);
  });

  test('a receipt that arrives after the restart advances the row', () {
    XprsOutbox.instance.noteSent('4bd6b9', 'X1WATT');
    restart();
    XprsOutbox.instance
        .noteReceipt('4bd6b9', state: 'ack', peer: 'X1WATT');
    expect(XprsOutbox.instance.stateOf('4bd6b9'), 'delivered');
    expect(XprsOutbox.advanced, 1);
    expect(XprsOutbox.unknown, 0,
        reason: 'this is the "status only, no outbox row" case, ended');
  });

  test('and a delivered message is not deposited with an archiver again', () {
    // What `XprsMailbox.depositIfUnanswered` asks. Before the store, this
    // answered null after a restart and another copy went out.
    XprsOutbox.instance.noteSent('4bd6b9', 'X1WATT');
    XprsOutbox.instance.noteReceipt('4bd6b9', state: 'ack', peer: 'X1WATT');
    restart();
    expect(XprsOutbox.instance.stateOf('4bd6b9'), 'delivered');
  });

  test('a late ack cannot walk a read back to delivered', () {
    XprsOutbox.instance.noteSent('4bd6b9', 'X1WATT');
    XprsOutbox.instance.noteReceipt('4bd6b9', state: 'read', peer: 'X1WATT');
    XprsOutbox.instance.noteReceipt('4bd6b9', state: 'ack', peer: 'X1WATT');
    restart();
    expect(XprsOutbox.instance.stateOf('4bd6b9'), 'read');
  });

  test('a receipt for something we never sent is still a status, not a row',
      () {
    XprsOutbox.instance
        .noteReceipt('ffffff', state: 'ack', peer: 'X1WATT');
    expect(XprsOutbox.unknown, 1);
    expect(XprsOutbox.instance.stateOf('ffffff'), isNull);
  });

  test('the pocket holds the hot end, the file holds the rest', () {
    for (var i = 0; i < XprsOutbox.maxRows + 40; i++) {
      XprsOutbox.instance.noteSent('id${i.toString().padLeft(5, '0')}', 'X1WATT');
    }
    // Evicted from memory, still on disk: a receipt for it must find its row.
    expect(XprsOutbox.instance.stateOf('id00000'), 'sent');
    XprsOutbox.instance.noteReceipt('id00000', state: 'ack', peer: 'X1WATT');
    expect(XprsOutbox.instance.stateOf('id00000'), 'delivered');
    expect(XprsOutbox.unknown, 0);
  });
}
