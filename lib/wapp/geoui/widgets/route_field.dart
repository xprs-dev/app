// A GeoUI field (`$type:"route"`) that draws how a message gets from here to
// a station: one row per way, station, bearer, station, hop by hop. It shows
// what the core's diagnostic says (hal_station_read get:"ways") and decides
// nothing; a hop the core only inferred is drawn dashed and marked a guess.
//
// Value: {"routes":[{"sure":bool,"hops":[{"from","to","bearer","reach",
// "know":"heard|asked|said|guess","age_s","rssi"}]}]}
import 'package:flutter/material.dart';

import '../../../services/i18n/core_i18n.dart';

class RouteField extends StatelessWidget {
  const RouteField({super.key, required this.value});
  final Map<String, dynamic> value;

  static const Map<String, (IconData, Color)> _bearers = {
    'ble': (Icons.bluetooth, Color(0xFF4FC3F7)),
    'ble5': (Icons.bluetooth, Color(0xFF4FC3F7)),
    'lan': (Icons.lan_outlined, Color(0xFF81C784)),
    'wifi': (Icons.wifi, Color(0xFF81C784)),
    'espnow': (Icons.wifi_tethering, Color(0xFF81C784)),
    'lora': (Icons.cell_tower, Color(0xFFBA68C8)),
    'vhf': (Icons.settings_input_antenna, Color(0xFFE57373)),
    'uhf': (Icons.settings_input_antenna, Color(0xFFE57373)),
    'hf': (Icons.settings_input_antenna, Color(0xFFE57373)),
    'radio': (Icons.settings_input_antenna, Color(0xFFE57373)),
    'internet': (Icons.public, Color(0xFFFFD54F)),
    'rns': (Icons.public, Color(0xFFFFD54F)),
  };

  static String bearerName(String b) => switch (b) {
        'ble' || 'ble5' => 'Bluetooth',
        'lan' => 'LAN',
        'wifi' => 'WiFi',
        'espnow' => 'ESP-NOW',
        'lora' => 'LoRa',
        'internet' || 'rns' => 'Reticulum',
        '' => '?',
        _ => b.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final routes = (value['routes'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    if (routes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(tr('geoui.route.none'),
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      );
    }
    // A station heard here on several radios is one card with a line per
    // radio, not a card each.
    final direct = [
      for (final r in routes)
        if ((r['hops'] as List? ?? const []).length == 1) r,
    ];
    final relayed = [for (final r in routes) if (!direct.contains(r)) r];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (direct.isNotEmpty)
          _route(context, {
            'sure': direct.every((r) => r['sure'] != false),
            'hops': [for (final r in direct) (r['hops'] as List).first],
            'parallel': true,
          }),
        for (final r in relayed) _route(context, r),
        if (value['busy'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr('geoui.route.asking'),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ],
    );
  }

  Widget _route(BuildContext context, Map<String, dynamic> r) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hops = (r['hops'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    if (hops.isEmpty) return const SizedBox.shrink();
    final sure = r['sure'] != false;

    Widget station(String call, {bool end = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: end ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(call == '?' ? tr('geoui.route.unknown') : call,
              style: tt.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontStyle: call == '?' ? FontStyle.italic : null,
                  color: end ? cs.onPrimaryContainer : cs.onSurface)),
        );

    Widget link(Map<String, dynamic> h) {
      final b = '${h['bearer'] ?? ''}';
      final know = '${h['know'] ?? 'guess'}';
      final guess = know == 'guess';
      final (icon, color) = _bearers[b] ?? (Icons.more_horiz, cs.outline);
      final c = guess ? cs.outline : color;
      final age = h['age_s'] is int ? h['age_s'] as int : null;
      final rssi = h['rssi'] is int ? h['rssi'] as int : null;
      final note = [
        switch (know) {
          'heard' => tr('geoui.route.know.heard'),
          'asked' => tr('geoui.route.know.asked'),
          'said' => tr('geoui.route.know.said'),
          _ => tr('geoui.route.know.guess'),
        },
        if (age != null && !guess) _ago(age),
        if (rssi != null) '$rssi dBm',
      ].join(' · ');
      return Padding(
        padding: const EdgeInsets.only(left: 18),
        child: IntrinsicHeight(
          child: Row(
            children: [
              CustomPaint(
                size: const Size(2, 26),
                painter: _Line(c, dashed: guess),
              ),
              const SizedBox(width: 14),
              Icon(guess ? Icons.help_outline : icon, size: 18, color: c),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  guess ? note : '${bearerName(b)} · $note',
                  style: tt.bodySmall?.copyWith(
                      color: guess ? cs.onSurfaceVariant : cs.onSurface,
                      fontStyle: guess ? FontStyle.italic : null),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!sure)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('geoui.route.partly_guess'),
                  style: tt.labelSmall?.copyWith(color: cs.tertiary)),
            ),
          station(tr('geoui.route.you')),
          if (r['parallel'] == true) ...[
            for (final h in hops) link(h),
            station('${hops.first['to'] ?? '?'}', end: true),
          ] else
            for (var i = 0; i < hops.length; i++) ...[
              link(hops[i]),
              station('${hops[i]['to'] ?? '?'}', end: i == hops.length - 1),
            ],
        ],
      ),
    );
  }

  static String _ago(int s) => s < 90
      ? tr('geoui.route.ago_s', {'n': '$s'})
      : s < 5400
          ? tr('geoui.route.ago_m', {'n': '${s ~/ 60}'})
          : tr('geoui.route.ago_h', {'n': '${s ~/ 3600}'});
}

class _Line extends CustomPainter {
  _Line(this.color, {required this.dashed});
  final Color color;
  final bool dashed;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    if (!dashed) {
      canvas.drawLine(Offset(1, 0), Offset(1, size.height), p);
      return;
    }
    for (var y = 0.0; y < size.height; y += 7) {
      canvas.drawLine(Offset(1, y), Offset(1, (y + 4).clamp(0, size.height)), p);
    }
  }

  @override
  bool shouldRepaint(_Line old) => old.color != color || old.dashed != dashed;
}
