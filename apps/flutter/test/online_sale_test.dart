// On sale: the Online store screen's sale chip, filter and bulk actions at phone width.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/online.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Shop extends AppState {
  final calls = <(String, Json)>[];

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => {};

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    calls.add((path, body));
    return [];
  }
}

_Shop _shop() => _Shop()
  ..ready = true
  ..session = Session(
    api: 'https://pos.example.test/api/v1',
    token: 't',
    user: {'id': 'u1', 'name': 'Asha', 'role': 'owner'},
    branchId: 'main',
    organizationId: 'org',
    expiresAt: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
  )
  ..snapshot = {
    'settings': {'taxMode': 'inclusive'},
    'products': [
      {'id': 'filter', 'name': 'Oil Filter', 'sku': 'ML-FILTER-01', 'retailPrice': 30000},
      {'id': 'wiper', 'name': 'Wiper Blade', 'sku': 'ML-WIPER-01', 'retailPrice': 50000},
      {'id': 'spark', 'name': 'Spark Plug', 'sku': 'ML-SPARK-01', 'retailPrice': 20000},
    ],
    'onlineListings': [
      {'productId': 'filter', 'published': true, 'onSale': true, 'saleUntil': '2099-12-31', 'pricing': {'mode': 'percent', 'percent': 1000}},
      {'productId': 'wiper', 'published': true, 'pricing': {'mode': 'mrp'}},
      {'productId': 'spark', 'published': true, 'onSale': true, 'saleUntil': '2020-01-01', 'pricing': {'mode': 'percent', 'percent': 500}},
    ],
  };

void main() {
  test('sale state follows the India date', () {
    expect(indiaToday(DateTime.utc(2026, 3, 31, 19)), '2026-04-01');
    expect(saleState({'onSale': true, 'saleUntil': '2026-03-31'}, DateTime.utc(2026, 3, 31, 18)), 'on');
    expect(saleState({'onSale': true, 'saleUntil': '2026-03-31'}, DateTime.utc(2026, 3, 31, 19)), 'ended');
    expect(saleState({'onSale': true}), 'on');
    expect(saleState({'onSale': false}), isNull);
  });

  testWidgets('on sale chip, filter and bulk sale actions at phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _shop();
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(
        home: ShellScope(
          controller: ShellController(),
          child: Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: const [OnlineStoreScreen()])),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('On sale to 31/12/2099'), findsOneWidget);
    expect(find.text('Sale ended'), findsOneWidget);

    // The On sale filter keeps only parts marked on sale.
    await tester.tap(find.widgetWithText(ChoiceChip, 'On sale'));
    await tester.pumpAndSettle();
    expect(find.text('Oil Filter'), findsOneWidget);
    expect(find.text('Spark Plug'), findsOneWidget);
    expect(find.text('Wiper Blade'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All parts'));
    await tester.pumpAndSettle();

    // Put the wiper (sold at MRP) on sale: the dialog warns that no discount will show.
    final wiper = find.descendant(of: find.widgetWithText(Card, 'Wiper Blade'), matching: find.byType(Checkbox));
    await tester.ensureVisible(wiper);
    await tester.pumpAndSettle();
    await tester.tap(wiper);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Put on sale…'));
    await tester.tap(find.text('Put on sale…'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sale-no-discount')), findsOneWidget);
    expect(find.textContaining('ML-WIPER-01 sells at MRP'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sale ends on (YYYY-MM-DD)'), '2020-01-01');
    await tester.tap(find.widgetWithText(FilledButton, 'Put on sale'));
    await tester.pumpAndSettle();
    expect(find.text('The end date cannot be in the past.'), findsOneWidget);
    expect(app.calls, isEmpty);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sale ends on (YYYY-MM-DD)'), '2099-06-30');
    await tester.tap(find.widgetWithText(FilledButton, 'Put on sale'));
    await tester.pumpAndSettle();
    expect(app.calls.single.$1, '/online-listings');
    expect(app.calls.single.$2['productIds'], ['wiper']);
    expect(app.calls.single.$2['changes'], {'onSale': true, 'saleUntil': '2099-06-30'});

    await tester.ensureVisible(find.text('Remove from sale'));
    await tester.tap(find.text('Remove from sale'));
    await tester.pumpAndSettle();
    expect(app.calls.last.$2['changes'], {'onSale': false});
    expect(tester.takeException(), isNull);
  });

  testWidgets('one part: the edit dialog puts it on sale and takes it off', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _shop();
    late BuildContext ctx;
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      })),
    ));
    final wiper = app.products.firstWhere((p) => p['id'] == 'wiper');

    // Put the wiper on sale with an end date.
    editListing(ctx, wiper);
    await tester.pumpAndSettle();
    expect(find.text('On sale (home page & Sale menu)'), findsOneWidget);
    await tester.tap(find.text('No').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, show in the sale').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Sale ends on (YYYY-MM-DD)'), '2099-06-30');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final changes = app.calls.last.$2['changes'] as Map;
    expect(changes['onSale'], true);
    expect(changes['saleUntil'], '2099-06-30');
    expect(app.calls.last.$2['productIds'], ['wiper']);

    // The filter part (already on sale) is taken off sale.
    final filter = app.products.firstWhere((p) => p['id'] == 'filter');
    editListing(ctx, filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, show in the sale').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('No').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final off = app.calls.last.$2['changes'] as Map;
    expect(off['onSale'], false);
    expect(off.containsKey('saleUntil'), false);
    expect(tester.takeException(), isNull);
  });
}
