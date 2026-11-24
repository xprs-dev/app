/*
 * IsolateCallsignSource: keys searched on their own isolate where there are
 * isolates, and a source that says it cannot search on the web build, which
 * has none (docs/web.md; tool/arch_guard.dart no-native-import-outside-io-file).
 */
export 'callsign_search_web.dart' if (dart.library.io) 'callsign_search_io.dart';
