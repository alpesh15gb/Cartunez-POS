// Online only items: website-only parts outside POS stock. The part editor has
// the switch, the counter never offers them, and pick & pack lists them as
// "Order from supplier" with a "Create purchase order" action.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/counter_panes.dart';
import 'package:cartunez_pos/ui/online/pick_pack.dart';
import 'package:cartunez_pos/ui/screens/billing.dart';
import 'package:cartunez_pos/ui/screens/inventory.dart';
import 'package:cartunez_pos/ui/screens/purchasing.dart';
import 'package:cartunez_pos/ui/purchasing/supplier_return.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Shop extends AppState {
  final calls = <(String, Json)>[];
  final toasts = <String>[];
  bool manager = true;

  @override
  bool get isManager => manager;

  @override
  void toast(String text) => toasts.add(text);

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    calls.add((path, body));
    if (path == '/products') {
      final saved = {...body, 'id': 'new-part', 'sku': 'AUTO-1'};
      snapshot = {...snapshot, 'products': [...products, saved]};
      return saved;
    }
    if (path.endsWith('/purchase-order')) {
      // The first ask lists the part without a supplier; the second creates the order.
      return body['suppliers'] == null
          ? {'purchaseOrderIds': ['po-1'], 'needsSupplier': [{'productId': 'roof', 'sku': 'CZ-ROOF-01', 'name': 'Roof Box', 'quantity': 1}]}
          : {'purchaseOrderIds': ['po-2'], 'needsSupplier': []};
    }
    if (path.endsWith('/invoice')) return {'invoice': {'number': 'INV-1'}};
    return {};
  }
}

const _wheel = {
  'id': 'wheel', 'name': 'Alloy Wheel Set', 'sku': 'CZ-ALLOY-01', 'barcodes': ['8900000000099'], 'retailPrice': 1180000,
  'category': 'Filters', 'onlineOnly': true, 'supplierId': 's',
};
const _filter = {'id': 'p', 'name': 'Oil filter', 'sku': 'OF1', 'barcodes': ['8901234567890'], 'retailPrice': 25000, 'wholesalePrice': 20000, 'category': 'Filters'};

void main() {
  testWidgets('part editor: the Online only switch is saved and skips the first-stock offer', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Shop()
      ..snapshot = {
        'products': <Json>[],
        'suppliers': [{'id': 's', 'name': 'Parts Co'}],
        'locations': [{'id': 'bin1', 'kind': 'sellable', 'area': 'A', 'rack': '1', 'shelf': '1', 'bin': '1'}],
        'settings': {'taxScheme': 'none', 'features': {'fitment': true}},
      };
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => editProduct(context, const {}), child: const Text('New part')))))));
    await tester.tap(find.text('New part'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, 'Online only (sold on the website, not at the counter)');
    expect(toggle, findsOneWidget);
    expect(find.textContaining('ordered from the supplier'), findsOneWidget); // help text
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.enterText(find.widgetWithText(TextFormField, 'Part name'), 'Alloy Wheel Set');
    await tester.enterText(find.widgetWithText(TextFormField, 'Retail price'), '11800');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = app.calls.firstWhere((c) => c.$1 == '/products').$2;
    expect(saved['onlineOnly'], isTrue);
    // No shop stock to add for an online-only part.
    expect(find.text('Alloy Wheel Set saved'), findsNothing);
    app.dispose();
  });

  testWidgets('counter: online-only parts are hidden, and a scan says why', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Shop()
      ..online = true
      ..session = Session(api: '', token: '', user: {'role': 'cashier', 'id': 'c', 'name': 'Asha'}, branchId: 'b', organizationId: 'o', expiresAt: '')
      ..snapshot = {
        'settings': {'currency': 'INR', 'tenderTypes': ['Cash']},
        'products': [_filter, _wheel],
        'locations': [{'id': 'bin', 'kind': 'sellable', 'bin': 'A1'}],
        'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 5}],
        'shifts': [{'id': 'shift', 'userId': 'c'}],
      };
    app.manager = false;
    final shell = ShellController()..section = 'billing';
    await tester.pumpWidget(AppScope(
      state: app,
      child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: BillingScreen()))),
    ));
    await tester.pump();
    expect(find.text('Oil filter'), findsWidgets);
    expect(find.text('Alloy Wheel Set'), findsNothing);
    expect(app.saleProducts.map((p) => p['id']), ['p']);
    expect(counterParts(app, '', 'All parts').map((p) => p['id']), ['p']);
    expect(app.findByCode('8900000000099', forSale: true), isEmpty);
    expect(app.stockParts.map((p) => p['id']), ['p']);
    // Scanning its barcode at the counter adds nothing and explains why.
    handleScan(tester.element(find.byType(BillingScreen)), shell, '8900000000099');
    await tester.pump();
    expect(app.cart['lines'] as List, isEmpty);
    expect(app.toasts.last, contains('online only'));
    // A cart line for it is refused at checkout.
    expect(() => quote({'lines': [{'productId': 'wheel', 'qty': 1, 'binId': null}]}, app.products), throwsA(isA<BillingError>()));
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('invoiced website order still offers procurement until its units are covered', (tester) async {
    final order = <String, dynamic>{
      'id': 'web', 'number': '100', 'mode': 'pos', 'total': 10000,
      'fulfilment': {'invoiceId': 'inv', 'invoiceNumber': 'I-1'},
      'lines': [{'productId': 'wheel', 'name': 'Wheel', 'onlineOnly': true, 'ordered': 4, 'posInvoiced': 4, 'shipped': 1}],
      'supplierPurchaseNeeded': true,
    };
    final app = _Shop()..snapshot = {'onlineOrders': [order], 'products': [_wheel]};
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: PickPackPage(orderId: 'web'))));
    await tester.pumpAndSettle();
    expect(find.text('Invoice & pack'), findsNothing);
    expect(find.text('Create purchase order'), findsOneWidget);
    order['supplierPurchaseNeeded'] = false;
    expect(hasSupplierLines(app, order), isFalse);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('receive, enter bill and return a website-only SKU without a warehouse bin', (tester) async {
    tester.view.physicalSize = const Size(1280, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final order = {'id': 'po', 'status': 'open', 'supplierId': 's',
      'lines': [{'productId': 'wheel', 'quantity': 1, 'received': 0, 'cost': 90000}]};
    final app = _Shop()..snapshot = {'purchaseOrders': [order], 'products': [_wheel],
      'suppliers': [{'id': 's', 'name': 'Parts Co'}], 'locations': [], 'settings': {}};
    Widget orders() => AppScope(state: app, child: MaterialApp(home: ShellScope(controller: ShellController(),
      child: const Scaffold(body: OrdersScreen()))));
    await tester.pumpWidget(orders());
    await tester.tap(find.byTooltip('Receive goods without a bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add part'));
    await tester.pumpAndSettle();
    expect(find.text('Put away into'), findsNothing);
    await tester.tap(find.text('Add line'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record delivery'));
    await tester.pumpAndSettle();
    expect(app.calls.single.$1, '/purchase-orders/po/receive');
    expect((app.calls.single.$2['lines'] as List).single['binId'], null);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(orders());
    await tester.tap(find.text('Enter bill'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save supplier bill'));
    await tester.tap(find.text('Save supplier bill'));
    await tester.pumpAndSettle();
    expect(app.calls.last.$1, '/purchase-bills');
    expect((app.calls.last.$2['lines'] as List).single['binId'], null);

    await tester.pumpWidget(const SizedBox());
    final bill = {'id': 'bill', 'lines': [{'productId': 'wheel', 'cost': 90000, 'onlineOnly': true, 'quantity': 1}]};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => supplierReturn(context, {'id':'s', 'name':'Parts Co'}, bill: bill),
          child: const Text('Return shipment')))))));
    await tester.tap(find.text('Return shipment'));
    await tester.pumpAndSettle();
    expect(find.text('Take from bin'), findsNothing);
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Damaged in transit');
    await tester.tap(find.text('Return and adjust balance'));
    await tester.pumpAndSettle();
    expect(app.calls.last.$1, '/purchase-returns');
    expect(app.calls.last.$2['billId'], 'bill');
    expect((app.calls.last.$2['lines'] as List).single['binId'], null);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('pick & pack: online-only lines are "Order from supplier", with Create purchase order', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Shop()
      ..snapshot = {
        'onlineOrders': [
          {
            'id': 'mg-1', 'number': '100000001', 'mode': 'pos', 'posState': 'reserved', 'total': 1210000,
            'customer': {'name': 'Asha Rao'}, 'payment': {'title': 'Razorpay'},
            'lines': [
              {'itemId': 10, 'sku': 'OF1', 'name': 'Oil filter', 'productId': 'p', 'ordered': 1, 'canceled': 0, 'refunded': 0, 'reserved': 1},
              {'itemId': 11, 'sku': 'CZ-ALLOY-01', 'name': 'Alloy Wheel Set', 'productId': 'wheel', 'ordered': 1, 'canceled': 0, 'refunded': 0, 'reserved': 0, 'onlineOnly': true},
            ],
          },
        ],
        'products': [_filter, _wheel],
        'suppliers': [{'id': 's', 'name': 'Parts Co'}],
        'locations': [{'id': 'bin', 'kind': 'sellable', 'area': 'Main', 'rack': 'A', 'shelf': '1', 'bin': '01'}],
        'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 5}],
        'settings': {},
      };
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: PickPackPage(orderId: 'mg-1'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('supplier-line-11')), findsOneWidget);
    expect(find.textContaining('Order from supplier'), findsOneWidget);
    // Only the shop item is picked (the online-only line has no pick buttons).
    expect(find.text('0 / 1'), findsOneWidget);
    // Scanning the online-only part picks nothing.
    await tester.enterText(find.byKey(const ValueKey('pick-scan')), '8900000000099');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('ordered from the supplier'), findsOneWidget);

    // Create purchase order: a part without a supplier is asked for.
    await tester.tap(find.text('Create purchase order'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the supplier'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parts Co').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create purchase order').last);
    await tester.pumpAndSettle();
    final asks = app.calls.where((c) => c.$1 == '/online-orders/mg-1/purchase-order').toList();
    expect(asks.length, 2);
    expect(asks.last.$2['suppliers'], {'roof': 's'});
    expect(app.toasts.last, contains('2 purchase orders created as draft'));

    // Pick the shop item, then invoice: only it is sent as a pick.
    await tester.enterText(find.byKey(const ValueKey('pick-scan')), '8901234567890');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Invoice & pack'));
    await tester.tap(find.text('Invoice & pack'));
    await tester.pumpAndSettle();
    final invoice = app.calls.firstWhere((c) => c.$1 == '/online-orders/mg-1/invoice');
    expect(invoice.$2['picks'], [{'itemId': 10, 'qty': 1}]);
    expect(tester.takeException(), isNull);
    app.dispose();
  });
}
