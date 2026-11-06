/*
 * xprs_line — the line lane (XPRS.md 13.4, 13.0.2): the client half of the
 * one-port rule. The sockets live in xprs_line_io.dart; a page (dart2js)
 * gets the same names with nothing behind them, the way lib/platform/fs.dart
 * is split (docs/architecture.md).
 */
export 'xprs_line_stub.dart' if (dart.library.io) 'xprs_line_io.dart';
