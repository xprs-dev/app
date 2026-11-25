// The home screen's three bars on a fresh profile are Status, Chat and
// Check-in. Mesh is not one: the devices bar under them opens it, and the dock
// leaves it out for the same reason (_kStatusBarWapp, launcher/home_modules.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/services/launch_count_store.dart';
import 'package:xprs/services/preferences_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
    await PreferencesService.instance();
  });

  test('a fresh profile shows Status, Chat and Check-in as bars', () async {
    expect(await LaunchCountStore.instance.preferredModules(3),
        ['social', 'chat', 'checkin']);
  });

  test('Mesh is behind the devices bar, not on a bar of its own', () async {
    expect(LaunchCountStore.kDefaultModuleWapps, isNot(contains('mesh')));
  });

}
