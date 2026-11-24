import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart' show Json;
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Invoices combine status, search and inclusive date filters and name the cashier', (tester) async {
    tester.view.physicalSize = const Size(924, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateUtils.dateOnly(DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));
    Json invoice(String id, DateTime time) => {
      'id': id, 'number': 'INV-$id', 'createdAt': time.toUtc().toIso8601String(), 'cashierId': 'staff',
      'total': 10000, 'lines': [{'id': 'line-$id', 'qty': 2, 'name': 'Part', 'total': 10000}],
    };
    final app = AppState()
      ..session = Session(
        api: 'http://test', token: 'token', organizationId: 'demo', branchId: 'shop',
        user: {'id': 'staff', 'name': 'Asha', 'role': 'manager'},
        expiresAt: DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      )
      ..snapshot = {
        'invoices': [invoice('YESTERDAY', yesterday), invoice('OPEN', today), invoice('PARTIAL', today.add(const Duration(hours: 23)))],
        'returns': [
          {'id': 'cn', 'number': 'CN-1', 'invoiceId': 'PARTIAL', 'invoiceNumber': 'INV-PARTIAL', 'total': 5000,
            'createdAt': today.toUtc().toIso8601String(), 'lines': [{'lineId': 'line-PARTIAL', 'quantity': 1}]},
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
}
