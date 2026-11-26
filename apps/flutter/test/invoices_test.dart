import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart' show Json;
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/receipt.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:cartunez_pos/ui/widgets.dart' show formatDate;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Invoices combine status, search and inclusive date filters and name the cashier', (tester) async {
    tester.view.physicalSize = const Size(924, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shopNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final today = DateTime(shopNow.year, shopNow.month, shopNow.day);
    final beforeMidnight = DateTime.utc(today.year, today.month, today.day, 18, 29).subtract(const Duration(days: 1));
    Json invoice(String id, DateTime time) => {
      'id': id, 'number': 'INV-$id', 'createdAt': time.toUtc().toIso8601String(), 'cashierId': 'staff',
      'currency': 'INR', 'total': 10000, 'lines': [{'id': 'line-$id', 'qty': 2, 'name': 'Part', 'total': 10000}],
    };
    final app = AppState()
      ..session = Session(
        api: 'http://test', token: 'token', organizationId: 'demo', branchId: 'shop',
        user: {'id': 'staff', 'name': 'Asha', 'role': 'manager'},
        expiresAt: DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      )
      ..snapshot = {
        'settings': {'currency': 'USD'},
        'invoices': [
          invoice('YESTERDAY', beforeMidnight),
          invoice('OPEN', beforeMidnight.add(const Duration(minutes: 1))),
          invoice('PARTIAL', beforeMidnight.add(const Duration(hours: 23))),
        ],
        'returns': [
          {'id': 'cn', 'number': 'CN-1', 'invoiceId': 'PARTIAL', 'invoiceNumber': 'INV-PARTIAL', 'total': 5000,
            'currency': 'INR', 'createdAt': beforeMidnight.add(const Duration(hours: 23)).toIso8601String(),
            'lines': [{'lineId': 'line-PARTIAL', 'quantity': 1}]},
        ],
      };
    final shell = ShellController();
    await tester.pumpWidget(AppScope(state: app, child: ShellScope(
      controller: shell,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: InvoicesScreen()))),
    )));
    final namedInvoice = find.widgetWithText(InkWell, 'INV-PARTIAL');
    final partialFilter = find.widgetWithText(ChoiceChip, 'Partially returned');
    final resetStatus = find.widgetWithText(ChoiceChip, 'All statuses');
    await tester.tap(partialFilter);
    await tester.pumpAndSettle();
    expect(find.text('INV-OPEN'), findsNothing);
    expect(namedInvoice, findsWidgets);
    await tester.tap(resetStatus);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Invoice dates'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    final input = '${today.month}/${today.day}/${today.year}';
    await tester.enterText(find.widgetWithText(TextField, 'Start Date'), input);
    await tester.enterText(find.widgetWithText(TextField, 'End Date'), input);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('INV-YESTERDAY'), findsNothing);
    expect(namedInvoice, findsWidgets);
    expect(find.text('INV-OPEN'), findsOneWidget);

    shell.search.text = 'INV-OPEN';
    await tester.pumpAndSettle();
    expect(namedInvoice, findsNothing);
    await tester.tap(find.text('View receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Cashier: Asha'), findsOneWidget);
    expect(find.textContaining(', 12:00 am'), findsWidgets);
    expect(find.text('₹100.00'), findsWidgets);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    shell.search.clear();
    await tester.tap(find.byTooltip('Clear date filter'));
    await tester.pumpAndSettle();
    expect(find.text('INV-YESTERDAY'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    shell.dispose();
    app.dispose();
  });

  test('receipt uses the issued currency or time zone and preserves non-INR local display', () {
    final app = AppState()..snapshot = {'settings': {'currency': 'USD'}};
    addTearDown(app.dispose);
    const timestamp = '2026-11-26T18:30:00Z';
    const invoice = {
      'number': 'INV-123',
      'createdAt': timestamp,
      'invoiceDate': '2026-11-26',
      'currency': 'INR',
      'total': 10000,
    };
    expect(receiptSummary(app, invoice), contains('27 Nov 2026, 12:00 am'));
    expect(formatDocumentDate(app, invoice, field: 'invoiceDate'), '26 Nov 2026');
    expect(formatDocumentDate(app, {...invoice, 'timeZone': 'UTC'}), '26 Nov 2026, 06:30 pm');
    expect(formatDocumentDate(app, {...invoice, 'currency': 'USD', 'timeZone': 'Asia/Kolkata'}), '27 Nov 2026, 12:00 am');
    expect(formatDocumentDate(app, {...invoice, 'currency': 'USD'}), formatDate(timestamp));
  });
}
