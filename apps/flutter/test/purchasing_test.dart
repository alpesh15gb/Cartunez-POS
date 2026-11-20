import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/purchasing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? saved;
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    saved = body;
    return {};
  }
}

void main() {
  testWidgets('receive two parts into a single delivery with one freight amount', (tester) async {
    final app = _Register()..snapshot = {
      'products': [{'id': 'a', 'name': 'Filter', 'sku': 'FA'}, {'id': 'b', 'name': 'Belt', 'sku': 'BB'}],
      'locations': [{'id': 'bin1', 'kind': 'sellable', 'area': 'A', 'rack': '1', 'shelf': '1', 'bin': '1'}],
    };
    final order = {'id': 'po', 'lines': [
      {'productId': 'a', 'quantity': 3, 'received': 1},
      {'productId': 'b', 'quantity': 4, 'received': 0},
    ]};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => receiveOrder(context, order), child: const Text('Receive')))))));
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    Future<void> line(String label, String quantity) async {
      await tester.tap(find.text('Add part'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(label).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), quantity);
      await tester.tap(find.text('Add line'));
      await tester.pumpAndSettle();
    }
    await line('FA · Filter', '1');
    await line('BB · Belt', '3');
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Belt'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '12.50');
    await tester.tap(find.text('Receive into stock'));
    await tester.pumpAndSettle();
    expect(app.saved!['landedCost'], 1250);
    expect(app.saved!['lines'], [
      {'productId': 'a', 'quantity': 1, 'binId': 'bin1', 'serials': []},
      {'productId': 'b', 'quantity': 3, 'binId': 'bin1', 'serials': []},
    ]);
    app.dispose();
  });
}
