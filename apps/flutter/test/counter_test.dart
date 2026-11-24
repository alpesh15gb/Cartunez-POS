// WS-A: counter speed: F-keys, scanner guard, held bills, phone cart pill.
import 'dart:io';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/core/receipt_print.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/counter/counter_panes.dart';
import 'package:cartunez_pos/ui/counter/held_bills.dart';
import 'package:cartunez_pos/ui/screens/billing.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  List<Json>? tenders;
  Json? parked;

  @override
  Future<Json?> checkout({required List<Json> tenders, required int expectedTotal, String placeOfSupply = ''}) async {
    this.tenders = tenders;
    final invoice = {'id': 'inv1', 'number': 'INV-1', 'total': expectedTotal, 'tenders': tenders, 'lines': cart['lines']};
    clearCart();
    return invoice;
  }

  @override
  Future<void> parkCart({Json meta = const {}}) async {
    parked = {...meta, 'cart': cart};
    clearCart();
  }
}

_Register _register() => _fill(_Register());

/// Opens real (temporary) storage first so cart autosaves have somewhere to go.
Future<_Register> _ready(WidgetTester tester) async {
  LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-counter');
  final app = _Register();
  await tester.runAsync(app.init);
  return _fill(app);
}

_Register _fill(_Register app) => app
  ..online = true
  ..session = Session(api: '', token: '', user: {'role': 'cashier', 'id': 'c', 'name': 'Asha'}, branchId: 'b', organizationId: 'o', expiresAt: '')
  ..snapshot = {
    'settings': {'currency': 'INR', 'tenderTypes': ['Cash', 'Card', 'UPI']},
    'products': [
      {'id': 'p', 'name': 'Oil filter', 'sku': 'OF1', 'barcodes': ['8901234567890'], 'retailPrice': 25000, 'wholesalePrice': 20000, 'category': 'Filters'},
      {'id': 's', 'name': 'Seat cover fitting', 'sku': 'SVC-FIT', 'type': 'service', 'retailPrice': 30000, 'category': 'Services'},
    ],
    'locations': [{'id': 'bin', 'kind': 'sellable', 'bin': 'A1'}],
    'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 5}],
    'shifts': [{'id': 'shift', 'userId': 'c'}],
    'holds': [
      {
        'id': 'h1', 'userId': 'c', 'customerName': 'Ravi', 'regNo': 'MH12AB1234', 'label': 'Bay 2', 'createdAt': '2026-11-21T09:00:00Z',
        'cart': {'transactionId': 't1', 'priceLevel': 'wholesale', 'customerId': '', 'discount': 0,
          'vehicle': {'make': 'Maruti', 'model': 'Swift', 'year': 2019},
          'lines': [{'productId': 'p', 'qty': 2, 'binId': 'bin', 'serials': <String>[]}]},
      },
      {
        'id': 'h2', 'userId': 'c', 'customerName': 'Meena', 'regNo': 'KA01MJ0001', 'createdAt': '2026-11-21T10:00:00Z',
        'cart': {'transactionId': 't2', 'priceLevel': 'retail', 'customerId': '', 'discount': 0, 'vehicle': null,
          'lines': [{'productId': 's', 'qty': 1, 'binId': null, 'serials': <String>[]}]},
      },
      // Integration: a job card's stock reservation; never a counter held bill.
      {
        'id': 'h3', 'userId': 'c', 'jobId': 'job-1', 'customerName': 'Workshop', 'createdAt': '2026-11-21T11:00:00Z',
        'cart': {'transactionId': 't3', 'jobId': 'job-1', 'customerId': '', 'discount': 0,
          'lines': [{'productId': 'p', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}]},
      },
    ],
  };

Future<ShellController> _mount(WidgetTester tester, AppState app, Size size, {Widget? above, bool nested = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shell = ShellController()..section = 'billing';
  final counter = ShellScope(
    controller: shell,
    child: Scaffold(body: Column(children: [?above, const Expanded(child: BillingScreen())])),
  );
  await tester.pumpWidget(AppScope(
    state: app,
    child: MaterialApp(
      home: nested ? Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => counter)) : counter,
    ),
  ));
  await tester.pump();
  return shell;
}

const _oneFilter = [{'productId': 'p', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}];

void main() {
  setUp(() => ReceiptPrinterPrefs.instance.reset());

  testWidgets('Clear sale stays on the nested counter after cancel and confirm', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900), nested: true);
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    final clearSale = find.byTooltip('Clear sale');

    await tester.tap(clearSale);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Clear this sale?'), findsNothing);
    expect(app.cart['lines'], _oneFilter);

    await tester.tap(clearSale);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear this sale?'), findsNothing);
    expect(find.byType(BillingScreen), findsOneWidget);
    expect(app.cart['lines'], isEmpty);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('F9 reviews exact cash before posting and resets the counter after confirmation', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    expect(find.byType(PartRow), findsOneWidget); // desktop: dense parts list
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(app.tenders, isNull);
    expect(find.text('Take payment'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.cart['lines'], _oneFilter);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();
    expect(app.tenders, [{'type': 'Cash', 'amount': 25000, 'confirmed': true, 'reference': ''}]);
    expect(find.textContaining('Sale complete'), findsOneWidget);
    expect((app.cart['lines'] as List), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('Sale complete'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('one-tap add chooses the only stocked bin and review is required when stock runs out', (tester) async {
    final app = await _ready(tester);
    app.snapshot = {...app.snapshot, 'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 1}]};
    await _mount(tester, app, const Size(924, 800));
    final add = find.byTooltip('Add Oil filter');
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Picked from bin'), findsNothing);
    expect(app.cart['lines'], _oneFilter);

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Picked from bin'), findsOneWidget);
    expect(find.text('No stock available. Adding this part can make stock negative.'), findsOneWidget);
    expect(app.cart['lines'], _oneFilter);
    await tester.tap(find.text('Cancel'));
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('F6 prepares UPI and Ctrl+Shift+Enter opens checkout without posting a sale', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    app.updateCart({'lines': _oneFilter});
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pumpAndSettle();
    expect(find.text('No UPI ID set, so no QR.'), findsOneWidget);
    expect(app.tenders, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Take payment'), findsOneWidget);
    expect(app.tenders, isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('a long cart item keeps its full name and quantity times rate at 924px', (tester) async {
    final app = await _ready(tester);
    const name = 'Oil filter heavy duty deep housing with extended filter element';
    app.snapshot = {
      ...app.snapshot,
      'products': [{...app.productById('p')!, 'name': name}],
    };
    await _mount(tester, app, const Size(924, 900));
    app.updateCart({'lines': _oneFilter});
    await tester.pumpAndSettle();
    final title = find.descendant(of: find.byType(CartTable), matching: find.text(name));
    expect(title, findsOneWidget);
    expect(tester.widget<Text>(title).maxLines, isNull);
    expect(tester.getSize(title).width, greaterThan(240));
    expect(find.text('1 × ${app.money(25000)}'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('percentage discount becomes paise under the existing cashier approval limit', (tester) async {
    final app = await _ready(tester);
    app.snapshot = {
      ...app.snapshot,
      'settings': {...app.settings, 'cashierDiscountLimit': 2500},
    };
    await _mount(tester, app, const Size(1400, 900));
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Percentage (%)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Discount value'), '12.5');
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Counter promotion');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A manager approval is needed'), findsOneWidget);
    expect(app.cart['discount'], 0);

    await tester.enterText(find.widgetWithText(TextField, 'Discount value'), '10');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(app.cart['discount'], 2500);
    expect(app.currentQuote().total, 22500);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('F4 parks the bill with a customer name and registration number', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Customer name'), 'Ravi');
    await tester.enterText(find.widgetWithText(TextField, 'Vehicle reg. no.'), 'mh 12 ab 1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Hold bill'));
    await tester.pumpAndSettle();
    expect(app.parked!['customerName'], 'Ravi');
    expect(app.parked!['regNo'], 'MH12AB1234');
    expect((app.parked!['cart'] as Map)['lines'], _oneFilter);
    expect((app.cart['lines'] as List), isEmpty);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('arrow keys choose a line; + and Del change and remove it', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.pump();
    expect((app.cart['lines'] as List).single['qty'], 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect((app.cart['lines'] as List), isEmpty);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('a scanner burst in another field is routed to the sale; slow typing is not', (tester) async {
    final app = _register();
    final note = TextEditingController(text: 'note ');
    final noteFocus = FocusNode();
    await _mount(tester, app, const Size(1400, 900), above: TextField(controller: note, focusNode: noteFocus));
    noteFocus.requestFocus();
    await tester.pump();
    var now = Duration.zero;
    CounterKeyboard.clock = () => now;
    addTearDown(() => CounterKeyboard.clock = () => Duration.zero);

    Future<void> type(String text, Duration gap) async {
      for (final ch in text.split('')) {
        now += gap;
        // The OS puts the character in the focused field, then the key event arrives.
        note.text = '${note.text}$ch';
        await tester.sendKeyDownEvent(LogicalKeyboardKey(0x30 + int.parse(ch)), character: ch);
        await tester.sendKeyUpEvent(LogicalKeyboardKey(0x30 + int.parse(ch)));
      }
      now += gap;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }

    await type('8901234567890', const Duration(milliseconds: 8));
    expect(app.cart['lines'], _oneFilter);
    expect(note.text, 'note ');

    await type('1234', const Duration(milliseconds: 250));
    expect((app.cart['lines'] as List).single['qty'], 1);
    expect(note.text, 'note 1234');

    await tester.pumpWidget(const SizedBox());
    noteFocus.dispose();
    note.dispose();
    app.dispose();
  });

  test('held bills are found by name, reg no and item', () {
    final app = _register();
    expect(app.list('holds').length, 3);
    final holds = counterHolds(app); // the job card's reservation (h3) is not offered
    List<String> find(String q) => [for (final h in holds) if (holdMatches(app, h, q)) '${h['id']}'];
    expect(find(''), ['h1', 'h2']);
    expect(find('ravi'), ['h1']);
    expect(find('mh12'), ['h1']);
    expect(find('seat cover'), ['h2']);
    expect(find('swift'), ['h1']);
    app.dispose();
  });

  testWidgets('recall (F5) searches held bills and resumes the whole cart in one click', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(find.text('Held bills (2)'), findsOneWidget);
    expect(find.text('Workshop'), findsNothing, reason: 'job card reservations are billed from the job card');
    await tester.enterText(find.widgetWithText(TextField, 'Name, reg no or item'), 'MH12');
    await tester.pumpAndSettle();
    expect(find.text('Meena'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Resume'));
    await tester.pumpAndSettle();
    expect(app.cart['holdId'], 'h1');
    expect(app.cart['priceLevel'], 'wholesale');
    expect((app.cart['vehicle'] as Map)['model'], 'Swift');
    expect(app.cart['regNo'], 'MH12AB1234');
    expect((app.cart['lines'] as List).single['qty'], 2);
    expect(find.text('Held bills (2)'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('phone: sticky cart pill opens the cart sheet with payment', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(390, 800));
    expect(find.byKey(const ValueKey('cart-pill')), findsNothing);
    expect(find.byType(PartRow), findsOneWidget); // compact rows
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    expect(find.textContaining('1 item • ₹250.00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cart-pill')));
    await tester.pumpAndSettle();
    expect(find.text('Current sale'), findsOneWidget);
    expect(find.text('Exact cash'), findsOneWidget);
    expect(find.text('Staff'), findsOneWidget);
    await tester.tap(find.text('Exact cash'));
    await tester.pumpAndSettle();
    expect(app.tenders, isNull);
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();
    expect(app.tenders!.single['amount'], 25000);
    expect(find.textContaining('Sale complete'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  test('UPI link and WhatsApp link', () {
    expect(upiPayUri(vpa: 'shop@okhdfc', payee: 'Car Tunez', amountMinor: 125050, note: 'Bill 1'),
        'upi://pay?pa=shop%40okhdfc&pn=Car%20Tunez&am=1250.50&cu=INR&tn=Bill%201');
    expect(whatsappUri('98765 43210', 'Hi').toString(), 'https://wa.me/919876543210?text=Hi');
    expect(whatsappUri('', 'Hi').toString(), 'https://wa.me/?text=Hi');
    expect(normalize('x'), 'x');
  });
}
