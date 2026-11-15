// A wapp's settings save as they are changed, and a button can open the host
// page where a setting the wapp depends on is changed.
//
// A text field with `apply` sends that command once the typing pauses (no
// Save button), and a button with `"open": "host:<name>"` opens the page
// registered under that name, then sends its own command when the person
// comes back so the wapp can re-read what changed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/geoui_parser.dart';
import 'package:xprs/wapp/geoui/geoui_renderer.dart';
import 'package:xprs/wapp/wapp_open.dart';

class _Bindings extends GeoUiBindings {
  final Map<String, dynamic> values = {};
  @override
  dynamic getValue(String name) => values[name];
  @override
  void setValue(String name, dynamic v) => values[name] = v;
}

const _screen = '''
[{"\$":"screen","name":"S","children":[
  {"\$":"field","name":"greeting","\$type":"string","label":"Greeting",
   "apply":"save_greeting"},
  {"\$":"action","name":"share_location","label":"Share my location",
   "open":"host:test"}
]}]''';

void main() {
  Future<(List<String>, _Bindings)> pump(WidgetTester tester) async {
    final sent = <String>[];
    final b = _Bindings();
    final file = GeoUiParser(_screen).parse();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GeoUiScreenRenderer(
          screen: file.firstScreen!,
          bindings: b,
          onAction: sent.add,
        ),
      ),
    ));
    return (sent, b);
  }

  testWidgets('a text field saves once the typing pauses', (tester) async {
    final (sent, b) = await pump(tester);
    await tester.enterText(find.byType(TextField), 'Welcome');
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, isEmpty, reason: 'not on every keystroke');
    await tester.enterText(find.byType(TextField), 'Welcome, 73');
    await tester.pump(const Duration(milliseconds: 900));
    expect(sent, ['save_greeting']);
    expect(b.values['greeting'], 'Welcome, 73');
  });

  testWidgets('a button opens a host page and reports back', (tester) async {
    hostNotificationPages['host:test'] =
        () => const Scaffold(body: Text('position settings'));
    addTearDown(() => hostNotificationPages.remove('host:test'));
    final (sent, _) = await pump(tester);
    await tester.tap(find.text('Share my location'));
    await tester.pumpAndSettle();
    expect(find.text('position settings'), findsOneWidget);
    expect(sent, isEmpty, reason: 'the command waits for the way back');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(sent, ['share_location']);
  });
}
