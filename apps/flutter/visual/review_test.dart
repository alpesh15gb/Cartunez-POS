// UI/UX review: every workspace and key sub-screen at phone, tablet/web and
// desktop sizes, plus dark and high-contrast for Counter and Dashboard.
// Layout errors (overflows) are collected into out/review/<size>-errors.txt
// instead of failing the run, so one bad screen does not hide the rest.
// Run: flutter test visual/review_test.dart --update-goldens
// (needs the demo API on 127.0.0.1:4100: PORT=4100 SEED_DEMO=true npx tsx src/server.ts)
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/router.dart';
import 'package:cartunez_pos/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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
    for (final family in ['Roboto', 'Segoe UI']) {
      await _font(family, ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf', '$fonts/roboto-black.ttf']);
    }
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('tablet', const Size(900, 1000)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('review on $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final errors = <String>[];
      var current = 'start';
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        final text = details.exceptionAsString().split('\n').first;
        errors.add('[$current] $text');
      };

      LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-review');
      final state = AppState();
      final prefs = UiPrefs();
      await tester.runAsync(state.init);
      await tester.runAsync(() => state.login(
          api: api, organizationId: 'demo', branchId: 'pune', email: 'owner@motorline.local', password: 'MotorlineDemo123!'));
      await tester.runAsync(() async {
        try {
          await state.mutate('/settings', {'upiVpa': 'motorline@okhdfcbank', 'upiPayeeName': 'Motorline Auto Parts'});
        } catch (_) {}
        if (state.list('customerVehicles').isEmpty && state.list('customers').isNotEmpty) {
          try {
            await state.mutate('/customer-vehicles', {'regNo': 'MH12AB1234', 'make': 'Maruti Suzuki', 'model': 'Swift',
                'year': 2019, 'odo': 42150, 'customerId': state.list('customers').first['id']});
            await state.sync();
          } catch (e) {
            // ignore: avoid_print
            print('vehicle create failed: $e');
          }
        }
        final vehicles = state.list('customerVehicles');
        // ignore: avoid_print
        print('data: jobs=${state.list('jobs').length} vehicles=${vehicles.length} online=${state.list('onlineOrders').length}');
        for (final v in vehicles) {
          if (state.list('jobs').isNotEmpty) break;
          try {
            await state.mutate('/jobs', {'vehicleId': v['id'], 'customerId': v['customerId'], 'bay': 'Bay 2', 'odo': 42150,
                'complaint': 'Brake noise from front left; check pads and service due.'});
          } catch (e) {
            // ignore: avoid_print
            print('job create failed: $e');
          }
          await state.sync();
        }
        await state.sync();
      });

      await tester.pumpWidget(_ReviewApp(state: state, prefs: prefs));
      await tester.pumpAndSettle();

      Future<void> settle([int rounds = 6]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        try {
          await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
        } catch (_) {}
      }

      var index = 1;
      Future<void> shot(String label) async {
        current = label;
        // ignore: avoid_print
        print('shot $label');
        await settle(2);
        try {
          await expectLater(find.byType(MaterialApp),
              matchesGoldenFile('out/review/$name-${(index++).toString().padLeft(2, '0')}-$label.png'));
        } catch (e) {
          errors.add('[$label] screenshot failed: $e');
        }
      }

      Future<bool> tap(Finder finder, {bool last = false}) async {
        if (finder.evaluate().isEmpty) {
          errors.add('[$current] not found: $finder');
          return false;
        }
        // ignore: avoid_print
        print('tap [$current]');
        try {
          final target = last ? finder.last : finder.first;
          await tester.ensureVisible(target);
          await tester.pump();
          await tester.runAsync(() async => tester.tap(target, warnIfMissed: false));
          await settle();
          return true;
        } catch (e) {
          errors.add('[$current] tap failed $finder: $e');
          return false;
        }
      }

      void closeOverlays() => rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);

      Future<void> go(String path) async {
        closeOverlays();
        await settle(1);
        current = path;
        GoRouter.of(rootNavigatorKey.currentContext!).go(path);
        await settle();
      }

      // Counter: two items, held bills, payment sheet, UPI QR.
      await go('/counter');
      await shot('counter-empty');
      for (final part in ['Engine Air Filter', 'Drive Belt']) {
        if (await tap(find.byTooltip('Add $part'))) {
          if (find.text('Add to sale').evaluate().isNotEmpty) await tap(find.text('Add to sale'));
        }
      }
      await shot('counter-cart');
      final pill = find.byKey(const ValueKey('cart-pill'));
      if (pill.evaluate().isNotEmpty) {
        await tap(pill);
        await shot('counter-cart-sheet');
      }
      if (find.textContaining('Recall').evaluate().isNotEmpty) {
        await tap(find.textContaining('Recall'));
        await shot('counter-held-bills');
        await tap(find.byIcon(Icons.close), last: true);
      }
      // Payment: the UPI quick button opens the payment sheet on UPI; fall back to Checkout.
      if (find.widgetWithText(OutlinedButton, 'UPI').evaluate().isNotEmpty) {
        await tap(find.widgetWithText(OutlinedButton, 'UPI'));
      } else if (find.textContaining('Checkout').evaluate().isNotEmpty) {
        await tap(find.textContaining('Checkout'), last: true);
      } else {
        await tap(find.textContaining('Pay'), last: true);
      }
      if (find.text('Open shift').evaluate().isNotEmpty) {
        await shot('counter-open-shift');
        await tap(find.widgetWithText(FilledButton, 'Open shift'));
        await settle(15);
      }
      await shot('counter-payment');
      if (find.textContaining('Show UPI QR').evaluate().isEmpty) await tap(find.text('UPI'), last: true);
      if (await tap(find.textContaining('Show UPI QR'))) {
        await shot('counter-upi-qr');
        if (find.byTooltip('Close').evaluate().isNotEmpty) {
          await tap(find.byTooltip('Close'));
        } else {
          await tap(find.byIcon(Icons.close));
        }
      }
      // Finish as cash so Orders and the returns desk have a bill.
      if (find.text('Complete sale').evaluate().isNotEmpty) {
        await tap(find.text('Cash'), last: true);
        await tap(find.text('Complete sale'));
        for (var i = 0; i < 60 && find.text('SALES RECEIPT').evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 30));
        }
        await shot('counter-receipt');
        if (find.text('Next customer').evaluate().isNotEmpty) await tap(find.text('Next customer'));
        await tester.runAsync(state.sync);
      }

      // Themes for Counter and Dashboard.
      closeOverlays();
      await settle();
      for (final look in [Appearance.dark, Appearance.highContrast]) {
        prefs.setAppearance(look);
        await go('/counter');
        await shot('counter-${look.name}');
        await go('/dashboard');
        await shot('dashboard-${look.name}');
      }
      prefs.setAppearance(Appearance.light);
      await settle();

      // Orders.
      await go('/orders/invoices');
      await shot('orders-invoices');
      await go('/orders/returns');
      await shot('orders-returns');
      final invoice = state.list('invoices').firstOrNull;
      if (invoice != null) {
        await tester.enterText(find.byType(TextField).last, '${invoice['number']}');
        await tap(find.text('Find bill'));
        await settle(10);
        await shot('orders-returns-found');
      }
      await go('/orders/online');
      await shot('orders-online');
      if (state.list('onlineOrders').isNotEmpty) {
        await tap(find.textContaining('Pick'));
        await shot('orders-pick-pack');
      }

      // Catalog.
      await go('/catalog/parts');
      await shot('catalog-parts');
      await go('/catalog/labels');
      await shot('catalog-labels');

      // Purchasing.
      for (final tab in ['bills', 'reorder', 'cost-changes']) {
        await go('/purchasing/$tab');
        await shot('purchasing-$tab');
      }

      // People.
      await go('/people/customers');
      await shot('people-customers');
      final customers = state.list('customers');
      final withVehicle = state.list('customerVehicles').map((v) => v['customerId']).toSet();
      final customer = customers.where((c) => withVehicle.contains(c['id'])).firstOrNull ?? customers.firstOrNull;
      if (customer != null) {
        await go('/people/customers/${customer['id']}');
        await shot('people-customer-360');
      }
      await go('/people/vehicles');
      await shot('people-vehicles');
      await go('/people/collections');
      await shot('people-collections');

      // Workshop.
      await go('/orders/jobs');
      await shot('workshop-board');
      final job = state.list('jobs').firstOrNull;
      if (job != null) {
        await go('/orders/jobs/${job['id']}');
        await shot('workshop-job-card');
      }

      // Shift.
      await go('/shift');
      await shot('shift-home');
      if (find.text('Close shift').evaluate().isEmpty && find.text('Open shift').evaluate().isNotEmpty) {
        await tap(find.text('Open shift'));
        await tap(find.widgetWithText(FilledButton, 'Open shift'));
        await settle(15);
        closeOverlays();
        await settle();
        await shot('shift-home-open');
      }
      if (await tap(find.text('Close shift'))) await shot('shift-close-dialog');

      // Dashboard, reports, settings.
      await go('/dashboard');
      await shot('dashboard');
      await go('/reports');
      await shot('reports');
      if (find.text('Run report').evaluate().isNotEmpty) await tap(find.text('Run report'));
      await settle(10);
      await shot('reports-run');
      if (await tap(find.text('Export'))) await shot('reports-export');
      closeOverlays();
      await go('/settings');
      await shot('settings');

      closeOverlays();
      await settle();
      FlutterError.onError = original;
      Directory('visual/out/review').createSync(recursive: true);
      File('visual/out/review/$name-errors.txt').writeAsStringSync(errors.join('\n'));
      await tester.runAsync(() async {
        try {
          await state.logout();
        } catch (_) {}
      });
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}

/// The production theme with an explicit family on the few styles that have
/// none (button and snack-bar text). On a device those use the system font;
/// in `flutter test` a missing family renders as black boxes, which would
/// hide every button label in the screenshots.
ThemeData _testTheme(Appearance look) {
  final t = buildTheme(look);
  WidgetStatePropertyAll<TextStyle> family(ButtonStyle? s, FontWeight w) =>
      WidgetStatePropertyAll((s?.textStyle?.resolve({}) ?? TextStyle(fontWeight: w)).copyWith(fontFamily: 'Roboto'));
  return t.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: t.filledButtonTheme.style!.copyWith(textStyle: family(t.filledButtonTheme.style, FontWeight.w700))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: t.outlinedButtonTheme.style!.copyWith(textStyle: family(t.outlinedButtonTheme.style, FontWeight.w600))),
    snackBarTheme: t.snackBarTheme.copyWith(contentTextStyle: t.snackBarTheme.contentTextStyle?.copyWith(fontFamily: 'Roboto')),
  );
}

/// Same wiring as CartunezApp (scopes, route guard, router), with [_testTheme].
class _ReviewApp extends StatefulWidget {
  const _ReviewApp({required this.state, required this.prefs});
  final AppState state;
  final UiPrefs prefs;
  @override
  State<_ReviewApp> createState() => _ReviewAppState();
}

class _ReviewAppState extends State<_ReviewApp> {
  late final RouteGuard guard = RouteGuard(widget.state);
  late final GoRouter router = buildRouter(widget.state, refresh: guard);

  @override
  void dispose() {
    router.dispose();
    guard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
        state: widget.state,
        child: UiPrefsScope(
          prefs: widget.prefs,
          child: ListenableBuilder(
            listenable: widget.prefs,
            builder: (context, _) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              theme: _testTheme(widget.prefs.appearance),
              routerConfig: router,
            ),
          ),
        ),
      );
}
