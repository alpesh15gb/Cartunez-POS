import 'dart:async';
import 'dart:typed_data';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/people/collections.dart';
import 'package:cartunez_pos/ui/photos.dart';
import 'package:cartunez_pos/ui/prefs.dart';
import 'package:cartunez_pos/ui/purchasing/bill_detail.dart';
import 'package:cartunez_pos/ui/purchasing/file_thumbs.dart';
import 'package:cartunez_pos/ui/purchasing/received.dart';
import 'package:cartunez_pos/ui/screens/dashboard.dart';
import 'package:cartunez_pos/ui/screens/physical_count.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:cartunez_pos/ui/widgets.dart';
import 'package:cartunez_pos/ui/workshop/estimates.dart';
import 'package:cartunez_pos/ui/workshop/vehicles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

final _png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

class _Shop extends AppState {
  _Shop({String role = 'manager', String userId = 'u1'}) {
    ready = true;
    session = Session(
      api: '',
      token: '',
      user: {'id': userId, 'name': 'Asha', 'role': role},
      branchId: 'main',
      organizationId: 'org',
      expiresAt: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
    );
  }

  Json collections = {'rows': [], 'total': 0};
  final mutations = <(String, Json)>[];
  Completer<dynamic>? syncCompletion;
  Future<Uint8List> Function(String)? fileReply;
  int fileLoads = 0;

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    if (path == '/collections') return collections;
    if (path.startsWith('/purchasing/sync-status')) {
      final ids = Uri.parse(path).queryParameters['productIds']?.split(',') ?? const <String>[];
      return {
        'parts': [
          for (final id in ids) {'productId': id, 'state': 'synced'},
        ],
      };
    }
    return {};
  }

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    mutations.add((path, body));
    if (path == '/purchasing/sync-online') return syncCompletion?.future ?? {};
    if (path == '/estimates') {
      return {...body, 'id': body['id'] ?? 'est-new', 'number': 'EST-1', 'status': 'draft'};
    }
    return {};
  }

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}

  @override
  Future<Uint8List> fileBytes(String fileId) async {
    fileLoads++;
    return fileReply?.call(fileId) ?? _png;
  }

  @override
  Future<Uint8List> photoBytes(String imageId) async => _png;
}

void _phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _close(WidgetTester tester, _Shop app, [ShellController? shell]) async {
  await tester.pumpWidget(const SizedBox.shrink());
  app.dispose();
  shell?.dispose();
}

void main() {
  testWidgets('cashier dashboard scopes both sales and refunds to the signed-in cashier', (tester) async {
    _phone(tester, const Size(1163, 900));
    final now = DateTime.now().toIso8601String();
    final app = _Shop(role: 'cashier')
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'invoices': [
          {'id': 'mine', 'number': 'INV-1', 'createdAt': now, 'userId': 'u1', 'total': 1000},
          {'id': 'other', 'number': 'INV-2', 'createdAt': now, 'userId': 'u2', 'total': 9000},
        ],
        'returns': [
          {'id': 'r1', 'createdAt': now, 'userId': 'u1', 'total': 200},
          {'id': 'r2', 'createdAt': now, 'userId': 'u2', 'total': 8000},
        ],
        'coreReturns': [
          {'id': 'c1', 'createdAt': now, 'userId': 'u1', 'total': 50},
        ],
      };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: DashboardScreen())),
        ),
      ),
    );
    String metric(String label) => tester.widget<Metric>(find.widgetWithText(Metric, label)).value;
    expect(metric('Sales today'), '1');
    expect(metric('Refunds today'), app.money(250));
    expect(metric('Net sales today'), app.money(750));
    await _close(tester, app);
  });

  testWidgets('collections reacts to search and distinguishes no matches from no debtors', (tester) async {
    _phone(tester, const Size(1163, 900));
    final app = _Shop()
      ..collections = {
        'total': 30000,
        'rows': [
          {'customerId': 'c1', 'name': 'Arjun Mehta', 'phone': '9000000101', 'balance': 20000},
          {'customerId': 'c2', 'name': 'Meena Joshi', 'phone': '9123456789', 'balance': 10000},
        ],
      };
    final shell = ShellController();
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: ShellScope(
            controller: shell,
            child: const Scaffold(body: SingleChildScrollView(child: CollectionsPage())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Arjun Mehta'), findsOneWidget);
    expect(find.text('Meena Joshi'), findsOneWidget);

    shell.search.text = '9000000101';
    await tester.pump();
    expect(find.text('Arjun Mehta'), findsOneWidget);
    expect(find.text('Meena Joshi'), findsNothing);

    shell.search.text = 'nobody';
    await tester.pump();
    expect(find.text('No customers match your search.'), findsOneWidget);
    expect(find.textContaining('Nobody owes you.'), findsNothing);

    app.collections = {'rows': [], 'total': 0};
    shell.search.clear();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nobody owes you.'), findsOneWidget);
    expect(find.text('No customers match your search.'), findsNothing);
    await _close(tester, app, shell);
  });

  testWidgets('vehicle changes replace only an owner that was not deliberately changed', (tester) async {
    _phone(tester);
    final app = _Shop()
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'customers': [
          {'id': 'c1', 'name': 'Arjun Mehta'},
          {'id': 'c2', 'name': 'Meena Joshi'},
        ],
        'customerVehicles': [
          {'id': 'v1', 'regNo': 'MH 12 AB 1234', 'customerId': 'c1'},
          {'id': 'v2', 'regNo': 'KA 05 MN 7788', 'customerId': 'c2'},
        ],
      };
    for (final initialCustomer in ['c1', 'c2']) {
      String? customerId;
      String? vehicleId;
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            home: Scaffold(
              body: PartyPicker(customerId: initialCustomer, vehicleId: 'v1', onChanged: (c, v) => (customerId, vehicleId) = (c, v)),
            ),
          ),
        ),
      );
      await tester.tap(find.textContaining('MH 12 AB 1234'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('vehicle-search')), 'KA05MN7788');
      await tester.pumpAndSettle();
      await tester.tap(find.text('KA 05 MN 7788').last);
      await tester.pumpAndSettle();
      expect(vehicleId, 'v2');
      expect(customerId, 'c2', reason: initialCustomer == 'c1' ? 'auto-filled owner follows the new vehicle' : 'deliberately selected customer is preserved');
    }
    await _close(tester, app);
  });

  testWidgets('estimate edits block sharing and back until saved or explicitly discarded', (tester) async {
    _phone(tester, const Size(390, 1100));
    final app = _Shop()
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'customers': [
          {'id': 'c1', 'name': 'Arjun Mehta'},
        ],
        'products': [
          {'id': 'filter', 'name': 'Oil Filter', 'retailPrice': 1000, 'taxRate': 0},
        ],
        'estimates': [
          {
            'id': 'est-1',
            'number': 'EST-1',
            'status': 'draft',
            'customerId': 'c1',
            'lines': [
              {'productId': 'filter', 'name': 'Oil Filter', 'qty': 1, 'unitPrice': 1000},
            ],
          },
        ],
      };
    await tester.pumpWidget(CartunezApp(state: app, prefs: UiPrefs(), initialLocation: '/orders/estimates/est-1'));
    await tester.pumpAndSettle();
    final notes = find.widgetWithText(TextField, 'Notes for the customer');
    await tester.ensureVisible(notes);
    await tester.enterText(notes, 'Customer requested a replacement.');
    await tester.pump();
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'WhatsApp')).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Share PDF')).onPressed, isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(EstimateEditor), findsOneWidget);

    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.mutations.single.$1, '/estimates');
    expect(app.mutations.single.$2['notes'], 'Customer requested a replacement.');
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'WhatsApp')).onPressed, isNotNull);
    expect(find.textContaining('Unsaved changes.'), findsNothing);

    await tester.enterText(notes, 'Customer requested a replacement and fitting.');
    await tester.pump();
    final back = find.widgetWithText(TextButton, 'Estimates');
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(EstimateEditor), findsOneWidget);

    await tester.tap(back);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard and leave'));
    await tester.pumpAndSettle();
    expect(find.byType(EstimateEditor), findsNothing);
    expect(app.mutations.where((m) => m.$1.endsWith('/status')), isEmpty);
    await _close(tester, app);
  });

  testWidgets('stock-count discard follows the same open policy as its row', (tester) async {
    _phone(tester, const Size(900, 900));
    final app = _Shop(role: 'cashier')
      ..snapshot = {
        'products': [
          {'id': 'p', 'name': 'Filter'},
        ],
        'locations': [
          {'id': 'bin', 'kind': 'sellable', 'bin': 'A1'},
        ],
        'stockCounts': [
          {'id': 'own', 'productId': 'p', 'binId': 'bin', 'status': 'counting', 'startedBy': 'u1'},
          {'id': 'other', 'productId': 'p', 'binId': 'bin', 'status': 'counting', 'startedBy': 'u2'},
          {'id': 'review', 'productId': 'p', 'binId': 'bin', 'status': 'review', 'startedBy': 'u2'},
        ],
      };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => openPhysicalCounts(context), child: const Text('Open counts')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open counts'));
    await tester.pumpAndSettle();
    final rows = find.byType(ListTile);
    expect(tester.widget<ListTile>(rows.at(0)).onTap, isNotNull);
    expect(tester.widget<ListTile>(rows.at(1)).onTap, isNull);
    expect(tester.widget<ListTile>(rows.at(2)).onTap, isNull);
    final discard = find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Discard count');
    expect(tester.widget<IconButton>(discard.at(0)).onPressed, isNotNull);
    expect(tester.widget<IconButton>(discard.at(1)).onPressed, isNull);
    expect(tester.widget<IconButton>(discard.at(2)).onPressed, isNull);
    await _close(tester, app);
  });

  test('vehicle prefill accepts registrations but not phone, VIN, name or partial searches', () {
    expect(vehicleRegistrationPrefill(' mh 12 ab 1234 '), 'MH 12 AB 1234');
    expect(vehicleRegistrationPrefill('ka-05-mn-7788'), 'KA-05-MN-7788');
    for (final query in ['', '1234', 'mh12ab', '9000000101', '1HGBH41JXMN109186', 'Maruti Swift']) {
      expect(vehicleRegistrationPrefill(query), isNull, reason: query);
    }
  });

  testWidgets('vehicle add form does not prefill an owner-phone search as a registration', (tester) async {
    _phone(tester, const Size(1163, 900));
    final app = _Shop()
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'customers': [
          {'id': 'c1', 'name': 'Arjun Mehta', 'phone': '9000000101'},
        ],
        'customerVehicles': [
          {'id': 'v1', 'regNo': 'MH 12 AB 1234', 'customerId': 'c1'},
        ],
      };
    final shell = ShellController()..search.text = '9000000101';
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: ShellScope(
            controller: shell,
            child: const Scaffold(body: SingleChildScrollView(child: VehiclesScreen())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add vehicle'));
    await tester.pumpAndSettle();
    final registration = find.widgetWithText(TextFormField, 'Registration number');
    expect(tester.widget<TextFormField>(registration).controller!.text, isEmpty);
    await _close(tester, app, shell);
  });

  testWidgets('received-goods update is single-flight, blocks dismissal and tolerates disposal', (tester) async {
    _phone(tester, const Size(1000, 900));
    final app = _Shop()
      ..syncCompletion = Completer<dynamic>()
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'products': [
          {'id': 'p', 'name': 'Filter', 'sku': 'F1', 'retailPrice': 1000},
        ],
        'locations': [
          {'id': 'bin', 'kind': 'sellable', 'bin': 'A1'},
        ],
      };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showReceivedGoods(context, [
                  {'productId': 'p', 'quantity': 1, 'binId': 'bin'},
                ]),
                child: const Text('Goods received'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Goods received'));
    await tester.pumpAndSettle();
    final update = find.widgetWithText(OutlinedButton, 'Update website now');
    await tester.tap(update);
    await tester.pump();
    expect(app.mutations, hasLength(1));
    expect(tester.widget<OutlinedButton>(update).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);
    final refresh = find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Refresh website status');
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    await tester.tap(find.text('Done'));
    await tester.tap(find.text('Update website now'));
    await tester.pump();
    expect(app.mutations, hasLength(1));
    expect(find.byType(ReceivedGoodsDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ReceivedGoodsDialog), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.syncCompletion!.completeError(Exception('Offline after close'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    app.dispose();
  });

  testWidgets('file viewer shows an error and retries instead of spinning forever', (tester) async {
    _phone(tester);
    final app = _Shop();
    var first = true;
    app.fileReply = (_) async {
      if (first) {
        first = false;
        throw Exception('Missing attachment');
      }
      return _png;
    };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => viewFile(context, {'id': 'file', 'contentType': 'image/jpeg'}), child: const Text('Open file')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open file'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load this file.'), findsOneWidget);
    expect(find.textContaining('Missing attachment'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(app.fileLoads, 2);
    expect(find.text('Could not load this file.'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await _close(tester, app);
  });

  testWidgets('photo dialog scrolls on a phone while keeping actions reachable', (tester) async {
    _phone(tester);
    final app = _Shop()
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'products': [
          {'id': 'product', 'name': 'Oil Filter'},
        ],
        'productImages': [
          for (var i = 0; i < 8; i++) {'id': 'photo-$i', 'productId': 'product', 'position': i},
        ],
      };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => editPhotos(context, {'id': 'product', 'name': 'Oil Filter'}), child: const Text('Photos')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(tester.widget<AlertDialog>(dialog).scrollable, isTrue);
    expect(find.text('Close').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove photo').last);
    await tester.pumpAndSettle();
    expect(find.text('Close').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, app);
  });

  testWidgets('bill label picker excludes online-only products', (tester) async {
    _phone(tester, const Size(1163, 900));
    final app = _Shop()
      ..labelPrinter = {'mode': 'dialog'}
      ..snapshot = {
        'settings': {'currency': 'INR'},
        'products': [
          {'id': 'wheel', 'name': 'Alloy Wheel Set', 'sku': 'CZ-ALLOY-01', 'onlineOnly': true, 'retailPrice': 1000},
          {'id': 'filter', 'name': 'Oil filter', 'sku': 'OF1', 'retailPrice': 1000},
        ],
        'locations': [
          {'id': 'bin', 'kind': 'sellable', 'bin': 'A1'},
        ],
      };
    final bill = {
      'id': 'bill',
      'billNumber': 'B1',
      'supplierName': 'Parts Co',
      'billDate': '2026-11-21T09:00Z',
      'subtotal': 300,
      'total': 300,
      'lines': [
        {'productId': 'wheel', 'name': 'Alloy Wheel Set', 'sku': 'CZ-ALLOY-01', 'quantity': 1, 'cost': 100, 'binId': null},
        {'productId': 'filter', 'name': 'Oil filter', 'sku': 'OF1', 'quantity': 2, 'cost': 100, 'binId': 'bin'},
      ],
    };
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => showBill(context, bill), child: const Text('Open bill')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print labels'));
    await tester.pumpAndSettle();
    expect(find.text('Labels for this delivery'), findsOneWidget);
    expect(find.textContaining('Oil filter · OF1'), findsWidgets);
    expect(find.textContaining('Alloy Wheel Set · CZ-ALLOY-01'), findsNothing);
    await _close(tester, app);
  });
}
