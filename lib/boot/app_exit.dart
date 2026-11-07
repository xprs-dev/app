// Exit XPRS completely (app_exit_io.dart); a no-op on the web.
export 'app_exit_web.dart' if (dart.library.io) 'app_exit_io.dart';
