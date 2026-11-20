import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/physical_count.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  final posted = <String>[];
  final bodies = <Json>[];
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    posted.add(path);
    bodies.add(body);
    return {'id': 'count1', 'productId': 'part', 'binId': 'bin', 'startedBy': 'manager', 'serialTracked': false,
      'expected': 4, if (path.endsWith('submit')) ...{'counted': 0, 'delta': -4, 'reason': 'Empty shelf'}};
  }
}

void main() {
  testWidgets('manager captures the baseline before counting and sees the variance before stock changes', (tester) async {
    final app = _Register()
      ..session = Session(api: '', token: '', user: {'role': 'manager', 'id': 'manager'}, branchId: 'shop', organizationId: 'org', expiresAt: '')
      ..snapshot = {
        'products': [{'id': 'part', 'sku': 'F1', 'name': 'Filter'}],
        'locations': [{'id': 'bin', 'kind': 'sellable', 'area': 'Main', 'rack': 'A', 'shelf': '1', 'bin': '1'}],
      };
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => startPhysicalCount(context), child: const Text('Stock count')))))));
    await tester.tap(find.text('Stock count'));
    await tester.pumpAndSettle();
    Future<void> choose(int index, String option) async {
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(index));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(option).last);
      await tester.pumpAndSettle();
    }
    await choose(0, 'F1 · Filter');
    await choose(1, 'sellable');
    await tester.tap(find.text('Start counting'));
    await tester.pumpAndSettle();
    expect(app.posted, ['/inventory/count/start']);
    await tester.enterText(find.byType(TextFormField).first, '0');
    await tester.enterText(find.byType(TextFormField).last, 'Empty shelf');
    await tester.tap(find.text('Submit for review'));
    await tester.pumpAndSettle();
    expect(app.posted.last, '/inventory/count/submit');
    expect(app.bodies.last, containsPair('counted', 0));
    expect(find.text('Expected   4'), findsOneWidget);
    expect(find.text('Counted   0'), findsOneWidget);
    expect(find.text('Change   -4'), findsOneWidget);
    await tester.tap(find.text('Confirm count'));
    await tester.pumpAndSettle();
    expect(app.posted, ['/inventory/count/start', '/inventory/count/submit', '/inventory/count']);
    expect(app.bodies.last, containsPair('countId', 'count1'));
    app.dispose();
  });
}
