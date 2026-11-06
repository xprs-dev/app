/// Web: no files of an earlier build to remove.
Future<void> sweepLegacySqlite(String root) async {}

bool isLegacySqliteFile(String path) => false;

bool isSqliteFile(String path) => false;
