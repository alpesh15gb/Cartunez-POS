// Runs against an isolated seeded API. Supply --dart-define=API=... for that fixture.
import 'dart:io';

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scan twice, post one cash invoice, return stock, reconcile margin and tenders', (tester) async {
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-checkout');
    final state = AppState();
    final code = 'FLOW-${uuid()}';
    late Json part;
    await tester.runAsync(() async {
      await state.init();
      const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4193/api/v1');
      if (!Uri.parse(api).isLoopbackHost) throw StateError('Use the isolated local test API.');
      await state.login(api: api, email: 'owner@motorline.local', password: 'MotorlineDemo123!',
          organizationId: 'demo', branchId: 'pune');
      if (state.openShift == null) await state.mutate('/shifts/open', {'openingCash': 10000});
      part = await state.mutate('/products', {'sku': code, 'name': 'Counter test filter', 'brand': 'Fixture',
        'category': 'Flow test', 'unit': 'Each', 'barcodes': [code], 'cost': 12500, 'retailPrice': 25000, 'taxRate': 0});
      await state.mutate('/inventory/adjust', {'productId': part['id'], 'binId': 'bin-a1',
        'quantity': 4, 'reason': 'Opening test stock'});
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
    await tester.tap(find.text('Checkout  (F6)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Amount received'), '600');
    await tester.runAsync(() => tester.tap(find.text('Complete sale')));
    // Socket and filesystem completion run outside the widget-test fake clock.
    for (var i = 0; i < 100 && find.text('SALES RECEIPT').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('SALES RECEIPT'), findsOneWidget);
    for (var i = 0; i < 100 && state.syncing; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(state.syncing, isFalse);
    await tester.runAsync(() async {
      await state.sync();
      final invoice = state.list('invoices').singleWhere((r) => r['lines'][0]['productId'] == part['id']);
      expect(invoice['total'], 50000);
      expect(invoice['change'], 10000);
      expect(state.available(part['id']), 2);
      final credit = await state.mutate('/invoices/${invoice['id']}/returns', {'reason': 'Test return',
        'condition': 'sellable', 'refundType': 'Cash', 'lines': [
          {'lineId': invoice['lines'][0]['id'], 'quantity': 2, 'binId': 'bin-a1'}
        ]});
      expect(credit['total'], 50000);
      expect(state.available(part['id']), 4);
      final margin = await state.api('/reports/margin?sku=$code');
      expect(margin['totals']['margin'], 0);
      expect(margin['rows'].length, 2);
      final tenders = await state.api('/reports/tenders');
      final cash = (tenders['rows'] as List).singleWhere((row) => row['type'] == 'Cash');
      expect(cash['net'], cash['collected'] - cash['refunded']);
      await state.logout();
    });
    await tester.pumpAndSettle();
    state.dispose();
  });
}

extension on Uri {
  bool get isLoopbackHost => const ['localhost', '127.0.0.1', '::1'].contains(host);
}
