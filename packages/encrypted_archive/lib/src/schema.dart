/// Archive schema and migrations (zxdb, SQLite's dialect).
library;

import 'package:zx/zxdb.dart';

import 'options.dart';

/// Current schema version.
const int currentSchemaVersion = 1;

/// Magic string identifying archive format.
const String archiveMagic = 'EARCH01';

/// Opens (or creates) the archive's database file. Durable: the archive
/// holds a profile's files, and a commit must survive a power cut. LZ4 pages
/// (the chunks are encrypted, so stronger compression would gain nothing)
/// and caches sized for one open archive on a phone.
ZxDb openArchiveDb(String path) => zxDbOpenFile(path,
    options: ZxDbStoreOptions(
        compression: 'fast',
        durable: true,
        pageCacheBytes: 8 << 20,
        blockCacheBytes: 4 << 20,
        txnMemoryBytes: 32 << 20));

/// Kept for the archive's open path: SQLite's pragmas meant nothing to
/// zxdb (it has no page size, cache or journal settings per connection).
void configurePragmas(ZxDb db, ArchiveOptions options) {}

/// Create all tables for a new archive.
void createSchema(ZxDb db) {
  // Archive header (singleton)
  db.execute('''
    CREATE TABLE archive_header (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      magic TEXT NOT NULL,
      schema_version INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      salt BLOB NOT NULL,
      verification_hash BLOB NOT NULL,
      encrypted_master_key BLOB,
      options_json TEXT NOT NULL,
      description TEXT
    )
  ''');

  // Files table
  db.execute('''
    CREATE TABLE files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL,
      type INTEGER NOT NULL DEFAULT 0,
      size INTEGER NOT NULL DEFAULT 0,
      stored_size INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL,
      content_hash BLOB,
      encryption_nonce BLOB,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      permissions INTEGER,
      symlink_target TEXT,
      metadata_json TEXT,
      deleted INTEGER NOT NULL DEFAULT 0
    )
  ''');

  // Unique path index (only for non-deleted entries)
  db.execute('''
    CREATE UNIQUE INDEX idx_files_path ON files(path) WHERE deleted = 0
  ''');

  // Index for listing directories
  db.execute('''
    CREATE INDEX idx_files_deleted ON files(deleted)
  ''');

  // Chunks table
  db.execute('''
    CREATE TABLE chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_id INTEGER NOT NULL,
      sequence INTEGER NOT NULL,
      size_plain INTEGER NOT NULL,
      size_stored INTEGER NOT NULL,
      compression INTEGER NOT NULL DEFAULT 0,
      data BLOB NOT NULL,
      auth_tag BLOB NOT NULL,
      content_hash BLOB,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
      UNIQUE (file_id, sequence)
    )
  ''');

  // Index for reading chunks in order
  db.execute('''
    CREATE INDEX idx_chunks_file_seq ON chunks(file_id, sequence)
  ''');

  // Deduplication references (optional feature)
  db.execute('''
    CREATE TABLE dedup_refs (
      content_hash BLOB PRIMARY KEY,
      chunk_id INTEGER NOT NULL,
      ref_count INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (chunk_id) REFERENCES chunks(id)
    )
  ''');

  // Archive statistics (singleton)
  db.execute('''
    CREATE TABLE archive_stats (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      total_files INTEGER NOT NULL DEFAULT 0,
      total_size INTEGER NOT NULL DEFAULT 0,
      total_stored_size INTEGER NOT NULL DEFAULT 0,
      total_chunks INTEGER NOT NULL DEFAULT 0,
      dedup_savings INTEGER NOT NULL DEFAULT 0,
      last_vacuum_at INTEGER,
      last_integrity_check_at INTEGER
    )
  ''');

  // Initialize stats row
  db.execute('''
    INSERT INTO archive_stats (id, total_files, total_size, total_stored_size, total_chunks, dedup_savings)
    VALUES (1, 0, 0, 0, 0, 0)
  ''');
}


/// SQL statements for common operations.
class ArchiveSQL {
  // Header operations
  static const insertHeader = '''
    INSERT INTO archive_header (id, magic, schema_version, created_at, salt, verification_hash, encrypted_master_key, options_json, description)
    VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectHeader = '''
    SELECT * FROM archive_header WHERE id = 1
  ''';

  static const updateHeaderPassword = '''
    UPDATE archive_header SET salt = ?, verification_hash = ?, encrypted_master_key = ? WHERE id = 1
  ''';

  // File operations
  static const insertFile = '''
    INSERT INTO files (path, type, size, stored_size, created_at, modified_at, content_hash, encryption_nonce, chunk_count, permissions, symlink_target, metadata_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectFileByPath = '''
    SELECT * FROM files WHERE path = ? AND deleted = 0
  ''';

  static const selectFileById = '''
    SELECT * FROM files WHERE id = ?
  ''';

  static const listFiles = '''
    SELECT * FROM files WHERE deleted = 0 ORDER BY path
  ''';

  static const listFilesWithPrefix = '''
    SELECT * FROM files WHERE path LIKE ? AND deleted = 0 ORDER BY path
  ''';

  static const listFilesIncludingDeleted = '''
    SELECT * FROM files ORDER BY path
  ''';

  static const softDeleteFile = '''
    UPDATE files SET deleted = 1 WHERE path = ? AND deleted = 0
  ''';

  static const hardDeleteFile = '''
    DELETE FROM files WHERE id = ?
  ''';

  static const renameFile = '''
    UPDATE files SET path = ?, modified_at = ? WHERE path = ? AND deleted = 0
  ''';

  static const updateFileStats = '''
    UPDATE files SET size = ?, stored_size = ?, chunk_count = ?, content_hash = ?, modified_at = ? WHERE id = ?
  ''';

  // Chunk operations
  static const insertChunk = '''
    INSERT INTO chunks (file_id, sequence, size_plain, size_stored, compression, data, auth_tag, content_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static const selectChunks = '''
    SELECT * FROM chunks WHERE file_id = ? ORDER BY sequence
  ''';

  static const selectChunkBySequence = '''
    SELECT * FROM chunks WHERE file_id = ? AND sequence = ?
  ''';

  static const deleteChunksByFileId = '''
    DELETE FROM chunks WHERE file_id = ?
  ''';

  // Dedup operations
  static const selectDedupRef = '''
    SELECT * FROM dedup_refs WHERE content_hash = ?
  ''';

  static const insertDedupRef = '''
    INSERT INTO dedup_refs (content_hash, chunk_id, ref_count) VALUES (?, ?, 1)
  ''';

  static const incrementDedupRef = '''
    UPDATE dedup_refs SET ref_count = ref_count + 1 WHERE content_hash = ?
  ''';

  static const decrementDedupRef = '''
    UPDATE dedup_refs SET ref_count = ref_count - 1 WHERE content_hash = ?
  ''';

  static const deleteDedupRefIfZero = '''
    DELETE FROM dedup_refs WHERE content_hash = ? AND ref_count <= 0
  ''';

  // Stats operations
  // The totals are counted when asked (zxdb has no triggers to keep a
  // running sum, and a stats screen is not a hot path); the stats row keeps
  // what nothing else records: dedup savings and the maintenance times.
  static const selectStats = '''
    SELECT
      (SELECT COUNT(*) FROM files WHERE deleted = 0 AND type = 0) AS total_files,
      (SELECT COALESCE(SUM(size), 0) FROM files WHERE deleted = 0 AND type = 0) AS total_size,
      (SELECT COALESCE(SUM(stored_size), 0) FROM files WHERE deleted = 0 AND type = 0) AS total_stored_size,
      (SELECT COUNT(*) FROM chunks) AS total_chunks,
      s.dedup_savings, s.last_vacuum_at, s.last_integrity_check_at
    FROM archive_stats s WHERE s.id = 1
  ''';

  static const countDirectories = '''
    SELECT COUNT(*) as count FROM files WHERE type = 1 AND deleted = 0
  ''';

  static const updateDedupSavings = '''
    UPDATE archive_stats SET dedup_savings = ? WHERE id = 1
  ''';

  static const updateVacuumTime = '''
    UPDATE archive_stats SET last_vacuum_at = ? WHERE id = 1
  ''';

  static const updateIntegrityCheckTime = '''
    UPDATE archive_stats SET last_integrity_check_at = ? WHERE id = 1
  ''';

  // Vacuum operations
  static const selectDeletedFiles = '''
    SELECT id FROM files WHERE deleted = 1
  ''';

  static const hardDeleteAllDeleted = '''
    DELETE FROM files WHERE deleted = 1
  ''';
}
