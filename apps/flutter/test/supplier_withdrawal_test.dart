import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/purchasing/supplier_return.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? saved;
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    expect(path, '/purchase-returns');
    saved = body;
    return {};
  }
}

void main() {
  testWidgets('supplier return sends one distinct serial for each tracked item', (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Register()..snapshot = {
      'products': [{'id': 'p', 'sku': 'TRACK', 'name': 'Radio', 'serialTracked': true}],
      'locations': [{'id': 'bin', 'bin': 'A1', 'kind': 'sellable'}],
    };
    final bill = {'id': 'b', 'lines': [{'productId': 'p', 'quantity': 2, 'cost': 10000,
      'binId': 'bin', 'serials': ['R01', 'R02']}]};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(child: const Text('Return'), onPressed: () =>
          supplierReturn(context, {'id': 's', 'name': 'Supplier'}, bill: bill)))))));
    await tester.tap(find.text('Return'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Sent wrong model');
    final serials = find.widgetWithText(TextFormField, 'Serial numbers');
    await tester.enterText(serials, 'R01, R01');
    await tester.tap(find.text('Return and adjust balance'));
    await tester.pumpAndSettle();
    expect(find.text('Enter one unique serial number per returned unit.'), findsOneWidget);
    expect(app.saved, isNull);
    await tester.enterText(serials, 'R01, R02');
    await tester.tap(find.text('Return and adjust balance'));
    await tester.pumpAndSettle();
    final line = (app.saved!['lines'] as List).single;
    expect(line['serials'], ['R01', 'R02']);
    expect(line['binId'], 'bin');
    expect(app.saved!['billId'], 'b');
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
