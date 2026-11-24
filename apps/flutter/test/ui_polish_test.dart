// UI polish: phone record pages, the sub-tab strip, the search box flag and
// the refund breakdown in the expected drawer cash.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Register extends AppState {
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => {'rows': []};
}

AppState _signedIn([Map<String, dynamic> data = const {}]) => _Register()
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
    'settings': {},
    'branch': {'name': 'Main'},
    ...data,
  };

Future<void> _open(WidgetTester tester, AppState app, String location, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CartunezApp(state: app, prefs: UiPrefs(), initialLocation: location));
  await tester.pumpAndSettle();
}

String _location(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('a phone record page has a compact back-arrow header and no search box', (tester) async {
    await _open(tester, _signedIn(), '/people/vehicles/V404');
    expect(find.byKey(const ValueKey('record-app-bar')), findsOneWidget);
    expect(find.text('People & vehicles'), findsNothing);
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.widgetWithText(TextField, 'Search this list'), findsNothing);

    await tester.tap(find.byTooltip('Back to vehicles'));
    await tester.pumpAndSettle();
    expect(_location(tester), '/people/vehicles');
    expect(find.byKey(const ValueKey('record-app-bar')), findsNothing);
    expect(find.text('People & vehicles'), findsOneWidget);
  });

  testWidgets('the same record page keeps the workspace heading on desktop', (tester) async {
    await _open(tester, _signedIn(), '/people/vehicles/V404', size: const Size(1400, 900));
    expect(find.byKey(const ValueKey('record-app-bar')), findsNothing);
    expect(find.text('People & vehicles'), findsWidgets);
  });

  testWidgets('the selected sub-tab stays visible on a phone', (tester) async {
    await _open(tester, _signedIn(), '/settings');
    final tab = find.byKey(const ValueKey('workspace-tab-settings'));
    expect(tester.widget<ChoiceChip>(tab).selected, isTrue);
    final rect = tester.getRect(tab);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    // Settings does not read the shared search box, so it is hidden.
    expect(find.widgetWithText(TextField, 'Search'), findsNothing);
  });

  testWidgets('list tabs keep the search box', (tester) async {
    await _open(tester, _signedIn(), '/people/customers');
    expect(find.byType(TextField), findsWidgets);
    expect(tabById('customers')!.search, isTrue);
    expect(tabById('dashboard')!.search, isFalse);
    expect(tabById('reports')!.isRecordPage('tax'), isFalse);
    expect(tabById('jobs')!.isRecordPage('J1'), isTrue);
  });

  test('expected cash counts only the cash part of a refund breakdown', () {
    final app = _signedIn({
      'shifts': [
        {'id': 's1', 'userId': 'u1', 'openingCash': 100000},
      ],
      'invoices': [
        {'id': 'i1', 'shiftId': 's1', 'tenders': [{'type': 'Cash', 'amount': 50000}, {'type': 'UPI', 'amount': 30000}], 'change': 0},
      ],
      'returns': [
        // Mixed refund: 10,000 cash + 6,000 UPI; only the cash leaves the drawer.
        {'id': 'r1', 'shiftId': 's1', 'refundType': 'Mixed', 'refundTotal': 16000, 'total': 16000,
          'refunds': [{'type': 'Cash', 'amount': 10000}, {'type': 'UPI', 'amount': 6000}]},
        // Exchange with nothing paid back.
        {'id': 'r2', 'shiftId': 's1', 'refundType': 'Exchange', 'refundTotal': 0, 'total': 9000, 'exchangeApplied': 9000, 'refunds': []},
        // Older note without the breakdown: one refund type for the whole amount.
        {'id': 'r3', 'shiftId': 's1', 'refundType': 'Cash', 'total': 2500},
        {'id': 'r4', 'shiftId': 's1', 'refundType': 'Card', 'total': 4000},
      ],
    });
    final shift = app.list('shifts').single;
    expect(app.expectedCash(shift), 100000 + 50000 - 10000 - 2500);
    expect(refundBy(app.list('returns').first, 'UPI'), 6000);
    expect(refundParts(app.list('returns')[1]), isEmpty);
  });
}
