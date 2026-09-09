// What the switches on an installed device become.
//
// Three preferences that never met -- `xprs.archive` (keep what I hear),
// `xprs.serveHistory` (answer cmd:history) and `xprs.superArchiver` (the old
// always-on flag) -- become two that do: Public archiver, and Always on gated
// on it. Every device already out there has one of these shapes, and the
// update has to read the operator's intent out of it rather than reset them.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xprs/services/preferences_service.dart';

Future<PreferencesService> prefsWith(Map<String, Object> values) async {
  PreferencesService.resetForTest();
  SharedPreferences.setMockInitialValues(values);
  return PreferencesService.instance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => PreferencesService.resetForTest());

  test('a fresh install on this desktop is public', () async {
    // The suite runs on a desktop, which is the powered-station case of
    // XPRS.md 12: it archives what it hears and announces the role.
    final p = await prefsWith({});
    expect(p.xprsPublicArchiver, true);
    expect(p.xprsAlwaysOn, false, reason: 'always-on is always opted into');
    expect(p.xprsKeepFollowed, true);
  });

  test('an operator who turned either legacy switch off stays private',
      () async {
    expect((await prefsWith({'xprs.archive': false})).xprsPublicArchiver, false);
    expect((await prefsWith({'xprs.serveHistory': false})).xprsPublicArchiver,
        false);
  });

  test('a station that was an always-on archiver stays one', () async {
    // The C61 case: made the mesh's archiver by hand, holding mail for five
    // stations. Coming back from the update with the role off would have
    // taken that away without asking.
    final p = await prefsWith({'xprs.superArchiver': true});
    expect(p.xprsPublicArchiver, true);
    expect(p.xprsAlwaysOnStored, true);
    expect(p.xprsAlwaysOn, true);
  });

  test('and using the screen does not undo that migration', () async {
    // `xprs.superArchiver` is dropped when Always on is written. If the public
    // answer were still being derived from it at that point, toggling this
    // switch would quietly make the station private.
    final p = await prefsWith({'xprs.superArchiver': true});
    await p.setXprsAlwaysOn(false);
    expect(p.xprsPublicArchiver, true);
    expect(p.xprsAlwaysOnStored, false);
  });

  test('always-on is meaningless without public, and survives it', () async {
    final p = await prefsWith({'xprs.public': false, 'xprs.alwaysOn': true});
    expect(p.xprsAlwaysOn, false, reason: 'gated on public');
    expect(p.xprsAlwaysOnStored, true,
        reason: 'the operator said so once; turning public back on restores it '
            'rather than making them say it twice');
    await p.setXprsPublicArchiver(true);
    expect(p.xprsAlwaysOn, true);
  });

  test('the named archivers come across under the new key', () async {
    final p = await prefsWith({
      'xprs.superArchivers': ['X1ARKL']
    });
    expect(p.xprsNamedArchivers, ['X1ARKL']);
  });

  test('an explicit choice always wins over any legacy reading', () async {
    final p = await prefsWith({
      'xprs.public': false,
      'xprs.superArchiver': true,
      'xprs.archive': true,
    });
    expect(p.xprsPublicArchiver, false);
  });
}
