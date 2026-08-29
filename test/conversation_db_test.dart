// Durable conversation history: the properties that had to hold for a phone
// to stop losing every message it had ever received.
import 'dart:ffi';
import 'dart:io';

import 'package:xprs/wapp/geoui/conversation_db.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('convo_db_test');
    dbPath = '${tmp.path}/conversations.sqlite3';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConversationStore attached(ConversationDb db, {String field = 'conversations'}) =>
      ConversationStore()
        ..db = db
        ..dbField = field
        ..loaded = true;

  /// Reopen the way the page does: `loadInto` restores the THREAD rows, then
  /// the store is attached so a conversation's message tail is read when
  /// something actually looks at it. Loading every thread's messages up front
  /// is the cost this split removed, so the tests reopen the same way the app
  /// does rather than asserting the old shape.
  ConversationStore reopen(ConversationDb db,
      {String field = 'conversations'}) {
    final store = ConversationStore()
      ..dbField = field
      ..loaded = false;
    db.loadInto(field, store);
    return store
      ..db = db
      ..loaded = true;
  }

  test('messages survive close and reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'lxmf:abc', 'title': 'X1RD89'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'in', 'text': 'LIVE-D2P-001'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'out', 'text': 'LIVE-P2D-001'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    expect(restored.items['lxmf:abc']!.title, 'X1RD89');
    expect(
      restored.messagesOf('lxmf:abc').map((m) => m['text']).toList(),
      ['LIVE-D2P-001', 'LIVE-P2D-001'],
    );
    db2.close();
  });

  test('a store that failed to load never writes', () {
    // Seed real history.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c1', 'title': 'kept'});
    store.addMessage({'id': 'c1', 'dir': 'in', 'text': 'precious'});
    db.close();

    // A page whose restore threw: db handle present, loaded false.
    final db2 = ConversationDb.open(dbPath);
    final broken = ConversationStore()
      ..db = db2
      ..dbField = 'conversations'
      ..loaded = false;
    broken.upsert({'id': 'c1', 'title': 'clobbered'});
    broken.addMessage({'id': 'c1', 'dir': 'in', 'text': 'overwrite'});
    broken.clear();
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = reopen(db3);
    expect(check.items['c1']?.title, 'kept', reason: 'history was overwritten');
    expect(check.messagesOf('c1').single['text'], 'precious');
    db3.close();
  });

  test('a message carrying a mid is stored once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < 3; i++) {
      store.addMessage(
          {'id': 'g', 'dir': 'in', 'text': 'hello', 'mid': 'abc123'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    expect(restored.messagesOf('g'), hasLength(1));
    db2.close();
  });

  test('the same message re-emitted after an engine restart shows once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // No mid (a 1:1 LXMF message), same content signature both times.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    db.close();

    // Engine restarts, re-reads the durable inbox, re-emits the same message.
    final db2 = ConversationDb.open(dbPath);
    final reloaded = reopen(db2);
    reloaded
        .addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    expect(reloaded.messagesOf('c'), hasLength(1));
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = reopen(db3);
    expect(check.messagesOf('c'), hasLength(1));
    db3.close();
  });

  test('a database written before the ckey column still opens', () {
    // Simulate the older schema exactly: no ckey column, one stored message.
    final legacyDb = ConversationDb.open(dbPath);
    legacyDb.close();
    final raw = sqlite3.open(dbPath);
    raw.execute('DROP INDEX IF EXISTS msg_key');
    raw.execute('ALTER TABLE messages DROP COLUMN ckey');
    raw.execute(
        "INSERT INTO messages(field, convo_id, mid, body) VALUES('conversations','c','', ?)",
        ['{"dir":"in","text":"older build"}']);
    raw.dispose();

    final db = ConversationDb.open(dbPath); // must NOT throw
    final restored = reopen(db);
    expect(restored.messagesOf('c').single['text'], 'older build');
    db.close();
  });

  test('two engines emitting the same message id show one bubble', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // Page engine and headless engine each cursor the host inbox from 0 and
    // re-emit the same LXMF message: same mid (its hash), no content key.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    expect(store.items['c']!.messages, hasLength(1));
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final check = reopen(db2);
    expect(check.messagesOf('c'), hasLength(1));
    db2.close();
  });

  test('legacy JSON imports once, then the DB owns the history', () {
    final legacy = ConversationStore();
    legacy.upsert({'id': 'old', 'title': 'from json'});
    legacy.addMessage({'id': 'old', 'dir': 'in', 'text': 'archived'});

    final db = ConversationDb.open(dbPath);
    expect(db.hasField('conversations'), isFalse);
    db.importStore('conversations', legacy);
    expect(db.hasField('conversations'), isTrue);

    final restored = reopen(db);
    expect(restored.messagesOf('old').single['text'], 'archived');
    db.close();
  });

  test('delivery receipts and reactions survive a reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.addMessage(
        {'id': 'c', 'dir': 'out', 'text': 'hi', 'rid': 'r1', 'mid': 'm1'});
    store.setStatus({'rid': 'r1', 'status': 'delivered'});
    store.react({'mid': 'm1', 'from': 'someone'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    final msg = restored.messagesOf('c').single;
    expect(msg['status'], 'delivered');
    expect(msg['likes'], 1);
    db2.close();
  });

  test('a reopen reads thread rows, not every message', () {
    // The property that keeps the wapp opening in constant time as history
    // grows: the list needs a title, a preview, an unread count and a
    // timestamp, all of which live on the thread row.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var c = 0; c < 5; c++) {
      store.upsert({'id': 'c$c', 'title': 'chat $c', 'subtitle': 'last line'});
      for (var i = 0; i < 40; i++) {
        store.addMessage({'id': 'c$c', 'dir': 'in', 'text': 'm$i'});
      }
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items, hasLength(5), reason: 'every thread is listed');
    expect(fresh.items['c0']!.title, 'chat 0');
    expect(fresh.items['c0']!.subtitle, 'last line',
        reason: 'the list row is complete without reading a single message');
    for (final it in fresh.items.values) {
      expect(it.messages, isEmpty, reason: 'no tail is read until asked for');
    }

    // …and asking for one reads that one, in order, and nothing else.
    fresh
      ..db = db2
      ..loaded = true;
    expect(fresh.messagesOf('c3').map((m) => m['text']).take(3).toList(),
        ['m0', 'm1', 'm2']);
    expect(fresh.items['c4']!.messages, isEmpty,
        reason: 'opening one conversation does not read its neighbours');
    expect(db2.countMessages('conversations'), 200);
    db2.close();
  });

  test('the list preview survives a reopen without reading messages', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c', 'title': 'chat'});
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X3ARK', 'text': 'hello'});
    // A like is not something anybody said.
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X1RD89',
      'text': 'abc12345:like'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items['c']!.lastLine, 'X3ARK: hello');
    expect(fresh.items['c']!.messages, isEmpty,
        reason: 'the preview came off the thread row, not the messages');
    db2.close();
  });

  test('a conversation written before previews were stored gets one', () {
    // The upgrade case: rows exist, none of them carries lastLine, and the
    // messages that used to supply the preview are no longer read at load.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c', 'title': 'chat'});
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X3ARK', 'text': 'older'});
    db.close();

    // Strip it the way an older build would have left the row.
    final raw = sqlite3.open(dbPath);
    raw.execute(
        "UPDATE threads SET meta = json_remove(meta, '\$.lastLine') "
        "WHERE field='conversations'");
    raw.dispose();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items['c']!.lastLine, 'X3ARK: older');
    expect(fresh.items['c']!.messages, isEmpty);
    db2.close();

    // …and it was written back, so the next open asks nothing.
    final db3 = ConversationDb.open(dbPath);
    final again = ConversationStore()..loaded = false;
    db3.loadInto('conversations', again);
    expect(again.items['c']!.lastLine, 'X3ARK: older');
    db3.close();
  });

  test('the per-thread cap is enforced on disk', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < kConvoMaxMessages + 25; i++) {
      store.addMessage({'id': 'big', 'dir': 'in', 'text': 'm$i'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    final msgs = restored.messagesOf('big');
    expect(msgs, hasLength(kConvoMaxMessages));
    expect(msgs.last['text'], 'm${kConvoMaxMessages + 24}');
    db2.close();
  });
}
