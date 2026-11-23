// QA audit #1: the supplier bill's "Left on the supplier's account" preview must be
// the same amount the API posts (total = items (+GST) + freight − discount; due = total − paid now).

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/purchasing/bill_entry_dialog.dart';
import 'package:cartunez_pos/ui/purchasing/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? saved;
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    saved = body;
    return <String, dynamic>{};
  }
}

void main() {
  test('bill totals and balance follow the API rules', () {
    final lines = [{'quantity': 1, 'cost': 6000, 'taxRate': 1800}];
    expect(supplierBillTotals(lines, gst: false).total, 6000);
    expect(supplierBillTotals(lines, gst: true).total, 7080);
    expect(supplierBillTotals(lines, gst: false, otherCharges: 500, discount: 1500).total, 5000);
    // Half-paise GST rounds up, like roundRatio on the API.
    expect(supplierBillTotals([{'quantity': 1, 'cost': 25, 'taxRate': 1800}], gst: true).tax, 5);
    expect(supplierBillDue(6000, 0), 6000);
    expect(supplierBillDue(6000, 2000), 4000);
    expect(supplierBillDue(6000, 6000), 0);
    expect(supplierBillDue(6000, 7000), 0);
  });

  testWidgets('₹60 bill previews ₹60 / ₹40 / ₹0 due for ₹0 / ₹20 / ₹60 paid, live', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Register()..snapshot = {
      'products': [{'id': 'a', 'name': 'Filter', 'sku': 'FA', 'taxRate': 1800}],
      'suppliers': [{'id': 's', 'name': 'Parts Co'}],
      'locations': [{'id': 'bin1', 'kind': 'sellable', 'area': 'A', 'rack': '1', 'shelf': '1', 'bin': '1'}],
    };
    final order = {'id': 'po', 'supplierId': 's', 'lines': [{'productId': 'a', 'quantity': 1, 'received': 0, 'cost': 6000}]};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => enterBill(context, order: order), child: const Text('Bill')))))));
    await tester.tap(find.text('Bill'));
    await tester.pumpAndSettle();

    String due() => tester.widget<Text>(find.byKey(const ValueKey('bill-due'))).data!;
    final paid = find.widgetWithText(TextField, 'Paid now');
    expect(due(), contains(app.money(6000)));
    await tester.enterText(paid, '20');
    await tester.pump();
    expect(due(), contains(app.money(4000)));
    await tester.enterText(paid, '60');
    await tester.pump();
    expect(due(), contains(app.money(0)));
    // Freight, discount and GST recompute the balance too.
    await tester.enterText(paid, '0');
    await tester.enterText(find.widgetWithText(TextField, 'Freight / other charges'), '10');
    await tester.enterText(find.widgetWithText(TextField, 'Discount on bill'), '5');
    await tester.pump();
    expect(due(), contains(app.money(6500)));
    await tester.tap(find.text('GST bill'));
    await tester.pump();
    expect(due(), contains(app.money(6500 + 1080)));
    await tester.tap(find.text('GST bill'));
    await tester.enterText(find.widgetWithText(TextField, 'Freight / other charges'), '0');
    await tester.enterText(find.widgetWithText(TextField, 'Discount on bill'), '0');
    await tester.enterText(paid, '20');
    await tester.pump();
    expect(due(), contains(app.money(4000)));

    await tester.ensureVisible(find.text('Save bill · add to stock'));
    await tester.tap(find.text('Save bill · add to stock'));
    await tester.pumpAndSettle();
    // What is posted gives the API the same ₹60 total and ₹20 paid (₹40 left).
    expect(app.saved!['paidNow'], {
      'amount': 2000,
      'mode': 'Cash',
      'fromDrawer': true,
    });
    expect(app.saved!['otherCharges'], 0);
    expect(app.saved!['discount'], 0);
    expect(app.saved!['purchaseOrderId'], 'po');
    app.dispose();
  });
}
