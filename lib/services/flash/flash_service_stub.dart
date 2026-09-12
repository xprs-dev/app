/// The web build's FlashService: no USB serial, every verb answers no, and
/// the state says `supported: false` so the wapp writes "No USB here".
library;

class FlashPhase {
  static const idle = 'idle';
  static const failed = 'failed';
}

class FlashService {
  FlashService._();
  static final FlashService instance = FlashService._();

  static bool get supported => false;
  bool get busy => false;

  Future<void> scan({bool force = false}) async {}
  Future<bool> probeDevice(String deviceId) async => false;
  Future<bool> fetchBoard(String id) async => false;
  Future<bool> writeBoard(String deviceId, String id, {bool wipe = false}) async => false;
  void cancel() {}

  Map<String, Object> stateJson() => const {
        'phase': 'idle',
        'busy': false,
        'message': 'No USB here',
        'error': '',
        'supported': false,
        'devices': <Object>[],
        'boards': <Object>[],
        'device': <String, Object>{},
        'board': '',
        'part': '',
        'partIndex': 0,
        'partCount': 0,
        'done': 0,
        'total': 0,
      };
}
