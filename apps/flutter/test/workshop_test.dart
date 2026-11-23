import 'dart:convert';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart' show Json;
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/router.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:cartunez_pos/ui/workshop/common.dart';
import 'package:cartunez_pos/ui/workshop/jobs.dart';
import 'package:cartunez_pos/ui/workshop/kits.dart';
import 'package:cartunez_pos/ui/workshop/vehicles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? submitted;
  void refreshJobs(List<dynamic> jobs) {
    snapshot = {...snapshot, 'jobs': jobs};
    notifyListeners();
  }

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => {'rows': []};

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    if (!path.endsWith('/lines')) return super.mutate(path, body, message);
    submitted = body;
    return {};
  }
}

const _phone = Size(390, 844);

_Register _workshop({String role = 'manager'}) => _Register()
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
    'settings': {'currency': 'INR'},
    'branch': {'name': 'Main'},
    'customers': [
      {'id': 'c1', 'name': 'Arjun Mehta', 'phone': '9000000101'},
    ],
    'products': [
      {'id': 'filter', 'sku': 'FLT-1', 'name': 'Oil Filter', 'retailPrice': 28500, 'taxRate': 1800, 'type': 'part'},
      {'id': 'labour', 'sku': 'LAB-1', 'name': 'Fitting labour', 'retailPrice': 45000, 'taxRate': 1800, 'type': 'service'},
      {
        'id': 'kit', 'sku': 'KIT-1', 'name': 'Service kit', 'retailPrice': 90000, 'taxRate': 1800, 'type': 'service',
        'components': [{'productId': 'filter', 'qty': 2}, {'productId': 'labour', 'qty': 1}],
      },
    ],
    'locations': [
      {'id': 'a1', 'kind': 'sellable', 'rack': 'A', 'shelf': '1', 'bin': '01'},
    ],
    'stock': [
      {'productId': 'filter', 'binId': 'a1', 'quantity': 7, 'available': 7},
    ],
    'customerVehicles': [
      {'id': 'v1', 'regNo': 'MH 12 AB 1234', 'regKey': 'MH12AB1234', 'customerId': 'c1', 'make': 'Maruti Suzuki', 'model': 'Swift', 'year': 2022, 'odo': 41000},
      {'id': 'v2', 'regNo': 'KA 05 MN 7788', 'regKey': 'KA05MN7788', 'make': 'Hyundai', 'model': 'Creta', 'year': 2023},
    ],
    'jobs': [
      {
        'id': 'j1', 'number': 'JOB-MAIN-1', 'status': 'in-progress', 'vehicleId': 'v1', 'customerId': 'c1', 'bay': '2',
        'lines': [
          {'id': 'l1', 'productId': 'filter', 'name': 'Oil Filter', 'kind': 'part', 'qty': 1, 'unitPrice': 28500, 'binId': 'a1'},
        ],
        'subtotal': 28500, 'tax': 5130, 'total': 33630, 'photos': [], 'history': [],
      },
      {
        'id': 'j2', 'number': 'JOB-MAIN-2', 'status': 'ready', 'vehicleId': 'v2', 'lines': [], 'subtotal': 0, 'tax': 0, 'total': 0,
        'photos': [], 'history': [],
      },
    ],
    'estimates': [],
  };

Future<void> _open(WidgetTester tester, AppState app, String location) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CartunezApp(state: app, prefs: UiPrefs(), initialLocation: location));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('inventory technician reaches assigned job from vehicle history without billing actions', (tester) async {
    final app = _workshop(role: 'inventory');
    expect(homePath(app), '/catalog/parts');
    expect(redirectFor(app, Uri.parse('/orders/jobs/new?vehicle=v1')), isNull);
    expect(redirectFor(app, Uri.parse('/orders/estimates/new?vehicle=v1')), isNull);
    expect(redirectFor(app, Uri.parse('/orders/invoices/example')), '/catalog/parts');
    await _open(tester, app, '/people/vehicles/v1');
    final history = find.text('JOB-MAIN-1 · In progress');
    await tester.ensureVisible(history);
    await tester.pumpAndSettle();
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.byType(JobCard), findsOneWidget);
    expect(find.text('Move to ready'), findsOneWidget);
    expect(find.textContaining('Bill job ('), findsNothing);
    expect(find.text('Take advance'), findsNothing);
  });

  testWidgets('editing a job line keeps the displayed revision across a background sync', (tester) async {
    final app = _workshop();
    await _open(tester, app, '/orders/jobs/j1');
    await tester.ensureVisible(find.text('1 × Oil Filter'));
    await tester.tap(find.text('1 × Oil Filter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    final jobs = app.list('jobs');
    app.refreshJobs([{...jobs.first, 'linesRevision': 7}, ...jobs.skip(1)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(app.submitted?['expectedLinesRevision'], 0);
    expect(app.submitted?['lines'][0]['qty'], 2);
  });

  testWidgets('Share PDF paginates all 100 lines of a workshop document', (tester) async {
    final app = _workshop();
    late BuildContext context;
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }))));
    List<int>? pdf;
    const channel = MethodChannel('net.nfet.printing');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sharePdf') pdf = call.arguments['doc'];
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final document = {'number': 'EST-TEST', 'createdAt': '2026-11-20T09:00Z', 'subtotal': 10000, 'total': 10000,
      'lines': List.generate(100, (i) => {'name': 'Part ${i + 1}', 'kind': 'part', 'qty': 1, 'unitPrice': 100})};
    await tester.runAsync(() => shareDocumentPdf(context, document, title: 'Estimate'));
    expect(pdf, isNotNull);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(pdf!)).length, greaterThan(1));
  });

  test('workshop routes are registered under their workspaces', () {
    expect(matchPath('/orders/jobs')?.tab.id, 'jobs');
    expect(matchPath('/orders/jobs/j1')?.arg, 'j1');
    expect(matchPath('/orders/estimates/new')?.tab.id, 'estimates');
    expect(matchPath('/people/vehicles/v1')?.arg, 'v1');
    expect(matchPath('/catalog/serials')?.tab.id, 'serials');
  });

  test('WhatsApp link, kit components and availability', () {
    expect(whatsappLink('90000 00101', 'Hi & bye'), 'https://wa.me/919000000101?text=Hi%20%26%20bye');
    final app = _workshop();
    expect(parseKitComponents(app, 'FLT-1 x2, LAB-1', 'kit'), [
      {'productId': 'filter', 'qty': 2},
      {'productId': 'labour', 'qty': 1},
    ]);
    expect(() => parseKitComponents(app, 'NOPE x1', null), throwsA(isA<Exception>()));
    expect(kitComponentsText(app, app.productById('kit')!), 'FLT-1 x2, LAB-1 x1');
    expect(kitAvailable(app, app.productById('kit')!), 3, reason: '7 filters make 3 kits');
    expect(searchVehicles(app, '1234').first['id'], 'v1');
    expect(searchVehicles(app, 'mh-12-ab').first['id'], 'v1');
    expect(searchVehicles(app, '9000000101').first['id'], 'v1');
  });

  testWidgets('job board on a phone: status filter, then the job card', (tester) async {
    await _open(tester, _workshop(), '/orders/jobs');
    expect(find.byType(JobBoard), findsOneWidget);
    expect(find.text('MH 12 AB 1234 · JOB-MAIN-1'), findsOneWidget);
    expect(find.text('KA 05 MN 7788 · JOB-MAIN-2'), findsOneWidget);

    // Status chips sit in one sideways-scrolling row on phones.
    await tester.ensureVisible(find.text('Ready (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ready (1)'));
    await tester.pumpAndSettle();
    expect(find.text('MH 12 AB 1234 · JOB-MAIN-1'), findsNothing);
    expect(find.text('KA 05 MN 7788 · JOB-MAIN-2'), findsOneWidget);

    await tester.ensureVisible(find.text('Open (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open (2)'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('MH 12 AB 1234 · JOB-MAIN-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MH 12 AB 1234 · JOB-MAIN-1'));
    await tester.pumpAndSettle();
    expect(find.byType(JobCard), findsOneWidget);
    expect(find.text('Job JOB-MAIN-1'), findsOneWidget);
    expect(find.text('1 × Oil Filter'), findsOneWidget);
    expect(find.text('Bill job (invoice)'), findsOneWidget);
    expect(find.text('Move to ready'), findsOneWidget);

    // Back to the board: no dead end.
    await tester.ensureVisible(find.text('Job board'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Job board'));
    await tester.pumpAndSettle();
    expect(find.byType(JobBoard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('job card: advance on the job, bill offers the held advance, disabled bill says why', (tester) async {
    final app = _workshop();
    app.snapshot = {
      ...app.snapshot,
      'partyBalances': {'customers': {'c1': -20000}},
      'partyPayments': [
        {'id': 'p1', 'partyKind': 'customer', 'partyId': 'c1', 'jobId': 'j1', 'amount': 20000, 'mode': 'UPI', 'advance': true,
          'createdAt': '2026-11-21T10:00:00Z'},
      ],
      'shifts': [
        {'id': 's1', 'userId': 'u1', 'openedAt': '2026-11-21T08:00:00Z', 'closedAt': null, 'openingCash': 0},
      ],
    };
    await _open(tester, app, '/orders/jobs/j1');
    expect(find.textContaining('Advance ₹200.00 by UPI'), findsOneWidget);
    expect(find.textContaining('billing offers it first'), findsOneWidget);
    expect(find.text('Take advance'), findsOneWidget);

    await tester.ensureVisible(find.text('Bill job (invoice)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bill job (invoice)'));
    await tester.pumpAndSettle();
    expect(find.text('Use from advance'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '200.00'), findsOneWidget, reason: 'pre-filled up to the balance due');
    expect(find.text('Rest paid by'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('QA #10: GST wording only when registered; no shift opens one inline and returns to the job bill', (tester) async {
    final gstShop = _workshop();
    gstShop.snapshot = {...gstShop.snapshot, 'settings': {'currency': 'INR', 'taxScheme': 'india-gst'}};
    await _open(tester, gstShop, '/orders/jobs/j1');
    expect(find.text('Bill job (GST invoice)'), findsOneWidget);

    final app = _workshop(); // not GST registered, no shift open
    app.snapshot = {...app.snapshot, 'settings': {'currency': 'INR', 'taxScheme': 'none'}};
    await _open(tester, app, '/orders/jobs/j1');
    expect(find.text('Bill job (invoice)'), findsOneWidget);
    expect(find.textContaining('GST'), findsNothing);
    await tester.ensureVisible(find.text('Bill job (invoice)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bill job (invoice)'));
    await tester.pumpAndSettle();
    expect(find.text('Open shift'), findsWidgets, reason: 'the shift opens here, not on the Shifts page');
    expect(find.byKey(const ValueKey('opening-cash')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(JobCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('job card with nothing on it: the bill button is off and says why', (tester) async {
    await _open(tester, _workshop(), '/orders/jobs/j2');
    expect(find.byKey(const ValueKey('bill-blocked')), findsOneWidget);
    expect(find.text('Add parts or labour before billing.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vehicle lookup on a phone: search by last digits and open the vehicle', (tester) async {
    await _open(tester, _workshop(), '/people/vehicles');
    expect(find.byType(VehiclesScreen), findsOneWidget);
    expect(find.text('KA 05 MN 7788'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('vehicle-list-search')), '1234');
    await tester.pumpAndSettle();
    expect(find.text('KA 05 MN 7788'), findsNothing);
    await tester.ensureVisible(find.text('MH 12 AB 1234'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MH 12 AB 1234'));
    await tester.pumpAndSettle();
    expect(find.byType(VehicleDetail), findsOneWidget);
    expect(find.text('Owner: Arjun Mehta · 9000000101'), findsOneWidget);
    expect(find.text('New job card'), findsOneWidget);
    expect(find.text('JOB-MAIN-1 · In progress'), findsOneWidget);

    // The registration picker used by the counter and job cards.
    final context = tester.element(find.byType(VehicleDetail));
    final picked = pickVehicle(context);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('vehicle-search')), 'ka05');
    await tester.pumpAndSettle();
    await tester.tap(find.text('KA 05 MN 7788').last);
    await tester.pumpAndSettle();
    expect((await picked)?['id'], 'v2');
    expect(counterVehicle((await picked)!)['customerVehicleId'], 'v2');
    expect(tester.takeException(), isNull);
  });
}
