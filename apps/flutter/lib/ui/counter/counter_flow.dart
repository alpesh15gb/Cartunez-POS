import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../core/receipt_print.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/people.dart' show editContact;
import '../screens/receipt.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import '../workshop/common.dart' show vehicleTitle;
import '../workshop/vehicles.dart' show counterVehicle, editVehicle, searchVehicles;
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

/// F9 prepares the exact cash amount for review before posting the sale.
Future<void> expressCash(BuildContext context) async {
  final app = context.appRead;
  if (!app.canSell) return;
  if (!app.tenderTypes.contains('Cash')) {
    app.toast('Cash is switched off in Register settings.');
    return;
  }
  await startCheckout(context, tender: 'Cash');
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
            if (invoice['exchange']?['refunds'] is List && (invoice['exchange']['refund'] ?? 0) > 0)
              Text(refundInstructions(app, {...invoice['exchange'] as Map, 'currency': invoice['currency']})),
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

/// F2: searchable customer and vehicle picker in one dialog. Selecting a
/// registered vehicle fills in the fitment vehicle (with customerVehicleId) and
/// links its owner; selecting a customer offers their registered vehicles.
Future<void> editCustomerVehicle(BuildContext context) async {
  final app = context.appRead;
  await showDialog<void>(
    context: context,
    builder: (_) => AppScope(state: app, child: const CustomerVehicleDialog()),
  );
}

class CustomerVehicleDialog extends StatefulWidget {
  const CustomerVehicleDialog({super.key});
  @override
  State<CustomerVehicleDialog> createState() => _CustomerVehicleDialogState();
}

class _CustomerVehicleDialogState extends State<CustomerVehicleDialog> {
  late final AppState app = context.appRead;
  final search = TextEditingController();
  late String customerId = '${app.cart['customerId'] ?? ''}';
  late String regNo = '${app.cart['regNo'] ?? ''}';
  late Json? vehicle = app.cart['vehicle'] == null ? null : Map<String, dynamic>.from(app.cart['vehicle'] as Map);
  bool manualVehicle = false;
  late final make = TextEditingController(text: '${vehicle?['make'] ?? ''}');
  late final model = TextEditingController(text: '${vehicle?['model'] ?? ''}');
  late final year = TextEditingController(text: '${vehicle?['year'] ?? ''}' == '0' ? '' : '${vehicle?['year'] ?? ''}');
  String? error;

  @override
  void dispose() {
    search.dispose();
    make.dispose();
    model.dispose();
    year.dispose();
    super.dispose();
  }

  void _apply() {
    final plate = normalizeRegNo(regNo.trim());
    if (!validRegNo(plate)) {
      setState(() => error = 'Enter the registration with letters and digits only, for example MH12AB1234.');
      return;
    }
    var resolvedVehicle = vehicle;
    var resolvedCustomerId = customerId;
    if (plate.isNotEmpty && resolvedVehicle == null) {
      final saved = app.list('customerVehicles')
          .where((v) => normalizeRegNo('${v['regNo'] ?? v['regKey'] ?? ''}') == plate)
          .firstOrNull;
      if (saved != null) {
        resolvedVehicle = counterVehicle(saved);
        if (resolvedCustomerId.isEmpty && '${saved['customerId'] ?? ''}'.isNotEmpty) {
          resolvedCustomerId = '${saved['customerId']}';
        }
      }
    }
    if (manualVehicle && make.text.trim().isNotEmpty && model.text.trim().isNotEmpty) {
      resolvedVehicle = {
        'make': make.text.trim(),
        'model': model.text.trim(),
        'year': int.tryParse(year.text.trim()) ?? 0,
        if (plate.isNotEmpty) 'regNo': plate,
      };
    }
    final vehicleChanged = !_sameVehicle(resolvedVehicle, app.cart['vehicle'] as Map?);
    app.updateCart({
      'customerId': resolvedCustomerId,
      'regNo': plate,
      if (vehicleChanged) ...{
        'vehicle': resolvedVehicle,
        'approvalId': null,
        'lines': [for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': ''}],
      },
    });
    Navigator.pop(context);
  }

  void _pickRegisteredVehicle(Json v) {
    setState(() {
      vehicle = counterVehicle(v);
      regNo = '${v['regNo'] ?? ''}';
      make.text = '${v['make'] ?? ''}';
      model.text = '${v['model'] ?? ''}';
      year.text = '${v['year'] ?? ''}' == '0' ? '' : '${v['year'] ?? ''}';
      manualVehicle = false;
      if (customerId.isEmpty && '${v['customerId'] ?? ''}'.isNotEmpty) {
        customerId = '${v['customerId']}';
      }
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final q = normalize(search.text);
    final selectedCustomer = customerId.isEmpty ? null : app.customerById(customerId);
    final customers = app.list('customers').where((c) {
      if (q.isEmpty) return true;
      return normalize('${c['name']} ${c['phone']} ${c['taxRegistrationId']}').contains(q);
    }).take(25).toList();
    final vehicles = searchVehicles(app, search.text).where((v) {
      if (q.isNotEmpty) return true;
      return customerId.isEmpty || v['customerId'] == customerId;
    }).take(20).toList();
    final customerVehicles = customerId.isEmpty
        ? const <Json>[]
        : app.list('customerVehicles').where((v) => v['customerId'] == customerId).toList();
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: const Text('Customer and vehicle'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(10)),
              child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                InputChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text(selectedCustomer == null
                      ? 'Walk-in customer'
                      : '${selectedCustomer['name']}${'${selectedCustomer['phone'] ?? ''}'.isNotEmpty ? ' · ${selectedCustomer['phone']}' : ''}'),
                  onDeleted: customerId.isEmpty ? null : () => setState(() => customerId = ''),
                ),
                if (vehicle != null || regNo.isNotEmpty)
                  InputChip(
                    avatar: const Icon(Icons.directions_car_outlined, size: 18),
                    label: Text(vehicle == null
                        ? regNo
                        : '${regNo.isEmpty ? '' : '$regNo · '}${vehicle!['year'] == 0 || vehicle!['year'] == null ? '' : '${vehicle!['year']} '}${vehicle!['make']} ${vehicle!['model']}'.trim()),
                    onDeleted: () => setState(() {
                      vehicle = null;
                      regNo = '';
                      make.clear();
                      model.clear();
                      year.clear();
                    }),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('customer-vehicle-search'),
              controller: search,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Search customer, phone or vehicle reg. no.',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close, size: 18), onPressed: () => setState(search.clear)),
              ),
              onChanged: (_) => setState(() => error = null),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              OutlinedButton.icon(
                onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) {
                  if (mounted) setState(() => customerId = '${saved['id']}');
                }),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('New customer'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final saved = await editVehicle(context, {
                    if (customerId.isNotEmpty) 'customerId': customerId,
                    if (search.text.trim().isNotEmpty && RegExp(r'\d').hasMatch(search.text))
                      'regNo': search.text.trim().toUpperCase(),
                  });
                  if (saved != null && mounted) _pickRegisteredVehicle(saved);
                },
                icon: const Icon(Icons.directions_car_outlined, size: 18),
                label: const Text('New vehicle'),
              ),
              TextButton.icon(
                onPressed: () => setState(() => manualVehicle = !manualVehicle),
                icon: Icon(manualVehicle ? Icons.expand_less : Icons.tune, size: 18),
                label: Text(manualVehicle ? 'Hide manual vehicle' : 'Enter make / model'),
              ),
            ]),
            if (customerVehicles.isNotEmpty && q.isEmpty) ...[
              const SizedBox(height: 8),
              Text('Customer vehicles', style: small),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final v in customerVehicles)
                  ActionChip(
                    avatar: const Icon(Icons.directions_car_outlined, size: 16),
                    label: Text(vehicleTitle(v)),
                    onPressed: () => _pickRegisteredVehicle(v),
                  ),
              ]),
            ],
            if (manualVehicle) ...[
              const SizedBox(height: 10),
              TextFormField(
                initialValue: regNo,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Vehicle reg. no.', hintText: 'MH12AB1234'),
                onChanged: (v) => regNo = v,
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: make, decoration: const InputDecoration(labelText: 'Make'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: model, decoration: const InputDecoration(labelText: 'Model'))),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: TextField(controller: year, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Year')),
                ),
              ]),
            ],
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(shrinkWrap: true, children: [
                if (vehicles.isNotEmpty) ...[
                  Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('Vehicles', style: small)),
                  for (final v in vehicles)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.directions_car_outlined, size: 20),
                      title: Text(vehicleTitle(v)),
                      subtitle: v['customerId'] == null ? null : Text(app.customerById('${v['customerId']}')?['name'] ?? ''),
                      selected: vehicle?['customerVehicleId'] == v['id'],
                      onTap: () => _pickRegisteredVehicle(v),
                    ),
                ],
                if (customers.isNotEmpty) ...[
                  Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: Text('Customers', style: small)),
                  for (final c in customers)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline, size: 20),
                      title: Text('${c['name']}'),
                      subtitle: '${c['phone'] ?? ''}'.isEmpty ? null : Text('${c['phone']}'),
                      selected: customerId == '${c['id']}',
                      onTap: () => setState(() => customerId = '${c['id']}'),
                    ),
                ],
                if (vehicles.isEmpty && customers.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No matching customers or vehicles.')),
              ]),
            ),
            if (error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _apply, child: const Text('Use')),
      ],
    );
  }
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
