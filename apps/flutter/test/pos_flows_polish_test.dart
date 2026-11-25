import 'dart:io';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/counter_panes.dart';
import 'package:cartunez_pos/ui/orders/exchange.dart';
import 'package:cartunez_pos/ui/orders/returns.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/screens/billing.dart';
import 'package:cartunez_pos/ui/screens/inventory.dart';
import 'package:cartunez_pos/ui/screens/receipt.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:cartunez_pos/ui/workshop/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _TestApp extends AppState {
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => {'rows': []};

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}
}

Future<_TestApp> _readyApp(WidgetTester tester, {String taxScheme = 'general', String role = 'cashier'}) async {
  LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-polish');
  final app = _TestApp();
  await tester.runAsync(app.init);
  return app
    ..ready = true
    ..online = true
    ..lastSync = '2026-11-24T09:00:00Z'
    ..session = Session(
      api: 'https://pos.example.test/api/v1',
      token: 't',
      user: {'id': 'u1', 'name': 'Asha', 'role': role},
      branchId: 'main',
      organizationId: 'org',
      expiresAt: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
    )
    ..snapshot = {
      'settings': {
        'currency': 'INR',
        'taxScheme': taxScheme,
        'tenderTypes': ['Cash', 'Card', 'UPI'],
      },
      'branch': {'name': 'Main'},
      'customers': [
        {'id': 'c1', 'name': 'Ravi Kumar', 'phone': '9876543210'},
        {'id': 'c2', 'name': 'Meena Joshi', 'phone': '9123456789'},
      ],
      'partyBalances': {
        'customers': {'c1': 125000},
      },
      'customerVehicles': [
        {
          'id': 'cv1',
          'regNo': 'MH 12 AB 1234',
          'regKey': 'MH12AB1234',
          'customerId': 'c1',
          'make': 'Maruti',
          'model': 'Swift',
          'year': 2021,
        },
      ],
      'products': [
        {
          'id': 'p1',
          'name': 'Swift Brake Pad',
          'sku': 'PAD-1',
          'retailPrice': 100000,
          'taxRate': taxScheme == 'none' ? 0 : 1800,
          'category': 'Brakes',
          'fitments': [
            {'make': 'Maruti', 'model': 'Swift', 'yearFrom': 2018, 'yearTo': 2024},
          ],
        },
        {
          'id': 'p2',
          'name': 'Creta Air Filter',
          'sku': 'FLT-2',
          'retailPrice': 40000,
          'taxRate': taxScheme == 'none' ? 0 : 1800,
          'category': 'Filters',
          'fitments': [
            {'make': 'Hyundai', 'model': 'Creta', 'yearFrom': 2020, 'yearTo': 2025},
          ],
        },
      ],
      'locations': [
        {'id': 'bin', 'kind': 'sellable', 'bin': 'A1'},
      ],
      'stock': [
        {'productId': 'p1', 'binId': 'bin', 'quantity': 5},
        {'productId': 'p2', 'binId': 'bin', 'quantity': 5},
      ],
      'shifts': [
        {'id': 's1', 'userId': 'u1', 'closedAt': null, 'openingCash': 0},
      ],
      'invoices': [
        {
          'id': 'inv-1',
          'number': 'INV-MAIN-101',
          'createdAt': '2026-11-24T10:00:00Z',
          'customerId': 'c1',
          'customer': {'id': 'c1', 'name': 'Ravi Kumar', 'phone': '9876543210'},
          'vehicle': {'regNo': 'MH 12 AB 1234'},
          'total': 118000,
          'tenders': [{'type': 'Cash', 'amount': 118000}],
          'lines': [{'id': 'l1', 'productId': 'p1', 'name': 'Swift Brake Pad', 'sku': 'PAD-1', 'qty': 1, 'total': 118000}],
        },
      ],
    };
}

void main() {
  testWidgets('counter shows active exchange panel, net total, and disables Hold across desktop and phone', (tester) async {
    for (final size in [const Size(1400, 900), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final app = await _readyApp(tester);
      app.updateCart({
        'lines': [{'productId': 'p1', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}],
        'returns': [
          {
            'kind': 'returnRef',
            'invoiceId': 'inv-1',
            'invoiceNumber': 'INV-MAIN-101',
            'invoiceCustomerId': 'c1',
            'lineId': 'l1',
            'productId': 'p2',
            'name': 'Creta Air Filter',
            'qty': 1,
            'disposition': 'restock',
            'serials': <String>[],
            'credit': 47200,
          },
        ],
      });

      final shell = ShellController()..section = 'billing';
      await tester.pumpWidget(AppScope(
        state: app,
        child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: BillingScreen()))),
      ));
      await tester.pumpAndSettle();

      if (size.width < 600) {
        expect(find.byKey(const ValueKey('cart-pill')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('cart-pill')));
        await tester.pumpAndSettle();
      }

      expect(find.text('Coming back · exchange against INV-MAIN-101'), findsOneWidget);
      expect(find.text('Customer pays'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('dock-total'))).data, app.money(70800));
      final holdButton = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('Hold'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
      );
      expect(holdButton.onPressed, isNull);

      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  testWidgets('F2 searchable picker links registered customerVehicleId, owner, and shows balance hint', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    final shell = ShellController()..section = 'billing';
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: BillingScreen()))),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('customer-vehicle-search')), '1234');
    await tester.pumpAndSettle();

    await tester.tap(find.text('MH 12 AB 1234 · Maruti Swift 2021'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Use'));
    await tester.pumpAndSettle();

    expect(app.cart['customerId'], 'c1');
    expect(app.cart['regNo'], 'MH12AB1234');
    expect((app.cart['vehicle'] as Map)['customerVehicleId'], 'cv1');
    expect(find.text('Owes ${app.money(125000)}'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('fitment filter offers Show all toggle and F7 opens Card checkout', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    app.updateCart({
      'vehicle': {'make': 'Maruti', 'model': 'Swift', 'year': 2021},
      'lines': [{'productId': 'p1', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}],
    });
    final shell = ShellController()..section = 'billing';
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: BillingScreen()))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Swift Brake Pad'), findsNWidgets(2));
    expect(find.text('Creta Air Filter'), findsNothing);
    await tester.tap(find.text('Show all (1 hidden)'));
    await tester.pumpAndSettle();
    expect(find.text('Creta Air Filter'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.pumpAndSettle();
    expect(find.text('Take payment'), findsOneWidget);
    expect(find.text('Card payment reference'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('tablet top bar gives search room and pending chip opens Sync & audit', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    app.pending = [
      {
        'status': 'awaiting-payment',
        'total': 10000,
        'createdAt': '2026-11-24T10:00:00Z',
        'transaction': {'transactionId': 'tx-1', 'lines': [], 'tenders': []},
      },
    ];
    await tester.pumpWidget(CartunezApp(state: app, prefs: UiPrefs(), initialLocation: '/counter'));
    await tester.pumpAndSettle();

    final searchBox = tester.getSize(find.widgetWithText(TextField, 'Search or scan parts'));
    expect(searchBox.width, greaterThan(300));

    await tester.tap(find.text('1 waiting'));
    await tester.pumpAndSettle();
    final location = GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.toString();
    expect(location, '/settings/sync');

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('invoices search matches phone, registration, and SKU', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    final shell = ShellController()..section = 'invoices';
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: SingleChildScrollView(child: InvoicesScreen())))),
    ));
    await tester.pumpAndSettle();

    for (final q in ['9876543210', 'MH12AB1234', 'PAD-1']) {
      shell.search.text = q;
      await tester.pump();
      expect(find.text('INV-MAIN-101'), findsOneWidget, reason: q);
    }
    shell.search.text = 'NONEXISTENT';
    await tester.pump();
    expect(find.text('INV-MAIN-101'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('non-GST mode omits Tax in PaymentDock and DocumentTotals, and receipt has one Share button', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester, taxScheme: 'none');
    app.updateCart({'lines': [{'productId': 'p1', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}]});
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(
        home: ShellScope(
          controller: ShellController(),
          child: Scaffold(
            body: Column(children: [
              const PaymentDock(),
              const DocumentTotals({'subtotal': 10000, 'tax': 0, 'total': 10000}),
              Builder(builder: (c) => TextButton(
                onPressed: () => showReceipt(c, app.list('invoices').first),
                child: const Text('Open receipt'),
              )),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Tax'), findsNothing);
    expect(find.textContaining('Tax ₹'), findsNothing);

    await tester.tap(find.text('Open receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Share PDF'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('PartsScreen filters low/out-of-stock and searches interchange references', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester, role: 'manager');
    app.snapshot = {
      ...app.snapshot,
      'products': [
        {
          'id': 'p1', 'name': 'Swift Brake Pad', 'sku': 'PAD-1', 'retailPrice': 100000, 'reorderLevel': 10,
          'interchanges': ['BREMBO-99'],
        },
        {
          'id': 'p2', 'name': 'Creta Air Filter', 'sku': 'FLT-2', 'retailPrice': 40000, 'reorderLevel': 1,
        },
      ],
    };
    final shell = ShellController()..section = 'parts';
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: SingleChildScrollView(child: PartsScreen())))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Swift Brake Pad'), findsOneWidget);
    expect(find.text('Creta Air Filter'), findsOneWidget);
    await tester.tap(find.text('Low / out (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Swift Brake Pad'), findsOneWidget);
    expect(find.text('Creta Air Filter'), findsNothing);

    await tester.tap(find.text('Low / out (1)'));
    await tester.pumpAndSettle();
    shell.search.text = 'BREMBO-99';
    await tester.pump();
    expect(find.text('Swift Brake Pad'), findsOneWidget);
    expect(find.text('Creta Air Filter'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('CheckoutDialog selects cash amount on focus and focuses ref when confirmed toggled on', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    await tester.pumpWidget(AppScope(
      state: app,
      child: const MaterialApp(home: Scaffold(body: CheckoutDialog(total: 45000))),
    ));
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(find.widgetWithText(TextField, 'Amount received'));
    expect(amountField.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 6));

    await tester.tap(find.text('Card'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    final refField = tester.widget<TextField>(find.widgetWithText(TextField, 'Card payment reference'));
    expect(refField.focusNode!.hasFocus, isTrue);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('ExchangeCheckoutDialog calculates cash change and offers UPI QR', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester);
    app.snapshot = {
      ...app.snapshot,
      'settings': {...app.settings, 'upiVpa': 'cartunez@okhdfcbank'},
    };
    app.updateCart({
      'lines': [{'productId': 'p1', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}],
      'returns': [
        {
          'kind': 'returnRef', 'invoiceId': 'inv-1', 'invoiceNumber': 'INV-MAIN-101', 'invoiceCustomerId': 'c1',
          'lineId': 'l1', 'productId': 'p2', 'name': 'Creta Air Filter', 'qty': 1, 'disposition': 'restock',
          'serials': <String>[], 'credit': 47200,
        },
      ],
    });
    await tester.pumpWidget(AppScope(
      state: app,
      child: const MaterialApp(home: Scaffold(body: ExchangeCheckoutDialog(total: 118000))),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Cash received'), '1000');
    await tester.pumpAndSettle();
    expect(find.text('Change to give: ${app.money(29200)}'), findsOneWidget);

    await tester.tap(find.text('UPI'));
    await tester.pumpAndSettle();
    expect(find.text('UPI QR checkout · ${app.money(70800)}'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('ReturnDialog offers quick reason chips', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await _readyApp(tester, role: 'manager');
    final inv = {
      'id': 'inv-1', 'number': 'INV-MAIN-101', 'createdAt': '2026-11-24T10:00:00Z',
      'tenders': [{'type': 'Cash', 'amount': 118000}],
      'lines': [{'lineId': 'l1', 'productId': 'p1', 'name': 'Swift Brake Pad', 'sku': 'PAD-1', 'type': 'part',
        'qty': 1, 'returnedQty': 0, 'returnableQty': 1, 'refundable': 118000, 'refundedSoFar': 0, 'serials': []}],
    };
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: Scaffold(body: ReturnDialog(invoice: inv))),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong part / fitment'));
    await tester.pumpAndSettle();
    final reasonField = tester.widget<TextField>(find.widgetWithText(TextField, 'Reason'));
    expect(reasonField.controller!.text, 'Wrong part / fitment');

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
