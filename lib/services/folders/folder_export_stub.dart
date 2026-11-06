library;

/// Web: there is no OS to hand a file to. Null, exactly like an archive that
/// does not hold the key.
Future<String?> exportArchiveFile({
  required String blobPath,
  required String outPath,
}) async =>
    null;
