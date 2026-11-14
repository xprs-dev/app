// The map screen: radius slider, prefetch, and the wiring of SlippyMap
// (geoui/widgets/slippy_map.dart) to the page. Part of the wapp_page
// library: map builders are an extension on _WappPageState (which still
// holds the map state fields).

part of 'wapp_page.dart';

/// The most tiles one `ui.map.prefetch` saves: a city at street level, not a
/// country (see _prefetchMapArea).
const int _kPrefetchCap = 1500;

// Log-scale radius mapping bounds (km), used by the slider helpers.
const double _rMin = 1, _rMid = 100, _rMax = 1000;

extension _WappMaps on _WappPageState {
  /// `ui.map.prefetch`: save an area's tiles into the disk cache so the map
  /// works off-grid there. {bbox:[south,west,north,east]?, minZoom, maxZoom,
  /// max?}; without a bbox, the area on screen. At most [_kPrefetchCap] tiles
  /// however many are asked for, and one save at a time: a tile server is
  /// shared, and OpenStreetMap's own refuses bulk downloads, so this is for
  /// the area a person asked for, not for preloading the world. Progress goes
  /// back to the wapp as {type:"map.prefetch", state, done, total, held}.
  void _prefetchMapArea(Map<String, dynamic> data) {
    if (_mapPrefetching) {
      _sendMapPrefetch('busy', 0, 0, 0);
      return;
    }
    final minZ = ((data['minZoom'] as num?)?.toInt() ?? _mapZoom).clamp(0, 19);
    final maxZ = ((data['maxZoom'] as num?)?.toInt() ?? minZ + 2).clamp(minZ, 19);
    final cap = ((data['max'] as num?)?.toInt() ?? _kPrefetchCap)
        .clamp(1, _kPrefetchCap);
    double s0, w0, n0, e0;
    final bbox = data['bbox'];
    if (bbox is List && bbox.length == 4 && bbox.every((v) => v is num)) {
      s0 = (bbox[0] as num).toDouble();
      w0 = (bbox[1] as num).toDouble();
      n0 = (bbox[2] as num).toDouble();
      e0 = (bbox[3] as num).toDouble();
    } else {
      final size = MediaQuery.maybeOf(context)?.size ?? const Size(1280, 800);
      (s0, w0, n0, e0) =
          tiles.viewBox(_mapLat, _mapLon, _mapZoom, size.width, size.height);
    }
    final list = tiles.tilesForBox(s0, w0, n0, e0, minZ, maxZ, cap: cap);
    final urls = [for (final t in list) tiles.tileUrl(_tileUrl, t)];
    if (urls.isEmpty) {
      _sendMapPrefetch('done', 0, 0, 0);
      return;
    }
    _mapPrefetching = true;
    _sendMapPrefetch('running', 0, urls.length, 0);
    var last = 0;
    prefetchTiles(urls, cancelled: () => !mounted, onProgress: (done, total) {
      if (done - last >= 25 && done < total) {
        last = done;
        _sendMapPrefetch('running', done, total, 0);
      }
    }).then((held) {
      _mapPrefetching = false;
      if (mounted) _sendMapPrefetch('done', urls.length, urls.length, held);
    });
  }

  void _sendMapPrefetch(String state, int done, int total, int held) {
    _engine.sendMessage(jsonEncode({
      'type': 'map.prefetch',
      'state': state,
      'done': done,
      'total': total,
      'held': held,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Build the slippy map wired to all the host callbacks. Shared by the
  /// embedded map (inside the map screen) and the full-screen map page so both
  /// drive the exact same state and behaviour. [onExpand]/[isFullscreen]
  /// control the full-screen toggle button.
  Widget _buildSlippyMap(
    GeoUiBlock mapGroup, {
    required bool embedChat,
    VoidCallback? onExpand,
    bool isFullscreen = false,
  }) {
    // What the map carries besides tiles and pins. Each is on unless the map
    // group says false: `radius` (the coverage circle and its slider),
    // `chat` (the floating geo-chat), `search` (the address search box). A
    // map of places (the Check-in wapp's) wants none of them.
    final showRadius = mapGroup.getBool('radius') ?? true;
    final showChat = mapGroup.getBool('chat') ?? true;
    final showSearch = mapGroup.getBool('search') ?? true;
    return SlippyMap(
      lat: _mapLat,
      lon: _mapLon,
      zoom: _mapZoom,
      tileUrl: _tileUrl,
      showSearch: showSearch,
      tileStyle: mapGroup.getString('tile-style') ?? '',
      labelUrl: mapGroup.getString('label-url'),
      labelMaxZoom: mapGroup.getNumber('label-max-zoom')?.toInt() ?? 13,
      minZoom: mapGroup.getNumber('min-zoom')?.toInt() ?? 2,
      maxZoom: mapGroup.getNumber('max-zoom')?.toInt() ?? 18,
      markers: _mapMarkers.values.toList(),
      onMarkerTap: (id) {
        _engine.sendMessage(jsonEncode({'command': 'marker_tap', 'id': id}));
        _engine.handleEvent();
        _drainOutbox();
        if (mounted) setState(() {});
      },
      onViewportChanged: (lat, lon, zoom) {
        _mapLat = lat;
        _mapLon = lon;
        _mapZoom = zoom;
        _engine.sendMessage(jsonEncode({
          'type': 'setViewport',
          'lat': lat,
          'lon': lon,
          'zoom': zoom,
        }));
        _engine.handleEvent();
        _drainOutbox();
      },
      radiusKm: showRadius ? (_mapDragKm ?? _mapRadiusKm) : null,
      centerLat: showRadius ? _mapCenterLat : null,
      centerLon: showRadius ? _mapCenterLon : null,
      onRadiusChanged: (km) {
        _mapRadiusKm = km;
        // Keep both the slider's value and the Settings field in sync so
        // a later Connect uses the same radius.
        _fieldValues['map_radius'] = km.round().toString();
        _fieldValues['radius_km'] = km.round().toString();
        _sendCommand('set_radius');
        _persistMapLocation(); // remember it across restarts
        if (mounted) setState(() {});
      },
      onCenterChanged: (lat, lon) {
        // Move the coverage area: update centre + my-position fields and
        // re-filter (set_radius reconnects with the new r/lat/lon/km).
        _mapCenterLat = lat;
        _mapCenterLon = lon;
        _fieldValues['my_lat'] = lat.toStringAsFixed(5);
        _fieldValues['my_lon'] = lon.toStringAsFixed(5);
        _sendCommand('set_radius');
        _persistMapLocation(); // remember the chosen pin across restarts
        if (mounted) setState(() {});
      },
      chatLive: _geoLive,
      chatBeacons: _geoBeacons,
      status: _mapStatus,
      chatOpen: _geoChatOpen,
      onChatOpenChanged: _setGeoChatOpen,
      onClearChat: (tab) {
        // Clear the chosen tab's list (keeps the seen/beacon keys so
        // future repeats still classify correctly).
        if (tab == 0) {
          _geoLive.clear();
        } else {
          _geoBeacons.clear();
        }
        if (mounted) setState(() {});
      },
      onChatSend: !showChat
          ? null
          : (text) {
              _fieldValues['geochat_input'] = text;
              _sendCommand('geochat_send');
              if (mounted) setState(() {});
            },
      onLocate: _locateFromMessage,
      highlightLat: _locateLat,
      highlightLon: _locateLon,
      // With the chat panel below the map there's no need for the floating
      // overlay; a plain map screen (no geochat field) keeps the old overlay.
      embedChat: embedChat,
      autoFitCircle: _mapAutoFit,
      onExpand: onExpand,
      isFullscreen: isFullscreen,
      // "Centre on my location" — only where the device actually has GPS
      // (mobile). Fetches a fresh fix, recentres the coverage circle on it,
      // pans the map there, and re-filters (set_radius).
      onUseMyLocation: _gpsCenterAvailable
          ? () async {
              final pos = await LocationService.instance.currentPosition();
              if (pos == null) return false;
              if (!showRadius) {
                // A map of places has no coverage area to move: go there.
                setState(() {
                  _mapLat = pos.lat;
                  _mapLon = pos.lon;
                  _mapZoom = 14;
                });
                _engine.sendMessage(jsonEncode({
                  'type': 'setViewport',
                  'lat': pos.lat,
                  'lon': pos.lon,
                  'zoom': 14,
                }));
                _engine.handleEvent();
                _drainOutbox();
                return true;
              }
              setState(() {
                _mapCenterLat = pos.lat;
                _mapCenterLon = pos.lon;
                _mapLat = pos.lat;
                _mapLon = pos.lon;
                // Frame at a city-level zoom where place labels are richest
                // (the reference layer carries city/town names around z11–12;
                // zoomed further in they thin out). Keeps the user's town named.
                _mapZoom = 12;
                _mapAutoFit = false;
              });
              _fieldValues['my_lat'] = pos.lat.toStringAsFixed(5);
              _fieldValues['my_lon'] = pos.lon.toStringAsFixed(5);
              _sendCommand('set_radius');
              _persistMapLocation(); // remember the GPS location across restarts
              return true;
            }
          : null,
    );
  }

  /// True only on platforms with a real GPS source (mobile). Desktop/web have
  /// no fix, so the "my location" button is hidden there.
  bool get _gpsCenterAvailable {
    final p = platform.platformName();
    return p == 'android' || p == 'ios';
  }

  /// Open the map as a dedicated full-screen page so it's easier to pan/zoom.
  /// Map-focused (no chat overlay covering it — the chat stays in its normal
  /// tab); the full-screen toggle becomes an "exit" button that pops back. The
  /// page shares the host's map state, so panning here carries back on exit.
  void _openFullScreenMap(GeoUiBlock mapGroup) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (ctx) => Scaffold(
        backgroundColor: const Color(0xFF0a0e14),
        body: SafeArea(
          child: _buildSlippyMap(
            mapGroup,
            embedChat: false,
            isFullscreen: true,
            onExpand: () => Navigator.of(ctx).maybePop(),
          ),
        ),
      ),
    ));
  }

  Widget _buildMapScreen(GeoUiBlock screen, GeoUiBlock mapGroup) {
    // A screen that carries BOTH the map group and the `geochat` chat field
    // renders as a vertical split: map (with radius/search) on top, the geo
    // chat panel below, separated by a drag handle so the user balances how
    // much of each they want. One tab = pick the area AND talk to it.
    final geoChatField = screen.children
        .where((c) =>
            c.keyword == 'field' &&
            c.type == 'chat' &&
            (c.name ?? '') == 'geochat')
        .firstOrNull;
    // `"toolbar": true` puts the screen's actions in a row over the map, as a
    // list screen does; without it they are only in the options menu.
    final toolbarActions = screen.getBool('toolbar') == true
        ? screen.children
            .where((c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty)
            .toList()
        : const <GeoUiBlock>[];
    final map = Column(
      children: [
        if (toolbarActions.isNotEmpty)
          _toolbarRow(toolbarActions,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8)),
        if (mapGroup.getBool('radius') ?? true) _buildMapRadiusBar(),
        Expanded(
          child: _buildSlippyMap(
            mapGroup,
            embedChat: geoChatField == null,
            onExpand: () => _openFullScreenMap(mapGroup),
          ),
        ),
      ],
    );
    if (geoChatField == null) return map;
    return LayoutBuilder(builder: (context, box) {
      // Landscape (wide enough): map on the LEFT, chat on the RIGHT, with a
      // movable vertical divider. Needs room for both columns; otherwise fall
      // back to the vertical (top/bottom) split.
      if (box.maxWidth > box.maxHeight && box.maxWidth >= 560) {
        final totalW = box.maxWidth;
        final chatW = (totalW * _geoSplitLand).clamp(240.0, totalW - 280.0);
        return Row(
          children: [
            Expanded(child: map),
            _geoSplitHandleH(totalW),
            SizedBox(
                width: chatW,
                child: _buildGeoChatScreen(showStatus: false)),
          ],
        );
      }
      final total = box.maxHeight;
      // While the user is typing (keyboard up), the old fixed ~150 px chat box
      // under the Expanded map left the composer cramped and half-hidden — easy
      // to mis-tap send, hard to actually write. So when the keyboard is open,
      // flip to CHAT-DOMINANT: the map shrinks to a thin peek and the chat
      // panel takes the rest, putting a full-size composer right above the
      // keyboard. Back to the normal drag-split once the keyboard closes.
      // Raw platform keyboard inset (View, not MediaQuery): the Scaffold's
      // resizeToAvoidBottomInset consumes MediaQuery.viewInsets for its
      // descendants, so that would always read 0 here.
      final view = View.of(context);
      final keyboardUp = view.viewInsets.bottom > 0;
      if (keyboardUp) {
        return Column(
          children: [
            SizedBox(height: (total * 0.25).clamp(80.0, 180.0), child: map),
            _geoSplitHandle(total),
            Expanded(child: _buildGeoChatScreen(showStatus: false)),
          ],
        );
      }
      // Chat height from the user-set fraction, but never starve either side:
      // chat keeps at least its header+composer, map keeps room to pan.
      final chatH = (total * _geoSplit).clamp(150.0, total - 200.0);
      return Column(
        children: [
          Expanded(child: map),
          _geoSplitHandle(total),
          SizedBox(
              height: chatH,
              child: _buildGeoChatScreen(showStatus: false)),
        ],
      );
    });
  }

  /// The vertical grab-bar between the map (left) and chat (right) in landscape
  /// — drag horizontally to rebalance. [total] is the available width.
  Widget _geoSplitHandleH(double total) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => setState(() {
          _geoSplitLand =
              (_geoSplitLand - d.delta.dx / total).clamp(0.2, 0.7);
        }),
        child: Container(
          width: 20,
          height: double.infinity,
          color: cs.surfaceContainerHighest.withAlpha(90),
          alignment: Alignment.center,
          child: Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withAlpha(140),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  /// The grab-bar between map and chat — drag to rebalance the split.
  Widget _geoSplitHandle(double total) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => setState(() {
        _geoSplit = (_geoSplit - d.delta.dy / total).clamp(0.18, 0.8);
      }),
      child: Container(
        height: 20,
        width: double.infinity,
        color: cs.surfaceContainerHighest.withAlpha(90),
        alignment: Alignment.center,
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: cs.onSurfaceVariant.withAlpha(140),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  /// The geo chat panel: Live | Beacons feed + composer. [showStatus] is off
  /// when the panel sits under the map (the map already shows the pills).
  Widget _buildGeoChatScreen({bool showStatus = true}) {
    return _GeoChatPanel(
      chatLive: _geoLive,
      chatBeacons: _geoBeacons,
      status: showStatus ? _mapStatus : const [],
      onChatSend: (text) {
        _fieldValues['geochat_input'] = text;
        _sendCommand('geochat_send');
        if (mounted) setState(() {});
      },
      onClearChat: (tab) {
        if (tab == 0) {
          _geoLive.clear();
        } else {
          _geoBeacons.clear();
        }
        if (mounted) setState(() {});
      },
      onLocate: _locateFromMessage,
      onSenderTap: _showProfile,
    );
  }

  double _sliderToKm(double t) => t <= 0.5
      ? _rMin * pow(_rMid / _rMin, t / 0.5).toDouble()
      : _rMid * pow(_rMax / _rMid, (t - 0.5) / 0.5).toDouble();

  double _kmToSlider(double km) {
    km = km.clamp(_rMin, _rMax);
    return km <= _rMid
        ? 0.5 * (log(km / _rMin) / log(_rMid / _rMin))
        : 0.5 + 0.5 * (log(km / _rMid) / log(_rMax / _rMid));
  }

  double _snapKm(double km) {
    if (km < 10) return (km * 2).round() / 2;
    if (km < 100) return km.round().toDouble();
    return (km / 10).round() * 10;
  }

  /// The radius slider strip shown above the map. Dragging updates the
  /// circle live; releasing commits (re-filters the APRS-IS feed).
  Widget _buildMapRadiusBar() {
    final cs = Theme.of(context).colorScheme;
    final km = _mapDragKm ?? _mapRadiusKm ?? 100;
    final label = km >= 10 ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      color: cs.surfaceContainerHighest.withAlpha(120),
      child: Row(
        children: [
          Icon(Icons.cell_tower, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Slider(
              value: _kmToSlider(km),
              onChanged: (t) =>
                  setState(() => _mapDragKm = _snapKm(_sliderToKm(t))),
              onChangeEnd: (t) {
                final v = _snapKm(_sliderToKm(t));
                setState(() {
                  _mapDragKm = null;
                  _mapRadiusKm = v;
                });
                _fieldValues['map_radius'] = v.round().toString();
                _fieldValues['radius_km'] = v.round().toString();
                _sendCommand('set_radius');
              },
            ),
          ),
          const SizedBox(width: 6),
          Text(label,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Full-panel Geo Chat (its own tab). Live | Beacons sub-tabs + composer,
/// sized to fill a whole screen so it's comfortable in portrait — the same
/// data the map overlay used, no minimise/close chrome.
class _GeoChatPanel extends StatefulWidget {
  final List<Map<String, dynamic>> chatLive;
  final List<Map<String, dynamic>> chatBeacons;
  final List<Map<String, dynamic>> status;
  final void Function(String text) onChatSend;
  final void Function(int tab) onClearChat;
  final void Function(Map<String, dynamic>)? onLocate;
  final void Function(String from)? onSenderTap;
  const _GeoChatPanel({
    required this.chatLive,
    required this.chatBeacons,
    required this.onChatSend,
    required this.onClearChat,
    this.status = const [],
    this.onLocate,
    this.onSenderTap,
  });

  @override
  State<_GeoChatPanel> createState() => _GeoChatPanelState();
}

class _GeoChatPanelState extends State<_GeoChatPanel> {
  int _tab = 0; // 0 = Live, 1 = Beacons

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = widget.chatLive;
    final beacons = widget.chatBeacons;
    final showing = _tab == 0 ? live : beacons;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
          child: Row(
            children: [
              Expanded(child: _tabBtn(cs, 'Live', live.length, 0)),
              const SizedBox(width: 8),
              Expanded(child: _tabBtn(cs, 'Beacons', beacons.length, 1)),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_sweep, size: 20),
                tooltip: tr(_tab == 0 ? 'wapp_host.geochat.clear_live' : 'wapp_host.geochat.clear_beacons'),
                visualDensity: VisualDensity.compact,
                onPressed:
                    showing.isEmpty ? null : () => widget.onClearChat(_tab),
              ),
            ],
          ),
        ),
        if (widget.status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _statusRow(cs, widget.status),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ChatViewField(
            key: ValueKey('geochat-tab-$_tab'),
            fieldName: 'geochat',
            label: '',
            hint: tr(_tab == 0 ? 'wapp_host.geochat.hint' : 'wapp_host.geochat.beacons_hint'),
            fill: true,
            messages: showing,
            onLocate: widget.onLocate,
            onSenderTap: widget.onSenderTap,
            onSend: widget.onChatSend,
          ),
        ),
      ],
    );
  }

  Widget _tabBtn(ColorScheme cs, String label, int count, int idx) {
    final sel = _tab == idx;
    return InkWell(
      onTap: () => setState(() => _tab = idx),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel
              ? cs.primaryContainer
              : cs.surfaceContainerHighest.withAlpha(90),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '$label ($count)',
          style: TextStyle(
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _statusRow(ColorScheme cs, List<Map<String, dynamic>> items) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(120),
              borderRadius: BorderRadius.circular(10),
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
                const SizedBox(width: 5),
                Text((s['label'] ?? '').toString(),
                    style: const TextStyle(fontSize: 11.5)),
              ],
            ),
          ),
      ],
    );
  }
}
