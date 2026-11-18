// The Archiver page and /api/xprs/archiver write through one function
// (lib/services/xprs/archiver_settings.dart), so their side effects cannot
// drift: the archiver list is the unified one (push + mailbox hold), and
// always-on only takes effect on a public archiver.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/archiver_settings.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
    await PreferencesService.instance();
  });

  test('the archiver list is written whole: named and mailbox hold', () async {
    expect(await applyArchiverSettings({'archivers': ['x3arc1', ' X3ARC2 ', '']}),
        isTrue);
    final p = PreferencesService.instanceSync!;
    expect(p.xprsNamedArchivers, ['X3ARC1', 'X3ARC2']);
    expect(p.xprsMailboxHold, 'X3ARC1,X3ARC2');
    expect(p.xprsArchivers, ['X3ARC1', 'X3ARC2']);
  });

  test('always-on needs a public archiver; legacy be sets both', () async {
    final p = PreferencesService.instanceSync!;
    // A desktop defaults to public; say private explicitly.
    await applyArchiverSettings({'public': false});
    await applyArchiverSettings({'alwaysOn': true});
    expect(p.xprsAlwaysOnStored, isTrue);
    expect(p.xprsAlwaysOn, isFalse, reason: 'not public yet');
    await applyArchiverSettings({'alwaysOn': true}, legacy: true);
    expect(p.xprsPublicArchiver, isTrue);
    expect(p.xprsAlwaysOn, isTrue);
  });

  test('limits, dial and room; a zero or bad limit is ignored', () async {
    final p = PreferencesService.instanceSync!;
    await applyArchiverSettings({
      'quotaMb': 2000,
      'maxDays': '30',
      'dial': ' arc.example:4242 ',
      'room': false,
      'roomStations': 0,
      'archiverAuto': false,
    });
    expect(p.xprsArchiveMaxMb, 2000);
    expect(p.xprsArchiveMaxDays, 30);
    expect(p.xprsDial, 'arc.example:4242');
    expect(p.xprsRoom, isFalse);
    expect(p.xprsRoomStations, 500);
    expect(p.xprsArchiverAuto, isFalse);
    await applyArchiverSettings({'quotaMb': -1});
    expect(p.xprsArchiveMaxMb, 2000);
  });

  test('a dial typed by hand outranks the announced one; null falls back',
      () async {
    final p = PreferencesService.instanceSync!;
    p.rememberArchiverDial('X3ARC9', 'arc9.example');
    await applyArchiverSettings({
      'dials': {'x3arc9': '127.0.0.1'},
    });
    // The archiver announcing again does not undo the person's choice.
    p.rememberArchiverDial('X3ARC9', 'arc9.example:4243');
    expect(p.xprsArchiverDials['X3ARC9'], '127.0.0.1');
    expect(p.xprsArchiverDialsHeard['X3ARC9'], 'arc9.example:4243');
    await applyArchiverSettings({
      'dials': {'X3ARC9': null},
    });
    expect(p.xprsArchiverDials['X3ARC9'], 'arc9.example:4243');
    expect(p.xprsArchiverDialsByHand, isEmpty);
  });
}
