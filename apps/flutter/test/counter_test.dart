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
    ],
  };

Future<ShellController> _mount(WidgetTester tester, AppState app, Size size, {Widget? above}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shell = ShellController()..section = 'billing';
  await tester.pumpWidget(AppScope(
    state: app,
    child: MaterialApp(
      home: ShellScope(
        controller: shell,
        child: Scaffold(body: Column(children: [?above, const Expanded(child: BillingScreen())])),
      ),
    ),
  ));
  await tester.pump();
  return shell;
}

const _oneFilter = [{'productId': 'p', 'qty': 1, 'binId': 'bin', 'serials': <String>[]}];

void main() {
  setUp(() => ReceiptPrinterPrefs.instance.reset());

  testWidgets('F9 completes an exact-cash sale and the counter resets for the next customer', (tester) async {
    final app = await _ready(tester);
    await _mount(tester, app, const Size(1400, 900));
    expect(find.byType(PartRow), findsOneWidget); // desktop: dense parts list
    app.updateCart({'lines': _oneFilter});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
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
    final holds = app.list('holds');
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
