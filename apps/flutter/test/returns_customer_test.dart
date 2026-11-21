// WS-B: return flow (exchange to the counter, refund to the shift) and the customer 360 page.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/orders/exchange.dart';
import 'package:cartunez_pos/ui/orders/invoice_code.dart';
import 'package:cartunez_pos/ui/orders/returns.dart';
import 'package:cartunez_pos/ui/people/account_actions.dart';
import 'package:cartunez_pos/ui/people/customer_360.dart';
import 'package:cartunez_pos/ui/screens/receipt.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  String? path;
  Json? body;
  Object? reply = <String, dynamic>{};
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    this.path = path;
    return reply;
  }

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    this.path = path;
    this.body = body;
    return {'id': 'return-1', 'number': 'CR-PUNE-1', 'invoiceId': 'inv-1', 'total': 23600, 'lines': []};
  }
}

_Register _app(String role) => _Register()
  ..online = true
  ..session = Session(api: 'http://test', token: 't', organizationId: 'demo', branchId: 'pune',
      user: {'id': 'u', 'role': role, 'name': role}, expiresAt: DateTime.now().add(const Duration(hours: 1)).toIso8601String())
  ..snapshot = {
    'settings': {'tenderTypes': ['Cash', 'Card', 'UPI'], 'currency': 'INR'},
    'customers': [{'id': 'c1', 'name': 'Arjun', 'phone': '9000000101', 'creditLimit': 100000}],
    'suppliers': [{'id': 's1', 'name': 'Sri Auto'}],
    'partyBalances': {'customers': {'c1': 90000}},
    'products': [{'id': 'oil', 'name': 'Engine oil', 'sku': 'OIL', 'retailPrice': 10000, 'taxRate': 1800}],
  };

final Json _invoice = {
  'id': 'inv-1',
  'number': 'ML-PUNE-1000',
  'createdAt': '2026-11-20T10:00:00Z',
  'customerId': 'c1',
  'customer': {'id': 'c1', 'name': 'Arjun'},
  'total': 35400,
  'tenders': [{'type': 'Cash', 'amount': 35400}],
  'lines': [
    {'lineId': 'l1', 'productId': 'oil', 'sku': 'OIL', 'name': 'Engine oil', 'type': 'part', 'qty': 3, 'returnedQty': 0,
      'returnableQty': 3, 'refundable': 35400, 'refundedSoFar': 0, 'serials': [], 'supplierId': 's1'},
  ],
};

Future<void> _openReturn(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => startReturn(context, _invoice), child: const Text('Open')))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  test('credit for a partial return follows the server rule; receipt code is the invoice number', () {
    final line = Map<String, dynamic>.from((_invoice['lines'] as List).first as Map);
    expect(creditFor(line, 1), 11800);
    expect(creditFor(line, 3), 35400);
    expect(creditFor({...line, 'returnedQty': 1, 'refundedSoFar': 11800}, 2), 23600);
    expect(receiptInvoiceCode(_invoice), 'ML-PUNE-1000');
  });

  testWidgets('exchange puts the returned item on the counter bill as a credit', (tester) async {
    final app = _app('cashier');
    await _openReturn(tester, app);
    expect(find.text('Return from ML-PUNE-1000'), findsOneWidget);
    // A one-line bill starts with one unit coming back.
    expect(find.text('Credit for these items: ${app.money(11800)}'), findsOneWidget);
    await tester.tap(find.byTooltip('More of Engine oil'));
    await tester.pumpAndSettle();
    expect(find.text('Credit for these items: ${app.money(23600)}'), findsOneWidget);
    await tester.tap(find.byTooltip('Fewer of Engine oil'));
    await tester.pumpAndSettle();
    // RMA needs a supplier; the product's supplier is chosen already.
    await tester.tap(find.text('Back on the shelf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supplier warranty (RMA)').last);
    await tester.pumpAndSettle();
    expect(find.text('Claim from supplier'), findsOneWidget);
    await tester.tap(find.text('Add to counter'));
    // (No settle: the cart's save-to-disk timer has no store in this test; dispose cancels it.)
    await tester.pump();
    final returns = exchangeReturns(app.cart);
    expect(returns, hasLength(1));
    expect(returns.first, containsPair('kind', 'returnRef'));
    expect(returns.first['qty'], 1);
    expect(returns.first['disposition'], 'rma');
    expect(returns.first['supplierId'], 's1');
    expect(exchangeCredit(app.cart), 11800);
    expect(app.cart['customerId'], 'c1');
    app.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets('refund needs a reason and, for a cashier, a manager approval', (tester) async {
    final app = _app('cashier');
    await _openReturn(tester, app);
    await tester.tap(find.byTooltip('More of Engine oil'));
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record return'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the reason for the return.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Wrong grade');
    await tester.tap(find.text('Record return'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A manager approval ID is needed'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Manager approval ID'), 'approval-9');
    await tester.tap(find.text('Record return'));
    await tester.pumpAndSettle();
    expect(app.path, '/invoices/inv-1/returns');
    expect(app.body!['refundType'], 'Cash');
    expect(app.body!['approvalId'], 'approval-9');
    expect(app.body!['lines'], [
      {'lineId': 'l1', 'quantity': 2, 'disposition': 'restock', 'serials': []},
    ]);
    // The credit note opens for printing or sharing.
    expect(find.text('CR-PUNE-1'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    app.dispose();
  });

  testWidgets('customer 360 shows account, due bills, purchases and actions; phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _app('manager');
    final summary = {
      'customer': {'id': 'c1', 'name': 'Arjun', 'phone': '9000000101', 'vehicle': {'make': 'Maruti', 'model': 'Swift', 'year': 2022}},
      'balance': 90000,
      'availableAdvance': 0,
      'creditLimit': 100000,
      'creditAvailable': 10000,
      'vehicles': [{'make': 'Maruti', 'model': 'Swift', 'year': 2022}],
      'stats': {'bills': 2, 'spent': 150000, 'returned': 0, 'lastVisit': '2026-11-20T10:00:00Z'},
      'dueBills': [{'invoiceId': 'inv-1', 'number': 'ML-PUNE-1000', 'date': '2026-11-20', 'amount': 90000, 'due': 90000, 'ageDays': 1}],
      'invoices': [{'id': 'inv-1', 'number': 'ML-PUNE-1000', 'createdAt': '2026-11-20T10:00:00Z', 'total': 90000, 'items': 1,
        'tenders': [{'type': 'Credit', 'amount': 90000}]}],
      'returns': [],
      'entries': [{'date': '2026-11-20', 'type': 'sale', 'reference': 'Invoice ML-PUNE-1000', 'note': 'Sold on credit', 'debit': 90000, 'credit': 0, 'balance': 90000}],
    };
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: ShellScope(controller: ShellController(),
        child: Scaffold(body: SingleChildScrollView(child: Customer360View(summary: summary)))))));
    expect(find.text('Arjun'), findsOneWidget);
    expect(find.text('Owes ${app.money(90000)}'), findsWidgets);
    expect(find.text('${app.money(10000)} left'), findsOneWidget);
    expect(find.text('Maruti Swift 2022'), findsOneWidget);
    expect(find.text('Bills still due'), findsOneWidget);
    expect(find.text('1 days'), findsOneWidget);
    for (final action in ['Collect payment', 'Take advance', 'WhatsApp reminder', 'Set credit limit', 'All customers']) {
      expect(find.text(action), findsOneWidget, reason: action);
    }
    expect(find.text('Give back advance'), findsNothing);
    expect(tester.takeException(), isNull);
    // The reminder link carries the amount due.
    expect(reminderLink(app, phone: '90000 00101', name: 'Arjun', amount: 90000),
        allOf(startsWith('https://wa.me/919000000101?text='), contains(Uri.encodeComponent(app.money(90000)))));
    app.dispose();
  });

  // Integration: registered vehicles (WS-C) replace the legacy vehicle field and link to their page.
  testWidgets('customer 360 lists registered vehicles with links', (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _app('manager');
    app.snapshot = {
      ...app.snapshot,
      'customerVehicles': [
        {'id': 'veh-1', 'customerId': 'c1', 'regNo': 'MH 12 AB 1234', 'make': 'Maruti Suzuki', 'model': 'Swift'},
        {'id': 'veh-2', 'customerId': 'other', 'regNo': 'KA 01 X 9999', 'make': 'Honda', 'model': 'City'},
      ],
    };
    final opened = <String>[];
    final shell = ShellController()..navigate = opened.add;
    final summary = {
      'customer': {'id': 'c1', 'name': 'Arjun', 'phone': '9000000101'},
      'balance': 0,
      'vehicles': [{'make': 'Legacy', 'model': 'Car'}],
      'stats': {'bills': 0, 'spent': 0},
    };
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: ShellScope(controller: shell,
        child: Scaffold(body: SingleChildScrollView(child: Customer360View(summary: summary)))))));
    expect(find.text('MH 12 AB 1234 Maruti Suzuki Swift'), findsOneWidget);
    expect(find.textContaining('Honda'), findsNothing);
    expect(find.text('Legacy Car'), findsNothing);
    await tester.tap(find.text('MH 12 AB 1234 Maruti Suzuki Swift'));
    expect(opened, ['/people/vehicles/veh-1']);
    expect(tester.takeException(), isNull);
    app.dispose();
  });

  // Integration: the receipt PDF carries the scannable bill code (and credit notes do not).
  test('receipt PDF prints the invoice code below the totals', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final app = _app('cashier');
    final bytes = await buildReceiptPdf(app, {..._invoice, 'lines': const [], 'tax': 0});
    expect(bytes.length, greaterThan(1000));
    expect(receiptInvoiceCode(_invoice), 'ML-PUNE-1000');
    app.dispose();
  });
}
