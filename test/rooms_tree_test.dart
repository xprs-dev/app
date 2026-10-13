// The rail draws a folder (XPRS.md 10.2) under the group that lists it,
// whatever order recency would put them in. roomsTreeByRank is that
// order, pure, so it is a table rather than a screenshot.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/rooms_field.dart';

List<String> _ids(List<Map<String, dynamic>> rows) =>
    [for (final r in rows) '${r['id']}'];

void main() {
  int rankOf(Map<String, dynamic> r) => (r['seen'] as int?) ?? 0;

  test('roots by recency, each folder right under its group', () {
    final rows = <Map<String, dynamic>>[
      {'id': '#LOCAL', 'seen': 50},
      {'id': '#X5GULF', 'seen': 10},
      {'id': '#X5FIX', 'parent': '#X5GULF', 'seen': 90},
      {'id': 'X1ANNA', 'seen': 70},
      {'id': '#X5NEWS', 'parent': '#X5GULF', 'seen': 20},
    ];
    // The busiest folder lifts its group to the top; its siblings follow it
    // in their own order, and nothing else lands between them.
    expect(_ids(roomsTreeByRank(rows, rankOf)),
        ['#X5GULF', '#X5FIX', '#X5NEWS', 'X1ANNA', '#LOCAL']);
  });

  test('a folder whose group is not on the list is a root', () {
    final rows = <Map<String, dynamic>>[
      {'id': '#X5FIX', 'parent': '#X5GONE', 'seen': 5},
      {'id': '#LOCAL', 'seen': 9},
    ];
    expect(_ids(roomsTreeByRank(rows, rankOf)), ['#LOCAL', '#X5FIX']);
  });

  test('two levels, and a cycle is still drawn, flat', () {
    final tree = <Map<String, dynamic>>[
      {'id': '#X5A', 'seen': 1},
      {'id': '#X5B', 'parent': '#X5A', 'seen': 2},
      {'id': '#X5C', 'parent': '#X5B', 'seen': 3},
    ];
    expect(_ids(roomsTreeByRank(tree, rankOf)), ['#X5A', '#X5B', '#X5C']);
    final loop = <Map<String, dynamic>>[
      {'id': '#X5P', 'parent': '#X5Q', 'seen': 1},
      {'id': '#X5Q', 'parent': '#X5P', 'seen': 2},
    ];
    expect(roomsTreeByRank(loop, rankOf), hasLength(2));
  });
}
