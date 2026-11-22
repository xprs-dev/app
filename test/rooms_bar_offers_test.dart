// The menu of the open room on a narrow screen (the three lines in the bar):
// what it offers is read from what the wapp states on the room's rail entry.
// Found on the phone, 2026-11-22: an open group offered "Group info", which
// opened nothing, and had no "Share link".
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/rooms_field.dart';

void main() {
  const rows = <Map<String, dynamic>>[
    {'id': '#X5TOWN', 'share': true, 'page': true},
    {'id': '#LISBOA', 'share': true, 'page': false},
    {'id': '#LOCAL', 'page': false},
    {'id': '#OLD'},
  ];

  test('a closed group: its page, its link, the bell', () {
    expect(roomsBarOffers(rows, '#X5TOWN', open: true),
        ['members', 'share', 'notify']);
  });

  test('an open group has no page to open, and has a link', () {
    expect(roomsBarOffers(rows, '#LISBOA', open: true), ['share', 'notify']);
  });

  test('a room by range has neither', () {
    expect(roomsBarOffers(rows, '#LOCAL', open: true), ['notify']);
  });

  test('a wapp that does not say is taken to have a page, as before', () {
    expect(roomsBarOffers(rows, '#OLD', open: true), ['members', 'notify']);
  });

  test('a folder where one may be made; no bell on a group being browsed', () {
    expect(roomsBarOffers(rows, '#X5TOWN', open: false, canFolder: true),
        ['members', 'share', 'new']);
  });

  test('nothing to offer: no menu', () {
    expect(roomsBarOffers(rows, '#LOCAL', open: false), isEmpty);
  });
}
