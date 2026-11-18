// The Archiver page's charts (lib/launcher/archiver_charts.dart) draw
// something: the split bar's parts have height (a childless ColoredBox is
// zero-sized, which hid the bar on the phone), and the bar chart shows a
// touched day's value.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/launcher/app_theme.dart';
import 'package:xprs/launcher/archiver_charts.dart';

Widget _host(Widget child) => MaterialApp(
      theme: xprsTheme(),
      home: Scaffold(body: SizedBox(width: 360, child: child)),
    );

void main() {
  testWidgets('every non-empty part of the split bar is visible',
      (tester) async {
    await tester.pumpWidget(_host(const SplitBar(parts: [
      ('Mine', 70, '70'),
      ('Followed', 0, '0'),
      ('Strangers', 30, '30'),
    ])));
    final boxes = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .where((b) => b.color == Colors.white || b.color == const Color(0xFF5C5C5C))
        .toList();
    expect(boxes, hasLength(2));
    for (final b in boxes) {
      final size = tester.getSize(find.byWidget(b));
      expect(size.height, 14);
      expect(size.width, greaterThan(0));
    }
    expect(find.text('70%'), findsOneWidget);
  });

  testWidgets('a touched bar reads out its day', (tester) async {
    await tester.pumpWidget(_host(BarChart(
      points: const [ChartPoint('1/11', 3), ChartPoint('2/11', 9)],
      idle: 'idle',
      format: (p) => '${p.label}: ${p.value.round()}',
    )));
    expect(find.text('idle'), findsOneWidget);
    final plot = find.byType(CustomPaint).last;
    final r = tester.getRect(plot);
    await tester.tapAt(Offset(r.right - 5, r.center.dy));
    await tester.pump();
    expect(find.text('2/11: 9'), findsOneWidget);
  });
}
