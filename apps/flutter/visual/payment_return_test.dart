// Run with --dart-define=API=http://127.0.0.1:<port>/api/v1 against an isolated demo API.
import 'dart:io';

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/tender_sheet.dart';
import 'package:cartunez_pos/ui/counter/upi_qr.dart';
import 'package:cartunez_pos/ui/orders/returns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitFor(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 160 && target.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(target, findsOneWidget);
}

void main() {
  testWidgets('corrected QR amount posts once and a full return reconciles stock and split tenders', (tester) async {
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-payment-return');
    final app = AppState();
    late Json part;
    late Json invoice;
    const url = String.fromEnvironment('API');
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(Uri.parse(url).host)) {
      throw StateError('Use a loopback demo API.');
    }
    await tester.runAsync(() async {
      await app.init();
      await app.login(api: url, email: 'owner@motorline.local', password: 'MotorlineDemo123!',
        organizationId: 'demo', branchId: 'pune');
      await app.mutate('/settings', {'upiVpa': 'cartunez-test@upi', 'upiPayeeName': 'Cartunez Test'});
      if (app.openShift == null) await app.mutate('/shifts/open', {'openingCash': 0});
      part = await app.mutate('/products', {
        'sku': 'QR-FLOW-${uuid()}', 'name': 'Checkout test filter', 'brand': 'Fixture',
        'category': 'Checkout test', 'unit': 'Each', 'retailPrice': 1000, 'cost': 400,
        'taxRate': 0, 'hsnSac': '8421',
      });
      await app.mutate('/inventory/adjust', {'productId': part['id'], 'binId': 'bin-a1',
        'quantity': 1, 'reason': 'Isolated checkout fixture'});
      app.updateCart({'lines': [{'productId': part['id'], 'binId': 'bin-a1', 'qty': 1}]});
      expect(app.currentQuote().total, 1000);
    });
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) {
      return Scaffold(body: Column(children: [
        TextButton(onPressed: () async {
          final result = await showDialog<Json>(context: context, builder: (_) =>
            AppScope(state: app, child: const CheckoutDialog(total: 1000, initialTender: 'UPI')));
          if (result != null) invoice = result;
        }, child: const Text('Test checkout')),
        TextButton(onPressed: () => startReturnForInvoice(context, invoice), child: const Text('Test return')),
      ]));
    }))));
    await tester.tap(find.text('Test checkout'));
    await tester.pumpAndSettle();

    final qr = find.byKey(const ValueKey('show-upi-qr'));
    Future<void> confirmQr(String expected, String reference) async {
      await tester.ensureVisible(qr);
      await tester.tap(qr);
      await tester.pumpAndSettle();
      final painter = tester.widget<CustomPaint>(find.byKey(const ValueKey('upi-qr'))).painter! as QrPainter;
      final uri = Uri.parse(painter.data);
      expect(uri.scheme, 'upi');
      expect(uri.queryParameters, containsPair('pa', 'cartunez-test@upi'));
      expect(uri.queryParameters, containsPair('am', expected));
      expect(uri.queryParameters, containsPair('cu', 'INR'));
      await tester.enterText(find.byType(TextField), reference);
      await tester.ensureVisible(find.text('Confirm received'));
      await tester.tap(find.text('Confirm received'));
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.widgetWithText(TextField, 'Amount received'), '3');
    await tester.ensureVisible(find.text('Split payment'));
    await tester.tap(find.text('Split payment'));
    await tester.pumpAndSettle();
    await confirmQr('3.00', 'QA-FIRST-300');
    await tester.enterText(find.widgetWithText(TextField, 'UPI amount'), '4');
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '6');
    await tester.pumpAndSettle();
    expect(find.text('Save pending payment'), findsOneWidget);
    expect(find.text('QA-FIRST-300'), findsNothing);
    await confirmQr('4.00', 'QA-CORRECT-400');
    await tester.runAsync(() => tester.tap(find.text('Complete sale')));
    await waitFor(tester, find.text('Test return').hitTestable());
    final tenders = (invoice['tenders'] as List).cast<Map>();
    expect(tenders.map((t) => [t['type'], t['amount'], t['reference']]), containsAll([
      ['UPI', 400, 'QA-CORRECT-400'], ['Cash', 600, ''],
    ]));
    await tester.runAsync(app.sync);
    expect(app.available(part['id']), 0);

    await tester.runAsync(() => tester.tap(find.text('Test return')));
    await waitFor(tester, find.text('Return from ${invoice['number']}'));
    await tester.tap(find.byTooltip('More of Checkout test filter'));
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'End-to-end return');
    await tester.runAsync(() => tester.tap(find.text('Record return')));
    await waitFor(tester, find.text('CREDIT NOTE'));

    await tester.runAsync(() async {
      await app.sync();
      final saved = app.list('returns').singleWhere((r) => r['invoiceId'] == invoice['id']);
      expect(saved['refundTotal'], 1000);
      final refunds = (saved['refunds'] as List).cast<Map>();
      expect(refunds.map((r) => [r['type'], r['amount']]), unorderedEquals([['UPI', 400], ['Cash', 600]]));
      expect(app.available(part['id']), 1);
      final margin = await app.api('/reports/margin?sku=${part['sku']}');
      expect(margin['totals']['margin'], 0);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(app.logout);
    app.dispose();
  });
}
