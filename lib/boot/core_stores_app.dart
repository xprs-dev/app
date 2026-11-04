/*
 * The app's Flutter-plugin-backed implementations of xprs_core's storage
 * seams: settings (shared_preferences), the OS keychain
 * (flutter_secure_storage), shipped files (the asset bundle). Wired into
 * CoreHost at boot by core_host_app.dart, and for tests by
 * test/flutter_test_config.dart.
 */
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs_core/src/platform/asset_source.dart';
import 'package:xprs_core/src/platform/key_value_store.dart';
import 'package:xprs_core/src/platform/secure_store.dart';

/// shared_preferences behind the core's KeyValueStore.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._p);
  final SharedPreferences _p;

  static Future<KeyValueStore> open() async =>
      SharedPreferencesStore(await SharedPreferences.getInstance());

  @override
  bool? getBool(String key) => _p.getBool(key);
  @override
  int? getInt(String key) => _p.getInt(key);
  @override
  double? getDouble(String key) => _p.getDouble(key);
  @override
  String? getString(String key) => _p.getString(key);
  @override
  List<String>? getStringList(String key) => _p.getStringList(key);
  @override
  bool containsKey(String key) => _p.containsKey(key);
  @override
  Set<String> getKeys() => _p.getKeys();
  @override
  Future<bool> setBool(String key, bool value) => _p.setBool(key, value);
  @override
  Future<bool> setInt(String key, int value) => _p.setInt(key, value);
  @override
  Future<bool> setDouble(String key, double value) => _p.setDouble(key, value);
  @override
  Future<bool> setString(String key, String value) => _p.setString(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _p.setStringList(key, value);
  @override
  Future<bool> remove(String key) => _p.remove(key);
}

/// flutter_secure_storage behind the core's SecureStore. The options are the
/// ones device_key_store.dart used before the seam existed.
class FlutterSecureStore implements SecureStore {
  const FlutterSecureStore(this._s);
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// The Flutter asset bundle behind the core's AssetSource.
class BundleAssets implements AssetSource {
  const BundleAssets();
  @override
  Future<List<String>> list() async =>
      (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();
  @override
  Future<String> loadString(String path) => rootBundle.loadString(path);
}
