/*
 * Remote-control HTTP API for the XPRS app.
 *
 * Opens a small JSON HTTP server (default port 3456 — the standard xprs
 * device-API port) so the app can be driven and inspected remotely:
 *
 *   GET  /api/status        → app + active-profile info, installed wapps
 *   GET  /api/log[?n=200]   → recent log lines (see LogService)
 *   GET  /api/wapps         → installed wapps [{id,name,folder,kind}]
 *   POST /api/launch        → body {"wapp":"<id|folder|name>"} opens that wapp
 *
 * Off by default (Settings > Remote control API). When on it listens on
 * 127.0.0.1 only, sends no CORS headers, and refuses any request a browser
 * makes (an Origin or Sec-Fetch-* header, or a Host that is not loopback), so
 * neither the network nor a web page can reach it: only `adb forward` and
 * processes on the same machine. Conditional export keeps dart:io out of the
 * web build (the stub is a no-op there).
 */

export 'remote_api_service_stub.dart'
    if (dart.library.io) 'remote_api_service_io.dart';
