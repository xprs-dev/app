// One wapp, two engines, one kv.json.
//
// A wapp's KV is held by whichever engines are alive — the page's and the
// headless one's — and each loads the file once, at setStorage. `_saveKv` used
// to rewrite the WHOLE file from that snapshot, so the second engine to write
// rolled back every key the first had set since.
//
// That is not a tidiness problem. Chat guards its one-shot migrations with KV
// tokens, and one of those migrations cleared the entire conversation field —
// every room on the device, the Local room included. A rolled-back token
// re-armed it, so the wipe that was supposed to happen once happened again,
// and with no backfill the history did not come back.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/profile/profile_storage.dart';
import 'package:xprs/wapp/wapp_engine.dart';

void main() {
  late MemoryProfileStorage storage;

  setUp(() => storage = MemoryProfileStorage());

  Map<String, dynamic> onDisk() {
    final b = storage.readBytesSync('kv.json');
    if (b == null) return {};
    return jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
  }

  test('a second engine does not roll back the first engine\'s key', () {
    // Engine A starts, and writes the migration token.
    final a = WappEngine(headless: true)..setStorage(storage);
    a.kvSet('grponly', '3');
    expect(onDisk()['grponly'], '3');

    // Engine B started BEFORE that write, so its snapshot has no token.
    final b = WappEngine(headless: true)..setStorage(storage);
    b.kvSet('recent', '#LOCAL=17');

    expect(onDisk()['grponly'], '3',
        reason: 'B must not un-set a token it never saw — that re-arms the '
            'migration that wiped every conversation');
    expect(onDisk()['recent'], '#LOCAL=17');
  });

  test('a delete still removes the key', () {
    final a = WappEngine(headless: true)..setStorage(storage);
    a.kvSet('doomed', 'x');
    a.kvSet('kept', 'y');
    expect(onDisk()['doomed'], 'x');

    a.kvDelete('doomed');
    expect(onDisk().containsKey('doomed'), isFalse,
        reason: 'the merge must not read a deleted key back off disk');
    expect(onDisk()['kept'], 'y');
  });

  test('setting a key again after deleting it brings it back', () {
    final a = WappEngine(headless: true)..setStorage(storage);
    a.kvSet('k', '1');
    a.kvDelete('k');
    a.kvSet('k', '2');
    expect(onDisk()['k'], '2');
  });
}
