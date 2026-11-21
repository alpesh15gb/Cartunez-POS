// WS-D: PIN pad, switch user keeps the cart, denomination helper, shift summary.
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/shift/pin_counter.dart';
import 'package:cartunez_pos/ui/shift/shift_dialogs.dart';
import 'package:cartunez_pos/ui/shift/shift_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? sent;
  String? endpoint;
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    sent = body;
    endpoint = path;
    return {'variance': 0};
  }
}

Future<void> _pump(WidgetTester tester, AppState app, Widget child) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)))));
}

void main() {
  testWidgets('PIN pad fills dots, deletes, and submits only 4 to 6 digits', (tester) async {
    final submitted = <String>[];
    await _pump(tester, AppState(), PinPad(onSubmit: submitted.add));
    final pad = tester.state<PinPadState>(find.byType(PinPad));
    for (final d in ['1', '9', '7']) {
      await tester.tap(find.byKey(ValueKey('pin-key-$d')));
    }
    await tester.pump();
    expect(pad.pin, '197');
    await tester.tap(find.byKey(const ValueKey('pin-key-ok')));
    expect(submitted, isEmpty, reason: 'three digits is too short');
    await tester.tap(find.byKey(const ValueKey('pin-key-back')));
    await tester.pump();
    expect(pad.pin, '19');
    for (final d in ['2', '5', '8', '0', '3']) {
      await tester.tap(find.byKey(ValueKey('pin-key-$d')));
    }
    await tester.pump();
    expect(pad.pin, '192580', reason: 'stops at six digits');
    await tester.tap(find.byKey(const ValueKey('pin-key-ok')));
    expect(submitted, ['192580']);
  });

  testWidgets('PIN sign-in lists staff tiles and shows a wrong PIN message', (tester) async {
    final tried = <String>[];
    await _pump(tester, AppState(), PinSignIn(
      counter: const {'deviceName': 'Front counter', 'branchId': 'pune'},
      onUseEmail: () {},
      loadStaff: (_) async => {'branchName': 'Pune', 'staff': [{'id': 'u1', 'name': 'Ravi Kumar', 'role': 'cashier'}]},
      signIn: (id, pin) async {
        tried.add('$id:$pin');
        throw FormProblemLike('Wrong PIN. 4 tries left.');
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('RK'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('staff-tile-u1')));
    await tester.pumpAndSettle();
    for (final d in ['4', '8', '2', '6']) {
      await tester.tap(find.byKey(ValueKey('pin-key-$d')));
    }
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-key-ok')));
    await tester.pumpAndSettle();
    expect(tried, ['u1:4826']);
    expect(find.textContaining('Wrong PIN'), findsOneWidget);
  });

  test('denomination helper sums notes and coins in paise', () {
    expect(denominationTotal({200000: 1, 50000: 3, 10: 0}, coins: 1250), 200000 + 150000 + 1250);
    expect(denominationTotal({}, coins: 0), 0);
    expect(cashNotes.first, 200000);
  });

  testWidgets('close shift counts notes, shows the difference and sends the count', (tester) async {
    final app = _Register();
    app.snapshot = {'settings': {'currency': 'INR'}};
    await _pump(tester, app, const CloseShiftDialog(shift: {'id': 'shift-1', 'openingCash': 0}, expected: 75000));
    await tester.enterText(find.byKey(const ValueKey('note-50000')), '1');
    await tester.enterText(find.byKey(const ValueKey('note-10000')), '2');
    await tester.enterText(find.byKey(const ValueKey('note-coins')), '5');
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('counted-cash')), matching: find.text('₹705.00')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('variance')), matching: find.textContaining('short')), findsOneWidget);
    await tester.tap(find.text('Close shift').last);
    await tester.pump();
    expect(app.endpoint, '/shifts/shift-1/close');
    expect(app.sent!['countedCash'], 70500);
    expect(app.sent!['denominations'], {'50000': 1, '10000': 2, 'coins': 500});
  });

  testWidgets('shift summary shows tenders, refunds, movements and the drawer, and exports CSV', (tester) async {
    final app = AppState();
    app.snapshot = {'settings': {'currency': 'INR'}, 'customers': [{'id': 'c1', 'name': 'Asha Motors'}]};
    final summary = {
      'shiftId': 'shift-1', 'userId': 'u1', 'openedAt': '2026-11-20T04:00:00Z', 'closedAt': '2026-11-20T12:00:00Z',
      'openingCash': 50000, 'invoices': 2, 'gross': 30000, 'tenders': {'Cash': 10000, 'UPI': 20000},
      'refunds': {'Cash': 10000}, 'refundCount': 1, 'refundTotal': 10000,
      'cashMovements': [{'direction': 'out', 'amount': 5000, 'reason': 'Tea'}],
      'partyPayments': [{'partyKind': 'customer', 'partyId': 'c1', 'direction': 'in', 'amount': 2000}],
      'cashSales': 10000, 'cashRefunds': 10000, 'cashIn': 2000, 'cashOut': 5000, 'expectedCash': 47000,
      'countedCash': 47250, 'variance': 250, 'denominations': {'20000': 2, '5000': 1, 'coins': 2250},
    };
    await _pump(tester, app, ShiftSummaryDialog(summary: summary));
    for (final text in ['Sales', 'Refunds', 'Cash movements', 'Party payments in cash', 'Drawer', 'Note count']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('  UPI'), findsOneWidget);
    expect(find.text('  From Asha Motors'), findsOneWidget);
    expect(find.text('₹470.00'), findsOneWidget);
    expect(find.text('₹472.50'), findsOneWidget);
    final csv = shiftSummaryCsv(shiftSummaryLines(app, summary));
    expect(csv.split('\r\n').first, 'Section,Item,Value');
    expect(csv, contains('"Sales","UPI","₹200.00"'));
    expect(csv, contains('"Drawer","Expected cash","₹470.00"'));
  });
}

class FormProblemLike implements Exception {
  FormProblemLike(this.message);
  final String message;
  @override
  String toString() => message;
}
