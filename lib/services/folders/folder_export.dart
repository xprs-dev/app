/*
 * Copyright (c) xprs
 * License: Apache-2.0
 *
 * Materialise one file out of the content-addressed archive so the OS can open
 * it. Native only: the blob is copied on a worker isolate straight from the
 * SQLite file into a temp sibling and renamed into place; a browser has
 * neither the isolate nor a disk to write to, so the web half reports that.
 */

export 'folder_export_stub.dart' if (dart.library.io) 'folder_export_io.dart';
