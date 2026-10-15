// XPRS.md 7.8: the list of versions of one message, oldest first, and what
// happens to it when the message is withdrawn while it is open.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/edit_history_list.dart';

void main() {
  final versions = [
    {'text': 'meet at six', 'date': '2026-10-15', 'time': '09:12', 'by': 'X1ARKL', 'role': 'author'},
    {'text': 'meet at seven', 'date': '2026-10-15', 'time': '09:20', 'by': 'X1ARKL', 'role': 'author'},
  ];

  testWidgets('lists the original first and the current version last', (t) async {
    final shown = ValueNotifier<List<Map<String, dynamic>>>(versions);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: EditHistoryList(versions: shown))));
    expect(find.textContaining('Original'), findsOneWidget);
    expect(find.textContaining('Current'), findsOneWidget);
    expect(find.text('meet at six'), findsOneWidget);
    expect(find.text('meet at seven'), findsOneWidget);
  });

  testWidgets('a withdrawal while it is open takes the words off the screen',
      (t) async {
    final shown = ValueNotifier<List<Map<String, dynamic>>>(versions);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: EditHistoryList(versions: shown))));
    expect(find.text('meet at six'), findsOneWidget);
    shown.value = [
      {'note': 'This message was deleted.'},
    ];
    await t.pump();
    expect(find.text('meet at six'), findsNothing);
    expect(find.text('meet at seven'), findsNothing);
    expect(find.text('This message was deleted.'), findsOneWidget);
  });
}
