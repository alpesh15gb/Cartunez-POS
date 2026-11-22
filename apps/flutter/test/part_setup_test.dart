// QA audit #6 (part setup): required fields first, optional ones marked, and a new part
// is offered "Receive against a supplier bill" or "Adjust stock" right after saving.

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/inventory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  final paths = <String>[];
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    paths.add(path);
    if (path != '/products') return {};
    final saved = {...body, 'id': 'new-part', 'sku': 'AUTO-1'};
    snapshot = {...snapshot, 'products': [...products, saved]};
    return saved;
  }
}

_Register _app({bool fitment = true}) => _Register()..snapshot = {
      'products': <Json>[],
      'suppliers': [{'id': 's', 'name': 'Parts Co'}],
      'locations': [{'id': 'bin1', 'kind': 'sellable', 'area': 'A', 'rack': '1', 'shelf': '1', 'bin': '1'}],
      'settings': {'taxScheme': 'none', 'features': {'fitment': fitment}},
    };

Future<void> _open(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => editProduct(context, const {}), child: const Text('New part')))))));
  await tester.tap(find.text('New part'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('name, price and fitment come before the optional fields', (tester) async {
    final app = _app();
    await _open(tester, app);
    // Reading order (the form lays fields out in columns): row first, then left to right.
    bool before(String a, String b) {
      final pa = tester.getTopLeft(find.text(a).first), pb = tester.getTopLeft(find.text(b).first);
      return pa.dy < pb.dy || (pa.dy == pb.dy && pa.dx < pb.dx);
    }
    expect(before('Part name', 'Retail price'), isTrue);
    expect(before('Retail price', 'Fits'), isTrue);
    expect(before('Fits', 'SKU / item code (optional)'), isTrue);
    expect(before('Fits', 'Brand (optional)'), isTrue);
    for (final label in ['SKU / item code (optional)', 'Category (optional)', 'Barcodes (optional)', 'Purchase cost (optional)']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    app.dispose();
  });

  testWidgets('after saving a new part, Adjust stock opens with the part chosen', (tester) async {
    final app = _app();
    await _open(tester, app);
    await tester.enterText(find.widgetWithText(TextFormField, 'Part name'), 'QA Brake Pad');
    await tester.enterText(find.widgetWithText(TextFormField, 'Retail price'), '90');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('QA Brake Pad saved'), findsOneWidget);
    expect(find.text('Receive against a supplier bill'), findsOneWidget);
    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();
    final part = tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>).first);
    expect(part.initialValue, 'new-part');
    app.dispose();
  });

  testWidgets('after saving a new part, the supplier bill starts with that part', (tester) async {
    final app = _app(fitment: false);
    await _open(tester, app);
    await tester.enterText(find.widgetWithText(TextFormField, 'Part name'), 'QA Brake Pad');
    await tester.enterText(find.widgetWithText(TextFormField, 'Retail price'), '90');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Receive against a supplier bill'));
    await tester.pumpAndSettle();
    expect(find.text('Supplier bill'), findsOneWidget);
    expect(find.text('QA Brake Pad'), findsOneWidget);
    app.dispose();
  });
}
