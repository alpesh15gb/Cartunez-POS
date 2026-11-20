import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/screens/tender_comparison.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? sent;
  String? endpoint;
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    sent = body;
    endpoint = path;
    return {};
  }

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    sent = body as Json;
    endpoint = path;
    return {
      'posGross': 1000, 'posCount': 1, 'statementGross': 900, 'statementCount': 1, 'difference': -100,
      'matched': 0, 'exceptions': 1, 'excluded': 0, 'rows': [
        {'type': 'UPI', 'reference': '0001', 'status': 'Amount differs',
          'pos': [{'document': 'INV-1', 'date': '2026-01-10', 'amount': 1000}],
          'statement': [{'document': 'CSV row 2', 'date': '2026-01-10', 'amount': 900}]},
      ],
    };
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _Register app, void Function(BuildContext) open) async {
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => open(context), child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('cash-out captures exact paise, reason and a retry ID', (tester) async {
    final app = _Register();
    await mount(tester, app, (ctx) => recordDrawerMovement(ctx, {'id': 'shift'}, 'out'));
    await tester.enterText(find.byType(TextFormField).first, '0');
    await tester.enterText(find.byType(TextFormField).last, 'Safe drop');
    await tester.tap(find.text('Record movement'));
    await tester.pumpAndSettle();
    expect(app.sent, isNull);
    await tester.enterText(find.byType(TextFormField).first, '75.05');
    await tester.tap(find.text('Record movement'));
    await tester.pumpAndSettle();
    expect(app.endpoint, '/shifts/shift/cash-movements');
    expect(app.sent, containsPair('amount', 7505));
    expect(app.sent, containsPair('reason', 'Safe drop'));
    expect(app.sent, containsPair('direction', 'out'));
    expect(app.sent!['transactionId'], isNotEmpty);
    app.dispose();
  });

  testWidgets('provider CSV uses report period, type and receipt-level differences', (tester) async {
    final app = _Register()..snapshot = {'settings': {'currency': 'INR'}};
    await mount(tester, app, (ctx) => compareTenderStatement(ctx,
      range: DateTimeRange(start: DateTime(2026, 1, 9), end: DateTime(2026, 1, 11)), method: 'UPI'));
    const csv = 'date,type,reference,gross_inr\n2026-01-10,UPI,0001,9.00';
    await tester.enterText(find.byType(TextField), csv);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare captures'));
    await tester.pumpAndSettle();
    expect(app.endpoint, '/reports/tenders/compare');
    expect(app.sent, {'branchId': null, 'from': '2026-01-09', 'to': '2026-01-11', 'type': 'UPI', 'csv': csv});
    expect(find.text('0 matched · 1 exception groups'), findsOneWidget);
    await tester.ensureVisible(find.text('UPI · 0001'));
    await tester.tap(find.text('UPI · 0001'));
    await tester.pumpAndSettle();
    expect(find.textContaining('INV-1'), findsOneWidget);
    expect(find.textContaining('CSV row 2'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Amount differs'), findsNothing);
    app.dispose();
  });
}
