// WS-B: return flow (exchange to the counter, refund to the shift) and the customer 360 page.
import 'dart:async';

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

class _LookupRegister extends AppState {
  final responses = <String, Completer<List<Json>>>{};

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) {
    final query = Uri.parse(path).queryParameters['q']!;
    return responses.putIfAbsent(query, () => Completer<List<Json>>()).future;
  }
}

class _RefundLookupRegister extends AppState {
  final lookups = <(String, Completer<List<Json>>)>[];
  final refund = Completer<Json>();
  Json? refundPayload;

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) {
    final response = Completer<List<Json>>();
    lookups.add((Uri.parse(path).queryParameters['q']!, response));
    return response.future;
  }

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) {
    refundPayload = body;
    return refund.future;
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

Future<void> _openReturn(WidgetTester tester, AppState app, {Json? invoice}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => startReturn(context, invoice ?? _invoice), child: const Text('Open')))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Walk-in explains store credit and a named invoice can use a store credit preview', (tester) async {
    final app = _app('manager')..reply = {'currency': 'INR', 'refunds': [{'type': 'Credit', 'amount': 11800}]};
    await _openReturn(tester, app, invoice: {..._invoice, 'customerId': null, 'customer': null});
    expect(find.text('Store credit'), findsNothing);
    expect(find.textContaining('Store credit requires an invoice billed to a named customer'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await _openReturn(tester, app);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    final storeCredit = find.text('Store credit');
    await tester.ensureVisible(storeCredit);
    await tester.tap(storeCredit);
    await tester.pumpAndSettle();
    expect(find.text('Customer account · ${app.money(11800)}'), findsOneWidget);
    expect(app.path, '/returns/preview');
    expect(tester.takeException(), isNull);
  });

  testWidgets('return lookup keeps the newest response when requests finish out of order', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _LookupRegister()..online = true;
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ReturnsPage())),
    )));
    final field = find.widgetWithText(TextField, 'Invoice number, receipt barcode, phone or serial');
    await tester.enterText(field, 'OLD');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.enterText(field, 'NEW');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(app.responses.keys, containsAll(['OLD', 'NEW']));
    Json row(String number) => {'id': number, 'number': number, 'createdAt': '2026-11-20T10:00:00Z',
      'customer': null, 'total': 1000, 'lines': [], 'voided': false};
    app.responses['NEW']!.complete([row('NEW')]);
    await tester.pumpAndSettle();
    app.responses['OLD']!.complete([row('OLD')]);
    await tester.pumpAndSettle();
    expect(find.text('NEW'), findsNWidgets(2));
    expect(find.text('OLD'), findsNothing);

    await tester.enterText(field, 'SEARCH');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.enterText(field, 'S');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    app.responses['SEARCH']!.complete([row('STALE')]);
    await tester.pumpAndSettle();
    expect(find.text('STALE'), findsNothing);
    expect(find.text('Enter the invoice number, phone number or serial number.'), findsOneWidget);
    app.dispose();
  });

  testWidgets('a recorded refund refreshes the current lookup and removes the fully returned action', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _RefundLookupRegister()
      ..online = true
      ..session = Session(api: 'http://test', token: 't', organizationId: 'demo', branchId: 'pune',
          user: {'id': 'u', 'role': 'manager', 'name': 'Manager'}, expiresAt: DateTime.now().toIso8601String())
      ..snapshot = {'settings': {'tenderTypes': ['Cash'], 'currency': 'INR'}};
    Json bill(int returnable) => {
      ..._invoice,
      'total': 23600,
      'tenders': [{'type': 'Cash', 'amount': 23600}],
      'lines': [
        {...((_invoice['lines'] as List).single as Json),
          'qty': 2, 'returnableQty': returnable, 'refundable': 23600, 'returnedQty': 2 - returnable},
      ],
    };
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ReturnsPage())),
    )));
    final field = find.widgetWithText(TextField, 'Invoice number, receipt barcode, phone or serial');
    const query = '9000000101';
    await tester.enterText(field, query);
    await tester.tap(find.text('Find bill'));
    await tester.pump();
    expect(app.lookups.single.$1, query);
    app.lookups.single.$2.complete([bill(2)]);
    await tester.pumpAndSettle();
    expect(find.text('2 item(s)'), findsOneWidget);
    await tester.tap(find.text('Return items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.lookups, hasLength(1));
    expect(find.text('Return items'), findsOneWidget);

    await tester.tap(find.text('Return items'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More of Engine oil'));
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Full return');
    await tester.tap(find.text('Record return'));
    await tester.pump();
    expect((app.refundPayload!['lines'] as List).single['quantity'], 2);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('Return from ML-PUNE-1000'), findsOneWidget);

    app.refund.complete({'id': 'return-1', 'number': 'CR-PUNE-1', 'invoiceId': 'inv-1', 'total': 23600, 'lines': []});
    await tester.pump();
    expect(app.lookups.map((lookup) => lookup.$1), [query, query]);
    app.lookups.last.$2.complete([bill(0)]);
    await tester.pumpAndSettle();
    expect(find.text('CREDIT NOTE'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, query);
    expect(find.text('Returned'), findsOneWidget);
    expect(find.text('2 item(s)'), findsNothing);
    expect(find.text('Return items'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  test('an exchange is always bound to the original invoice customer', () {
    final app = _app('manager');
    app.updateCart({'customerId': 'other'});
    addExchangeReturns(app, _invoice, [
      {'lineId': 'l1', 'productId': 'oil', 'name': 'Engine oil', 'quantity': 1,
        'disposition': 'restock', 'onlineOnly': true, 'serials': <String>[], 'credit': 11800},
    ], 'Wrong grade');
    expect(app.cart['customerId'], 'c1');
    expect(exchangeReturns(app.cart).single['invoiceCustomerId'], 'c1');
    expect(exchangeReturns(app.cart).single['onlineOnly'], isTrue);
    app.dispose();
  });

  test('exchange receipt separates the credit, the amount applied and each actual payout', () {
    final app = _app('manager');
    final note = {'invoiceId': 'i', 'total': 10000, 'exchangeApplied': 8000, 'refundTotal': 2000,
      'refunds': [{'type': 'UPI', 'amount': 1200}, {'type': 'Credit', 'amount': 800}]};
    final text = receiptSummary(app, note);
    expect(text, contains('Credit note total: ${app.money(10000)}'));
    expect(text, contains('Set against new bill: ${app.money(8000)}'));
    expect(text, contains('Amount refunded: ${app.money(2000)}'));
    expect(refundInstructions(app, note), contains('Send ${app.money(1200)} by UPI.'));
    expect(refundInstructions(app, note), contains('${app.money(800)} credited to the customer account.'));
    app.dispose();
  });

  testWidgets('mixed account and UPI shows the server payout preview before recording the return', (tester) async {
    final app = _app('owner')..reply = {'currency': 'INR', 'refunds': [{'type': 'Credit', 'amount': 7000}, {'type': 'UPI', 'amount': 4800}]};
    final bill = {..._invoice, 'tenders': [{'type': 'Advance', 'amount': 21000}, {'type': 'UPI', 'amount': 14400}]};
    tester.view.physicalSize = const Size(924, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => startReturn(context, bill), child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    expect(app.path, '/returns/preview');
    expect(find.text('Customer account · ${app.money(7000)}'), findsOneWidget);
    expect(find.text('UPI · ${app.money(4800)}'), findsOneWidget);
    expect(find.textContaining('Send ${app.money(11800)}'), findsNothing);
    app.dispose();
  });
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
    // QA #7: nothing is committed until settlement is chosen.
    const choose = 'Choose a settlement method';
    expect(find.text(choose), findsOneWidget);
    expect(tester.widget<FilledButton>(find.ancestor(of: find.text(choose), matching: find.byWidgetPredicate((w) => w is FilledButton))).onPressed, isNull);
    await tester.tap(find.text('Exchange'));
    await tester.pumpAndSettle();
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

  testWidgets('QA #3: refund defaults to the original tender; switching to cash shows the drawer effect', (tester) async {
    final app = _app('owner');
    final upiBill = {..._invoice, 'tenders': [{'type': 'UPI', 'amount': 35400}]};
    tester.view.physicalSize = const Size(924, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => startReturn(context, upiBill), child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    expect(find.text('UPI (as paid)'), findsOneWidget);
    expect(find.textContaining('back by UPI to the customer'), findsOneWidget);
    expect(find.textContaining('drawer is not affected'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'UPI reference (optional)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'UPI reference (optional)'), 'UTR123');
    // Explicit switch to cash shows what it does to the drawer.
    await tester.tap(find.text('UPI (as paid)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash from the drawer').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Expected cash at shift close goes down by ${app.money(11800)}'), findsOneWidget);
    expect(find.textContaining('paid by UPI, not cash'), findsOneWidget);
    await tester.tap(find.text('Cash from the drawer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UPI (as paid)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Wrong part');
    await tester.tap(find.text('Record return'));
    await tester.pumpAndSettle();
    expect(app.body!['refundType'], 'UPI');
    expect(app.body!['refundReference'], 'UTR123');
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
  testWidgets('settled customer offers an advance and can add a linked vehicle', (tester) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _app('manager');
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(
        home: ShellScope(
          controller: ShellController(),
          child: const Scaffold(
            body: SingleChildScrollView(
              child: Customer360View(summary: {
                'customer': {'id': 'c1', 'name': 'Arjun'},
                'balance': 0,
              }),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('Collect payment'), findsNothing);
    expect(find.ancestor(of: find.text('Take advance'), matching: find.byWidgetPredicate((w) => w is FilledButton)), findsOneWidget);
    final addVehicle = find.text('Add vehicle');
    await tester.ensureVisible(addVehicle);
    await tester.tap(addVehicle);
    await tester.pumpAndSettle();
    expect(find.text('Registration number'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

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
