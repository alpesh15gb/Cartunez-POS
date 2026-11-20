// Renders every screen against a running demo API and writes PNGs for review.
// Run: flutter test visual --update-goldens   (needs the API on 127.0.0.1:4100)
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4100/api/v1');

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
    await _font('Roboto', ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf', '$fonts/roboto-black.ttf']);
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  });

  for (final (name, size) in [('desktop', const Size(1440, 900)), ('phone', const Size(400, 860))]) {
    testWidgets('screens on $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-visual');
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(CartunezApp(state: state));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-01-login.png'));

      await tester.runAsync(() => state.login(
            api: api,
            organizationId: 'demo',
            branchId: 'pune',
            email: 'owner@motorline.local',
            password: 'MotorlineDemo123!',
          ));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          final image = (element.widget as Image).image;
          await precacheImage(image, element);
        }
      });
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-02-billing.png'));

      // Exact SKU lookup must show the match even when catalog rows were copied.
      final search = tester.widgetList<TextField>(find.byType(TextField))
          .firstWhere((field) => field.controller != null).controller!;
      search.text = 'ML-FILTER-01';
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add Spin-On Oil Filter'), findsOneWidget);
      search.clear();
      await tester.pumpAndSettle();

      // Put two parts in the sale and open checkout.
      await tester.tap(find.byTooltip('Add Engine Air Filter'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-03-add-part.png'));
      await tester.tap(find.text('Add to sale'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(name == 'phone' ? 'Add 45Ah Car Battery' : 'Add Drive Belt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to sale'));
      await tester.pumpAndSettle();
      if (name == 'phone') {
        await tester.tap(find.textContaining('View sale'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-04-cart.png'));
        await tester.tapAt(const Offset(200, 20));
        await tester.pumpAndSettle();
        if (find.byType(BottomSheet).evaluate().isNotEmpty) {
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
          await tester.pumpAndSettle();
        }
      } else {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-04-cart.png'));
        await tester.tap(find.text('Checkout  (F6)'));
        await tester.pumpAndSettle();
        if (find.text('Open shift').evaluate().isNotEmpty) {
          await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, 'Open shift')));
          for (var i = 0; i < 200 && find.text('Complete sale').evaluate().isEmpty; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await tester.pump(const Duration(milliseconds: 30));
          }
          expect(find.text('Complete sale'), findsOneWidget);
          await tester.pumpAndSettle();
        }
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-05-checkout.png'));
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
      }

      var index = 6;
      for (final area in ['Sales', 'Customers', 'Inventory', 'Purchasing', 'Dashboard', 'Reports', 'Settings']) {
        final target = find.text(area);
        if (target.evaluate().isEmpty) {
          await tester.tap(find.text('More'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(area).last);
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('out/$name-${(index++).toString().padLeft(2, '0')}-${area.toLowerCase()}.png'));
      }
      if (name == 'desktop') {
        await tester.tap(find.text('Inventory').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add part'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name-20-new-part.png'));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      state.dispose();
    });
  }
}
