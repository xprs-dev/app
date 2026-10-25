/*
 * Typing a callsign the way an Android keyboard does.
 *
 * Gboard holds each word as COMPOSING text while it is typed. The profile
 * screen's old formatter uppercased the text under it on every keystroke and
 * dropped the composing range; the keyboard then re-sent its own copy and the
 * field doubled, lost or reordered letters -- "it doesn't allow to type"
 * (2026-10-24). This drives the field with composing updates and checks the
 * letters arrive as typed.
 */
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/profile/callsign_input.dart';

void main() {
  testWidgets('composing text is never rewritten under the keyboard',
      (t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TextField(
          controller: c,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [CallsignInputFormatter()],
        ),
      ),
    ));
    await t.tap(find.byType(TextField));
    await t.pump();

    // Letter by letter, each one composing, as Gboard sends them.
    var typed = '';
    for (final ch in 'ct1abc'.split('')) {
      typed += ch;
      t.testTextInput.updateEditingValue(TextEditingValue(
        text: typed,
        selection: TextSelection.collapsed(offset: typed.length),
        composing: TextRange(start: 0, end: typed.length),
      ));
      await t.pump();
      expect(c.text, typed, reason: 'composing text must arrive unchanged');
    }
    // The keyboard commits the word.
    t.testTextInput.updateEditingValue(TextEditingValue(
      text: typed,
      selection: TextSelection.collapsed(offset: typed.length),
    ));
    await t.pump();
    expect(c.text, 'ct1abc');
  });

  testWidgets('what a callsign cannot contain is kept out, once committed',
      (t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TextField(
            controller: c, inputFormatters: [CallsignInputFormatter()]),
      ),
    ));
    await t.tap(find.byType(TextField));
    await t.pump();
    t.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'EA/CT1 ABC!',
      selection: TextSelection.collapsed(offset: 11),
    ));
    await t.pump();
    expect(c.text, 'EA/CT1ABC');
  });
}
