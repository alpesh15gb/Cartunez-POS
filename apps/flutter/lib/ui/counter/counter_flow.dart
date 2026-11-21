import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../core/receipt_print.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/receipt.dart';
import '../shell.dart';
import '../widgets.dart';
import 'counter_keys.dart';
import 'tender_sheet.dart';

// WS-A: the fast walk-in flow: hold with a name / reg no, customer & vehicle
// in one dialog, express exact cash, and the after-sale screen.

/// "MH 12 AB 1234" -> "MH12AB1234" (same rule as the server).
String normalizeRegNo(String value) => value.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
bool validRegNo(String value) => value.isEmpty || RegExp(r'^[A-Z0-9]{4,12}$').hasMatch(value);

/// Why the current sale cannot be paid yet, or null when it can.
String? checkoutBlocker(AppState app) {
  final lines = (app.cart['lines'] as List).cast<Map>();
  if (lines.isEmpty) return 'Add an item to the sale first.';
  try {
    app.currentQuote();
  } catch (error) {
    return errorText(error);
  }
  final vehicle = app.cart['vehicle'] as Map?;
  if (vehicle != null &&
      lines.any((line) {
        final product = app.productById('${line['productId']}');
        return product != null &&
            fitment(product, Map<String, dynamic>.from(vehicle)).needsOverride &&
            '${line['overrideReason'] ?? ''}'.isEmpty;
      })) {
    return 'Record the fitment approval before payment.';
  }
  return null;
}

/// F9: the customer pays the exact total in cash. No dialog unless something
/// is missing (shift, place of supply).
Future<void> expressCash(BuildContext context) async {
  final app = context.appRead;
  if (!app.canSell) return;
  final blocker = checkoutBlocker(app);
  if (blocker != null) {
    app.toast(blocker);
    return;
  }
  if (!app.tenderTypes.contains('Cash')) {
    app.toast('Cash is switched off in Register settings.');
    return;
  }
  if (!app.online) {
    app.toast('Reconnect before taking payment. Your cart is saved on this counter.');
    return;
  }
  if (app.openShift == null) {
    final opened = await openShiftDialog(context, forCheckout: true);
    if (!opened || !context.mounted) return;
  }
  final place = '${app.customerById('${app.cart['customerId']}')?['stateCode'] ?? app.business['stateCode'] ?? ''}'.trim();
  if (app.gst && !RegExp(r'^\d{2}$').hasMatch(place)) {
    // The dialog asks for the place of supply.
    await startCheckout(context, tender: 'Cash');
    return;
  }
  final total = app.currentQuote().total;
  Json? invoice;
  try {
    invoice = await app.checkout(
      tenders: [{'type': 'Cash', 'amount': total, 'confirmed': true, 'reference': ''}],
      expectedTotal: total,
      placeOfSupply: place,
    );
  } catch (error) {
    app.toast(errorText(error));
    return;
  }
  if (invoice != null && context.mounted) await afterSale(context, invoice);
}

/// After a completed sale: print (silently on Windows) when asked or when this
/// device prints every receipt, offer WhatsApp / share, then hand the counter
/// back to the scanner for the next customer.
Future<void> afterSale(BuildContext context, Json invoice, {bool print = false}) async {
  final app = context.appRead;
  final prefs = ReceiptPrinterPrefs.instance;
  await prefs.load();
  if (print || prefs.autoPrint) {
    unawaited(printReceipt(app, invoice).catchError((Object error) => app.toast('Could not print the receipt: $error')));
  }
  if (!context.mounted) return;
  CounterScope.read(context)?.select(null);
  await showDialog<void>(context: context, builder: (_) => AppScope(state: app, child: SaleDoneDialog(invoice: invoice, printed: print || prefs.autoPrint)));
  if (context.mounted) focusScan(context);
}

class SaleDoneDialog extends StatelessWidget {
  const SaleDoneDialog({super.key, required this.invoice, this.printed = false});
  final Json invoice;
  final bool printed;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final change = (invoice['change'] ?? 0) as num;
    final phone = invoice['customer'] is Map ? '${invoice['customer']['phone'] ?? ''}' : '';
    void next() => Navigator.pop(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP): () => printReceipt(app, invoice),
        const SingleActivator(LogicalKeyboardKey.keyW): () => shareReceiptWhatsApp(app, invoice),
      },
      child: AlertDialog(
        icon: const Icon(Icons.check_circle, size: 40),
        // The invoice number on its own line, never broken at a hyphen.
        title: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Sale complete'),
          if ('${invoice['number'] ?? ''}'.isNotEmpty)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('${invoice['number']}',
                  maxLines: 1, softWrap: false, style: Theme.of(context).textTheme.titleMedium?.copyWith(letterSpacing: 0.4)),
            ),
        ]),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(app.money(invoice['total'] as num?),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
            if (change > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Give change ${app.money(change)}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            if (printed) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Printing the receipt…')),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: () => printReceipt(app, invoice),
                icon: const Icon(Icons.print_outlined),
                label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Print'), KeyCap('P')]),
              ),
              OutlinedButton.icon(
                onPressed: () => shareReceiptWhatsApp(app, invoice),
                icon: const Icon(Icons.chat_outlined),
                label: Row(mainAxisSize: MainAxisSize.min, children: [Text(phone.isEmpty ? 'WhatsApp' : 'WhatsApp $phone'), const KeyCap('W')]),
              ),
              OutlinedButton.icon(
                onPressed: () => shareReceipt(app, invoice),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share PDF'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  showReceipt(context, invoice);
                },
                child: const Text('View receipt'),
              ),
            ]),
          ]),
        ),
        actions: [
          FilledButton.icon(
            autofocus: true,
            style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
            onPressed: next,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Next customer'), KeyCap('Enter', onDark: true)]),
          ),
        ],
      ),
    );
  }
}

/// F4: park the bill with a quick name / vehicle registration prompt.
Future<void> parkWithPrompt(BuildContext context) async {
  final app = context.appRead;
  if (!app.canSell) return;
  if ((app.cart['lines'] as List).isEmpty) {
    app.toast('Add an item before holding the bill.');
    return;
  }
  if (!app.online) {
    app.toast('Reconnect to hold this bill. Held bills reserve stock on the server.');
    return;
  }
  final held = app.list('holds').where((h) => h['id'] == app.cart['holdId']).firstOrNull;
  await showDialog<void>(
    context: context,
    builder: (_) => AppScope(state: app, child: HoldPrompt(held: held)),
  );
}

class HoldPrompt extends StatefulWidget {
  const HoldPrompt({super.key, this.held});
  final Json? held;
  @override
  State<HoldPrompt> createState() => _HoldPromptState();
}

class _HoldPromptState extends State<HoldPrompt> {
  late final AppState app = context.appRead;
  late final name = TextEditingController(
      text: '${widget.held?['customerName'] ?? app.customerById('${app.cart['customerId']}')?['name'] ?? ''}');
  late final reg = TextEditingController(text: '${widget.held?['regNo'] ?? app.cart['regNo'] ?? ''}');
  late final note = TextEditingController(text: '${widget.held?['label'] ?? ''}');
  int? hours;
  String? error;
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    reg.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) return;
    final plate = normalizeRegNo(reg.text.trim());
    if (!validRegNo(plate)) {
      return setState(() => error = 'Enter the registration with letters and digits only, for example MH12AB1234.');
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await app.parkCart(meta: {
        'customerName': name.text.trim(),
        'regNo': plate,
        'label': note.text.trim(),
        if (hours != null) 'expiresAt': DateTime.now().toUtc().add(Duration(hours: hours!)).toIso8601String(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hold bill'),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Customer name'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: reg,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Vehicle reg. no.', hintText: 'MH12AB1234'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Note (bay, mechanic…)'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (value, label) in const [(null, 'Until resumed'), (2, '2 hours'), (24, '1 day'), (72, '3 days')])
              ChoiceChip(label: Text(label), selected: hours == value, onSelected: (_) => setState(() => hours = value)),
          ]),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: busy ? null : _save,
          icon: const Icon(Icons.pause),
          label: const Text('Hold bill'),
        ),
      ],
    );
  }
}

/// F2: customer and vehicle in one dialog. A registration number that matches
/// a saved vehicle fills in the vehicle (and its owner).
Future<void> editCustomerVehicle(BuildContext context) async {
  final app = context.appRead;
  final current = Map<String, dynamic>.from(app.cart['vehicle'] as Map? ?? {});
  await showFormDialog<void>(
    context,
    title: 'Customer and vehicle',
    submit: 'Use',
    fields: [
      FieldSpec('customerId', 'Customer', kind: FieldKind.select, value: '${app.cart['customerId'] ?? ''}', options: [
        ('', 'Walk-in customer'),
        for (final c in app.list('customers'))
          ('${c['id']}', '${c['name']}${'${c['phone'] ?? ''}'.isNotEmpty ? ' · ${c['phone']}' : ''}'),
      ]),
      FieldSpec('regNo', 'Vehicle reg. no.', value: app.cart['regNo'], help: 'For example MH12AB1234'),
      FieldSpec('preset', 'Saved vehicle', kind: FieldKind.select, options: [
        for (final v in app.list('vehicles')) ('${v['id']}', '${v['year']} ${v['make']} ${v['model']} ${v['engine'] ?? ''}'.trim()),
      ]),
      FieldSpec('make', 'Make', value: current['make'], advanced: true),
      FieldSpec('model', 'Model', value: current['model'], advanced: true),
      FieldSpec('year', 'Year', kind: FieldKind.number, value: current['year'], advanced: true),
    ],
    onSubmit: (values) async {
      final plate = normalizeRegNo('${values['regNo'] ?? ''}'.trim());
      if (!validRegNo(plate)) throw FormProblem('Enter the registration with letters and digits only, for example MH12AB1234.');
      Json? vehicle = app.cart['vehicle'] == null ? null : current;
      var customerId = '${values['customerId'] ?? ''}';
      final saved = plate.isEmpty
          ? null
          : app.list('vehicles').where((v) => normalizeRegNo('${v['regNo'] ?? v['registration'] ?? ''}') == plate).firstOrNull;
      if ('${values['preset'] ?? ''}'.isNotEmpty) {
        vehicle = app.list('vehicles').firstWhere((v) => v['id'] == values['preset']);
      } else if (saved != null) {
        vehicle = saved;
        if (customerId.isEmpty && '${saved['customerId'] ?? ''}'.isNotEmpty) customerId = '${saved['customerId']}';
      } else if ('${values['make'] ?? ''}'.isNotEmpty && '${values['model'] ?? ''}'.isNotEmpty) {
        vehicle = {'make': values['make'], 'model': values['model'], 'year': int.tryParse('${values['year']}') ?? 0};
      }
      final vehicleChanged = !_sameVehicle(vehicle, app.cart['vehicle'] as Map?);
      app.updateCart({
        'customerId': customerId,
        'regNo': plate,
        if (vehicleChanged) ...{
          'vehicle': vehicle,
          'approvalId': null,
          'lines': [for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': ''}],
        },
      });
    },
  );
}

bool _sameVehicle(Map? a, Map? b) =>
    (a == null && b == null) ||
    (a != null && b != null && a['make'] == b['make'] && a['model'] == b['model'] && '${a['year']}' == '${b['year']}' && a['id'] == b['id']);

/// Staff who can be tagged on a line ("who sold / fitted this"); no commission.
List<(String, String)> staffChoices(AppState app) {
  final users = app.list('users').where((u) => u['active'] != false).toList();
  final me = app.session?.userId;
  return [
    if (me != null && !users.any((u) => u['id'] == me)) (me, app.userName(me)),
    for (final u in users) ('${u['id']}', '${u['name'] ?? u['email']}'),
  ];
}

/// Picks the staff member for one cart line.
Future<void> tagLineStaff(BuildContext context, int index) async {
  final app = context.appRead;
  final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  if (index >= lines.length) return;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Who sold or fitted this?')),
        ListTile(leading: const Icon(Icons.person_off_outlined), title: const Text('No one'), onTap: () => Navigator.pop(sheet, '')),
        for (final (id, name) in staffChoices(app))
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(name),
            selected: lines[index]['staffId'] == id,
            onTap: () => Navigator.pop(sheet, id),
          ),
      ]),
    ),
  );
  if (choice == null) return;
  final fresh = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  if (index >= fresh.length) return;
  fresh[index] = {...fresh[index], 'staffId': choice.isEmpty ? null : choice}..removeWhere((k, v) => k == 'staffId' && v == null);
  app.updateCart({'lines': fresh});
}

/// The shell (search box, navigation) around the counter, when there is one.
ShellController? shellOf(BuildContext context) => context.getInheritedWidgetOfExactType<ShellScope>()?.notifier;
