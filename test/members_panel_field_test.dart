// The reusable members panel ($type:"members"): a full-size list that the wapp
// answers a page at a time, so a group of hundreds costs the rows on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/members_panel_field.dart';

void main() {
  Map<String, dynamic> page(int from, int n, int total) => {
        'title': 'Embaixada',
        'subtitle': '$total members',
        'total': total,
        'actions': [
          {'id': 'inv', 'label': 'Invite', 'icon': 'person_add', 'primary': true},
          {'id': 'fold', 'label': 'New folder', 'icon': 'create_new_folder'},
        ],
        'filters': [
          {'id': '', 'label': 'All', 'count': total},
          {'id': 'admin', 'label': 'Admins', 'count': 1},
        ],
        'rows': [
          for (var i = from; i < from + n; i++)
            {'id': 'go:X1M$i', 'title': 'X1M$i', 'subtitle': 'member'},
        ],
      };

  Future<void> pump(
    WidgetTester tester,
    Map<String, dynamic> data, {
    String query = '',
    List<String>? log,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MembersPanelField(
          fieldName: 'members',
          data: data,
          query: query,
          filter: '',
          onSearch: (q) => log?.add('search:$q'),
          onFilter: (f) => log?.add('filter:$f'),
          onMore: (o) => log?.add('more:$o'),
          onTap: (id) => log?.add('tap:$id'),
          onAction: (id) => log?.add('action:$id'),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the header, the action buttons and the rows draw', (tester) async {
    await pump(tester, page(0, 3, 3));
    expect(find.text('Embaixada'), findsOneWidget);
    expect(find.text('3 members'), findsOneWidget);
    expect(find.text('Invite'), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('X1M0'), findsOneWidget);
    expect(find.text('All 3'), findsOneWidget);
  });

  testWidgets('a button, a row and a chip report what was tapped', (tester) async {
    final log = <String>[];
    await pump(tester, page(0, 3, 3), log: log);
    await tester.tap(find.text('Invite'));
    await tester.tap(find.text('X1M1'));
    await tester.tap(find.text('Admins 1'));
    expect(log, ['action:inv', 'tap:go:X1M1', 'filter:admin']);
  });

  testWidgets('search is sent to the wapp after a pause, not on every key',
      (tester) async {
    final log = <String>[];
    await pump(tester, page(0, 3, 3), log: log);
    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'bob');
    expect(log, isEmpty);
    await tester.pump(const Duration(milliseconds: 350));
    expect(log, ['search:bob']);
  });

  testWidgets('a big roster builds only the rows in view and asks for more once',
      (tester) async {
    final log = <String>[];
    await pump(tester, page(0, 40, 600), log: log);
    // 600 members total, 40 held: far fewer rows than that are built.
    expect(find.byType(ListTile).evaluate().length, lessThan(40));
    await tester.drag(find.byType(ListView).last, const Offset(0, -20000));
    await tester.pump();
    await tester.pump();
    expect(log.where((e) => e == 'more:40').length, 1);
    // Rebuilding while the page is in flight does not ask again.
    await tester.pump();
    expect(log.where((e) => e == 'more:40').length, 1);
  });

  testWidgets('an empty query says nobody yet; a query says nobody matches',
      (tester) async {
    await pump(tester, {'rows': [], 'total': 0}, query: '');
    expect(find.text('Nobody yet.'), findsOneWidget);
    await pump(tester, {'rows': [], 'total': 0}, query: 'zz');
    expect(find.text('Nobody matches "zz".'), findsOneWidget);
  });
}
