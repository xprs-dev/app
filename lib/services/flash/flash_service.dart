/// Flashing a board over USB: the core's one door. The native half is
/// flash_service_io.dart (serial ports, isolates, files); on the web there
/// is no cable, and the stub says so through the same state.
library;

export 'flash_service_stub.dart' if (dart.library.io) 'flash_service_io.dart';
