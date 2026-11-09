// WappSocialStore on zx: reactions and comments persist per wapp directory,
// survive a reopen, and stay apart between wapps.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/wapp_social_store.dart';

void main() {
  late Directory tmp;
  final s = WappSocialStore.instance;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wapp_social_'));
  tearDown(() {
    s.closeAll();
    tmp.deleteSync(recursive: true);
  });

  test('reactions: add, dedupe by id, count, remove', () {
    final dir = '${tmp.path}/maps';
    Directory(dir).createSync();
    s.addReaction(dir, id: 'r1', npub: 'npub1a', createdAt: 10);
    s.addReaction(dir, id: 'r1', npub: 'npub1a', createdAt: 11); // same id
    s.addReaction(dir, id: 'r2', npub: 'npub1b', reaction: '🔥', createdAt: 20);
    expect(s.reactionCount(dir), 2);
    expect(s.hasReacted(dir, 'npub1b'), isTrue);
    expect(s.hasReacted(dir, 'npub1z'), isFalse);
    expect(s.reactions(dir).map((r) => r['id']), ['r2', 'r1']); // newest first
    s.removeReaction(dir, 'r2');
    expect(s.reactionCount(dir), 1);
  });

  test('comments: top level and replies, kept across a reopen', () {
    final dir = '${tmp.path}/chat';
    Directory(dir).createSync();
    s.addComment(dir, id: 'c1', content: 'first', npub: 'n', createdAt: 1);
    s.addComment(dir, id: 'c2', content: 'second', npub: 'n', createdAt: 2);
    s.addComment(dir,
        id: 'c3', content: 'reply', npub: 'm', parentId: 'c1', createdAt: 3);
    s.close(dir);

    expect(File('$dir/social.zx').existsSync(), isTrue);
    expect(s.commentCount(dir), 3);
    expect(s.topLevelComments(dir).map((c) => c['id']), ['c2', 'c1']);
    expect(s.replies(dir, 'c1').single['content'], 'reply');
    s.removeComment(dir, 'c3');
    expect(s.replies(dir, 'c1'), isEmpty);
  });

  test('each wapp directory has its own store', () {
    final a = '${tmp.path}/a', b = '${tmp.path}/b';
    Directory(a).createSync();
    Directory(b).createSync();
    s.addReaction(a, id: 'x', npub: 'n');
    expect(s.reactionCount(a), 1);
    expect(s.reactionCount(b), 0);
  });
}
