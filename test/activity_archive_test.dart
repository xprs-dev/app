import 'dart:io';

import 'package:xprs/profile/profile_storage_fs.dart';
import 'package:xprs/wapp/geoui/activity_archive.dart';
import 'package:xprs/wapp/geoui/widgets/activity_feed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs_core/src/storage/store_db.dart';

void main() {

  final dirs = <Directory>[];
  String repeated(String value, int count) => List.filled(count, value).join();
  final baseTime = DateTime.now().millisecondsSinceEpoch - 60000;

  ActivityArchive archive(Directory dir, String name) =>
      ActivityArchive.forStorage(
        makeFilesystemStorage(dir.path),
        fileName: name,
      );

  Map<String, dynamic> note({
    required String id,
    required String author,
    required String source,
    required int time,
  }) => {
    'mid': id,
    'author': author,
    'from': author.substring(0, 12),
    'source': source,
    'text': 'note $id',
    't': time,
  };

  tearDownAll(() {
    for (final dir in dirs) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('one XPRS post, one row (one author and ts, XPRS.md 7.6)', () {
    const t = 1795022699000;
    Map<String, dynamic> copy(String mid, String text, {bool deleted = false}) => {
          'mid': mid,
          'from': 'X1WATT',
          'text': deleted ? '' : text,
          if (deleted) 'deleted': true,
          't': t,
          'source': 'xprs',
        };

    test('a second identifier for the same post is not kept', () {
      final dir = Directory.systemTemp.createTempSync('activity_xprs_');
      dirs.add(dir);
      final a = archive(dir, 'one.zx');
      a.add(copy('aa0001', 'you should see the link'));
      a.add(copy('bb0002', 'you should seethe link'));
      final rows = a.recent().where((r) => r['from'] == 'X1WATT').toList();
      expect(rows, hasLength(1));
      expect(rows.single['mid'], 'aa0001');
      a.close();
    });

    test('copies kept by older builds merge on open; a withdrawal wins', () {
      final dir = Directory.systemTemp.createTempSync('activity_merge_');
      dirs.add(dir);
      final a = archive(dir, 'merge.zx');
      a.add(copy('aa0001', 'you should see the link'));
      a.revise('aa0001', '', deleted: true, by: 'X1WATT');
      a.close();
      // What an older build left behind: the same post under two more ids.
      final db = openStoreDb('${dir.path}/merge.zx');
      for (final (mid, text) in [
        ('bb0002', 'you should seethe link'),
        ('cc0003', 'you should see the link'),
      ]) {
        db.execute(
            "INSERT INTO activity(t,dir,from_call,text,kind,mid,parent,source) "
            "VALUES(?,?,?,?,?,?,?,?)",
            [t, 'in', 'X1WATT', text, 'msg', mid, '', 'xprs']);
      }
      // And a different post of the same author, which stays.
      db.execute(
          "INSERT INTO activity(t,dir,from_call,text,kind,mid,parent,source) "
          "VALUES(?,?,?,?,?,?,?,?)",
          [t + 60000, 'in', 'X1WATT', 'another post', 'msg', 'dd0004', '', 'xprs']);
      db.dispose();
      final rows = a.recent().where((r) => r['from'] == 'X1WATT').toList();
      expect(rows.map((r) => r['mid']), unorderedEquals(['aa0001', 'dd0004']),
          reason: 'the deleted copy stands for the post');
      a.close();
    });

    test('without a withdrawal the longest text (spaces kept) stays', () {
      final dir = Directory.systemTemp.createTempSync('activity_long_');
      dirs.add(dir);
      final a = archive(dir, 'long.zx');
      a.add(copy('bb0002', 'you should seethe link'));
      a.close();
      final db = openStoreDb('${dir.path}/long.zx');
      db.execute(
          "INSERT INTO activity(t,dir,from_call,text,kind,mid,parent,source) "
          "VALUES(?,?,?,?,?,?,?,?)",
          [t, 'in', 'X1WATT', 'you should see the link', 'msg', 'cc0003', '', 'xprs']);
      db.dispose();
      final rows = a.recent().where((r) => r['from'] == 'X1WATT').toList();
      expect(rows.single['text'], 'you should see the link');
      a.close();
    });
  });

  test('legacy migration routes by provenance and exact follow key', () {
    final dir = Directory.systemTemp.createTempSync('activity_route_');
    dirs.add(dir);
    final legacy = archive(dir, 'activity.zx');
    final all = archive(dir, 'social_all.zx');
    final following = archive(dir, 'social_following.zx');
    final followed = repeated('a', 64);
    final stranger = repeated('b', 64);

    legacy.add(
      note(
        id: repeated('1', 64),
        author: followed,
        source: 'firehose',
        time: baseTime + 1000,
      ),
    );
    legacy.add(
      note(
        id: repeated('2', 64),
        author: stranger,
        source: 'following',
        time: baseTime + 2000,
      ),
    );
    legacy.add(
      note(
        id: repeated('3', 64),
        author: stranger,
        source: '',
        time: baseTime + 3000,
      ),
    );

    legacy.copyRoutedTo(
      all: all,
      following: following,
      followedPubkeys: {followed},
    );

    expect(all.recent().map((p) => p['mid']), [repeated('1', 64)]);
    expect(following.recent().map((p) => p['mid']), [
      repeated('1', 64),
      repeated('2', 64),
    ]);
    expect(following.recent().every((p) => p['source'] == 'following'), isTrue);
  });

  test('All cleanup preserves archived batches but removes mixed sources', () {
    final dir = Directory.systemTemp.createTempSync('activity_cleanup_');
    dirs.add(dir);
    final all = archive(dir, 'social_all.zx');
    final author = repeated('c', 64);
    all.add(
      note(
        id: repeated('4', 64),
        author: author,
        source: 'firehose',
        time: baseTime + 1000,
      ),
    );
    all.add(
      note(
        id: repeated('5', 64),
        author: author,
        source: 'firehose',
        time: baseTime + 2000,
      ),
    );
    all.add(
      note(
        id: repeated('6', 64),
        author: author,
        source: 'following',
        time: baseTime + 3000,
      ),
    );

    all.retainSources({'firehose', 'discovery'});

    expect(all.recent().map((p) => p['mid']), [
      repeated('4', 64),
      repeated('5', 64),
    ]);
  });

  test('independent archives both retain the same event id', () {
    final dir = Directory.systemTemp.createTempSync('activity_dual_');
    dirs.add(dir);
    final all = archive(dir, 'social_all.zx');
    final following = archive(dir, 'social_following.zx');
    final author = repeated('d', 64);
    final id = repeated('7', 64);

    all.add(
      note(id: id, author: author, source: 'firehose', time: baseTime + 1000),
    );
    following.add(
      note(id: id, author: author, source: 'following', time: baseTime + 1000),
    );

    expect(all.recent(), hasLength(1));
    expect(following.recent(), hasLength(1));
  });

  test('older pages are bounded and returned oldest first', () {
    final dir = Directory.systemTemp.createTempSync('activity_pages_');
    dirs.add(dir);
    final all = archive(dir, 'social_all.zx');
    final author = repeated('e', 64);
    for (var i = 1; i <= 5; i++) {
      all.add(
        note(
          id: repeated(i.toString(), 64),
          author: author,
          source: 'firehose',
          time: baseTime + i * 1000,
        ),
      );
    }

    final page = all.olderBefore(baseTime + 5000, limit: 2);
    expect(page.map((p) => p['t']), [baseTime + 3000, baseTime + 4000]);
  });

  test('a corrected or withdrawn post comes back as one after a restart (7.8)',
      () {
    final dir = Directory.systemTemp.createTempSync('activity_revise');
    dirs.add(dir);
    var a = archive(dir, 'a.zx');
    a.add({
      'mid': 'aa1111',
      'from': 'X1FRND',
      'text': 'meet at six',
      'source': 'xprs',
      't': baseTime,
    });
    a.add({
      'mid': 'bb2222',
      'from': 'X1FRND',
      'text': 'my phone number',
      'source': 'xprs',
      't': baseTime + 1,
    });
    // Somebody else's correction does nothing; the author's does.
    a.revise('aa1111', 'meet at seven', edited: true, by: 'X3EVIL');
    expect(a.byMid('aa1111')!['text'], 'meet at six');
    a.revise('aa1111', 'meet at seven', edited: true, by: 'X1FRND');
    a.revise('bb2222', '', deleted: true, by: 'X1FRND');
    final rows = {for (final r in a.recent()) r['mid'] as String: r};
    expect(rows['aa1111']!['text'], 'meet at seven');
    expect(activityEdited(rows['aa1111']!), isTrue);
    expect(rows['bb2222']!['text'], '', reason: 'the words are gone');
    expect(activityDeleted(rows['bb2222']!), isTrue);
    expect(activityEdited(rows['bb2222']!), isFalse);
  });
}
