/*
 * Where storage_paths.dart gets its ProfileStorage. One backend now
 * (profile_storage_fs.dart, over lib/platform/fs.dart), so this is a plain
 * re-export; it stays a separate file so the call sites -- and the name
 * [makeFilesystemStorage] -- did not have to change when the web backend
 * moved from localStorage to the filesystem seam.
 */

export 'profile_storage_fs.dart';
