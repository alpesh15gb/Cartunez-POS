import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/login.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/router.dart';
import 'package:cartunez_pos/ui/screens/bills.dart';
import 'package:cartunez_pos/ui/screens/inventory.dart';
import 'package:cartunez_pos/ui/screens/people.dart';
import 'package:cartunez_pos/ui/screens/purchasing.dart';
import 'package:cartunez_pos/ui/screens/reports.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Register extends AppState {
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => {'rows': []};
}

AppState _signedIn(String role) => _Register()
  ..ready = true
  ..lastSync = '2026-11-21T09:00:00Z'
  ..session = Session(
    api: 'https://pos.example.test/api/v1',
    token: 't',
    user: {'id': 'u1', 'name': 'Asha', 'role': role},
    branchId: 'main',
    organizationId: 'org',
    expiresAt: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
  )
  ..snapshot = {
    'settings': {},
    'branch': {'name': 'Main'},
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
  test('every tab has a unique address that resolves back to it', () {
    final paths = <String>{};
    for (final ws in workspaces) {
      for (final tab in ws.tabs) {
        expect(paths.add(tab.path), isTrue, reason: tab.path);
        expect(matchPath(tab.path)?.tab, tab);
        expect(pathForId(tab.id), tab.path);
      }
    }
    expect(workspaces.length, 6);
    expect(matchPath('/orders/invoices/INV-7')?.arg, 'INV-7');
    expect(matchPath('/reports/tax')?.tab.id, 'reports');
    expect(matchPath('/shift/tender')?.tab.id, 'tender');
    expect(matchPath('/catalog/nowhere'), isNull);
  });

  testWidgets('a deep link opens its workspace and sub-tab on desktop', (tester) async {
    await _open(tester, _signedIn('owner'), '/purchasing/bills', const Size(1400, 900));
    expect(find.byType(BillsScreen), findsOneWidget);
    expect(find.text('Purchasing'), findsWidgets);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('Purchase orders'));
    await tester.pumpAndSettle();
    expect(find.byType(OrdersScreen), findsOneWidget);
    expect(_location(tester), '/purchasing/orders');

    // Old ids still navigate.
    ShellScope.of(tester.element(find.byType(OrdersScreen))).open('suppliers');
    await tester.pumpAndSettle();
    expect(find.byType(ContactsScreen), findsOneWidget);
    expect(_location(tester), '/purchasing/suppliers');
  });

  testWidgets('purchase orders use the shared search for suppliers, SKUs and status', (tester) async {
    final app = _signedIn('owner');
    app.snapshot.addAll({
      'suppliers': [
        {'id': 'a', 'name': 'Southside Spares'},
        {'id': 'b', 'name': 'East Auto'},
      ],
      'products': [
        {'id': 'p1', 'name': 'Oil filter', 'sku': 'OF-1'},
        {'id': 'p2', 'name': 'Brake pads', 'sku': 'BP-2'},
      ],
      'purchaseOrders': [
        {'id': 'po-1', 'supplierId': 'a', 'status': 'open', 'lines': [{'productId': 'p1', 'quantity': 2, 'cost': 6000, 'received': 0}]},
        {'id': 'po-2', 'supplierId': 'b', 'status': 'received', 'lines': [{'productId': 'p2', 'quantity': 1, 'cost': 8500, 'received': 1}]},
      ],
    });
    await _open(tester, app, '/purchasing/orders', const Size(1024, 900));
    final search = find.byType(TextField);
    expect(find.text('Oil filter 0/2'), findsOneWidget);
    expect(find.text('Brake pads 1/1'), findsOneWidget);
    for (final term in ['Southside', 'OF-1', 'open']) {
      await tester.enterText(search, term);
      await tester.pumpAndSettle();
      expect(find.text('Oil filter 0/2'), findsOneWidget);
      expect(find.text('Brake pads 1/1'), findsNothing);
    }
    expect(find.text('Reorder alerts'), findsOneWidget);
    expect(find.text('Cost changes'), findsOneWidget);
  });

  testWidgets('legacy supplier links reach Purchasing and Dashboard has a manager rail entry', (tester) async {
    final app = _signedIn('owner');
    expect(redirectFor(app, Uri.parse('/people/suppliers/a?origin=people')), '/purchasing/suppliers/a?origin=people');
    expect(pathForId('people-suppliers'), '/purchasing/suppliers');
    await _open(tester, app, '/people/suppliers', const Size(1400, 900));
    expect(_location(tester), '/purchasing/suppliers');
    await tester.tap(find.text('Dashboard'));
    await tester.pumpAndSettle();
    expect(_location(tester), '/dashboard');
    expect(find.byKey(const ValueKey('workspace-tab-dashboard')), findsNothing);
    expect(homePath(_signedIn('cashier')), '/counter');
    expect(redirectFor(_signedIn('cashier'), Uri.parse('/dashboard')), isNull);
  });

  testWidgets('a workspace address opens its first tab and reports take a name', (tester) async {
    await _open(tester, _signedIn('owner'), '/reports/tax', const Size(1400, 900));
    expect(tester.widget<ReportsScreen>(find.byType(ReportsScreen)).initial, 'tax');

    rootNavigatorKey.currentContext!.go('/catalog');
    await tester.pumpAndSettle();
    expect(find.byType(PartsScreen), findsOneWidget);
    expect(_location(tester), '/catalog/parts');
  });

  testWidgets('an invoice link opens its receipt, and closing returns to the list', (tester) async {
    final app = _signedIn('owner');
    app.snapshot['invoices'] = [
      {'id': 'inv-1', 'number': 'INV-7', 'createdAt': '2026-11-20T09:00:00Z', 'total': 1000, 'lines': [], 'payments': []},
    ];
    await _open(tester, app, '/orders/invoices/INV-7', const Size(1400, 900));
    expect(find.byType(InvoicesScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(_location(tester), '/orders/invoices');
  });

  testWidgets('phone width shows the bottom bar with More', (tester) async {
    await _open(tester, _signedIn('owner'), '/orders/invoices', const Size(390, 844));
    expect(find.byType(InvoicesScreen), findsOneWidget);
    final bar = find.byType(NavigationBar);
    expect(bar, findsOneWidget);
    for (final label in ['Counter', 'Orders', 'Stock', 'Shift', 'More']) {
      expect(find.descendant(of: bar, matching: find.text(label)), findsOneWidget, reason: label);
    }
    await tester.tap(find.descendant(of: bar, matching: find.text('More')));
    await tester.pumpAndSettle();
    expect(find.text('Purchasing'), findsOneWidget);
    expect(find.text('People & vehicles'), findsOneWidget);
    await tester.tap(find.text('Purchasing'));
    await tester.pumpAndSettle();
    expect(find.byType(BillsScreen), findsOneWidget);
  });

  testWidgets('a link the role may not use goes to its home tab', (tester) async {
    await _open(tester, _signedIn('inventory'), '/orders/invoices', const Size(1000, 800));
    expect(find.byType(InvoicesScreen), findsNothing);
    expect(find.byType(PartsScreen), findsOneWidget);
    expect(_location(tester), '/catalog/parts');
  });

  testWidgets('signed out, a deep link waits behind sign-in', (tester) async {
    final app = _Register()..ready = true;
    await _open(tester, app, '/purchasing/bills', const Size(1400, 900));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(Uri.parse(_location(tester)).queryParameters['from'], '/purchasing/bills');
    expect(redirectFor(_signedIn('owner'), Uri.parse(_location(tester))), '/purchasing/bills');
  });
}
