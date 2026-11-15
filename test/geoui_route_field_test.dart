// The route field draws how a message gets to a station as the core's
// diagnostic says it, and a hop nobody reported is shown as a guess.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/route_field.dart';

void main() {
  Future<void> pump(WidgetTester tester, Map<String, dynamic> value) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RouteField(value: value))),
      ));

  testWidgets('each hop names its station, its bearer and how it is known',
      (tester) async {
    await pump(tester, {
      'routes': [
        {
          'sure': true,
          'hops': [
            {'from': 'X1ME', 'to': 'X3AAAA', 'bearer': 'ble', 'know': 'heard', 'age_s': 4},
            {'from': 'X3AAAA', 'to': 'X3BBBB', 'bearer': 'lora', 'know': 'asked', 'age_s': 70, 'rssi': -101},
            {'from': 'X3BBBB', 'to': 'X1FAR', 'bearer': 'lan', 'know': 'said', 'age_s': 200},
          ],
        },
      ],
    });
    expect(find.text('X3AAAA'), findsOneWidget);
    expect(find.text('X3BBBB'), findsOneWidget);
    expect(find.text('X1FAR'), findsOneWidget);
    expect(find.textContaining('Bluetooth'), findsOneWidget);
    expect(find.textContaining('LoRa'), findsOneWidget);
    expect(find.textContaining('-101 dBm'), findsOneWidget);
    expect(find.textContaining('LAN'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsNothing);
  });

  testWidgets('a hop nobody reported is drawn as a guess', (tester) async {
    await pump(tester, {
      'routes': [
        {
          'sure': false,
          'hops': [
            {'from': 'X1ME', 'to': 'X3HUB', 'bearer': 'internet', 'know': 'heard', 'age_s': 9},
            {'from': 'X3HUB', 'to': '?', 'bearer': '', 'know': 'guess'},
            {'from': '?', 'to': 'X1AWAY', 'bearer': '', 'know': 'guess'},
          ],
        },
      ],
    });
    expect(find.byIcon(Icons.help_outline), findsNWidgets(2));
    expect(find.text('X1AWAY'), findsOneWidget);
    expect(find.textContaining('Reticulum'), findsOneWidget);
  });

  testWidgets('no way known says so and invents nothing', (tester) async {
    await pump(tester, {'routes': []});
    expect(find.byType(Container), findsNothing);
  });
}
