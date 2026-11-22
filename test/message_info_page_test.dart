// A message's Info is a page of its own, filled in from what the wapp says
// about it; and a sender's name opens the same menu the bubble's ⋮ does,
// rather than a prompt that could only block.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/chat_view_field.dart';
import 'package:xprs/services/people/xprs_people.dart';
import 'package:xprs/wapp/geoui/widgets/message_info_page.dart';

import 'i18n_english.dart';

void main() {
  installEnglishForTest();

  Map<String, dynamic> bubble({String status = '', String dir = 'in'}) => {
        'dir': dir,
        'from': 'X1PEER',
        'text': 'the better words',
        'time': '13:33',
        'mid': 'aa1111',
        'enc': true,
        'edited': true,
        if (status.isNotEmpty) 'status': status,
      };

  Future<void> pumpChat(WidgetTester tester, Map<String, dynamic> m,
      {List<Map<String, dynamic>>? asked,
      List<Map<String, dynamic>>? plain}) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatViewField(
          fieldName: 'chat',
          label: 'Chat',
          fill: true,
          messages: [m],
          onSend: (_) {},
          onInfo: asked?.add,
          onSendPlain: plain?.add,
          onDirectMessage: (_) {},
          onBlock: (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('tapping the sender name opens the full message menu',
      (tester) async {
    await pumpChat(tester, bubble());
    await tester.tap(find.text('X1PEER').first);
    await tester.pumpAndSettle();
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Message X1PEER directly'), findsOneWidget);
    expect(find.text('Block X1PEER'), findsOneWidget);
  });

  testWidgets('Info opens a page, asks the wapp, and shows what it answers',
      (tester) async {
    final asked = <Map<String, dynamic>>[];
    await pumpChat(tester, bubble(), asked: asked);
    await tester.tap(find.text('X1PEER').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(asked.single['mid'], 'aa1111');
    expect(find.text('Message info'), findsOneWidget);

    MessageInfoBus.publish({
      'type': 'ui.convo.info',
      'id': 'X1PEER',
      'mid': 'aa1111',
      'stored': {
        'row': {'mid': 'aa1111', 'dir': 'in', 'sender': 'X1PEER', 'ts': 1700000000},
        'versions': [
          {'text': 'the first words', 'role': 'author', 'by': 'X1PEER'},
          {'text': 'the better words', 'role': 'author', 'by': 'X1PEER'},
        ],
      },
      'packet': {
        'bearer': 'ble',
        'rssi': -71,
        'heard': 3,
        'sig': 'verified',
        'heardTs': 1700000042,
        'wire': 't:message f:X1PEER d:X1SELF ts:2023-11-14_22:13:20 via:X3RLY7 x:QQ',
      },
      'relays': 'X3RLY7,X32DVA',
      'signed': true,
      'sealedWire': true,
      'bytes': 64,
    });
    await tester.pumpAndSettle();
    expect(find.text('Original text'), findsOneWidget);
    expect(find.textContaining('the first words'), findsWidgets);
    // The route: the author, each relay, and this station.
    expect(find.text('X3RLY7'), findsOneWidget);
    expect(find.text('X32DVA'), findsOneWidget);
    expect(find.text('X3RLY7 → X32DVA'), findsOneWidget);
    expect(find.text('-71 dBm'), findsOneWidget);
    final page = find
        .descendant(
            of: find.byType(MessageInfoPage), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Signed — author verified'), 200,
        scrollable: page);
    expect(find.text('Signed — author verified'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('The packet as it travelled'), 200,
        scrollable: page);
    expect(find.textContaining('via:X3RLY7'), findsOneWidget);
  });

  testWidgets('what the sender says they are also known as is shown (6.3.3)',
      (tester) async {
    const npub =
        'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f';
    final people = XprsPeople.instance..debugReset();
    addTearDown(people.debugReset);
    people.claim(npub, XprsIdType.callsign, 'X1PEER',
        evidence: XprsIdEvidence.derived);
    people.stated(npub, 'email', 'peer@example.org', tsMs: 1700000000000);
    people.stated(npub, 'meshtastic', 'MTA1B2C3D4', tsMs: 1700000000000);
    // Something this device only observed is not a thing they said.
    people.note(npub, XprsIdType.ble, 'A4:CF:12:0B:7E:31',
        evidence: XprsIdEvidence.observed);

    await pumpChat(tester, bubble(), asked: []);
    await tester.tap(find.text('X1PEER').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    MessageInfoBus.publish({
      'type': 'ui.convo.info',
      'id': 'X1PEER',
      'mid': 'aa1111',
      'stored': {
        'row': {'mid': 'aa1111', 'dir': 'in', 'sender': 'X1PEER', 'ts': 1700000000},
        'versions': const [],
      },
      'packet': const {'bearer': 'ble'},
    });
    await tester.pumpAndSettle();
    final page = find
        .descendant(
            of: find.byType(MessageInfoPage), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('peer@example.org'), 200,
        scrollable: page);
    expect(find.text('E-mail address'), findsOneWidget);
    expect(find.text('MTA1B2C3D4'), findsOneWidget);
    expect(find.text('A4:CF:12:0B:7E:31'), findsNothing);
  });

  testWidgets('an issued callsign claimed by two keys says so beside the '
      'signature (6.4.2)', (tester) async {
    final people = XprsPeople.instance..debugReset();
    addTearDown(people.debugReset);
    people.claim('npub1aaa', XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    people.claim('npub1bbb', XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    final m = bubble()..['from'] = 'CT1ABC';
    await pumpChat(tester, m, asked: []);
    await tester.tap(find.text('CT1ABC').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    MessageInfoBus.publish({
      'type': 'ui.convo.info',
      'id': 'CT1ABC',
      'mid': 'aa1111',
      'stored': {
        'row': {'mid': 'aa1111', 'dir': 'in', 'sender': 'CT1ABC', 'ts': 1700000000},
        'versions': const [],
      },
      'packet': const {'bearer': 'ble', 'sig': 'verified'},
      'signed': true,
    });
    await tester.pumpAndSettle();
    final page = find
        .descendant(
            of: find.byType(MessageInfoPage), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
        find.textContaining('Claimed by more than one key'), 200,
        scrollable: page);
    expect(find.textContaining('Claimed by more than one key'), findsOneWidget);
  });

  testWidgets('details for another message are not shown', (tester) async {
    MessageInfoBus.publish({'mid': 'zz9999', 'relays': 'X3OTHER'});
    await tester.pumpWidget(
        MaterialApp(home: MessageInfoPage(message: bubble())));
    await tester.pump();
    expect(find.text('X3OTHER'), findsNothing);
  });

  testWidgets('one of ours waiting for a key can be sent unsealed',
      (tester) async {
    final plain = <Map<String, dynamic>>[];
    await pumpChat(tester, bubble(status: 'key', dir: 'out'), plain: plain);
    await tester.longPress(find.text('the better words'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send now, unsealed'));
    await tester.pumpAndSettle();
    expect(plain.single['mid'], 'aa1111');
  });
}
