// The slippy map every wapp map screen draws: tiles, pins (clustered when
// they would overlap), a coverage circle, address search, the floating geo
// chat and the gestures. Its own library so it can be built and tested
// without the whole wapp page; wapp_maps.dart wires it to a page's state.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../connections/internet/http_transport.dart';
import '../../../services/i18n/core_i18n.dart';
import '../tile_cache.dart';
import '../tile_math.dart' as tiles;
import 'chat_view_field.dart';

/// The colour filter for a map's `tile-style`, or null to draw tiles as
/// served. Luminance (Rec. 601 weights) with the contrast pushed 25% about the
/// middle grey; 'mono-dark' inverts it, so land goes black and labels white.
ColorFilter? _tileFilter(String style) {
  const c = 1.25, o = 128 * (1 - c);
  const r = 0.299 * c, g = 0.587 * c, b = 0.114 * c;
  switch (style) {
    case 'mono':
      return const ColorFilter.matrix(<double>[
        r, g, b, 0, o, //
        r, g, b, 0, o,
        r, g, b, 0, o,
        0, 0, 0, 1, 0,
      ]);
    case 'mono-dark':
      return const ColorFilter.matrix(<double>[
        -r, -g, -b, 0, 255 - o, //
        -r, -g, -b, 0, 255 - o,
        -r, -g, -b, 0, 255 - o,
        0, 0, 0, 1, 0,
      ]);
  }
  return null;
}

/// Paints the coverage/filter radius circle on the map.
class _RadiusCirclePainter extends CustomPainter {
  final double cx, cy, radiusPx;
  _RadiusCirclePainter(
      {required this.cx, required this.cy, required this.radiusPx});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(cx, cy);
    canvas.drawCircle(
        c, radiusPx, Paint()..color = const Color(0x2258A6FF));
    canvas.drawCircle(
        c,
        radiusPx,
        Paint()
          ..color = const Color(0xAA58A6FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // small dot at the center (my station)
    canvas.drawCircle(c, 4, Paint()..color = const Color(0xFF58A6FF));
  }

  @override
  bool shouldRepaint(_RadiusCirclePainter o) =>
      o.cx != cx || o.cy != cy || o.radiusPx != radiusPx;
}

/// The wapp map on its own, for widget tests of its gestures: no tile source,
/// no search, no chat. [onViewportChanged] hears where it settles.
Widget slippyMapForTest({
  double lat = 38.7223,
  double lon = -9.1393,
  int zoom = 10,
  required void Function(double lat, double lon, int zoom) onViewportChanged,
  List<Map<String, dynamic>> markers = const [],
  void Function(String id)? onMarkerTap,
}) =>
    SlippyMap(
      lat: lat,
      lon: lon,
      zoom: zoom,
      tileUrl: '',
      showSearch: false,
      minZoom: 2,
      maxZoom: 18,
      onViewportChanged: onViewportChanged,
      markers: markers,
      onMarkerTap: onMarkerTap,
      embedChat: false,
    );

class SlippyMap extends StatefulWidget {
  final double lat, lon;
  final int zoom, minZoom, maxZoom;
  final String tileUrl;

  /// How the base tiles are coloured: '' as served, 'mono' black and white
  /// (grey levels with a touch of contrast), 'mono-dark' the same inverted
  /// for a dark screen, 'dark' repainted in the Protomaps dark palette
  /// (geoui/tile_recolor.dart). A wapp picks it with `tile-style` on its map
  /// group.
  final String tileStyle;

  /// The address search box over the map (map group `search`, default on).
  final bool showSearch;

  /// Optional transparent reference layer drawn over the base tiles to label
  /// places (countries, cities, villages…). The tile service supplies the
  /// zoom-appropriate level of detail.
  final String? labelUrl;

  /// Deepest zoom at which the label layer actually carries labels. Beyond it
  /// the labels are fetched from this zoom and scaled up ("overzoom") so place
  /// names stay visible when the map is zoomed in past the layer's detail.
  final int labelMaxZoom;
  final void Function(double lat, double lon, int zoom) onViewportChanged;

  /// Pins to overlay on the map. Each map is {id, lat, lon, label, color?,
  /// kind?} pushed by the wapp via `ui.map.marker`.
  final List<Map<String, dynamic>> markers;

  /// Called with a marker's id when its pin is tapped.
  final void Function(String id)? onMarkerTap;

  /// Coverage circle: filter radius (km) drawn around the station at
  /// [centerLat]/[centerLon]. Null disables the circle + slider.
  final double? radiusKm;
  final double? centerLat;
  final double? centerLon;

  /// Fired (on slider release) with the new radius in km.
  final void Function(double km)? onRadiusChanged;

  /// Fired (on drag release) with the new circle centre when the user
  /// drags the centre handle to move the coverage area.
  final void Function(double lat, double lon)? onCenterChanged;

  /// Floating geo-chat, split into Live (unique/manual) and Beacons
  /// (messages seen repeating within 10 min). Each {from,text,time,...}.
  final List<Map<String, dynamic>> chatLive;
  final List<Map<String, dynamic>> chatBeacons;

  /// Fired with the composed text from the floating chat box.
  final void Function(String text)? onChatSend;

  /// Fired to clear a geo-chat tab (0 = Live, 1 = Beacons).
  final void Function(int tab)? onClearChat;

  /// Tapping a geo-chat message's location meta (carries lat/lon).
  final void Function(Map<String, dynamic>)? onLocate;

  /// A highlighted point (the last "locate" target) drawn as a reticle.
  final double? highlightLat, highlightLon;

  /// Transport/status indicators pushed by the wapp via `ui.map.status`.
  /// Each {id, label, on:bool} renders as a labelled dot (green on / grey off).
  final List<Map<String, dynamic>> status;

  /// Geo-chat panel open/closed — owned by the parent so the unread badge on
  /// the Map tab survives tab switches. Null falls back to internal state.
  final bool? chatOpen;
  final void Function(bool open)? onChatOpenChanged;

  /// When false the map shows only the transport status pills, not the full
  /// geo-chat overlay (the chat lives in its own tab instead).
  final bool embedChat;

  /// On mount, frame the coverage circle (centerLat/centerLon + radiusKm):
  /// centre on it and pick the zoom that fits it in the view. Off when the
  /// host is steering the viewport somewhere specific (e.g. locate-on-map).
  final bool autoFitCircle;

  /// Toggle the full-screen map. When set, a button is shown that calls this:
  /// in the embedded map it opens the full-screen page; in the full-screen
  /// page it pops back. Null hides the button.
  final VoidCallback? onExpand;

  /// True when this instance IS the full-screen page (picks the exit icon).
  final bool isFullscreen;

  /// Centre the coverage circle on the device's current GPS position. Wired
  /// only where a fix is possible (mobile); returns true on success. Null hides
  /// the "my location" button.
  final Future<bool> Function()? onUseMyLocation;

  const SlippyMap({
    super.key,
    required this.lat,
    required this.lon,
    required this.zoom,
    required this.tileUrl,
    this.tileStyle = '',
    this.showSearch = true,
    required this.minZoom,
    required this.maxZoom,
    required this.onViewportChanged,
    this.labelUrl,
    this.labelMaxZoom = 13,
    this.markers = const [],
    this.onMarkerTap,
    this.radiusKm,
    this.centerLat,
    this.centerLon,
    this.onRadiusChanged,
    this.onCenterChanged,
    this.chatLive = const [],
    this.chatBeacons = const [],
    this.onChatSend,
    this.onClearChat,
    this.onLocate,
    this.highlightLat,
    this.highlightLon,
    this.status = const [],
    this.chatOpen,
    this.onChatOpenChanged,
    this.embedChat = true,
    this.autoFitCircle = false,
    this.onExpand,
    this.isFullscreen = false,
    this.onUseMyLocation,
  });

  @override
  State<SlippyMap> createState() => _SlippyMapState();
}

class _SlippyMapState extends State<SlippyMap>
    with TickerProviderStateMixin {
  static const _tileSize = 256.0;

  late double _pxX, _pxY; // top-left in world pixels
  late int _zoom;
  // The scale the tiles are drawn at: 1 at rest, between about 0.7 and 1.4
  // while a pinch sits between two zoom levels (tile_math.dart MapView).
  double _fs = 1.0;
  Offset? _dragStart;

  // One gesture (pan, pinch, or both at once): the world point that was under
  // the fingers when it began and the zoom then. Every update puts that point
  // back under the fingers at the new zoom, so the map follows them.
  (double, double) _gPoint = (0, 0);
  double _gZoom = 0;
  Offset _gFocal = Offset.zero;
  bool _gPinched = false; // two fingers were down at some point
  int _down = 0; // fingers on the map now

  // Easing to a whole zoom after a pinch, a double tap, the wheel or a fling.
  late final AnimationController _ease;
  (double, double) _ePoint = (0, 0);
  Offset _eFrom = Offset.zero, _eTo = Offset.zero;
  double _eZ0 = 0, _eZ1 = 0;
  Offset? _doubleTapAt;

  // Circle interaction: 'move' (drag anywhere inside) or 'resize' (drag the
  // edge band); null means the pan moves the map. Drag overrides apply live.
  String? _circleDrag;
  double? _dragCenterLat, _dragCenterLon, _dragRadiusKm;
  Offset? _circleC0; // circle centre (screen px) captured when a move begins

  // Id of the marker whose info popup is open (null = none).
  String? _popupId;

  // Search
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  List<_SearchResult>? _searchResults;
  bool _searching = false;
  Timer? _debounce;

  // Floating geo-chat visibility + active tab (0 = Live, 1 = Beacons).
  bool _showChat = true;
  int _geoTab = 0;

  // True while a "centre on my GPS location" fetch is in flight (button shows a
  // spinner so the user knows it's working — a fix can take a moment).
  bool _locating = false;

  // Chat open/closed: parent-owned when provided (so the Map-tab unread badge
  // can react), else internal.
  bool get _chatVisible => widget.chatOpen ?? _showChat;
  void _setChatVisible(bool v) {
    if (widget.onChatOpenChanged != null) {
      widget.onChatOpenChanged!(v);
    } else {
      setState(() => _showChat = v);
    }
  }

  /// Current circle centre in screen pixels (honouring an in-progress
  /// move drag), or null when there's no circle.
  Offset? _circleCenterPx() {
    if (widget.centerLat == null || widget.radiusKm == null) return null;
    final lat = _dragCenterLat ?? widget.centerLat!;
    final lon = _dragCenterLon ?? widget.centerLon!;
    return Offset(_sx(lon), _sy(lat));
  }

  /// Radius in screen pixels at the current zoom (Web-Mercator ground
  /// resolution at the circle's latitude).
  double _radiusPx(double km) {
    final lat = widget.centerLat ?? widget.lat;
    final groundRes =
        cos(lat * pi / 180) * 2 * pi * 6378137 / (_tileSize * pow(2, _zoom));
    return (km * 1000) / groundRes * _fs;
  }

  /// True when the whole viewport sits inside the circle, so its edge isn't
  /// visible anywhere. In that state the circle is just a full-screen tint
  /// that would hijack every drag — so we stop drawing it and let drags pan
  /// the map normally (zoom out to bring the circle back into play).
  bool _circleEngulfsView(double w, double h) {
    final c = _circleCenterPx();
    if (c == null) return false;
    final rPx = _radiusPx(_dragRadiusKm ?? widget.radiusKm!);
    var far = 0.0;
    for (final p in [
      const Offset(0, 0),
      Offset(w, 0),
      Offset(0, h),
      Offset(w, h),
    ]) {
      far = max(far, (p - c).distance);
    }
    return far < rPx;
  }

  List<Widget> _buildChatOverlay(double w, double h) {
    // Chat lives in its own tab — keep only the transport status pills on the
    // map so connection/BLE state stays visible without covering the map.
    if (!widget.embedChat) {
      // Sit just under the search bar so the pills don't cover it.
      return widget.status.isEmpty
          ? const []
          : [Positioned(top: 64, left: 12, child: _statusPills())];
    }
    // Portrait / phone: the panel can't sit full-height on the right or it
    // covers the map — show a bottom sheet (map visible above) instead.
    final narrow = w < 600;
    if (!_chatVisible) {
      // Minimised: a FAB to reopen, plus the transport indicators stay visible
      // (just under the search bar) so connection/BLE state is always readable.
      return [
        Positioned(top: 64, left: 12, child: _statusPills()),
        Positioned(
          right: 12,
          bottom: narrow ? 16 : 70,
          child: FloatingActionButton.small(
            heroTag: 'geochat-toggle',
            onPressed: () => _setChatVisible(true),
            child: const Icon(Icons.chat_bubble_outline),
          ),
        ),
      ];
    }
    final panel = _chatPanel();
    if (narrow) {
      // Portrait/phone: the panel fills the whole tab so the chat is usable;
      // the header's minimise button collapses it back to the FAB so the map
      // can be panned.
      return [
        Positioned(left: 8, right: 8, top: 8, bottom: 8, child: panel),
      ];
    }
    return [
      Positioned(right: 12, top: 64, bottom: 60, width: 320, child: panel),
    ];
  }

  /// Compact transport/status indicators (e.g. APRS-IS, BLE) — a coloured dot
  /// (green = on, grey = off) with a label. Driven by `ui.map.status`; empty
  /// for map wapps that push no status.
  Widget _statusPills() {
    final items = widget.status;
    if (items.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in items)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(140),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF30363d)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (s['on'] == true)
                        ? const Color(0xFF3FB950)
                        : const Color(0xFF6E7681),
                  ),
                ),
                const SizedBox(width: 4),
                Text((s['label'] ?? '').toString(),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 10.5)),
              ],
            ),
          ),
      ],
    );
  }

  /// A dark, translucent square icon button matching the map overlay style
  /// (used for the full-screen toggle).
  Widget _mapIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withAlpha(160),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF30363d)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 22, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _chatPanel() {
    final live = widget.chatLive;
    final beacons = widget.chatBeacons;
    final showing = _geoTab == 0 ? live : beacons;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(230),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363d)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 2, 0),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline,
                    size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                Text(tr('wapp_host.geochat.title'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                const Spacer(),
                _statusPills(),
                IconButton(
                  icon: const Icon(Icons.delete_sweep,
                      size: 18, color: Colors.white60),
                  tooltip: tr(_geoTab == 0 ? 'wapp_host.geochat.clear_live' : 'wapp_host.geochat.clear_beacons'),
                  visualDensity: VisualDensity.compact,
                  onPressed: showing.isEmpty
                      ? null
                      : () => widget.onClearChat?.call(_geoTab),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 16, color: Colors.white54),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _setChatVisible(false),
                ),
              ],
            ),
          ),
          // Live | Beacons tabs.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                _geoTabButton('Live', live.length, 0),
                const SizedBox(width: 6),
                _geoTabButton('Beacons', beacons.length, 1),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ChatViewField(
              key: ValueKey('geochat-$_geoTab'),
              fieldName: 'geochat',
              label: '',
              hint: tr(_geoTab == 0 ? 'wapp_host.geochat.hint' : 'wapp_host.geochat.beacons_hint'),
              fill: true,
              messages: showing,
              onLocate: widget.onLocate,
              onSend: (t) => widget.onChatSend?.call(t),
            ),
          ),
        ],
      ),
    );
  }

  Widget _geoTabButton(String label, int count, int idx) {
    final sel = _geoTab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _geoTab = idx),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: sel ? const Color(0x332B5278) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: sel ? const Color(0xFF2B5278) : const Color(0x33FFFFFF)),
          ),
          alignment: Alignment.center,
          child: Text('$label ($count)',
              style: TextStyle(
                  color: sel ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
        ),
      ),
    );
  }

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom;
    _centerOn(widget.lat, widget.lon);
    // _viewSize is a guess until the first layout (the render box doesn't
    // exist yet), which mis-centres the view — especially in portrait, where
    // the real map area is far from the fallback size. Re-centre (and, when
    // asked, fit the coverage circle) once the actual size is known.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (widget.autoFitCircle &&
            widget.radiusKm != null &&
            widget.centerLat != null &&
            widget.centerLon != null) {
          _fitCircle();
        } else {
          _centerOn(widget.lat, widget.lon);
        }
      });
      _syncViewport();
    });
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
    _ease = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260))
      ..addListener(_easeTick)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) _syncViewport();
      });
  }

  /// The view as tile_math sees it.
  tiles.MapView get _view => (zoom: _zoom, x: _pxX, y: _pxY, scale: _fs);
  void _setView(tiles.MapView v) {
    _zoom = v.zoom;
    _pxX = v.x;
    _pxY = v.y;
    _fs = v.scale;
  }

  /// Screen position of a longitude / latitude, and back.
  double _sx(double lon) => (_lon2px(lon, _zoom) - _pxX) * _fs;
  double _sy(double lat) => (_lat2px(lat, _zoom) - _pxY) * _fs;
  double _lonAt(double sx) => _px2lon(_pxX + sx / _fs, _zoom);
  double _latAt(double sy) => _px2lat(_pxY + sy / _fs, _zoom);

  /// Ease to [zoom] around screen point [focal], sliding that point by
  /// [slide] on the way (a fling).
  void _easeTo(double zoom, Offset focal, [Offset slide = Offset.zero]) {
    _ease.stop();
    _ePoint = tiles.viewPoint(_view, focal.dx, focal.dy);
    _eFrom = focal;
    _eTo = focal + slide;
    _eZ0 = tiles.viewZoom(_view);
    _eZ1 = zoom
        .clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble())
        .toDouble();
    _ease.forward(from: 0);
  }

  void _easeTick() {
    final t = Curves.easeOutCubic.transform(_ease.value);
    final z = t >= 1 ? _eZ1 : _eZ0 + (_eZ1 - _eZ0) * t;
    final f = Offset.lerp(_eFrom, _eTo, t)!;
    setState(() => _setView(tiles.viewAt(_ePoint.$1, _ePoint.$2, f.dx, f.dy,
        z, widget.minZoom, widget.maxZoom)));
  }

  /// Centre on the coverage circle and zoom so its diameter fits ~85% of the
  /// view's smaller side — the whole circle is visible in any orientation.
  void _fitCircle() {
    final lat = widget.centerLat!, lon = widget.centerLon!;
    final rM = widget.radiusKm! * 1000.0;
    final size = _viewSize;
    final minDim = min(size.width, size.height);
    if (rM <= 0 || minDim <= 0) {
      _centerOn(lat, lon);
      return;
    }
    final mppTarget = (2 * rM) / (0.85 * minDim);   // metres/px to fit
    final z = log(cos(lat * pi / 180) * 2 * pi * 6378137 /
            (_tileSize * mppTarget)) /
        ln2;
    _zoom = z.floor().clamp(widget.minZoom, widget.maxZoom);
    _centerOn(lat, lon);
  }

  @override
  void didUpdateWidget(SlippyMap old) {
    super.didUpdateWidget(old);
    if ((old.lat - widget.lat).abs() > 0.0001 ||
        (old.lon - widget.lon).abs() > 0.0001 ||
        old.zoom != widget.zoom) {
      _ease.stop();
      _zoom = widget.zoom;
      _centerOn(widget.lat, widget.lon);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    _pulse.dispose();
    _ease.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    setState(() => _searching = true);

    // Check if it's raw coordinates (lat, lon)
    final coordMatch = RegExp(r'^(-?\d+\.?\d*)\s*[,\s]\s*(-?\d+\.?\d*)$')
        .firstMatch(query.trim());
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1)!);
      final lon = double.tryParse(coordMatch.group(2)!);
      if (lat != null && lon != null) {
        setState(() {
          _searchResults = [_SearchResult('$lat, $lon', 'Coordinates', lat, lon)];
          _searching = false;
        });
        return;
      }
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '8',
        'addressdetails': '1',
      });
      final resp = await HttpTransport.shared.get(
        uri,
        headers: const {'User-Agent': 'XPRS/1.0'},
        timeout: const Duration(seconds: 10),
      );
      final body = resp.bodyString;

      final results = (jsonDecode(body) as List).map((r) {
        final lat = double.tryParse(r['lat']?.toString() ?? '') ?? 0;
        final lon = double.tryParse(r['lon']?.toString() ?? '') ?? 0;
        final name = r['display_name'] as String? ?? '';
        final type = r['type'] as String? ?? '';
        return _SearchResult(name, type, lat, lon);
      }).toList();

      // Sort by distance from current center
      final size = _viewSize;
      final cLat = _latAt(size.height / 2);
      final cLon = _lonAt(size.width / 2);
      results.sort((a, b) {
        final da = _distDeg(a.lat, a.lon, cLat, cLon);
        final db = _distDeg(b.lat, b.lon, cLat, cLon);
        return da.compareTo(db);
      });

      setState(() { _searchResults = results; _searching = false; });
    } catch (_) {
      setState(() { _searchResults = []; _searching = false; });
    }
  }

  double _distDeg(double lat1, double lon1, double lat2, double lon2) {
    final dlat = lat1 - lat2, dlon = lon1 - lon2;
    return sqrt(dlat * dlat + dlon * dlon);
  }

  void _goToResult(_SearchResult r) {
    setState(() {
      _searchResults = null;
      _searchController.clear();
      _zoom = 15;
      _centerOn(r.lat, r.lon);
    });
    _syncViewport();
  }

  void _centerOn(double lat, double lon) {
    final size = _viewSize;
    _fs = 1.0;
    _pxX = _lon2px(lon, _zoom) - size.width / 2;
    _pxY = _lat2px(lat, _zoom) - size.height / 2;
  }

  Size get _viewSize {
    final ctx = context;
    final rb = ctx.findRenderObject() as RenderBox?;
    return rb?.size ?? const Size(800, 600);
  }

  double _lon2px(double lon, int z) =>
      ((lon + 180) / 360) * _tileSize * pow(2, z);
  double _lat2px(double lat, int z) {
    final r = pi / 180 * lat;
    return (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * _tileSize * pow(2, z);
  }
  double _px2lon(double px, int z) =>
      px / (_tileSize * pow(2, z)) * 360 - 180;
  double _px2lat(double py, int z) {
    final n = pi - 2 * pi * py / (_tileSize * pow(2, z));
    return 180 / pi * atan(0.5 * (exp(n) - exp(-n)));
  }

  /// Group markers that would overlap on screen into a single cluster
  /// bubble showing the count, so dense areas stay readable. Tapping a
  /// cluster zooms in to break it apart.
  List<Widget> _clusterMarkers(double w, double h) {
    const cell = 50.0; // px proximity that triggers grouping
    final pts = <Offset>[];
    final mk = <Map<String, dynamic>>[];
    for (final m in widget.markers) {
      final lat = (m['lat'] as num?)?.toDouble();
      final lon = (m['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      pts.add(Offset(_sx(lon), _sy(lat)));
      mk.add(m);
    }
    final used = List<bool>.filled(pts.length, false);
    final out = <Widget>[];
    for (var i = 0; i < pts.length; i++) {
      if (used[i]) continue;
      used[i] = true;
      final group = <int>[i];
      for (var j = i + 1; j < pts.length; j++) {
        if (!used[j] && (pts[j] - pts[i]).distance <= cell) {
          used[j] = true;
          group.add(j);
        }
      }
      if (group.length == 1) {
        out.add(_buildMarker(mk[i], w, h));
      } else {
        double ax = 0, ay = 0;
        for (final g in group) { ax += pts[g].dx; ay += pts[g].dy; }
        ax /= group.length;
        ay /= group.length;
        if (ax < -60 || ax > w + 60 || ay < -60 || ay > h + 60) continue;
        out.add(_buildCluster(ax, ay, group.length));
      }
    }
    return out;
  }

  /// Info popup anchored next to a tapped marker: its position, when it was
  /// last heard, and the message/comment it sent.
  List<Widget> _buildMarkerPopup(double w, double h) {
    final id = _popupId;
    if (id == null) return const [];
    Map<String, dynamic>? m;
    for (final x in widget.markers) {
      if (x['id']?.toString() == id) { m = x; break; }
    }
    if (m == null) return const [];
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return const [];
    final px = _sx(lon);
    final py = _sy(lat);
    final label = (m['label'] as String?) ?? id;
    final heard = (m['heard'] as num?)?.toInt();
    final detail = (m['detail'] as String?) ?? '';
    final coords = '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

    const pw = 230.0;
    final left = (px - pw / 2).clamp(8.0, (w - pw - 8).clamp(8.0, w));
    final below = py < 150; // not enough room above → place below the pin
    final top = below ? (py + 14).clamp(8.0, h - 40) : (py - 132).clamp(8.0, h);

    return [
      Positioned(
        left: left,
        top: top,
        width: pw,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
          decoration: BoxDecoration(
            color: const Color(0xF0161b22),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF30363d)),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ),
                  InkWell(
                    onTap: () => setState(() => _popupId = null),
                    child: const Icon(Icons.close, size: 16, color: Color(0xFF8b949e)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Coordinates with a copy button.
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.place, size: 13, color: Color(0xFF8b949e)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(coords,
                          style: const TextStyle(
                              color: Color(0xFFe6edf3), fontSize: 11.5)),
                    ),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: coords));
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(tr('wapp_host.maps.coords_copied')),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.copy,
                            size: 14, color: Color(0xFF7FB0E0)),
                      ),
                    ),
                  ],
                ),
              ),
              if (heard != null)
                _popupRow(Icons.schedule, tr('wapp_host.maps.last_heard', {'time': _relativeTime(heard)})),
              if (detail.isNotEmpty) _popupRow(Icons.message, detail),
            ],
          ),
        ),
      ),
    ];
  }

  /// "just now" / "N minutes ago" / "N hours ago" / "N days ago" from an
  /// epoch (seconds).
  String _relativeTime(int epochSeconds) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var s = now - epochSeconds;
    if (s < 0) s = 0;
    if (s < 45) return 'just now';
    if (s < 3600) {
      final m = (s / 60).round();
      return '$m minute${m == 1 ? "" : "s"} ago';
    }
    if (s < 86400) {
      final hrs = (s / 3600).round();
      return '$hrs hour${hrs == 1 ? "" : "s"} ago';
    }
    final d = (s / 86400).round();
    return '$d day${d == 1 ? "" : "s"} ago';
  }

  Widget _popupRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF8b949e)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Color(0xFFe6edf3), fontSize: 11.5, height: 1.3),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  /// Draw a pulsing reticle on the last "locate" target so the user can
  /// immediately spot it among the other pins.
  List<Widget> _buildHighlight(double w, double h) {
    final lat = widget.highlightLat, lon = widget.highlightLon;
    if (lat == null || lon == null) return const [];
    final px = _sx(lon);
    final py = _sy(lat);
    if (px < -80 || px > w + 80 || py < -80 || py > h + 80) return const [];
    const box = 120.0;
    return [
      Positioned(
        left: px - box / 2,
        top: py - box / 2,
        width: box,
        height: box,
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = _pulse.value; // 0..1
              final ringSize = 26.0 + t * 70.0;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding fading pulse ring.
                  Opacity(
                    opacity: (1 - t) * 0.7,
                    child: Container(
                      width: ringSize,
                      height: ringSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF00E5FF), width: 3),
                      ),
                    ),
                  ),
                  // Steady reticle: bright ring + centre dot.
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: const Color(0xFF00E5FF), width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ];
  }

  /// A cluster bubble: orange circle with the callsign count; tap to
  /// zoom in (which separates the grouped pins).
  Widget _buildCluster(double cx, double cy, int n) {
    const sz = 38.0;
    return Positioned(
      left: cx - sz / 2,
      top: cy - sz / 2,
      width: sz,
      height: sz,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _zoomBy(2, Offset(cx, cy)),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xE6FB8C00),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 4),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            n > 999 ? '999+' : '$n',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: n > 99 ? 11 : 13,
            ),
          ),
        ),
      ),
    );
  }

  /// Build one marker pin (label chip + teardrop icon), anchored so the
  /// icon's tip sits on the geographic point. Off-screen markers collapse.
  Widget _buildMarker(Map<String, dynamic> m, double w, double h) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return const SizedBox.shrink();
    final px = _sx(lon);
    final py = _sy(lat);
    if (px < -200 || px > w + 200 || py < -200 || py > h + 200) {
      return const SizedBox.shrink();
    }
    final label = (m['label'] as String?) ?? (m['id']?.toString() ?? '');
    final color = _markerColor(m['color']);
    const pinW = 140.0;
    return Positioned(
      left: px - pinW / 2,
      top: py - 46,
      width: pinW,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final id = m['id']?.toString() ?? '';
          widget.onMarkerTap?.call(id);
          setState(() => _popupId = id);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(204),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            Icon(Icons.location_on,
                color: color,
                size: 28,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 3)]),
          ],
        ),
      ),
    );
  }

  Color _markerColor(dynamic raw) {
    if (raw is String && raw.isNotEmpty) {
      var s = raw.replaceAll('#', '');
      if (s.length == 6) s = 'FF$s';
      final v = int.tryParse(s, radix: 16);
      if (v != null) return Color(v);
      switch (raw.toLowerCase()) {
        case 'red':
          return const Color(0xFFE53935);
        case 'green':
          return const Color(0xFF43A047);
        case 'blue':
          return const Color(0xFF1E88E5);
        case 'orange':
          return const Color(0xFFFB8C00);
      }
    }
    return const Color(0xFFE53935);
  }

  void _syncViewport() {
    final size = _viewSize;
    final lat = _latAt(size.height / 2);
    final lon = _lonAt(size.width / 2);
    widget.onViewportChanged(lat, lon, _zoom);
  }

  /// One whole zoom step in or out around [focus] (the centre by default),
  /// eased. Steps pressed while one is still easing add up.
  void _zoomBy(int delta, [Offset? focus]) {
    final size = _viewSize;
    final from = _ease.isAnimating ? _eZ1 : tiles.viewZoom(_view);
    final target = (from.round() + delta)
        .clamp(widget.minZoom, widget.maxZoom)
        .toDouble();
    if (target == tiles.viewZoom(_view) && !_ease.isAnimating) return;
    _easeTo(target,
        focus ?? (_ease.isAnimating ? _eTo : size.center(Offset.zero)));
  }

  void _onScaleStart(ScaleStartDetails d, double w, double h) {
    _ease.stop();
    _popupId = null; // any drag dismisses an open marker popup
    _circleDrag = null;
    if (d.pointerCount >= 2) _gPinched = true;
    // One finger on the coverage circle: the edge band resizes it, anywhere
    // else inside moves it (relative to the grab, so it doesn't jump). When
    // the circle engulfs the whole view it's not manipulable, so the drag
    // pans the map.
    final c = d.pointerCount == 1 && !_circleEngulfsView(w, h)
        ? _circleCenterPx()
        : null;
    if (c != null) {
      final dist = (d.localFocalPoint - c).distance;
      final rPx = _radiusPx(_dragRadiusKm ?? widget.radiusKm!);
      if ((dist - rPx).abs() <= 16) {
        _circleDrag = 'resize';
        _dragRadiusKm = widget.radiusKm;
        return;
      }
      if (dist < rPx) {
        _circleDrag = 'move';
        _circleC0 = c;
        _dragStart = d.localFocalPoint;
        _dragCenterLat = widget.centerLat;
        _dragCenterLon = widget.centerLon;
        return;
      }
    }
    _gPoint = tiles.viewPoint(_view, d.localFocalPoint.dx, d.localFocalPoint.dy);
    _gZoom = tiles.viewZoom(_view);
    _gFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_circleDrag == 'move') {
      // Move the centre by the same delta as the pointer (relative).
      final np = _circleC0! + (d.localFocalPoint - _dragStart!);
      setState(() {
        _dragCenterLon = _lonAt(np.dx);
        _dragCenterLat = _latAt(np.dy);
      });
      return;
    }
    if (_circleDrag == 'resize') {
      final c = _circleCenterPx()!;
      final dist = (d.localFocalPoint - c).distance;
      final lat = _dragCenterLat ?? widget.centerLat ?? widget.lat;
      final groundRes = cos(lat * pi / 180) * 2 * pi * 6378137 /
          (_tileSize * pow(2, _zoom) * _fs);
      final km = (dist * groundRes) / 1000.0;
      setState(() => _dragRadiusKm = km.clamp(1.0, 1000.0));
      return;
    }
    _gFocal = d.localFocalPoint;
    final z = _gZoom + log(d.scale) / ln2;
    setState(() => _setView(tiles.viewAt(_gPoint.$1, _gPoint.$2,
        _gFocal.dx, _gFocal.dy, z, widget.minZoom, widget.maxZoom)));
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_circleDrag == 'move') {
      final la = _dragCenterLat, lo = _dragCenterLon;
      _circleDrag = null;
      setState(() {
        _dragCenterLat = null;
        _dragCenterLon = null;
      });
      if (la != null && lo != null) widget.onCenterChanged?.call(la, lo);
      return;
    }
    if (_circleDrag == 'resize') {
      final km = _dragRadiusKm;
      _circleDrag = null;
      setState(() => _dragRadiusKm = null);
      if (km != null) widget.onRadiusChanged?.call(km.roundToDouble());
      return;
    }
    // A finger lifted with another still down. The recogniser reports no
    // end when that last finger lifts without moving, so settle now; if it
    // does move, a new gesture starts from wherever the map is.
    if (d.pointerCount > 0) {
      _easeTo(tiles.viewZoom(_view).roundToDouble(), _gFocal);
      return;
    }
    final pinched = _gPinched;
    // A one-finger flick carries on a little; a pinch's release does not
    // (the fingers rarely leave together, and that is not a throw).
    var slide = Offset.zero;
    final v = d.velocity.pixelsPerSecond;
    if (!pinched && v.distance > 250) {
      slide = v * 0.22;
      if (slide.distance > 700) slide = slide / slide.distance * 700;
    }
    final z = tiles.viewZoom(_view);
    if (slide == Offset.zero && _fs == 1.0) {
      _syncViewport();
      return;
    }
    // Settle on a whole zoom, where the tiles are sharp.
    _easeTo(z.roundToDouble(), _gFocal, slide);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth, h = constraints.maxHeight;
      // The world pixels on screen: more of them while a pinch draws the
      // tiles smaller, fewer while it draws them larger.
      final vw = w / _fs, vh = h / _fs;
      final tileXMin = (_pxX / _tileSize).floor();
      final tileYMin = (_pxY / _tileSize).floor();
      final tileXMax = ((_pxX + vw) / _tileSize).floor();
      final tileYMax = ((_pxY + vh) / _tileSize).floor();
      final maxTile = pow(2, _zoom).toInt() - 1;

      // Build a layer of tiles for a {z}/{x}/{y} template. `transparent`
      // layers (the place-label overlay) fall back to nothing on error.
      List<Widget> buildTiles(String template, {required bool transparent}) {
        final out = <Widget>[];
        if (template.isEmpty) return out; // no tile source: background only
        for (var ty = tileYMin; ty <= tileYMax; ty++) {
          for (var tx = tileXMin; tx <= tileXMax; tx++) {
            final wrappedX =
                ((tx % (maxTile + 1)) + (maxTile + 1)) % (maxTile + 1);
            if (ty < 0 || ty > maxTile) continue;
            final url = template
                .replaceAll('{z}', '$_zoom')
                .replaceAll('{x}', '$wrappedX')
                .replaceAll('{y}', '$ty');
            out.add(Positioned(
              left: tx * _tileSize - _pxX,
              top: ty * _tileSize - _pxY,
              width: _tileSize,
              height: _tileSize,
              child: Image(
                image: tileImageProvider(url,
                    style: transparent ? '' : widget.tileStyle),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => transparent
                    ? const SizedBox.shrink()
                    : Container(color: const Color(0xFF0a0e14)),
              ),
            ));
          }
        }
        return out;
      }

      // Place-name labels (countries/cities/villages) — a transparent reference
      // layer over the imagery. When zoomed in past the layer's detail
      // (labelMaxZoom), fetch the labels at that zoom and SCALE them up so place
      // names don't just disappear (the satellite imagery keeps going much
      // deeper than the labels do).
      List<Widget> buildLabelTiles(String template) {
        final src = widget.labelMaxZoom;
        if (_zoom <= src) return buildTiles(template, transparent: true);
        final scale = pow(2, _zoom - src).toDouble();
        final tileWorld = _tileSize * scale; // px (at _zoom) of one source tile
        final maxTileS = pow(2, src).toInt() - 1;
        final txMin = (_pxX / tileWorld).floor();
        final txMax = ((_pxX + vw) / tileWorld).floor();
        final tyMin = (_pxY / tileWorld).floor();
        final tyMax = ((_pxY + vh) / tileWorld).floor();
        final out = <Widget>[];
        for (var ty = tyMin; ty <= tyMax; ty++) {
          if (ty < 0 || ty > maxTileS) continue;
          for (var tx = txMin; tx <= txMax; tx++) {
            final wrappedX =
                ((tx % (maxTileS + 1)) + (maxTileS + 1)) % (maxTileS + 1);
            final url = template
                .replaceAll('{z}', '$src')
                .replaceAll('{x}', '$wrappedX')
                .replaceAll('{y}', '$ty');
            out.add(Positioned(
              left: tx * tileWorld - _pxX,
              top: ty * tileWorld - _pxY,
              width: tileWorld,
              height: tileWorld,
              child: Image(
                image: tileImageProvider(url),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ));
          }
        }
        return out;
      }

      final baseTiles = buildTiles(widget.tileUrl, transparent: false);
      final tileFilter = _tileFilter(widget.tileStyle);
      final labelTiles = (widget.labelUrl == null || widget.labelUrl!.isEmpty)
          ? const <Widget>[]
          : buildLabelTiles(widget.labelUrl!);
      // The tiles, drawn at the pinch's scale, clipped to the map: tiles at
      // the edges reach past it, and a filter layer that let them paint there
      // covered whatever sat above the map (a screen's toolbar row). A double
      // tap on the map itself (not on a pin or a button) zooms in there.
      final tileLayer = Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () => _zoomBy(1, _doubleTapAt),
          child: ClipRect(
            child: Container(
              color: const Color(0xFF0a0e14),
              child: Transform.scale(
                scale: _fs,
                alignment: Alignment.topLeft,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (tileFilter == null)
                      ...baseTiles
                    else
                      Positioned.fill(
                        child: ColorFiltered(
                          colorFilter: tileFilter,
                          child: Stack(
                              clipBehavior: Clip.none, children: baseTiles),
                        ),
                      ),
                    ...labelTiles,
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final centerLat = _latAt(h / 2);
      final centerLon = _lonAt(w / 2);

      final mapStack = GestureDetector(
        // Long-press anywhere on the map to recentre the coverage circle on
        // that spot (an easier alternative to dragging the centre handle,
        // especially on a phone). Only active when there IS a circle.
        onLongPressStart: (d) {
          if (widget.onCenterChanged == null || widget.radiusKm == null) return;
          final lat = _latAt(d.localPosition.dy);
          final lon = _lonAt(d.localPosition.dx);
          HapticFeedback.selectionClick();
          setState(() {
            _popupId = null;
            _circleDrag = null;
            _dragCenterLat = null;
            _dragCenterLon = null;
          });
          widget.onCenterChanged!.call(lat, lon);
        },
        // One recogniser for one finger and two: a pan is a scale of 1, so a
        // second finger joining a pan turns it into a pinch without a jump.
        // (Pan callbacks alone saw a pinch as a drag of whichever finger
        // moved last, and the map jumped between the two.)
        onScaleStart: (d) => _onScaleStart(d, w, h),
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: Listener(
          // A touch on an empty map starts a fresh gesture: whether the last
          // one was a pinch no longer matters.
          onPointerDown: (_) {
            if (_down++ == 0) _gPinched = false;
          },
          onPointerUp: (_) => _down = max(0, _down - 1),
          onPointerCancel: (_) => _down = max(0, _down - 1),
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final delta = event.scrollDelta.dy < 0 ? 1 : -1;
              _zoomBy(delta, event.localPosition);
            }
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              tileLayer,
              // Coverage radius circle (filter area). Centre + radius
              // honour an in-progress move/resize drag for live feedback.
              // Hidden when it engulfs the whole view (zoomed in past its
              // edge) so the map stays clear and pannable. Drawing only:
              // its drags are worked out from the touch position.
              if (widget.radiusKm != null &&
                  widget.centerLat != null &&
                  !_circleEngulfsView(w, h))
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _RadiusCirclePainter(
                        cx: _sx(_dragCenterLon ?? widget.centerLon!),
                        cy: _sy(_dragCenterLat ?? widget.centerLat!),
                        radiusPx: _radiusPx(_dragRadiusKm ?? widget.radiusKm!),
                      ),
                    ),
                  ),
                ),
              // Marker pins (clustered when they would overlap).
              ..._clusterMarkers(w, h),
              // Highlighted "locate" target — a pulsing reticle on top.
              ..._buildHighlight(w, h),
              // Info popup for a tapped marker.
              ..._buildMarkerPopup(w, h),
              // Full-screen toggle in the bottom-RIGHT corner. The coordinates
              // sit bottom-left and the zoom control is higher up, so this
              // corner is clear; when the geo-chat FAB is showing (plain map,
              // chat minimised) we shift left of it so they don't overlap.
              if (widget.onExpand != null)
                Positioned(
                  right: (widget.embedChat && !_chatVisible) ? 64 : 12,
                  bottom: 12,
                  child: _mapIconButton(
                    icon: widget.isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    tooltip: tr(widget.isFullscreen
                        ? 'wapp_host.maps.exit_fullscreen'
                        : 'wapp_host.maps.fullscreen'),
                    onTap: widget.onExpand!,
                  ),
                ),
              // Search bar
              if (widget.showSearch)
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xF0161b22),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF30363d)),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.search, size: 18, color: Color(0xFF8b949e)),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              style: const TextStyle(fontSize: 13, color: Color(0xFFe6edf3)),
                              decoration: InputDecoration(
                                hintText: tr('wapp_host.maps.search_hint'),
                                hintStyle: const TextStyle(color: Color(0xFF8b949e), fontSize: 13),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                isDense: true,
                              ),
                              onChanged: (v) {
                                _debounce?.cancel();
                                _debounce = Timer(const Duration(milliseconds: 400), () => _doSearch(v));
                              },
                              onSubmitted: _doSearch,
                            ),
                          ),
                          if (_searching)
                            const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          else if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.close, size: 16, color: Color(0xFF8b949e)),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchResults = null);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                        ],
                      ),
                    ),
                    if (_searchResults != null && _searchResults!.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults!.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF30363d)),
                          itemBuilder: (context, i) {
                            final r = _searchResults![i];
                            return InkWell(
                              onTap: () => _goToResult(r),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.name.length > 80 ? '${r.name.substring(0, 80)}...' : r.name,
                                      style: const TextStyle(fontSize: 12, color: Color(0xFFe6edf3)),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${r.lat.toStringAsFixed(5)}, ${r.lon.toStringAsFixed(5)}',
                                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF8b949e)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_searchResults != null && _searchResults!.isEmpty && !_searching)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: Text(tr('wapp_host.maps.no_results'), style: const TextStyle(fontSize: 12, color: Color(0xFF8b949e))),
                      ),
                  ],
                ),
              ),
              // Zoom controls. Portrait/phone: bottom-right, above the chat
              // FAB \u2014 where phone-map users expect them. Landscape: left,
              // vertically centred so they stay clear of the right-side chat
              // panel.
              if (w < 600)
                Positioned(right: 12, bottom: 84, child: _buildZoomControl())
              else
                Positioned(
                  left: 12,
                  top: h / 2 - 44,
                  child: _buildZoomControl(),
                ),
              // Coordinates — always bottom-left, leaving the bottom-right
              // corner for the full-screen toggle in both orientations.
              Positioned(
                left: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${centerLat.toStringAsFixed(5)}, ${centerLon.toStringAsFixed(5)} z$_zoom',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF8b949e),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      // The geo-chat overlay sits OUTSIDE the map's GestureDetector/Listener
      // so drags and the mouse wheel over it drive the chat (scroll/compose),
      // never the map underneath.
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: mapStack),
          if (widget.onChatSend != null) ..._buildChatOverlay(w, h),
        ],
      );
    });
  }

  /// A single unified zoom control (+ over −, split by a divider) — the
  /// familiar map widget, with a rounded translucent body and a shadow.
  Widget _buildZoomControl() {
    final hasLocate = widget.onUseMyLocation != null;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF0161b22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363d)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Centre on my location" — fetch the GPS fix and move the circle.
          if (hasLocate) ...[
            _locateBtn(
                radius: const BorderRadius.vertical(top: Radius.circular(10))),
            Container(width: 30, height: 1, color: const Color(0xFF30363d)),
          ],
          _zoomBtn(Icons.add, () => _zoomBy(1),
              radius: hasLocate
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(top: Radius.circular(10))),
          Container(width: 30, height: 1, color: const Color(0xFF30363d)),
          _zoomBtn(Icons.remove, () => _zoomBy(-1),
              radius: const BorderRadius.vertical(bottom: Radius.circular(10))),
        ],
      ),
    );
  }

  /// The "centre on my GPS location" button (top of the zoom control). Shows a
  /// spinner while acquiring a fix, and a snackbar if it can't get one.
  Widget _locateBtn({required BorderRadius radius}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: _locating ? null : _useMyLocation,
        child: SizedBox(
          width: 42,
          height: 40,
          child: Center(
            child: _locating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFFE6EDF3)),
                  )
                : const Icon(Icons.my_location,
                    size: 20, color: Color(0xFFE6EDF3)),
          ),
        ),
      ),
    );
  }

  Future<void> _useMyLocation() async {
    final cb = widget.onUseMyLocation;
    if (cb == null || _locating) return;
    setState(() => _locating = true);
    bool ok = false;
    try {
      ok = await cb();
    } finally {
      if (mounted) setState(() => _locating = false);
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('wapp_host.maps.no_location')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _zoomBtn(IconData icon, VoidCallback onTap,
      {required BorderRadius radius}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 40,
          child: Center(
            child: Icon(icon, size: 20, color: const Color(0xFFE6EDF3)),
          ),
        ),
      ),
    );
  }
}

class _SearchResult {
  final String name;
  final String type;
  final double lat, lon;
  _SearchResult(this.name, this.type, this.lat, this.lon);
}
