// The map with a drawer: a map screen whose map group says `"drawer": true`
// and which also holds a `$type:"people"` field shows that list (with the
// screen's search box, chips and tabs, exactly as a list screen draws them)
// in a drawer over the map, the way the xprs.dev portal's map page does
// (portal/page/chat_page.html, sheetDraw): on a phone it is pulled up from the
// bottom to three heights, folded (the search box only), half the screen or
// all of it; on a screen wider than tall it is a panel on the left that folds
// away. The wapp can move it (`ui.drawer` {state: peek|half|full}); a
// `ui.map.locate` folds it so the place shows; Back folds it before leaving.
// Part of the wapp_page library, like wapp_maps.dart.

part of 'wapp_page.dart';

/// Wider than tall and at least this wide: the drawer is a side panel.
const double _kDrawerWideMin = 720;

extension _WappDrawer on _WappPageState {
  /// The list a map screen puts in its drawer, or null when it has none.
  GeoUiBlock? _drawerField(GeoUiBlock screen, GeoUiBlock mapGroup) {
    if (mapGroup.getBool('drawer') != true) return null;
    return screen.children
        .where((c) => c.keyword == 'field' && c.type == 'people' && (c.name ?? '').isNotEmpty)
        .firstOrNull;
  }

  bool _drawerWide(Size s) => s.width >= _kDrawerWideMin && s.width > s.height;

  /// Whether Back should fold the drawer: the tab on screen is a drawer map,
  /// no panel is open over it, and on a phone the drawer is up.
  bool _drawerBackFolds() {
    if (_panelScreen != null || _tabController == null) return false;
    final i = _tabController!.index;
    if (i < 0 || i >= _tabScreens.length) return false;
    final screen = _tabScreens[i];
    final map = screen.children.where((c) => c.keyword == 'group' && c.type == 'map').firstOrNull;
    if (map == null || _drawerField(screen, map) == null) return false;
    final size = MediaQuery.maybeOf(context)?.size ?? const Size(400, 800);
    return !_drawerWide(size) && _drawerState != 'peek';
  }

  /// `ui.drawer` from the wapp, a tab tapped in the peek, a drag settling.
  void _drawerTo(String state) {
    if (state != 'peek' && state != 'half' && state != 'full') return;
    setState(() {
      _drawerState = state;
      _drawerDragH = null;
      if (state != 'peek') _drawerFolded = false;
    });
  }

  Widget _buildDrawerMapScreen(GeoUiBlock screen, GeoUiBlock mapGroup, GeoUiBlock field) {
    // The map knows how much of it the drawer covers, so its buttons sit
    // just above the drawer's edge (and move with it).
    Widget mapUnder(double covered) => _buildSlippyMap(
          mapGroup,
          embedChat: false,
          onExpand: () => _openFullScreenMap(mapGroup),
          bottomInset: covered,
        );
    final list = _buildPeopleScreen(screen, field);
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      if (_drawerWide(size)) {
        // Landscape and desktop: the list in a panel on the left, the map
        // keeps the rest; the panel folds away to a button on the map.
        final panelW = (box.maxWidth * 0.32).clamp(300.0, 420.0);
        return Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: _drawerFolded ? 0 : panelW,
              decoration: BoxDecoration(
                color: ChatPalette.windowBg,
                border: Border(right: BorderSide(color: cs.outlineVariant.withAlpha(90))),
              ),
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: panelW,
                  maxWidth: panelW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          key: const ValueKey('drawer_fold'),
                          icon: const Icon(Icons.keyboard_double_arrow_left),
                          tooltip: tr('wapp_host.drawer.fold'),
                          onPressed: () => setState(() => _drawerFolded = true),
                        ),
                      ),
                      Expanded(child: list),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: mapUnder(0)),
                  if (_drawerFolded)
                    Positioned(
                      left: 12,
                      bottom: 16,
                      child: FloatingActionButton.small(
                        key: const ValueKey('drawer_unfold'),
                        heroTag: 'drawer_unfold',
                        tooltip: tr('wapp_host.drawer.unfold'),
                        onPressed: () => setState(() => _drawerFolded = false),
                        child: const Icon(Icons.view_list),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      }
      // A phone: the drawer over the bottom of the map. It is laid out at
      // its full height and shown through a window of the chosen height, so
      // the list keeps its size while the drawer moves (no reflow per frame)
      // and the folded drawer still shows the search box at its top.
      const handleH = 22.0;
      // Folded, it clears the phone's gesture bar.
      final peekH = (screen.getBool('search') == true ? handleH + 58.0 : handleH + 34.0) +
          MediaQuery.paddingOf(context).bottom;
      final fullH = box.maxHeight;
      final heights = {'peek': peekH, 'half': (box.maxHeight * 0.5).clamp(peekH, fullH), 'full': fullH};
      final h = (_drawerDragH ?? heights[_drawerState] ?? peekH).clamp(peekH, fullH);
      String nearest(double v) {
        var best = 'peek';
        var d = double.infinity;
        heights.forEach((k, x) {
          if ((x - v).abs() < d) {
            d = (x - v).abs();
            best = k;
          }
        });
        return best;
      }

      return Stack(
        children: [
          Positioned.fill(child: mapUnder(h)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: h,
            child: Material(
              key: const ValueKey('map_drawer'),
              color: ChatPalette.windowBg,
              elevation: 8,
              shadowColor: Colors.black,
              borderRadius: BorderRadius.vertical(top: Radius.circular(h >= fullH - 1 ? 0 : 16)),
              clipBehavior: Clip.antiAlias,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: fullH,
                maxHeight: fullH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The handle: drag to any height (it settles on the
                    // nearest of the three), tap to step up, from full back
                    // down to folded.
                    GestureDetector(
                      key: const ValueKey('drawer_handle'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _drawerTo(
                          _drawerState == 'peek' ? 'half' : _drawerState == 'half' ? 'full' : 'peek'),
                      onVerticalDragUpdate: (d) => setState(() {
                        _drawerDragH = ((_drawerDragH ?? h) - d.delta.dy).clamp(peekH, fullH);
                      }),
                      onVerticalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        final cur = _drawerDragH ?? h;
                        // A fling goes one height in its direction.
                        if (v.abs() > 700) {
                          const order = ['peek', 'half', 'full'];
                          var i = order.indexOf(nearest(cur));
                          if (v < 0 && heights[order[i]]! <= cur && i < 2) i++;
                          if (v > 0 && heights[order[i]]! >= cur && i > 0) i--;
                          _drawerTo(order[i]);
                        } else {
                          _drawerTo(nearest(cur));
                        }
                      },
                      child: SizedBox(
                        height: handleH,
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: cs.onSurfaceVariant.withAlpha(150),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      // Folded, a touch on the search box (or the list's
                      // top) opens the drawer to half, as the portal's line.
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerUp: (_) {
                          if (_drawerState == 'peek' && _drawerDragH == null) _drawerTo('half');
                        },
                        child: list,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  /// A `$type:"chips"` field: the wapp's filters as a row of chips, each
  /// with how many it matches, on or off. The value (ui.field.set) is
  /// [{id, label, count?, on?}]; a tap sends `<field>_tap` with
  /// `<field>_id`. The wapp decides what a chip means and redraws them.
  Widget _buildChipsField(GeoUiBlock f) {
    final name = f.name!;
    final raw = _fieldValues[name];
    final chips = raw is List ? raw.whereType<Map>().toList() : const <Map>[];
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        key: ValueKey('chips_$name'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final c = chips[i];
          final id = '${c['id'] ?? ''}';
          final count = c['count'];
          final label = _i18n.resolve('${c['label'] ?? id}');
          return FilterChip(
            key: ValueKey('chip_$id'),
            label: Text(count == null ? label : '$label  $count'),
            selected: c['on'] == true,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              _fieldValues['${name}_id'] = id;
              _sendCommand('${name}_tap');
            },
          );
        },
      ),
    );
  }
}
