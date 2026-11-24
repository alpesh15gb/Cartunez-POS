// QA audit fixes 4, 5, 12–16: Settings reflow, workspace tab strip overflow,
// reports default run and KPI labels, online stock labels, online-order
// queues, zero collections, warranty prerequisite and transfers.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/screens/online.dart';
import 'package:cartunez_pos/ui/screens/reports.dart';
import 'package:cartunez_pos/ui/screens/settings.dart';
import 'package:cartunez_pos/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Register extends AppState {
  final calls = <String>[];
  Map<String, dynamic> Function(String path) reply = (_) => {'rows': []};
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    calls.add(path);
    return reply(path);
  }
}

_Register _signedIn([Map<String, dynamic> data = const {}, Map<String, dynamic> settings = const {}]) => _Register()
  ..ready = true
  ..lastSync = '2026-11-21T09:00:00Z'
  ..session = Session(
    api: 'https://pos.example.test/api/v1',
    token: 't',
    user: {'id': 'u1', 'name': 'Asha', 'role': 'owner'},
    branchId: 'main',
    organizationId: 'org',
    expiresAt: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
  )
  ..snapshot = {
    'settings': {
      'features': {'onlineStore': true},
      'integrations': {
        'magento': {'enabled': true, 'tokenSet': true, 'baseUrl': 'https://shop.example.test/a/long/store/path', 'branchId': 'main'},
      },
      ...settings,
    },
    'business': {'legalName': 'Cartunez Motors', 'address': 'MG Road'},
    'branch': {'name': 'Main'},
    'branches': [
      {'id': 'main', 'name': 'Main'},
    ],
    ...data,
  };

Future<void> _open(WidgetTester tester, AppState app, String location, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CartunezApp(state: app, prefs: UiPrefs(), initialLocation: location));
  await tester.pumpAndSettle();
}

String _location(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.toString();

void main() {
  group('QA #4 Settings cards', () {
    test('columns follow the width with a minimum card width', () {
      expect(settingsColumns(390, 5), 1);
      expect(settingsColumns(600, 5), 1);
      expect(settingsColumns(700, 5), 2);
      expect(settingsColumns(1000, 5), 3);
      expect(settingsColumns(2000, 5), 3);
      expect(settingsColumns(2000, 2), 2);
    });

    for (final width in [924.0, 1163.0]) {
      testWidgets('at ${width.toInt()} px the cards sit in 2-3 columns, at least the minimum wide', (tester) async {
        await _open(tester, _signedIn(), '/settings', Size(width, 900));
        final titles = ['Shop', 'You', 'Online store', 'Barcode labels'];
        final lefts = <double>{};
        for (final t in titles) {
          final card = find.ancestor(of: find.text(t).first, matching: find.byType(Card)).first;
          final rect = tester.getRect(card);
          expect(rect.width, greaterThanOrEqualTo(settingsCardMinWidth - 8), reason: '$t card too narrow');
          lefts.add(rect.left.roundToDouble());
        }
        expect(lefts.length, inInclusiveRange(2, 3));
        // "Test connection" stays on one line.
        final button = tester.getSize(find.text('Test connection'));
        final line = tester.getSize(find.text('Magento settings'));
        expect(button.height, line.height);
      });
    }

    testWidgets('one column on a phone', (tester) async {
      await _open(tester, _signedIn(), '/settings', const Size(390, 844));
      final shop = tester.getRect(find.ancestor(of: find.text('Shop').first, matching: find.byType(Card)).first);
      final you = tester.getRect(find.ancestor(of: find.text('You').first, matching: find.byType(Card)).first);
      expect(shop.left, you.left);
      expect(you.top, greaterThan(shop.bottom));
    });
  });

  group('Catalog navigation', () {
    for (final width in [390.0, 924.0, 1163.0]) {
      testWidgets('at ${width.toInt()} px six primary tabs fit and secondary tools stay reachable', (tester) async {
        await _open(tester, _signedIn(), '/catalog/parts', Size(width, 900));

        final parts = find.byKey(const ValueKey('workspace-tab-parts'));
        final warranty = find.byKey(const ValueKey('workspace-tab-serials'));
        final tabs = find.byWidgetPredicate((widget) =>
          widget is ChoiceChip && widget.key.toString().contains('workspace-tab-'));
        expect(tabs, findsNWidgets(6));
        for (final tab in tabs.evaluate()) {
          final box = tab.renderObject! as RenderBox;
          expect(box.localToGlobal(Offset.zero).dx, greaterThanOrEqualTo(0));
          expect(box.localToGlobal(box.size.bottomRight(Offset.zero)).dx, lessThanOrEqualTo(width));
        }
        expect(find.byTooltip('Scroll tabs right'), findsNothing);

        for (final (action, path) in [
          ('Import parts', '/catalog/import'),
          ('Stock counts', '/catalog/counts'),
          ('Labels', '/catalog/labels'),
        ]) {
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(_location(tester), path);
          expect(tester.widget<ChoiceChip>(parts).selected, isTrue);
          await tester.tap(parts);
          await tester.pumpAndSettle();
        }

        await tester.tap(warranty);
        await tester.pumpAndSettle();
        expect(_location(tester), '/catalog/serials');
        await tester.tap(find.text('Claims & core refunds'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/catalog/warranty');
        expect(tester.widget<ChoiceChip>(warranty).selected, isTrue);
      });
    }

    testWidgets('cashiers can open Labels and Warranty lookup without stock tools', (tester) async {
      final app = _signedIn();
      app.session!.user['role'] = 'cashier';
      await _open(tester, app, '/catalog/parts', const Size(390, 844));
      expect(find.text('Labels'), findsOneWidget);
      expect(find.text('Import parts'), findsNothing);
      expect(find.text('Stock counts'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-serials')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/catalog/serials');
      expect(find.text('Claims & core refunds'), findsNothing);
    });
  });


  group('QA #12 reports', () {
    testWidgets('opens on daily sales for today, already run, with the report name as heading', (tester) async {
      final app = _signedIn();
      app.reply = (path) => {
            'name': 'daily-sales', 'timeZone': 'Asia/Kolkata', 'currency': 'INR',
            'rows': [
              {'day': '2026-11-21', 'sales': 1, 'beforeDiscount': 10000, 'discount': 1000, 'gross': 9000, 'returns': 0, 'coreReturns': 0, 'net': 9000},
            ],
            'totals': {'sales': 1, 'beforeDiscount': 10000, 'discount': 1000, 'gross': 9000, 'returns': 0, 'coreReturns': 0, 'net': 9000},
          };
      await _open(tester, app, '/reports', const Size(1163, 900));
      expect(app.calls.where((c) => c.startsWith('/reports/daily-sales')), hasLength(1));
      final today = app.calls.first;
      final from = Uri.parse(today).queryParameters['dateFrom'];
      expect(from, Uri.parse(today).queryParameters['dateTo']);
      expect(find.byKey(const ValueKey('report-heading')), findsOneWidget);
      expect(find.text('Daily sales report'), findsOneWidget);
      expect(find.text('Billed before discount'), findsWidgets);
      expect(find.text('Net billed'), findsWidgets);
      expect(find.text('Discounts'), findsWidgets);
      expect(find.byKey(const ValueKey('kpi-definitions')), findsOneWidget);
      // Run and Export sit in the same group as the report picker.
      final group = find.byKey(const ValueKey('report-primary'));
      expect(find.descendant(of: group, matching: find.text('Run report')), findsOneWidget);
      final runLabel = find.text('Run report');
      final runButton = tester.widget<FilledButton>(
        find.ancestor(of: runLabel, matching: find.byWidgetPredicate((widget) => widget is FilledButton)),
      );
      final foreground = DefaultTextStyle.of(tester.element(runLabel)).style.color!;
      final background = runButton.style!.backgroundColor!.resolve(const <WidgetState>{})!;
      expect(foreground, Colors.white);
      expect((foreground.computeLuminance() + 0.05) / (background.computeLuminance() + 0.05), greaterThanOrEqualTo(7));
      expect(find.text('Parts import'), findsNothing);
      expect(find.descendant(of: group, matching: find.text('Export')), findsOneWidget);
    });

    testWidgets('a cleared report shows a clear prompt, not a blank area', (tester) async {
      final app = _signedIn();
      await _open(tester, app, '/reports/tax', const Size(924, 900));
      // Clear the date range: the report waits for Run again.
      await tester.tap(find.byTooltip('All dates'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-empty-prompt')), findsOneWidget);
      expect(find.textContaining('Press Run report'), findsOneWidget);
    });

    test('exports use the same KPI names', () {
      final csv = reportCsv([
        {'day': '2026-11-21', 'beforeDiscount': 10000, 'discount': 1000, 'gross': 9000, 'net': 9000},
      ], currency: 'INR', labels: salesKpiLabels);
      expect(csv.split('\r\n').first, '"day","Billed before discount (INR)","Discounts (INR)","Net billed (INR)","Net after refunds (INR)"');
      expect(reportLabel('gross'), 'Net billed');
      expect(reportLabel('beforeDiscount'), 'Billed before discount');
    });
  });

  test('QA #13 online stock labels never read as live when unpublished', () {
    expect(onlineStockLabel(inShop: 2, online: 1, live: false), '2 in shop · Available to publish: 1 (after buffer)');
    expect(onlineStockLabel(inShop: 2, online: 1, live: true), '2 in shop · On website: 1 available');
    expect(onlineStockLabel(inShop: null, online: null, live: true), 'On website: — available');
  });

  group('QA #14 online orders', () {
    final sold = {'id': 'o1', 'number': '1001', 'posState': 'sold', 'createdAt': '2026-11-20T10:00:00Z', 'customer': {'name': 'Ravi'}, 'lines': []};
    testWidgets('opens on All when nothing needs attention; empty queues name themselves', (tester) async {
      await _open(tester, _signedIn({'onlineOrders': [sold]}), '/orders/online', const Size(1163, 900));
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All')).selected, isTrue);
      expect(find.text('#1001'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Needs attention'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing needs attention.'), findsOneWidget);
      expect(find.textContaining('No online orders yet'), findsNothing);
      await tester.tap(find.text('Show all orders'));
      await tester.pumpAndSettle();
      expect(find.text('#1001'), findsOneWidget);
    });

    testWidgets('opens on Needs attention when an order needs it', (tester) async {
      final reserved = {...sold, 'id': 'o2', 'number': '1002', 'posState': 'reserved'};
      await _open(tester, _signedIn({'onlineOrders': [sold, reserved]}), '/orders/online', const Size(1163, 900));
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Needs attention')).selected, isTrue);
    });
  });

  testWidgets('QA #15 zero collections are not shown as a warning', (tester) async {
    final app = _signedIn();
    app.reply = (_) => {'rows': [], 'total': 0};
    await _open(tester, app, '/people/collections', const Size(1163, 900));
    final total = tester.widget<Text>(find.byKey(const ValueKey('collections-total')));
    expect(total.style?.color, Brand.forest);
  });

  testWidgets('QA #15 warranty links its prerequisite to Returns & exchange', (tester) async {
    await _open(tester, _signedIn(), '/catalog/warranty', const Size(1163, 900));
    expect(find.byKey(const ValueKey('warranty-prerequisite')), findsOneWidget);
    await tester.tap(find.text('Go to Returns & exchange'));
    await tester.pumpAndSettle();
    expect(_location(tester), '/orders/returns');
  });

  group('QA #16 send stock', () {
    testWidgets('explains that a second branch is needed', (tester) async {
      await _open(tester, _signedIn(), '/catalog/transfers', const Size(1163, 900));
      await tester.tap(find.text('Send stock'));
      await tester.pumpAndSettle();
      expect(find.text('Add a second branch first'), findsOneWidget);
      expect(find.text('Send stock to another branch'), findsNothing);
    });

    testWidgets('Send stays disabled until the required fields are filled', (tester) async {
      final app = _signedIn({
        'branches': [
          {'id': 'main', 'name': 'Main'},
          {'id': 'pune', 'name': 'Pune'},
        ],
      });
      await _open(tester, app, '/catalog/transfers', const Size(1163, 900));
      await tester.tap(find.text('Send stock'));
      await tester.pumpAndSettle();
      expect(find.text('Send stock to another branch'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, 'Send');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
    });
  });
}
