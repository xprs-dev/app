// The widget that draws formatted text (lib/wapp/geoui/widgets/xprs_md_text.dart)
// with tappable links. The reading itself is core's xprs_md.dart, tested there
// against the vectors the web chat shares.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/xprs_md_text.dart';

void main() {
  testWidgets('tapping a link in the text opens it', (tester) async {
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: XprsMdText('**go** to https://xprs.dev now, @X1QZ3N',
            style: const TextStyle(fontSize: 14, color: Colors.white),
            linkColor: Colors.blue,
            mutedColor: Colors.grey,
            onLink: (u) => opened = u),
      ),
    ));
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    expect(rich.text.toPlainText(), 'go to https://xprs.dev now, @X1QZ3N');
    TextSpan? link;
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.recognizer != null) link = s;
      return true;
    });
    expect(link?.text, 'https://xprs.dev');
    (link!.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, 'https://xprs.dev');
  });
}
