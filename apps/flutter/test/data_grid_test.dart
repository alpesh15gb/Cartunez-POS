// WS-F: data grid sorting, paging, search, column visibility and keyboard use.
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/ui/widgets/data_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _columns = [
  GridColumn('sku', 'SKU'),
  GridColumn('category', 'Category'),
  GridColumn('qty', 'Qty', numeric: true),
];

List<Json> _rows(int n) => [
      for (var i = 0; i < n; i++) {'sku': 'P${(i + 1).toString().padLeft(2, '0')}', 'category': i.isEven ? 'Oil' : 'Brake', 'qty': (i * 7) % 10},
    ];

Widget _host(Widget child, {double width = 900}) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: width, child: SingleChildScrollView(child: child)))),
    );

List<String> _visibleSkus(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').where((s) => RegExp(r'^P\d\d$').hasMatch(s)).toList();

void main() {
  test('multi-column sort is stable and keeps blanks last', () {
    final rows = <Json>[
      {'c': 'b', 'n': 2}, {'c': 'a', 'n': 3}, {'c': 'b', 'n': 1}, {'c': null, 'n': 0}, {'c': 'a', 'n': 1},
    ];
    final sorted = sortRows(rows, const [GridSort('c', false), GridSort('n', true)], const []);
    expect(sorted.map((r) => '${r['c']}${r['n']}').toList(), ['b1', 'b2', 'a1', 'a3', 'null0']);
  });

  testWidgets('client paging, header sort, shift-click secondary sort and search', (tester) async {
    await tester.pumpWidget(_host(DataGrid(rows: _rows(30), columns: _columns, pageSize: 10)));
    expect(find.text('1–10 of 30'), findsOneWidget);
    expect(_visibleSkus(tester).first, 'P01');
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    expect(find.text('11–20 of 30'), findsOneWidget);
    expect(_visibleSkus(tester).first, 'P11');

    // Sort by quantity descending (two clicks) goes back to page one.
    await tester.tap(find.text('Qty'));
    await tester.pump();
    await tester.tap(find.text('Qty'));
    await tester.pump();
    expect(find.text('1–10 of 30'), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-qty')), findsOneWidget);
    final grid = tester.state<DataGridState>(find.byType(DataGrid));
    expect(grid.filtered.first['qty'], 9);

    // Category first, then quantity: shift-click adds a sort key.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Category'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(grid.sorts.map((s) => s.key), ['qty', 'category']);
    grid.toggleSort('category', add: true); // now descending
    grid.toggleSort('qty'); // plain click on a descending column: sort off
    expect(grid.sorts, isEmpty);
    grid.toggleSort('qty'); // and again: quantity only, ascending
    await tester.pump();
    expect(grid.sorts.map((s) => '${s.key}${s.ascending}'), ['qtytrue']);

    await tester.enterText(find.byType(TextField), 'p0');
    await tester.pump();
    expect(find.text('1–9 of 9'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No rows match "zzz".'), findsOneWidget);
  });

  testWidgets('server paging asks for the next page and keyboard opens the selected row', (tester) async {
    final pages = <int>[];
    final opened = <String>[];
    await tester.pumpWidget(_host(DataGrid(rows: _rows(10), columns: _columns, pageSize: 10, totalRows: 95, page: 2,
        onPage: pages.add, onRowTap: (r) => opened.add('${r['sku']}'))));
    expect(find.text('21–30 of 95'), findsOneWidget);
    await tester.tap(find.byTooltip('Next page'));
    expect(pages, [3]);
    await tester.tap(find.text('P01'));
    expect(opened, ['P01']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, ['P01', 'P03']);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    expect(pages, [3, 1]);
  });

  testWidgets('columns can be hidden, and narrow screens scroll sideways', (tester) async {
    await tester.pumpWidget(_host(DataGrid(rows: _rows(3), columns: const [..._columns, GridColumn('note', 'Note', visible: false)]),
        width: 360));
    expect(find.text('Note'), findsNothing);
    expect(find.text('Columns (1 hidden)'), findsOneWidget);
    await tester.tap(find.text('Columns (1 hidden)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Category'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Note'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Category'), findsNothing);
    expect(find.text('Note'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
