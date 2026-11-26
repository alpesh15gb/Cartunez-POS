// Runs against an isolated seeded API. Supply --dart-define=API=... for that fixture.
import 'dart:io';

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<void> waitFor(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 160 && target.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(target, findsOneWidget);
}

void main() {
  testWidgets('scan twice, post one cash invoice, return stock, reconcile margin and tenders', (tester) async {
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(697, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-checkout');
    final state = AppState();
    final code = 'FLOW-${uuid()}';
    late Json part;
    late Map cashBefore;
    Future<Map> cashReport() async {
      final report = await state.api('/reports/tenders');
      return (report['rows'] as List).singleWhere((row) => row['type'] == 'Cash') as Map;
    }
    await tester.runAsync(() async {
      await state.init();
      const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4193/api/v1');
      if (!Uri.parse(api).isLoopbackHost) throw StateError('Use the isolated local test API.');
      await state.login(api: api, email: 'owner@motorline.local', password: 'MotorlineDemo123!',
          organizationId: 'demo', branchId: 'pune');
      await state.mutate('/settings', {'taxScheme': 'none'});
      if (state.openShift == null) await state.mutate('/shifts/open', {'openingCash': 10000});
      part = await state.mutate('/products', {'sku': code, 'name': 'Counter test filter', 'brand': 'Fixture',
        'category': 'Flow test', 'unit': 'Each', 'barcodes': [code], 'cost': 12500, 'retailPrice': 25000, 'taxRate': 0});
      await state.mutate('/inventory/adjust', {'productId': part['id'], 'binId': 'bin-a1',
        'quantity': 4, 'reason': 'Opening test stock'});
      expect(state.available(part['id']), 4);
      cashBefore = await cashReport();
    });
    await tester.pumpWidget(CartunezApp(state: state));
    await tester.pumpAndSettle();
    for (var count = 1; count <= 2; count++) {
      await tester.tap(find.byTooltip('Scan barcode'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Barcode'), code);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect((state.cart['lines'] as List).single['qty'], count);
    }
    await tester.tap(find.byKey(const ValueKey('cart-pill')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Increase quantity'), findsOneWidget);
    await tester.tap(find.text('Exact cash'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Amount received'), '600');
    await tester.runAsync(() => tester.tap(find.text('Complete sale')));
    await waitFor(tester, find.text('Sale complete'));
    for (var attempt = 0; attempt < 160 && state.syncing; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(state.syncing, isFalse);
    expect(find.text('Give change ${state.money(10000)}'), findsOneWidget);
    await tester.tap(find.text('View receipt'));
    await tester.pumpAndSettle();
    expect(find.text('INVOICE'), findsOneWidget);
    expect(find.text('Counter test filter'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Current sale'), findsNothing);
    expect(find.byTooltip('Scan barcode'), findsOneWidget);
    expect(state.cart['lines'], isEmpty);
    late Json invoice;
    await tester.runAsync(() async {
      await state.sync();
      invoice = state.list('invoices').singleWhere((r) => (r['lines'] as List).any((line) => line['productId'] == part['id']));
      expect(invoice['total'], 50000);
      expect(invoice['change'], 10000);
      expect(invoice['lines'][0]['qty'], 2);
      expect(state.available(part['id']), 2);
      final cash = await cashReport();
      expect(cash['collected'], (cashBefore['collected'] as int) + 50000);
      expect(cash['refunded'], cashBefore['refunded']);
      final margin = await state.api('/reports/margin?sku=$code');
      expect(margin['totals']['margin'], 25000);
    });

    GoRouter.of(rootNavigatorKey.currentContext!).go('/orders/returns');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Invoice number, receipt barcode, phone or serial'), '${invoice['number']}');
    await tester.runAsync(() => tester.tap(find.text('Find bill')));
    final returnItems = find.text('Return items');
    await waitFor(tester, returnItems);
    await tester.ensureVisible(returnItems);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(returnItems));
    await tester.pumpAndSettle();
    final more = find.byTooltip('More of Counter test filter');
    await tester.tap(more);
    await tester.pump();
    await tester.tap(more);
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    final reason = find.widgetWithText(TextField, 'Reason');
    await tester.ensureVisible(reason);
    await tester.enterText(reason, 'Test return');
    final record = find.text('Record return');
    await tester.ensureVisible(record);
    await tester.runAsync(() => tester.tap(record));
    await waitFor(tester, find.text('CREDIT NOTE'));
    await tester.tap(find.text('Done'));
    await waitFor(tester, find.text('Returned'));
    expect(find.text('Return items'), findsNothing);

    await tester.runAsync(() async {
      await state.sync();
      final credit = state.list('returns').singleWhere((r) => r['invoiceId'] == invoice['id']);
      expect(credit['total'], 50000);
      expect(state.available(part['id']), 4);
      final margin = await state.api('/reports/margin?sku=$code');
      expect(margin['totals']['margin'], 0);
      expect(margin['rows'].length, 2);
      final cash = await cashReport();
      expect(cash['collected'], (cashBefore['collected'] as int) + 50000);
      expect(cash['refunded'], (cashBefore['refunded'] as int) + 50000);
      expect(cash['net'], cashBefore['net']);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(state.logout);
    state.dispose();
  });
}

extension on Uri {
  bool get isLoopbackHost => const ['localhost', '127.0.0.1', '::1'].contains(host);
}
