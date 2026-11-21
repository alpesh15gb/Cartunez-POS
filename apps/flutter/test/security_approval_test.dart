// Security: approvals issued by a manager carry the amount and the bill /
// customer / part they approve.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Manager extends AppState {
  String? path;
  Object? body;
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    this.path = path;
    this.body = body;
    return {'id': 'approval-1'};
  }
}

void main() {
  testWidgets('issuing an approval sends the amount in paise and the subject', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = _Manager()
      ..online = true
      ..session = Session(api: 'http://test', token: 't', organizationId: 'demo', branchId: 'pune',
          user: {'id': 'm', 'role': 'manager', 'name': 'Manager'},
          expiresAt: DateTime.now().add(const Duration(hours: 1)).toIso8601String())
      ..snapshot = {'settings': {'currency': 'INR'}};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => issueApproval(context), child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discount above the cashier limit').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Reference shown on the cashier\'s screen'), 'tx-1');
    await tester.enterText(find.widgetWithText(TextFormField, 'Most it covers'), '250.50');
    await tester.enterText(find.widgetWithText(TextFormField, 'For which bill / customer / part'), '9000000101');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Regular customer');
    await tester.tap(find.text('Issue'));
    await tester.pumpAndSettle();
    expect(app.path, '/approvals');
    expect(app.body, {
      'action': 'discount',
      'transactionId': 'tx-1',
      'reason': 'Regular customer',
      'amount': 25050,
      'subjectId': '9000000101',
    });
    expect(find.text('approval-1'), findsOneWidget);
  });
}
