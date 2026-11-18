// Small charts for the Archiver page, drawn with CustomPainter (the app ships
// no chart library and these need none).
//
// One series per chart, so no legend box: the title names it. Inks come from
// the theme (app_theme.dart: white on black), marks are thin with rounded
// data ends on a recessive baseline, and a touch on a mark shows its value
// above the plot (the touch equivalent of a hover tooltip). The split bar is
// the one multi-part chart; its parts are grey steps AND labelled in the
// legend rows beside their numbers, so identity is never colour alone.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One point: an x label (a day, an hour) and a value.
class ChartPoint {
  const ChartPoint(this.label, this.value);
  final String label;
  final double value;
}

/// The value line above a chart: the touched point, or [idle] when none is.
class _Readout extends StatelessWidget {
  const _Readout(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 20,
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
    );
  }
}

/// A touchable chart: tracks which point the finger is on.
class _Touchable extends StatefulWidget {
  const _Touchable({
    required this.points,
    required this.format,
    required this.idle,
    required this.painter,
    this.height = 120,
  });
  final List<ChartPoint> points;
  final String Function(ChartPoint p) format;
  final String idle;
  final CustomPainter Function(int? selected, ColorScheme cs) painter;
  final double height;

  @override
  State<_Touchable> createState() => _TouchableState();
}

class _TouchableState extends State<_Touchable> {
  int? _sel;

  void _at(Offset local, double width) {
    final n = widget.points.length;
    if (n == 0 || width <= 0) return;
    final i = (local.dx / width * n).floor().clamp(0, n - 1);
    if (i != _sel) setState(() => _sel = i);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sel = _sel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Readout(sel == null || sel >= widget.points.length
            ? widget.idle
            : widget.format(widget.points[sel])),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _at(d.localPosition, c.maxWidth),
            onHorizontalDragUpdate: (d) => _at(d.localPosition, c.maxWidth),
            onHorizontalDragEnd: (_) => setState(() => _sel = null),
            onTapUp: (_) {},
            child: SizedBox(
              height: widget.height,
              width: c.maxWidth,
              child: CustomPaint(painter: widget.painter(sel, cs)),
            ),
          );
        }),
        const SizedBox(height: 4),
        if (widget.points.isNotEmpty)
          Row(children: [
            Text(widget.points.first.label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const Spacer(),
            Text(widget.points.last.label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ]),
      ],
    );
  }
}

/// Columns, one per point, from a shared baseline.
class BarChart extends StatelessWidget {
  const BarChart({
    super.key,
    required this.points,
    required this.format,
    required this.idle,
    this.height = 120,
  });
  final List<ChartPoint> points;
  final String Function(ChartPoint p) format;
  final String idle;
  final double height;

  @override
  Widget build(BuildContext context) => _Touchable(
        points: points,
        format: format,
        idle: idle,
        height: height,
        painter: (sel, cs) => _BarPainter(points, sel, cs),
      );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.points, this.sel, this.cs);
  final List<ChartPoint> points;
  final int? sel;
  final ColorScheme cs;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = cs.outlineVariant
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5),
        Offset(size.width, size.height - 0.5), base);
    if (points.isEmpty) return;
    final maxV = points.map((p) => p.value).fold<double>(0, math.max);
    final slot = size.width / points.length;
    const gap = 2.0;
    final w = math.max(1.0, math.min(slot - gap, 28.0));
    for (var i = 0; i < points.length; i++) {
      final v = points[i].value;
      final h = maxV <= 0 ? 0.0 : (v / maxV) * (size.height - 4);
      if (h <= 0) continue;
      final x = i * slot + (slot - w) / 2;
      final r = math.min(4.0, w / 2);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, size.height - 1 - h, w, h),
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
      );
      final ink = sel == null || sel == i
          ? cs.onSurface
          : cs.onSurface.withValues(alpha: 0.35);
      canvas.drawRRect(rect, Paint()..color = ink);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.sel != sel || old.points != points || old.cs != cs;
}

/// A 2px line over a faint area, with the last value marked.
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.points,
    required this.format,
    required this.idle,
    this.height = 120,
  });
  final List<ChartPoint> points;
  final String Function(ChartPoint p) format;
  final String idle;
  final double height;

  @override
  Widget build(BuildContext context) => _Touchable(
        points: points,
        format: format,
        idle: idle,
        height: height,
        painter: (sel, cs) => _LinePainter(points, sel, cs),
      );
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, this.sel, this.cs, {this.marker = true});
  final List<ChartPoint> points;
  final int? sel;
  final ColorScheme cs;
  final bool marker;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final maxV = points.map((p) => p.value).fold<double>(0, math.max);
    final slot = size.width / points.length;
    Offset at(int i) {
      final v = points[i].value;
      final y = maxV <= 0
          ? size.height - 1
          : size.height - 1 - (v / maxV) * (size.height - 8);
      return Offset(i * slot + slot / 2, y);
    }

    canvas.drawLine(
        Offset(0, size.height - 0.5),
        Offset(size.width, size.height - 0.5),
        Paint()
          ..color = cs.outlineVariant
          ..strokeWidth = 1);
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(at(points.length - 1).dx, size.height)
      ..lineTo(at(0).dx, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = cs.onSurface.withValues(alpha: 0.10));
    canvas.drawPath(
        line,
        Paint()
          ..color = cs.onSurface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    final mark = sel ?? (marker ? points.length - 1 : null);
    if (mark != null) {
      final p = at(mark);
      if (sel != null) {
        canvas.drawLine(
            Offset(p.dx, 0),
            Offset(p.dx, size.height),
            Paint()
              ..color = cs.outline
              ..strokeWidth = 1);
      }
      // A surface ring keeps the dot readable where it sits on the line.
      canvas.drawCircle(p, 6, Paint()..color = cs.surfaceContainerLow);
      canvas.drawCircle(p, 4, Paint()..color = cs.onSurface);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.sel != sel || old.points != points || old.cs != cs;
}

/// A compact 24-hour line, no axis labels; [caption] says what it is.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.height = 36});
  final List<num> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pts = [
      for (final v in values) ChartPoint('', v.toDouble()),
    ];
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _LinePainter(pts, null, cs, marker: true)),
    );
  }
}

/// One horizontal bar split into parts, with a labelled row per part.
class SplitBar extends StatelessWidget {
  const SplitBar({super.key, required this.parts});

  /// (label, value, display text)
  final List<(String, double, String)> parts;

  static const _inks = [Colors.white, Color(0xFF9E9E9E), Color(0xFF5C5C5C)];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final total = parts.fold<double>(0, (s, p) => s + p.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 14,
            child: Row(children: [
              if (total <= 0)
                Expanded(
                    child: ColoredBox(
                        color: cs.surfaceContainerHighest,
                        child: const SizedBox(height: 14))),
              for (var i = 0; i < parts.length; i++)
                if (total > 0 && parts[i].$2 > 0) ...[
                  Expanded(
                    flex: math.max(1, (parts[i].$2 / total * 1000).round()),
                    // A childless ColoredBox is zero-sized: give it the bar's height.
                    child: ColoredBox(
                        color: _inks[i % _inks.length],
                        child: const SizedBox(height: 14)),
                  ),
                  if (i < parts.length - 1) const SizedBox(width: 2),
                ],
            ]),
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < parts.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _inks[i % _inks.length],
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: cs.outline, width: 0.5),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(parts[i].$1, style: tt.bodyMedium)),
              Text(parts[i].$3,
                  style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              SizedBox(
                width: 52,
                child: Text(
                  total <= 0
                      ? ''
                      : '${(parts[i].$2 / total * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ]),
          ),
      ],
    );
  }
}
