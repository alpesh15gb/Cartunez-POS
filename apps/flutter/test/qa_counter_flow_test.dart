// QA audit (22 Nov 2026) #6 counter half, #7, #8, #9, #11: counter shift, invoice list,
// pending UPI confirmation, UPI QR availability and the shift close summary.
import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/fitment_bar.dart';
import 'package:cartunez_pos/ui/counter/pending_payment.dart';
import 'package:cartunez_pos/ui/screens/billing.dart';
import 'package:cartunez_pos/ui/screens/sales.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:cartunez_pos/ui/shift/shift_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  String? endpoint;
  Json? sent;
  Json? confirmedRefs;

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    endpoint = path;
    sent = body;
    if (path == '/shifts/open') {
      snapshot = {...snapshot, 'shifts': [{'id': 's1', 'userId': 'u', 'closedAt': null, 'openingCash': 0}]};
      notifyListeners();
    }
    return {'variance': 0};
  }

  @override
  Future<void> confirmPayment(String transactionId, Json references) async {
    confirmedRefs = references;
    pending.clear();
    snapshot = {
      ...snapshot,
      'invoices': [{'id': 'inv-9', 'number': 'INV-9', 'transactionId': transactionId, 'total': 50000, 'tenders': [], 'lines': []}],
    };
  }
}

_Register _app({String role = 'owner', Json settings = const {}}) => _Register()
  ..online = true
  ..session = Session(api: '', token: '', user: {'role': role, 'id': 'u', 'name': 'Asha'}, branchId: 'b', organizationId: 'o',
      expiresAt: DateTime.now().add(const Duration(hours: 1)).toIso8601String())
  ..snapshot = {
    'settings': {'currency': 'INR', 'tenderTypes': ['Cash', 'Card', 'UPI'], ...settings},
    'products': [{'id': 'p', 'name': 'Oil filter', 'sku': 'OF1', 'retailPrice': 50000}],
    'shifts': <Json>[],
  };

Future<void> _pump(WidgetTester tester, AppState app, Widget child, {Size size = const Size(924, 900), ShellController? shell}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: app,
    child: MaterialApp(home: ShellScope(controller: shell ?? ShellController(), child: Scaffold(body: child))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('#6: the Counter opens a shift inline and puts the cursor back in item search', (tester) async {
    final app = _app(role: 'cashier');
    final shell = ShellController();
    await _pump(
      tester,
      app,
      Column(children: [
        TextField(focusNode: shell.searchFocus, decoration: const InputDecoration(labelText: 'Search parts')),
        FitmentBar(categories: const ['All'], current: 'All', onCategory: (_) {}),
      ]),
      shell: shell,
    );
    expect(find.text('Go to shifts'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('counter-open-shift')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('opening-cash')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Open shift'));
    await tester.pumpAndSettle();
    expect(app.endpoint, '/shifts/open');
    expect(find.byKey(const ValueKey('counter-open-shift')), findsNothing);
    expect(find.text('Scan or pick parts, then take payment.'), findsOneWidget);
    expect(shell.searchFocus.hasFocus, isTrue);
  });

  for (final size in const [Size(924, 900), Size(390, 844)]) {
    testWidgets('#7: invoice rows show View receipt and Return; Void is in the ⋮ menu (${size.width.toInt()}px)', (tester) async {
      final app = _app();
      app.snapshot = {
        ...app.snapshot,
        'invoices': [{'id': 'i1', 'number': 'INV-1', 'createdAt': '2026-11-21T10:00:00Z', 'total': 50000, 'tenders': [{'type': 'UPI', 'amount': 50000}], 'lines': []}],
      };
      await _pump(tester, app, const SingleChildScrollView(child: InvoicesScreen()), size: size);
      expect(find.text('View receipt'), findsWidgets);
      expect(find.text('Return'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Void'), findsNothing);
      await tester.tap(find.byTooltip('More actions for INV-1').first);
      await tester.pumpAndSettle();
      expect(find.text('Void invoice'), findsOneWidget);
      await tester.tap(find.text('Void invoice'));
      await tester.pumpAndSettle();
      // QA #3: the void refund defaults to the original tender, not cash.
      expect(find.text('UPI (as paid)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('#9: no UPI ID → QR disabled with a Settings link; #8: unconfirmed saves as a pending payment', (tester) async {
    final app = _app();
    await _pump(tester, app, Builder(builder: (context) => const CheckoutDialog(total: 50000, initialTender: 'UPI')));
    final qr = tester.widget<FilledButton>(find.byKey(const ValueKey('show-upi-qr')));
    expect(qr.onPressed, isNull);
    expect(find.text('Set UPI ID in Settings'), findsOneWidget);
    expect(find.text('Save pending payment'), findsOneWidget);
    expect(find.text('Complete sale'), findsNothing);
    expect(find.textContaining('checked on the card machine / UPI app'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Complete sale'), findsOneWidget);
  });

  testWidgets('#9: with a UPI ID the QR checkout is offered', (tester) async {
    final app = _app(settings: {'upiVpa': 'shop@upi'});
    await _pump(tester, app, const CheckoutDialog(total: 50000, initialTender: 'UPI'), size: const Size(390, 844));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('show-upi-qr'))).onPressed, isNotNull);
    expect(find.text('Set UPI ID in Settings'), findsNothing);
  });

  testWidgets('#8: confirming a pending UPI sale carries the reference and offers Open invoice', (tester) async {
    final app = _app();
    final entry = {
      'status': 'awaiting-payment',
      'total': 50000,
      'createdAt': '2026-11-22T10:00:00Z',
      'transaction': {
        'transactionId': 'tx-1',
        'lines': [{'productId': 'p', 'qty': 2}],
        'tenders': [{'type': 'UPI', 'amount': 50000, 'confirmed': false, 'reference': 'UTR-77'}],
      },
    };
    app.pending = [entry];
    await _pump(tester, app, Builder(builder: (context) => TextButton(onPressed: () => confirmPendingPayment(context, entry), child: const Text('Go'))));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Awaiting payment'), findsOneWidget);
    expect(find.textContaining('2 × Oil filter'), findsOneWidget);
    expect(find.textContaining('UPI · '), findsOneWidget);
    expect(find.widgetWithText(TextField, 'UTR-77'), findsOneWidget);
    await tester.tap(find.text('Confirm and save invoice'));
    await tester.pumpAndSettle();
    expect(app.confirmedRefs, {'UPI': 'UTR-77'});
    expect(find.textContaining('Invoice INV-9'), findsOneWidget);
    expect(find.text('Open invoice'), findsOneWidget);
  });

  for (final size in const [Size(924, 700), Size(390, 700)]) {
    testWidgets('#11: close shift keeps Expected, Counted and Difference together; count required (${size.width.toInt()}px)', (tester) async {
      final app = _app();
      await _pump(tester, app, Builder(builder: (context) => TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => AppScope(state: app,
                child: const CloseShiftDialog(shift: {'id': 'shift-1', 'openingCash': 0}, expected: 75000))),
            child: const Text('Go'))), size: size);
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      final summary = find.byKey(const ValueKey('close-summary'));
      for (final label in ['Expected in drawer', 'Counted', 'Difference']) {
        expect(find.descendant(of: summary, matching: find.text(label)), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('count-hint')), findsOneWidget);
      // The summary sits on screen with the notes still scrolling above it.
      final bottom = tester.getBottomLeft(summary).dy;
      expect(bottom, lessThanOrEqualTo(size.height));
      final close = find.widgetWithText(FilledButton, 'Close shift');
      expect(tester.widget<FilledButton>(close).onPressed, isNull, reason: 'a count is required');

      await tester.tap(find.text('Enter total'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('counted-total')));
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey('counted-total')), '0');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('count-hint')), findsNothing);
      expect(find.descendant(of: summary, matching: find.textContaining('short')), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(app.endpoint, '/shifts/shift-1/close');
      expect(app.sent!['countedCash'], 0);
    });
  }
}
