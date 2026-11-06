/*
 * Copyright (c) Max Brito and XPRS contributors
 * License: BSD-3-Clause
 *
 * Materialise one file out of the content-addressed archive so the OS can open
 * it (a PDF in a reader, an APK in the installer, a photo in the gallery).
 *
 * The blob is a file next to the archive's database (MediaArchive.blobPathOf),
 * encrypted on an encrypted profile, and can be tens or hundreds of MB.
 * Reading and decrypting it through MediaArchive.get() would pull all of that
 * through the isolate that draws the UI (docs/performance.md §4.1, rule 10).
 * So the read, the decryption and the write happen on a WORKER isolate: one
 * Isolate.run per user-initiated open — never per item, never on a hot path
 * (§3.1). The file key is computed here (the keyring lives on this isolate)
 * and handed over.
 */

import 'dart:io';
import 'dart:isolate';

import '../../profile/secure_file.dart';

/// Arguments for the worker (must be a plain, sendable value).
class _ExportJob {
  final String blobPath;
  final String? fileKey; // zx password; null: the blob is a plain file
  final String outPath;
  const _ExportJob(this.blobPath, this.fileKey, this.outPath);
}

/// Copy the blob at [blobPath] (MediaArchive.blobPathOf) into [outPath],
/// decrypted, and return the path (null when the archive does not hold it).
///
/// Runs off the calling isolate. Reuses an existing export when it is already
/// there and non-empty — a second tap on the same file must not rewrite
/// 300 MB.
Future<String?> exportArchiveFile({
  required String blobPath,
  required String outPath,
}) async {
  final existing = File(outPath);
  if (existing.existsSync() && existing.lengthSync() > 0) return outPath;
  final job = _ExportJob(blobPath, SecureProfileFile.fileKeyFor(blobPath), outPath);
  return Isolate.run(() => _export(job));
}

String? _export(_ExportJob job) {
  try {
    final src = File(job.blobPath);
    if (!src.existsSync() || src.lengthSync() == 0) return null;
    final out = File(job.outPath);
    out.parent.createSync(recursive: true);
    // Write to a temp sibling and rename: a killed export must never leave a
    // half-written file behind that a later open would hand to the OS as if it
    // were whole.
    final tmp = File('${job.outPath}.part');
    final key = job.fileKey;
    if (key == null) {
      // A plain blob is the file itself: copied, never read into memory.
      src.copySync(tmp.path);
    } else {
      // An encrypted blob is a one-entry .zx archive held in memory
      // (zxUnpackBytes), so it is read whole.
      // arch-ignore: no-whole-file-read a one-entry .zx unpacked in memory; worker isolate, one user-initiated open
      final raw = src.readAsBytesSync();
      tmp.writeAsBytesSync(SecureProfileFile.unwrap(raw, key), flush: true);
    }
    tmp.renameSync(job.outPath);
    return job.outPath;
  } catch (_) {
    return null;
  }
}
