// The Info page's "Where it is kept": the stations that said they keep a
// message, the archivers it was handed to, the reader's own mailboxes; and
// for a message that arrived, who handed it over.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/message_info_page.dart';

void main() {
  test('one we sent: confirmed first, then handed, then their mailboxes', () {
    expect(
        messageKeptRows(
          outgoing: true,
          kept: {'X3PTZM': 'handed', 'X3SQS6': 'held', 'X3AAAA': 'held'},
          holders: ['x3vgaz', ' ', 'X3PTZM'],
        ),
        [
          ('geoui.info.kept.held', 'X3AAAA, X3SQS6'),
          ('geoui.info.kept.handed', 'X3PTZM'),
          ('geoui.info.kept.theirs', 'X3VGAZ, X3PTZM'),
        ]);
  });

  test('nothing known is no rows, so the page says so in words', () {
    expect(messageKeptRows(outgoing: true), isEmpty);
    expect(messageKeptRows(outgoing: false), isEmpty);
  });

  test('one that arrived: the station that handed it over', () {
    expect(
        messageKeptRows(
            outgoing: false,
            kept: {'X3SQS6': 'held'},
            relays: ['X3FIRST', 'X3LAST']),
        [('geoui.info.kept.from', 'X3LAST')]);
  });
}
