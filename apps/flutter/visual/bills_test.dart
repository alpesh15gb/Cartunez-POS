// Purchasing end to end through the real screens: enter a supplier bill with a
// new item, see the supplier balance, and the supplier's ledger.
// Run: flutter test visual/bills_test.dart --update-goldens
// (needs the demo API on 127.0.0.1:4100, started from this repo)
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/purchasing/bill_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    loader.addFont(File(file).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

void main() {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter'}/bin/cache/artifacts/material_fonts';
  setUpAll(() async {
    HttpOverrides.global = null;
    for (final family in ['Roboto', 'Segoe UI']) {
      await _font(family, ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    }
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  });

  testWidgets('enter a supplier bill and see the supplier balance', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-bills');
    final state = AppState();
    const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4100/api/v1');
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(Uri.parse(api).host)) {
      throw StateError('Use a loopback demo API.');
    }
    await tester.runAsync(state.init);
    await tester.runAsync(() => state.login(
        api: api, organizationId: 'demo', branchId: 'pune',
        email: 'owner@motorline.local', password: 'MotorlineDemo123!'));
    final run = DateTime.now().millisecondsSinceEpoch % 100000;
    final supplier = await tester.runAsync(() => state.mutate('/suppliers', {'name': 'Sri Auto Spares $run', 'phone': '9000000000', 'openingBalance': 150000}));
    final part = state.products.singleWhere((p) => p['sku'] == 'ML-FILTER-01');
    final stockBefore = state.available(part['id']);
    await tester.pumpWidget(CartunezApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Purchasing').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supplier bills').first);
    await tester.pumpAndSettle();
    expect(find.byType(BillsScreen), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/bills-01-list.png'));

    await tester.tap(find.text('Enter supplier bill').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sri Auto Spares $run').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Bill / note no.'), 'H-$run');
    await tester.pumpAndSettle();

    // Add an existing part by typing its name.
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item'), 'oil filter');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Spin-On Oil Filter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '6');
    await tester.enterText(find.widgetWithText(TextField, 'Unit cost'), '210');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/bills-02-item.png'));
    await tester.tap(find.text('Add to bill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Add to bill'), findsNothing);
    final freight = find.widgetWithText(TextField, 'Freight / other charges');
    final paid = find.widgetWithText(TextField, 'Paid now');
    await tester.ensureVisible(freight);
    await tester.enterText(freight, '50');
    await tester.ensureVisible(paid);
    await tester.enterText(paid, '500');
    final payment = find.widgetWithText(DropdownButtonFormField<String>, 'Paid by');
    await tester.ensureVisible(payment);
    await tester.pump();
    await tester.tap(payment);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank transfer').last);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/bills-03-bill.png'));

    await tester.runAsync(() => tester.tap(find.text('Save bill · add to stock')));
    final confirmation = find.text('Bill saved · goods received');
    for (var i = 0; i < 160 && (confirmation.evaluate().isEmpty || state.syncing); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(state.syncing, isFalse);
    await tester.pumpAndSettle();
    expect(confirmation, findsOneWidget);
    expect(state.available(part['id']), stockBefore + 6);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/bills-04-saved.png'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('H-$run'), findsOneWidget);

    // Supplier balance: 1,500 old + 1,310 bill - 500 paid = 2,310.
    expect(state.partyBalance('suppliers', supplier['id']), 231000);
    await tester.tap(find.text('Suppliers').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('2,310'), findsWidgets);
    await tester.runAsync(() async {
      await tester.tap(find.text('Sri Auto Spares $run'));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/bills-05-ledger.png'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(state.logout);
    state.dispose();
  });
}
