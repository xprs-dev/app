// A link to a chat group opens the chat on that group: the forms the web
// chat's Share link writes, and their xprs:// twins.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/deep_link_service.dart';

void main() {
  String? room(String u) => DeepLinkService.groupRoomOfLink(u);

  test('a group with a callsign: xprs.dev/in/<x5>', () {
    expect(room('https://xprs.dev/in/x5abcd'), '#X5ABCD');
    expect(room('https://xprs.dev/in/X5ABCD/'), '#X5ABCD');
    expect(room('http://xprs.dev/in/x5nksf'), '#X5NKSF');
    expect(room('xprs://in/x5abcd'), '#X5ABCD');
  });

  test('an open group by name: xprs.dev/in/g/<name>', () {
    expect(room('https://xprs.dev/in/g/lisboa'), '#LISBOA');
    expect(room('https://xprs.dev/in/g/field-day_2'), '#FIELD-DAY_2');
    expect(room('xprs://in/g/lisboa'), '#LISBOA');
  });

  test('a station\'s page is for a browser, not a group', () {
    expect(room('https://xprs.dev/in/x3ptzm'), isNull);
    expect(room('https://xprs.dev/in/ct1abc'), isNull);
    expect(room('https://xprs.dev/in/'), isNull);
  });

  test('anything else is not a group link', () {
    expect(room('https://xprs.dev/circle/abc'), isNull);
    expect(room('https://example.org/in/x5abcd'), isNull);
    expect(room('xprs://open?wapp=chat'), isNull);
    expect(room('https://xprs.dev/in/g/'), isNull);
    expect(room('https://xprs.dev/in/g/${'a' * 40}'), isNull);
    expect(room('https://xprs.dev/in/g/a b'), isNull);
    expect(room('https://xprs.dev/in/x5abcd/extra'), isNull);
    expect(room('not a link'), isNull);
  });
}
