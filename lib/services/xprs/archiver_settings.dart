/*
 * The archiver's settings, written in ONE place.
 *
 * The Archiver page (lib/launcher/archiver_page.dart) and the remote API
 * (`POST /api/xprs/archiver`) both change what this station keeps and for
 * whom. They used to do it separately and drifted: the API restarted the
 * update mirror on an always-on change and the old wapp did not; the wapp
 * wrote the unified archiver list and the API only half of it. Every writer
 * now calls [applyArchiverSettings] with the keys it changes, and the side
 * effects run once, in this order.
 *
 * Keys (all optional):
 *   archivers     List<String>  the archivers this station chose (12.3); the
 *                               one list behind both the publication push and
 *                               the mailbox declaration (PreferencesService
 *                               .xprsArchivers)
 *   archiverAuto  bool          adopt one when none is chosen
 *   public        bool          keep strangers' packets; announce serve:archive
 *   keepFollowed  bool
 *   quotaMb       int > 0
 *   maxDays       int > 0
 *   dial          String        host[:port] this archiver answers on (13.0.2)
 *   room          bool          take new stations (12.9.5)
 *   roomStations  int > 0
 *   dials         Map<String, String?>  dials of other archivers, by hand;
 *                               they outrank what the archiver announces, and
 *                               null clears one back to the announced dial
 *   alwaysOn      bool          only takes effect on a public archiver
 *   archiver      bool          THE switch: on serves messages (`public`),
 *                               files (`serve:files`) and the file-location
 *                               index together; off stops all three
 *   files         bool          files for others alone (Advanced)
 *   fileIndex     bool          the file-location index alone (Advanced)
 *   filesGb       int > 0       the one limit of the file store
 *   onlyCharging  bool          serve files and the index only on charger
 *                               and an unlimited link
 */
import '../mesh/mesh_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import '../update_mirror_service.dart';
import 'xprs_ingest.dart';

/// Apply [data] to the archiver's settings. [legacy] is the old
/// `/api/xprs/super` shape, where becoming always-on also made the station
/// public. Returns false when the preferences are not open yet.
Future<bool> applyArchiverSettings(Map<String, dynamic> data,
    {bool legacy = false}) async {
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return false;
  List<String> calls(Object? v) => (v as List?)
          ?.map((e) => e.toString().trim().toUpperCase())
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];
  int? positive(Object? v) {
    final n = int.tryParse('$v');
    return n != null && n > 0 ? n : null;
  }

  if (data.containsKey('archivers')) prefs.xprsArchivers = calls(data['archivers']);
  if (data.containsKey('archiverAuto')) {
    prefs.xprsArchiverAuto = data['archiverAuto'] == true;
  }
  if (data.containsKey('public')) {
    await prefs.setXprsPublicArchiver(data['public'] == true);
  }
  // The whole archiver at once (12.9.2: the spool and the file store
  // reinforce each other, so one switch serves both). The parts can still be
  // set alone below; "on" is the date the page counts from.
  if (data.containsKey('archiver')) {
    final on = data['archiver'] == true;
    await prefs.setXprsPublicArchiver(on);
    _setFiles(prefs, on);
    _setFileIndex(prefs, on);
  }
  if (data.containsKey('files')) _setFiles(prefs, data['files'] == true);
  if (data.containsKey('fileIndex')) {
    _setFileIndex(prefs, data['fileIndex'] == true);
  }
  if (positive(data['filesGb']) case final v?) {
    // One store, one limit: what is admitted and what eviction keeps.
    prefs.hostCeilingGb = v;
    if (prefs.archiveQuotaGb > 0) prefs.archiveQuotaGb = v;
  }
  if (data.containsKey('onlyCharging')) {
    prefs.hostCapacityGated = data['onlyCharging'] == true;
    if (prefs.archiverVolunteer != 'off') {
      _setFileIndex(prefs, true);
    } else {
      RnsService.instance.applyHostingSettings();
    }
  }
  if (prefs.xprsArchiverSinceMs == 0 &&
      (prefs.xprsPublicArchiver || prefs.archiveQuotaGb > 0)) {
    prefs.xprsArchiverSinceMs = DateTime.now().millisecondsSinceEpoch;
  }
  if (data.containsKey('keepFollowed')) {
    await prefs.setXprsKeepFollowed(data['keepFollowed'] == true);
  }
  if (positive(data['quotaMb']) case final v?) prefs.xprsArchiveMaxMb = v;
  if (positive(data['maxDays']) case final v?) prefs.xprsArchiveMaxDays = v;
  if (data.containsKey('dial')) prefs.xprsDial = '${data['dial'] ?? ''}'.trim();
  if (data.containsKey('room')) prefs.xprsRoom = data['room'] != false;
  if (positive(data['roomStations']) case final v?) prefs.xprsRoomStations = v;
  if (data['dials'] is Map) {
    for (final e in (data['dials'] as Map).entries) {
      prefs.setArchiverDialByHand(
          e.key.toString(), e.value == null ? null : '${e.value}');
    }
  }
  // A changed list or dial re-dials now, not on the next minute tick.
  final redial = data.containsKey('archivers') || data['dials'] is Map;
  if (data.containsKey('alwaysOn')) {
    final on = data['alwaysOn'] == true;
    if (legacy && on) await prefs.setXprsPublicArchiver(true);
    await prefs.setXprsAlwaysOn(on);
  }
  // An always-on archiver mirrors releases (phones fetch them by digest from
  // it). Its effective value depends on `public` too, so this follows any
  // change of either, at runtime rather than at the next boot.
  if (data.containsKey('alwaysOn') || data.containsKey('public')) {
    final m = UpdateMirrorService.instance;
    if (m.enabled && !m.isRunning) {
      await m.start();
    } else if (!m.enabled && m.isRunning) {
      await m.stop();
    }
  }
  // Every writer re-reads the snapshot the receive funnel uses, and the
  // archive's limits (bytes, age, the gossip budget an always-on archiver
  // gets) follow the preferences.
  XprsIngest.reloadPolicy();
  if (data.isNotEmpty) MeshService.instance.applyArchiveLimits();
  if (redial) MeshService.instance.redialArchivers();
  return true;
}

/// Whether this station is an archiver at all: any of its three parts on.
bool archiverOn(PreferencesService p) =>
    p.xprsPublicArchiver || p.archiveQuotaGb > 0 || p.archiverVolunteer != 'off';

/// Files for others: the store admits them under the one limit, or nothing.
void _setFiles(PreferencesService p, bool on) {
  final gb = p.hostCeilingGb > 0 ? p.hostCeilingGb : 10;
  p.archiveQuotaGb = on ? (p.archiveQuotaGb > 0 ? p.archiveQuotaGb : gb) : 0;
}

/// The responder that sends files and the index archivers swap (12.9.2).
/// Unlike NodeRoleApi's `volunteer=off`, switching off keeps the charging
/// choice, so switching back on restores it.
void _setFileIndex(PreferencesService p, bool on) {
  p.archiverVolunteer = !on ? 'off' : (p.hostCapacityGated ? 'auto' : 'always');
  p.hostEnabled = on;
  RnsService.instance.applyHostingSettings();
}
