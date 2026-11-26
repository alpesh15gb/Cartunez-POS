// Drives Settings › Label printer against a fake network Zebra and checks the
// ZPL it receives. Run: flutter test visual/labels_test.dart --update-goldens
// (needs the demo API on 127.0.0.1:4100)
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/router.dart';
import 'package:cartunez_pos/ui/label_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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
    await _font('Roboto', ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
    // The label preview draws with the app's bundled font.
    await _font('CartunezSans', ['assets/fonts/Roboto-Regular.ttf', 'assets/fonts/Roboto-Medium.ttf', 'assets/fonts/Roboto-Bold.ttf']);
  });

  testWidgets('label printer setup and test label over the network', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-labels');
    final state = AppState();
    const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4100/api/v1');
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(Uri.parse(api).host)) {
      throw StateError('Use a loopback demo API.');
    }
    await tester.runAsync(state.init);
    await tester.runAsync(() => state.login(
        api: api, organizationId: 'demo', branchId: 'pune',
        email: 'owner@motorline.local', password: 'MotorlineDemo123!'));
    // Start from the default design (the demo database keeps earlier runs).
    await tester.runAsync(() => state.mutate('/settings', {'labelLayout': <String, dynamic>{}}));
    await tester.pumpWidget(CartunezApp(state: state));
    await tester.pumpAndSettle();

    final received = <int>[];
    final zebra = (await tester.runAsync(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) => client.listen(received.addAll, onDone: client.destroy));
      return server;
    }))!;

    final router = GoRouter.of(rootNavigatorKey.currentContext!);
    router.go('/settings');
    await tester.pumpAndSettle();
    expect(find.text('Barcode labels'), findsOneWidget);

    // Design the shop label: brand on, MRP, two labels across, an extra line.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Design label'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/labels-00-design-default.png'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Label size'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('75 × 50 mm (3 × 2 in)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Brand'));
    await tester.tap(find.widgetWithText(FilterChip, 'Bin location'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('MRP')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('2')).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Extra line (optional)'), 'Ph 98765 43210');
    await tester.pumpAndSettle();
    // Make the price extra large, then drag the part name 10 mm to the right.
    final priceRow = find.ancestor(of: find.text('Price').last, matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: priceRow, matching: find.text('XL')));
    await tester.pumpAndSettle();
    // Barcode: thinner bars, taller.
    for (final (row, size) in [('Width', 'S'), ('Height', 'L')]) {
      final r = find.ancestor(of: find.text(row).last, matching: find.byType(Row)).first;
      await tester.ensureVisible(r);
      await tester.tap(find.descendant(of: r, matching: find.text(size)));
      await tester.pumpAndSettle();
    }
    final previewFinder = find.descendant(of: find.byType(AlertDialog), matching: find.byType(LabelPreview));
    await tester.ensureVisible(previewFinder);
    await tester.pumpAndSettle();
    final preview = tester.getRect(previewFinder);
    final pxPerMm = preview.width / 152; // two 75 mm labels + 2 mm gap
    final nameAt = preview.topLeft + Offset(4 * pxPerMm, 2.4 * pxPerMm);
    await tester.dragFrom(nameAt, Offset(10 * pxPerMm, 0));
    await tester.pumpAndSettle();
    expect(find.text('Part name selected · drag it to move'), findsOneWidget);
    expect(find.text('Reset positions'), findsOneWidget);
    await expectLater(previewFinder, matchesGoldenFile('out/labels-01b-dragged.png'));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/labels-01-design.png'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save design'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    final saved = state.settings['labelLayout'] as Map;
    expect(saved['brand'], true);
    expect(saved['price'], 'mrp');
    expect(saved['columns'], 2);
    expect(saved['extra'], 'Ph 98765 43210');
    expect((saved['sizes'] as Map)['price'], 'xlarge');
    expect(saved['barcodeWidth'], 'small');
    expect(saved['barcodeHeight'], 'large');
    final namePos = (saved['positions'] as Map)['name'] as Map;
    expect((namePos['x'] as num).toDouble(), closeTo(11.2, 1.5));

    // This device prints to a network Zebra.
    final printer = find.widgetWithText(OutlinedButton, 'Printer');
    await tester.ensureVisible(printer);
    await tester.pump();
    await tester.runAsync(() => tester.tap(printer));
    final printerDialog = find.text('Label printer on this device');
    for (var attempt = 0; attempt < 160 && printerDialog.evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(printerDialog, findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zebra printer on the network (IP address)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Zebra IP address'), '127.0.0.1');
    await tester.tap(find.textContaining('More options'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Network port'), '${zebra.port}');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(state.labelPrinter['mode'], 'zebra-network');
    expect(find.textContaining('Zebra at 127.0.0.1'), findsOneWidget);

    final testLabel = find.text('Print test label');
    await tester.ensureVisible(testLabel);
    await tester.pump();
    await tester.runAsync(() => tester.tap(testLabel));
    for (var attempt = 0; attempt < 120 && received.isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    final zpl = utf8.decode(received);
    expect(zpl, startsWith('^XA'), reason: tester.widgetList<Text>(find.descendant(
      of: find.byType(SnackBar), matching: find.byType(Text),
    )).map((widget) => widget.data).join(' '));
    expect(zpl, contains('^PW1215^LL400')); // two 75 mm labels + 2 mm gap at 203 dpi
    expect(zpl, contains('MRP Rs.'));
    expect(zpl, contains('Incl. of all taxes'));
    expect(zpl, contains('Ph 98765 43210'));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/labels-02-settings.png'));

    // Print labels for a part from Inventory.
    received.clear();
    router.go('/catalog/parts');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Print label').first);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/labels-03-print.png'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Copies of each label'), '3');
    await tester.runAsync(() async {
      await tester.tap(find.text('Print labels'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    // 3 copies, two across the roll: 2 rows (the last row has one label).
    final job = utf8.decode(received);
    expect('^XA'.allMatches(job).length, 2);
    expect('^BY'.allMatches(job).length, 3);
    await tester.runAsync(zebra.close);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(state.logout);
    state.dispose();
  });
}
