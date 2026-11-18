// Moved to the shared core package (xprs-dev/core): the one formatted-text
// reader (XPRS.md 4.11) the server and the app share. This shim keeps the
// app's existing imports working; new code should import package:xprs_core.
export 'package:xprs_core/src/util/xprs_md.dart';
