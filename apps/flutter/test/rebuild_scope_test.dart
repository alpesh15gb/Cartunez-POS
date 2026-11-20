import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/catalog_grid.dart';
import 'package:cartunez_pos/ui/screens/billing.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adding a cart line notifies the cart only, not the whole register', () {
    final app = AppState()..snapshot = {'products': [{'id': 'p', 'name': 'Filter', 'retailPrice': 200}]};
    var shell = 0, cart = 0, terms = 0, catalog = 0;
    app.addListener(() => shell++);
    app.cartState.addListener(() => cart++);
    app.cartState.terms.addListener(() => terms++);
    app.catalogState.addListener(() => catalog++);

    app.updateCart({'lines': [{'productId': 'p', 'qty': 1}]});
    expect((shell, cart, terms, catalog), (0, 1, 0, 0));

    app.updateCart({'priceLevel': 'wholesale'});
    expect((shell, cart, terms, catalog), (0, 2, 1, 0));

    // Resuming a parked sale changes stock available to sell.
    app.updateCart({'holdId': 'h1'});
    expect((cart, terms, catalog), (3, 2, 1));
    expect(shell, 1);
    app.dispose();
  });

  testWidgets('the cart pane updates on a scan without the register notifying', (tester) async {
    final app = AppState()..snapshot = {'products': [{'id': 'p', 'name': 'Oil filter', 'retailPrice': 25000}]};
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: Scaffold(body: CartPanel()))));
    expect(find.text('Oil filter'), findsNothing);
    app.updateCart({'lines': [{'productId': 'p', 'qty': 2, 'serials': <String>[]}]});
    await tester.pump();
    expect(find.text('Oil filter'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    app.clearCart();
    await tester.pump();
    expect(find.text('Oil filter'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('scanning a barcode on the counter adds the line and leaves the catalog grid alone', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState()
      ..session = Session(api: '', token: '', user: {'role': 'cashier', 'id': 'c'}, branchId: 'b', organizationId: 'o', expiresAt: '')
      ..snapshot = {
        'products': [{'id': 'p', 'name': 'Oil filter', 'sku': 'OF1', 'barcodes': ['8901234567890'], 'retailPrice': 25000}],
        'locations': [{'id': 'bin', 'kind': 'sellable', 'bin': 'A1'}],
        'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 5}],
        'shifts': [{'id': 's', 'userId': 'c'}],
      };
    final shell = ShellController()..section = 'billing';
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: ShellScope(controller: shell, child: const Scaffold(body: BillingScreen())))));
    final card = tester.element(find.byType(PartCard));
    expect(find.text('Oil filter'), findsOneWidget);
    handleScan(tester.element(find.byType(BillingScreen)), shell, '8901234567890');
    await tester.pump();
    expect(app.cart['lines'], [{'productId': 'p', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}]);
    expect(find.text('Oil filter'), findsNWidgets(2)); // grid card and cart line
    expect(card.dirty, isFalse);
    expect(identical(tester.element(find.byType(PartCard)), card), isTrue);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
