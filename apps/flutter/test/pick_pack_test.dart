// WS-E: pick & pack at phone width: scan to pick, invoice & pack, then ship.
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/online/fulfilment.dart';
import 'package:cartunez_pos/ui/online/pick_pack.dart';
import 'package:cartunez_pos/ui/purchasing/received.dart';
import 'package:cartunez_pos/ui/purchasing/reorder.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Shop extends AppState {
  final calls = <(String, Json)>[];
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    calls.add((path, Map<String, dynamic>.from(body as Map? ?? {})));
    return {'sent': 1, 'failed': 0};
  }

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    calls.add((path, body));
    final order = list('onlineOrders').first;
    if (path.endsWith('/invoice')) {
      order['fulfilment'] = {'status': 'packed', 'invoiceId': 'inv-1', 'invoiceNumber': 'ML-PUNE-1000', 'invoiceTotal': 30000, 'cod': false};
      (order['lines'] as List).first['posInvoiced'] = 2;
      snapshot = {...snapshot, 'onlineOrders': [order]};
      notifyListeners();
      return {'invoice': {'number': 'ML-PUNE-1000'}, 'order': order};
    }
    if (path.endsWith('/ship')) {
      order['fulfilment'] = {...order['fulfilment'] as Map, 'shipment': {'courier': body['courier'], 'tracking': body['tracking'], 'state': 'sent'}};
      snapshot = {...snapshot, 'onlineOrders': [order]};
      notifyListeners();
    }
    return order;
  }
}

Json _order() => {
      'id': 'mg-1', 'number': '100000001', 'mode': 'pos', 'posState': 'reserved', 'total': 30000,
      'customer': {'name': 'Asha Rao'}, 'shipTo': '12 MG Road, Pune, 411001', 'payment': {'title': 'Razorpay'},
      'lines': [
        {'itemId': 10, 'sku': 'ML-FILTER-01', 'name': 'Spin-On Oil Filter', 'productId': 'filter', 'ordered': 2, 'canceled': 0, 'refunded': 0, 'reserved': 2},
      ],
    };

void main() {
  test('stages and quantities', () {
    final o = _order();
    expect(toPickQty((o['lines'] as List).first as Map), 2);
    expect(fulfilmentStage(o), 'To pick');
    expect(canInvoice(o), isTrue);
    expect(canShip(o), isFalse);
    expect(canInvoice({...o, 'mode': 'magento'}), isFalse);
    expect(canShip({...o, 'mode': 'magento', 'posState': 'sold'}), isTrue);
  });

  test('cost warning above the shop threshold', () {
    final app = _Shop()..snapshot = {'products': [{'id': 'p', 'name': 'Pad', 'sku': 'P', 'cost': 10000, 'lastPurchaseCost': 10000}], 'settings': {}};
    expect(costWarning(app, 'p', 10400), isNull);
    expect(costWarning(app, 'p', 11000), contains('10.0%'));
  });

  testWidgets('pick by scanning at phone width, invoice & pack, then ship', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Shop()
      ..snapshot = {
        'onlineOrders': [_order()],
        'products': [{'id': 'filter', 'name': 'Spin-On Oil Filter', 'sku': 'ML-FILTER-01', 'barcodes': ['8900000000002']}],
        'locations': [{'id': 'bin-a1', 'area': 'Main', 'rack': 'A', 'shelf': '1', 'bin': '01', 'kind': 'sellable'}],
        'stock': [{'productId': 'filter', 'binId': 'bin-a1', 'quantity': 24}],
        'settings': {},
      };
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: PickPackPage(orderId: 'mg-1'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Pick every item to invoice'), findsOneWidget);

    // A wrong item is refused; the right barcode picks one unit each time.
    await tester.enterText(find.byKey(const ValueKey('pick-scan')), 'NOPE');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('is not on this order'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await tester.enterText(find.byKey(const ValueKey('pick-scan')), '8900000000002');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pick-scan')), 'ML-FILTER-01');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('already picked'), findsOneWidget);

    await tester.tap(find.text('Invoice & pack'));
    await tester.pumpAndSettle();
    final invoice = app.calls.firstWhere((c) => c.$1 == '/online-orders/mg-1/invoice');
    expect(invoice.$2['picks'], [{'itemId': 10, 'qty': 2}]);
    await tester.scrollUntilVisible(find.text('Print packing slip'), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    expect(find.text('Print packing slip'), findsOneWidget);
    expect(find.textContaining('ML-PUNE-1000'), findsWidgets);

    // Courier and tracking go to Magento.
    await tester.scrollUntilVisible(find.text('Ship & send tracking to Magento'), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.enterText(find.widgetWithText(TextField, 'Courier'), 'Delhivery');
    await tester.enterText(find.widgetWithText(TextField, 'Tracking number'), 'DLV123');
    await tester.ensureVisible(find.text('Ship & send tracking to Magento'));
    await tester.tap(find.text('Ship & send tracking to Magento'));
    await tester.pumpAndSettle();
    expect(app.calls.any((c) => c.$1 == '/online-orders/mg-1/ship' && c.$2['tracking'] == 'DLV123'), isTrue);
    expect(app.calls.any((c) => c.$1 == '/online-orders/shipments/push'), isTrue);
    await tester.scrollUntilVisible(find.text('Mark delivered'), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    expect(find.textContaining('On Magento'), findsOneWidget);
    expect(find.text('Mark delivered'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('payment kinds, credit note flag and held shipments', () {
    final o = {
      ..._order(),
      'fulfilment': {'invoiceId': 'inv-1', 'paymentKind': 'bank', 'paymentDue': 20000, 'shipment': {'state': 'held'}},
    };
    expect(paymentLabel(fulfilmentOf(o)), 'bank transfer / UPI');
    expect(paymentDue(fulfilmentOf(o)), 20000);
    expect(fulfilmentStage(o), 'Shipment not sent');
    expect(canShip(o), isTrue);
    final flagged = {...o, 'fulfilment': {...fulfilmentOf(o), 'creditNoteNeeded': {'invoiceId': 'inv-1', 'invoiceNumber': 'ML-1', 'lines': []}}};
    expect(fulfilmentStage(flagged), 'Credit note needed');
    expect(canShip(flagged), isFalse);
    final cancelled = {...o, 'fulfilment': {...fulfilmentOf(o), 'shipment': {'state': 'cancelled'}}};
    expect(fulfilmentStage(cancelled), 'Nothing to ship');
    expect(canShip(cancelled), isFalse);
  });

  testWidgets('bank transfer payment received and the credit note banner at phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final order = {
      ..._order(),
      'posState': 'sold',
      'payment': {'title': 'Bank Transfer (UPI)'},
      'fulfilment': {
        'status': 'packed', 'invoiceId': 'inv-1', 'invoiceNumber': 'ML-PUNE-1000', 'invoiceTotal': 30000,
        'paymentKind': 'bank', 'paymentDue': 30000, 'cod': false,
        'creditNoteNeeded': {'invoiceId': 'inv-1', 'invoiceNumber': 'ML-PUNE-1000', 'lines': [{'itemId': 10, 'name': 'Spin-On Oil Filter', 'qty': 1}]},
      },
    };
    final app = _Shop()
      ..snapshot = {
        'onlineOrders': [order],
        'products': [{'id': 'filter', 'name': 'Spin-On Oil Filter', 'sku': 'ML-FILTER-01'}],
        'settings': {},
      };
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: PickPackPage(orderId: 'mg-1'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('credit-note-needed')), findsOneWidget);
    expect(find.textContaining('1 × Spin-On Oil Filter'), findsOneWidget);
    expect(find.text('Make credit note'), findsOneWidget);
    // No shipping while the credit note is outstanding.
    expect(find.text('Ship & send tracking to Magento'), findsNothing);
    await tester.tap(find.text('Credit note made'));
    await tester.pumpAndSettle();
    expect(app.calls.any((c) => c.$1 == '/online-orders/mg-1/credit-note/resolve'), isTrue);

    await tester.scrollUntilVisible(find.text('Payment received'), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    expect(find.textContaining('bank transfer / UPI'), findsWidgets);
    await tester.tap(find.text('Payment received'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'UPI / bank reference (UTR)'), 'UTR 4242');
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    final paid = app.calls.firstWhere((c) => c.$1 == '/online-orders/mg-1/payment-received');
    expect(paid.$2['reference'], 'UTR 4242');
    expect(paid.$2['amount'], 30000);
    expect(paid.$2['mode'], 'UPI');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reorder alerts make draft purchase orders at phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Shop()
      ..snapshot = {
        'onlineOrders': [_order()],
        'suppliers': [{'id': 's1', 'name': 'Fictional Auto Supply'}],
        'reorderSuggestions': [
          {'productId': 'filter', 'sku': 'F', 'name': 'Oil Filter', 'available': 2, 'reorderLevel': 5, 'onOrder': 0, 'suggestedQuantity': 8, 'supplierId': 's1'},
          {'productId': 'wiper', 'sku': 'W', 'name': 'Wiper', 'available': 0, 'reorderLevel': 5, 'onOrder': 0, 'suggestedQuantity': 10, 'supplierId': null},
        ],
        'settings': {},
      };
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: ShellScope(controller: ShellController(),
        child: Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: const [ReorderScreen()]))))));
    await tester.pumpAndSettle();
    expect(find.text('No usual supplier'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Order').first, '12');
    await tester.tap(find.text('Create draft purchase orders'));
    await tester.pumpAndSettle();
    final call = app.calls.firstWhere((c) => c.$1 == '/purchase-orders/from-suggestions');
    expect(call.$2['lines'], [{'productId': 'filter', 'quantity': 12}]);
    expect(tester.takeException(), isNull);
  });
}
