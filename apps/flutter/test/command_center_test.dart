// WS-F: owner command center at phone width, deep links and refresh.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/command_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _board(int net) => {
      'day': '2026-11-21', 'currency': 'INR', 'pendingConflicts': 0,
      'today': {'sales': 4, 'gross': net, 'returns': 0, 'net': net, 'tax': 0, 'margin': net ~/ 4},
      'hourly': [for (var h = 0; h < 24; h++) {'hour': h, 'sales': h == 11 ? 4 : 0, 'net': h == 11 ? net : 0, 'margin': h == 11 ? net ~/ 4 : 0}],
      'tills': [
        {'shiftId': 's1', 'userId': 'u1', 'userName': 'Ravi', 'counter': 'Front counter', 'openedAt': '2026-11-21T03:30:00Z',
          'cashOnHand': 1250000, 'sales': 4, 'lastSaleAt': '2026-11-21T05:45:00Z'},
      ],
      'lowStock': {'count': 1, 'rows': [{'name': 'Brake pads with a very long name that must not overflow on a phone', 'available': 1, 'reorderLevel': 5, 'onOrder': 0}]},
      'deadStock': {'days': 90, 'count': 2, 'value': 840000, 'rows': [{'name': 'Roof rack', 'quantity': 2, 'value': 800000}]},
      'onlineOrders': {'pending': 0, 'awaitingStock': 0, 'value': 0, 'rows': []},
      'customerDues': {'total': 350000, 'customers': 2, 'rows': [{'customerId': 'c1', 'name': 'Arjun', 'balance': 300000}]},
      'varianceShifts': [{'shiftId': 's0', 'userName': 'Meena', 'closedAt': '2026-11-20T14:00:00Z', 'variance': -5000}],
      'topItems': [{'productId': 'p1', 'name': 'Engine oil 5W-30', 'quantity': 3, 'revenue': 600000}],
    };

class _Owner extends AppState {
  int calls = 0;
  final paths = <String>[];
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    calls++;
    paths.add(path);
    return _board(calls * 100000);
  }
}

void main() {
  testWidgets('command center fits a phone, deep-links each tile and refreshes on a timer', (tester) async {
    tester.view.physicalSize = const Size(375, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Owner()
      ..session = Session(api: '', token: '', user: {'role': 'owner', 'id': 'u0'}, branchId: 'pune', organizationId: 'org', expiresAt: '')
      ..snapshot = {'settings': {'currency': 'INR'}};
    final opened = <String>[];
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Scaffold(body: ListView(padding: const EdgeInsets.all(16),
        children: [CommandCenter(refreshEvery: const Duration(seconds: 30), onOpen: opened.add)])))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Nothing on the phone layout overflows.
    expect(tester.allRenderObjects.whereType<RenderFlex>().where((r) => r.toStringShallow().contains('OVERFLOWING')), isEmpty);
    expect(app.paths.single, '/dashboard?deadDays=90');
    expect(find.text('Till watch'), findsOneWidget);
    expect(find.textContaining('Front counter'), findsOneWidget);
    expect(find.text('Shift cash differences (7 days)'), findsOneWidget);
    expect(find.textContaining('Short'), findsOneWidget);
    expect(find.byType(HourlyChart), findsOneWidget);
    // Phone: one column, every tile as wide as the screen.
    final tile = tester.getSize(find.byKey(const ValueKey('tile-sales')));
    expect(tile.width, closeTo(375 - 32, 0.5));
    expect(tester.getSize(find.byKey(const ValueKey('tile-dues'))).width, closeTo(375 - 32, 0.5));

    for (final (key, path) in const [
      ('tile-tills', '/shift'), ('tile-sales', '/reports/daily-sales'), ('tile-low', '/reports/low-stock'),
      ('tile-dues', '/people/customers'), ('tile-variance', '/reports/shifts'), ('tile-top', '/reports/fast-moving'),
    ]) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
      expect(opened.last, path);
    }

    // Polls while visible.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(app.calls, 2);
    // Dead-stock window change reloads with the new days.
    await tester.ensureVisible(find.text('90 days'));
    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('180 days').last);
    await tester.pump();
    expect(app.paths.last, '/dashboard?deadDays=180');
    expect(tester.takeException(), isNull);
    app.dispose();
  });

  testWidgets('a failed load says so and offers a retry', (tester) async {
    final app = _Failing()
      ..session = Session(api: '', token: '', user: {'role': 'owner', 'id': 'u0'}, branchId: 'pune', organizationId: 'org', expiresAt: '');
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Scaffold(body: CommandCenter(onOpen: (_) {})))));
    await tester.pump();
    expect(find.text('Cannot reach the server.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    app.dispose();
  });
}

class _Failing extends AppState {
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async => throw OfflineError('Cannot reach the server.');
}
