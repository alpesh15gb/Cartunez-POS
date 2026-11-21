// "Not GST registered": final prices, no tax lines, no GSTIN or HSN on the bill.
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppState _app() => AppState()
  ..snapshot = {
    'settings': {'currency': 'INR', 'taxScheme': 'none', 'tenderTypes': ['Cash']},
    'business': {'legalName': 'Cartunez', 'address': 'Pune', 'taxRegistrationId': '27ABCDE1234F1Z5'},
    'products': [
      {'id': 'oil', 'name': 'Engine oil', 'sku': 'OIL', 'retailPrice': 10000, 'wholesalePrice': 9000, 'taxRate': 1800, 'coreCharge': 0},
    ],
  };

// An invoice as the API issues it for a shop that is not GST registered.
final Json _invoice = {
  'id': 'inv-1',
  'number': 'INV-PUNE-1',
  'taxScheme': 'none',
  'taxMode': 'exclusive',
  'taxDisplayName': 'Tax',
  'currency': 'INR',
  'createdAt': '2026-11-20T10:00:00Z',
  // Older or hand-made documents may still hold a GSTIN; it must not print.
  'business': {'legalName': 'Cartunez', 'address': 'Pune', 'taxRegistrationId': '27ABCDE1234F1Z5'},
  'subtotal': 20000,
  'discount': 0,
  'tax': 0,
  'taxComponents': [],
  'total': 20000,
  'tenders': [{'type': 'Cash', 'amount': 20000}],
  'change': 0,
  'lines': [
    {'id': 'l1', 'productId': 'oil', 'name': 'Engine oil', 'qty': 2, 'unit': 'Each', 'unitPrice': 10000, 'subtotal': 20000,
      'discount': 0, 'tax': 0, 'taxRate': 0, 'hsnSac': '27101980', 'taxComponents': [], 'total': 20000},
  ],
};

void main() {
  test('checkout adds no tax when the shop is not GST registered', () {
    final products = (_app().snapshot['products'] as List).cast<Json>();
    final cart = {'lines': [{'productId': 'oil', 'qty': 2}], 'discount': 0};
    final taxed = quote(cart, products);
    expect(taxed.tax, 3600);
    final bill = quote(cart, products, noTax: true);
    expect(bill.tax, 0);
    expect(bill.total, 20000);
    expect(bill.lines.single.tax, 0);
  });

  test('the receipt is titled Invoice with no GST words', () {
    final app = _app();
    expect(app.noTax, isTrue);
    final r = ReceiptView(app, _invoice);
    expect(r.kind, 'INVOICE');
    expect(r.header.join(' '), isNot(contains('GSTIN')));
    expect(r.totals.map((t) => t.$1), isNot(contains('Tax')));
    final summary = receiptSummary(app, _invoice);
    for (final word in ['GST', 'GSTIN', 'CGST', 'SGST', 'IGST', 'HSN', 'TAX INVOICE', '27ABCDE1234F1Z5']) {
      expect(summary, isNot(contains(word)), reason: word);
    }
    expect(summary, contains('Total: '));
  });

  testWidgets('the receipt dialog shows no tax breakdown, GSTIN or HSN', (tester) async {
    final app = _app();
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => showReceipt(context, _invoice), child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('INVOICE'), findsOneWidget);
    expect(find.textContaining('GST'), findsNothing);
    expect(find.textContaining('HSN'), findsNothing);
    expect(find.textContaining('tax'), findsNothing);
    expect(find.text('Tax'), findsNothing);
  });

  test('credit notes for a not-registered bill carry no tax line either', () {
    final credit = {..._invoice, 'invoiceId': 'inv-1', 'invoiceNumber': 'INV-PUNE-1', 'reason': 'Returned'};
    final r = ReceiptView(_app(), credit);
    expect(r.kind, 'CREDIT NOTE');
    expect(r.totals.map((t) => t.$1).where((l) => l.contains('Tax')), isEmpty);
  });

  test('a receipt PDF builds for a not-registered bill', () async {
    final bytes = await buildReceiptPdf(_app(), _invoice);
    expect(bytes.length, greaterThan(500));
  });
}
