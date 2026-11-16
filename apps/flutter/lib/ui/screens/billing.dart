import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'people.dart';
import 'receipt.dart';

final billingKey = GlobalKey();

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});
  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  String category = 'All parts';

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1000;
    return ValueListenableBuilder(
      key: billingKey,
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final vehicle = app.cart['vehicle'] as Map?;
        final categories = {'All parts', ...app.products.map((p) => '${p['category']}')}.toList();
        final parts = app.products.where((p) {
          if (category != 'All parts' && p['category'] != category) return false;
          if (q.isNotEmpty &&
              ![p['name'], p['sku'], p['partNumber'], p['description'], ...(p['barcodes'] as List? ?? []), ...(p['oemReferences'] as List? ?? [])]
                  .any((v) => normalize(v).contains(q))) {
            return false;
          }
          if (vehicle != null && fitment(p, Map<String, dynamic>.from(vehicle)).needsOverride) return false;
          return true;
        }).toList();
        final catalog = CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 20, wide ? 20 : 16, 4),
            sliver: SliverList.list(children: [
              Row(children: [
                Expanded(child: Text('Sales terminal', style: Theme.of(context).textTheme.headlineMedium)),
                if (app.feature('fitment')) _VehicleChip(onTap: () => chooseVehicle(context)),
              ]),
              const SizedBox(height: 4),
              Text(app.openShift == null ? 'Open a shift to start selling.' : 'Scan or pick parts, then take payment.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              SizedBox(
                height: 38,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c),
                        selected: c == category,
                        onSelected: (_) => setState(() => category = c),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 14),
            ]),
          ),
          if (parts.isEmpty)
            SliverToBoxAdapter(child: EmptyState(message: q.isEmpty ? 'No parts in this category.' : 'No part matches "${search.text}".'))
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 0, wide ? 20 : 16, wide ? 28 : 96),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisExtent: 286,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: parts.length,
                itemBuilder: (context, i) => _PartCard(product: parts[i]),
              ),
            ),
        ]);
        if (wide) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: catalog),
            Container(
              width: 380,
              decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: Brand.line))),
              child: const CartPanel(),
            ),
          ]);
        }
        return Stack(children: [
          catalog,
          if ((app.cart['lines'] as List).isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: AppScope(state: app, child: const CartPanel())),
                ),
                child: Row(children: [
                  const Icon(Icons.shopping_bag_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('View sale · ${(app.cart['lines'] as List).length} item(s)', overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Text(app.money(app.bill?.total ?? 0)),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}

class _VehicleChip extends StatelessWidget {
  const _VehicleChip({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final vehicle = context.app.cart['vehicle'] as Map?;
    return ActionChip(
      avatar: const Icon(Icons.directions_car_outlined, size: 18),
      label: Text(vehicle == null ? 'Any vehicle' : '${vehicle['year']} ${vehicle['make']} ${vehicle['model']}'),
      onPressed: onTap,
    );
  }
}

class _PartCard extends StatelessWidget {
  const _PartCard({required this.product});
  final Json product;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final service = product['type'] == 'service';
    final stock = app.available('${product['id']}');
    final low = !service && stock <= (product['reorderLevel'] ?? 0);
    final price = app.cart['priceLevel'] == 'wholesale' ? product['wholesalePrice'] : product['retailPrice'];
    final icon = '${product['icon'] ?? ''}';
    final vehicle = app.cart['vehicle'] as Map?;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => addPart(context, product),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 128,
            child: Stack(fit: StackFit.expand, children: [
              Container(
                color: const Color(0xFFEFF3F0),
                child: icon.isNotEmpty
                    ? Image.asset('assets/parts/$icon.jpg', fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(Icons.settings_outlined, size: 44, color: Color(0xFF8FA99B)))
                    : const Icon(Icons.settings_outlined, size: 44, color: Color(0xFF8FA99B)),
              ),
              Positioned(
                left: 8,
                top: 8,
                child: StatusChip(service ? 'Service' : stock > 0 ? '$stock in stock' : 'Out of stock'),
              ),
              if (low && stock > 0) const Positioned(right: 8, top: 8, child: StatusChip('Low')),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${product['brand']} · ${product['sku']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 3),
                Text('${product['name']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 3),
                Text(
                  [
                    if (vehicle != null) titleCase(fitment(product, Map<String, dynamic>.from(vehicle)).status),
                    if ('${product['partNumber'] ?? ''}'.isNotEmpty) '${product['partNumber']}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Row(children: [
                  Expanded(
                    child: Text(app.money(price as num?),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3)),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Add ${product['name']}',
                    onPressed: () => addPart(context, product),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------- cart ----------------

class CartPanel extends StatelessWidget {
  const CartPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final cart = app.cart;
    final lines = (cart['lines'] as List).cast<Map>();
    Quote? bill;
    String? billError;
    try {
      bill = app.currentQuote();
    } catch (error) {
      billError = errorText(error);
    }
    final vehicle = cart['vehicle'] as Map?;
    final needsApproval = vehicle != null &&
        lines.any((line) {
          final product = app.productById('${line['productId']}');
          return product != null &&
              fitment(product, Map<String, dynamic>.from(vehicle)).needsOverride &&
              '${line['overrideReason'] ?? ''}'.isEmpty;
        });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 10, 6),
        child: Row(children: [
          Expanded(child: Text('Current sale', style: Theme.of(context).textTheme.titleLarge)),
          if (lines.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'Clear this sale?', 'All items will be removed from the current bill.', action: 'Clear')) {
                  app.clearCart();
                }
              },
              child: const Text('Clear'),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: '${cart['customerId'] ?? ''}',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Walk-in customer')),
                for (final c in app.list('customers')) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')),
              ],
              onChanged: (value) => app.updateCart({'customerId': value ?? ''}),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.outlined(
            tooltip: 'New customer',
            onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) => app.updateCart({'customerId': saved['id']})),
            icon: const Icon(Icons.person_add_alt),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: 'retail', label: Text('Retail')), ButtonSegment(value: 'wholesale', label: Text('Wholesale'))],
          selected: {'${cart['priceLevel'] ?? 'retail'}'},
          onSelectionChanged: (v) => app.updateCart({'priceLevel': v.first}),
        ),
      ),
      const Divider(),
      Expanded(
        child: lines.isEmpty
            ? const EmptyState(message: 'No items yet.\nScan a barcode or tap a part.', icon: Icons.qr_code_2)
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                itemCount: lines.length,
                separatorBuilder: (_, _) => const Divider(height: 18),
                itemBuilder: (context, index) => _CartLine(index: index, line: bill?.lines.elementAtOrNull(index)),
              ),
      ),
      if (billError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: Text('$billError Clear the sale or refresh.', style: const TextStyle(color: Brand.danger)),
        ),
      if (needsApproval)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.verified_user_outlined, color: Brand.danger),
            onPressed: () => approveFitment(context),
            label: const Text('Record fitment approval'),
          ),
        ),
      Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Brand.line)), color: Color(0xFFFBFCFB)),
        child: Column(children: [
          _TotalRow('Subtotal${bill?.taxMode == 'inclusive' ? ' (incl. tax)' : ''}', app.money(bill?.subtotal ?? 0)),
          _TotalRow('${app.settings['taxDisplayName'] ?? 'Tax'}${bill?.taxMode == 'inclusive' ? ' included' : ''}',
              app.money(bill?.tax ?? 0)),
          if ((bill?.core ?? 0) > 0) _TotalRow('Core deposits', app.money(bill!.core)),
          InkWell(
            onTap: lines.isEmpty ? null : () => editDiscount(context),
            child: _TotalRow(
              'Discount',
              (bill?.discount ?? 0) > 0 ? '−${app.money(bill!.discount)}' : 'Add',
              accent: true,
            ),
          ),
          if ((bill?.rounding ?? 0) != 0) _TotalRow('Rounding', app.money(bill!.rounding)),
          const SizedBox(height: 6),
          Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            Text(app.money(bill?.total ?? 0), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: lines.isEmpty || !app.online ? null : () => holdSale(context),
              icon: const Icon(Icons.pause, size: 18),
              label: const Text('Hold'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: lines.isEmpty || needsApproval || billError != null ? null : () => startCheckout(context),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Checkout  (F6)'),
              ),
            ),
          ]),
          if (!app.isManager)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText('Approval reference ${cart['transactionId']}',
                  style: const TextStyle(fontSize: 10, color: Brand.muted, fontFamily: 'monospace')),
            ),
        ]),
      ),
    ]);
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.value, {this.accent = false});
  final String label;
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: accent ? Brand.forest : Brand.muted, fontWeight: accent ? FontWeight.w700 : null))),
          Text(value, style: TextStyle(color: accent ? Brand.forest : Brand.ink, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.index, required this.line});
  final int index;
  final QuoteLine? line;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final raw = Map<String, dynamic>.from((app.cart['lines'] as List)[index] as Map);
    final product = app.productById('${raw['productId']}');
    final serial = product?['serialTracked'] == true;
    final vehicle = app.cart['vehicle'] as Map?;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${product?['name'] ?? raw['productId']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            '${app.money(line?.unitPrice ?? 0)} each${raw['binId'] != null ? ' · ${app.locationName('${raw['binId']}')}' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (vehicle != null && product != null)
            Text(
              '${titleCase(fitment(product, Map<String, dynamic>.from(vehicle)).status)}'
              '${'${raw['overrideReason'] ?? ''}'.isNotEmpty ? ' · override recorded' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if ((raw['serials'] as List? ?? []).isNotEmpty)
            Text('Serials ${(raw['serials'] as List).join(', ')}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          _Stepper(
            value: raw['qty'] as int,
            enabled: !serial,
            onChanged: (qty) => setLineQuantity(context, index, qty),
          ),
        ]),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          onPressed: () => setLineQuantity(context, index, 0),
          icon: const Icon(Icons.close, size: 18),
        ),
        Text(app.money(line?.total ?? 0), style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    ]);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged, this.enabled = true});
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove, size: 16),
          ),
          SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add, size: 16),
          ),
        ]),
      );
}

// ---------------- actions ----------------

bool setLineQuantity(BuildContext context, int index, int qty, {bool quiet = false}) {
  final app = context.appRead;
  final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  if (index >= lines.length) return false;
  if (qty < 1) {
    lines.removeAt(index);
    app.updateCart({'lines': lines});
    return true;
  }
  if (qty > 9999) return false;
  final line = lines[index];
  final product = app.productById('${line['productId']}');
  if (line['binId'] != null && product?['type'] != 'service') {
    final max = app.available('${line['productId']}', '${line['binId']}');
    if (qty > max) {
      if (!quiet) app.toast('Only $max available in ${app.locationName('${line['binId']}')}.');
      return false;
    }
  }
  lines[index] = {...line, 'qty': qty};
  app.updateCart({'lines': lines});
  return true;
}

Future<void> addPart(BuildContext context, Json product) async {
  final app = context.appRead;
  if (!app.canSell) {
    app.toast('Your role cannot create sales.');
    return;
  }
  final service = product['type'] == 'service' || product['category'] == 'Services';
  final choices = app.sellableBins.where((b) => app.available('${product['id']}', '${b['id']}') > 0).toList();
  if (!service && choices.isEmpty) {
    app.toast('${product['name']} is out of stock.');
    return;
  }
  final vehicle = app.cart['vehicle'] as Map?;
  final fit = vehicle == null ? const FitResult('unchecked') : fitment(product, Map<String, dynamic>.from(vehicle));
  await showFormDialog<void>(
    context,
    title: 'Add ${product['name']}',
    submit: 'Add to sale',
    fields: [
      const FieldSpec('qty', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      if (!service)
        FieldSpec('binId', 'Picked from bin',
            kind: FieldKind.select,
            required: true,
            value: choices.first['id'],
            options: [for (final b in choices) ('${b['id']}', '${app.binName(b)} · ${app.available('${product['id']}', '${b['id']}')} available')]),
      if (product['serialTracked'] == true)
        const FieldSpec('serials', 'Serial numbers', required: true, help: 'One per unit, separated by commas.'),
      if (fit.needsOverride)
        FieldSpec('overrideReason', '${titleCase(fit.status)} fitment — reason',
            required: true,
            help: fit.missing.isNotEmpty ? 'Add ${fit.missing.join(', ')} to the vehicle to verify the match.' : null),
      if (fit.needsOverride && !app.isManager)
        FieldSpec('approvalId', 'Manager approval ID',
            required: true, help: 'Ask a manager to approve fitment for ${app.cart['transactionId']}.'),
    ],
    onSubmit: (values) async {
      final qty = int.tryParse('${values['qty']}') ?? 0;
      if (qty < 1 || qty > 9999) throw FormProblem('Enter a quantity from 1 to 9999.');
      final binId = '${values['binId'] ?? ''}'.isEmpty ? null : '${values['binId']}';
      final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final existing = lines.indexWhere((l) => l['productId'] == product['id'] && l['binId'] == binId);
      final already = existing >= 0 ? lines[existing]['qty'] as int : 0;
      if (binId != null && qty + already > app.available('${product['id']}', binId)) {
        throw FormProblem('Only ${app.available('${product['id']}', binId)} available in that bin.');
      }
      final serials = splitList(values['serials']);
      if (product['serialTracked'] == true && serials.length != qty) {
        throw FormProblem('Enter one serial number for each unit.');
      }
      var approvalId = '${values['approvalId'] ?? ''}'.isNotEmpty ? values['approvalId'] : app.cart['approvalId'];
      if (fit.needsOverride && app.isManager) {
        final approval = await app.api('/approvals', body: {
          'action': 'fitment',
          'transactionId': app.cart['transactionId'],
          'reason': values['overrideReason'],
        }) as Map;
        approvalId = approval['id'];
      }
      final line = {
        'productId': product['id'],
        'qty': qty + already,
        'binId': binId,
        'serials': [...(existing >= 0 ? lines[existing]['serials'] as List? ?? [] : []), ...serials],
        'overrideReason': '${values['overrideReason'] ?? ''}'.isNotEmpty
            ? values['overrideReason']
            : (existing >= 0 ? lines[existing]['overrideReason'] ?? '' : ''),
      };
      if (existing >= 0) {
        lines[existing] = line;
      } else {
        lines.add(line);
      }
      app.updateCart({'lines': lines, 'approvalId': approvalId});
    },
  );
}

void handleScan(BuildContext context, ShellController shell, String raw) {
  final app = context.appRead;
  final code = raw.trim();
  if (code.isEmpty) return;
  final matches = app.findByCode(code);
  final bin = app.bins.where((b) => normalize(b['id']) == normalize(code)).firstOrNull;
  if (shell.section != 'billing' || !app.canSell) {
    shell.search.text = bin != null && matches.isEmpty ? app.binName(bin) : code;
    if (matches.isEmpty && bin == null) app.toast('No part or bin matches "$code".');
    return;
  }
  if (matches.isEmpty) {
    shell.search.text = code;
    app.toast(bin != null ? '${app.binName(bin)} is a bin label. Scan the part barcode.' : 'No part matches "$code".');
    return;
  }
  if (matches.length > 1) {
    shell.search.text = code;
    app.toast('${matches.length} parts share "$code". Choose the right one.');
    return;
  }
  final product = matches.first;
  shell.search.clear();
  HapticFeedback.selectionClick();
  if (product['serialTracked'] != true) {
    final lines = app.cart['lines'] as List;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i]['productId'] != product['id']) continue;
      if (setLineQuantity(context, i, (lines[i]['qty'] as int) + 1, quiet: true)) {
        app.toast('${product['name']} × ${(app.cart['lines'] as List)[i]['qty']}');
        return;
      }
    }
  }
  addPart(context, product);
}

Future<void> scanWithCamera(BuildContext context, ShellController shell) async {
  final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _CameraScanPage()));
  if (code != null && context.mounted) handleScan(context, shell, code);
}

class _CameraScanPage extends StatefulWidget {
  const _CameraScanPage();
  @override
  State<_CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<_CameraScanPage> {
  bool done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Scan barcode'), backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Stack(children: [
          MobileScanner(
            onDetect: (capture) {
              final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
              if (value == null || done) return;
              done = true;
              HapticFeedback.mediumImpact();
              Navigator.pop(context, value);
            },
          ),
          Center(
            child: Container(
              width: 280,
              height: 150,
              decoration: BoxDecoration(border: Border.all(color: Brand.lime, width: 3), borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Text('Hold the barcode inside the frame', textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
          ),
        ]),
      );
}

Future<void> chooseVehicle(BuildContext context) async {
  final app = context.appRead;
  final current = Map<String, dynamic>.from(app.cart['vehicle'] as Map? ?? {});
  await showFormDialog<void>(
    context,
    title: 'Vehicle',
    submit: 'Use vehicle',
    expanded: ['engine', 'fuel', 'trim', 'drivetrain', 'market'].any((k) => '${current[k] ?? ''}'.isNotEmpty),
    fields: [
      FieldSpec('preset', 'Saved vehicle',
          kind: FieldKind.select,
          options: [for (final v in app.list('vehicles')) ('${v['id']}', '${v['year']} ${v['make']} ${v['model']} ${v['engine'] ?? ''}')]),
      FieldSpec('make', 'Make', value: current['make']),
      FieldSpec('model', 'Model', value: current['model']),
      FieldSpec('year', 'Year', kind: FieldKind.number, value: current['year']),
      for (final k in ['engine', 'fuel', 'trim', 'drivetrain', 'market'])
        FieldSpec(k, titleCase(k), value: current[k], advanced: true),
    ],
    onSubmit: (values) async {
      Json? vehicle;
      if ('${values['preset']}'.isNotEmpty) {
        vehicle = app.list('vehicles').firstWhere((v) => v['id'] == values['preset']);
      } else if ('${values['make']}'.isNotEmpty && '${values['model']}'.isNotEmpty) {
        vehicle = {...values..remove('preset'), 'year': int.tryParse('${values['year']}') ?? 0};
      }
      final lines = [
        for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': ''},
      ];
      app.updateCart({'vehicle': vehicle, 'approvalId': null, 'lines': lines});
    },
  );
}

Future<void> approveFitment(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'Approve fitment',
    submit: 'Record approval',
    fields: [
      const FieldSpec('reason', 'Reason', required: true),
      if (!app.isManager)
        FieldSpec('approvalId', 'Manager approval ID', required: true, help: 'Reference ${app.cart['transactionId']}'),
    ],
    onSubmit: (values) async {
      var id = values['approvalId'];
      if (app.isManager) {
        id = (await app.api('/approvals',
            body: {'action': 'fitment', 'transactionId': app.cart['transactionId'], 'reason': values['reason']}) as Map)['id'];
      }
      app.updateCart({
        'approvalId': id,
        'lines': [
          for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': values['reason']},
        ],
      });
    },
  );
}

Future<void> editDiscount(BuildContext context) async {
  final app = context.appRead;
  final bill = app.currentQuote();
  final limit = (app.settings['cashierDiscountLimit'] ?? 0) as int;
  await showFormDialog<void>(
    context,
    title: 'Discount',
    fields: [
      FieldSpec('discount', 'Amount off (subtotal ${app.money(bill.subtotal)})',
          kind: FieldKind.money, value: ((app.cart['discount'] ?? 0) as int) / 100, required: true, help: 'Enter 0 to remove.'),
      FieldSpec('reason', 'Reason', value: app.cart['discountReason']),
      if (!app.isManager)
        FieldSpec('approvalId', 'Manager approval ID',
            help: 'Needed above ${app.money(limit)}. Reference ${app.cart['transactionId']}'),
    ],
    onSubmit: (values) async {
      final amount = ((double.tryParse('${values['discount']}') ?? -1) * 100).round();
      if (amount < 0) throw FormProblem('Enter a valid amount.');
      if (amount > bill.subtotal) throw FormProblem('Discount cannot be more than ${app.money(bill.subtotal)}.');
      if (amount == 0) {
        app.updateCart({'discount': 0, 'discountReason': '', 'discountApprovalId': null});
        return;
      }
      if ('${values['reason']}'.isEmpty) throw FormProblem('Enter a reason for the discount.');
      if (!app.isManager && amount > limit && '${values['approvalId'] ?? ''}'.isEmpty) {
        throw FormProblem('A manager approval is needed above ${app.money(limit)}.');
      }
      var id = values['approvalId'];
      if (app.isManager) {
        id = (await app.api('/approvals',
            body: {'action': 'discount', 'transactionId': app.cart['transactionId'], 'reason': values['reason']}) as Map)['id'];
      }
      app.updateCart({'discount': amount, 'discountReason': values['reason'], 'discountApprovalId': id});
    },
  );
}

Future<void> holdSale(BuildContext context) async {
  final app = context.appRead;
  try {
    await app.mutate('/holds', {'id': app.cart['holdId'], 'cart': app.cart}, 'Sale parked. Its stock is reserved.');
    app.clearCart();
  } catch (error) {
    app.toast(errorText(error));
  }
}

Future<void> showParked(BuildContext context, ShellController shell) async {
  final app = context.appRead;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => AppScope(
      state: app,
      child: Builder(builder: (context) {
        final holds = context.app.list('holds');
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Parked sales', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              if (holds.isEmpty)
                const EmptyState(message: 'No parked sales. Use Hold to park a sale and reserve its stock.')
              else
                for (final hold in holds)
                  Card(
                    child: ListTile(
                      title: Text('${app.customerById('${hold['cart']['customerId']}')?['name'] ?? 'Walk-in customer'}'),
                      subtitle: Text(
                        '${(hold['cart']['lines'] as List).map((l) => '${l['qty']} × ${app.productName('${l['productId']}')}').join(', ')}\n'
                        'Parked ${formatDate(hold['createdAt'])} by ${app.userName('${hold['userId']}')}',
                      ),
                      isThreeLine: true,
                      trailing: Wrap(spacing: 6, children: [
                        IconButton(
                          tooltip: 'Discard',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            try {
                              await app.api('/holds/${hold['id']}', method: 'DELETE');
                              await app.sync();
                              app.toast('Parked sale discarded. Stock released.');
                            } catch (error) {
                              app.toast(errorText(error));
                            }
                          },
                        ),
                        FilledButton(
                          onPressed: () {
                            if ((app.cart['lines'] as List).isNotEmpty) {
                              app.toast('Hold or clear the current sale first.');
                              return;
                            }
                            app.updateCart({...Map<String, dynamic>.from(hold['cart'] as Map), 'holdId': hold['id']});
                            Navigator.pop(sheet);
                            shell.open('billing');
                          },
                          child: const Text('Resume'),
                        ),
                      ]),
                    ),
                  ),
            ]),
          ),
        );
      }),
    ),
  );
}

// ---------------- checkout ----------------

Future<void> startCheckout(BuildContext context) async {
  final app = context.appRead;
  if ((app.cart['lines'] as List).isEmpty || !app.canSell) return;
  if (app.openShift == null) {
    final opened = await openShiftDialog(context, forCheckout: true);
    if (!opened || !context.mounted) return;
  }
  Quote bill;
  try {
    bill = app.currentQuote();
  } catch (error) {
    app.toast(errorText(error));
    return;
  }
  final invoice = await showDialog<Json>(
    context: context,
    builder: (_) => AppScope(state: app, child: _CheckoutDialog(total: bill.total)),
  );
  if (invoice != null && context.mounted) await showReceipt(context, invoice);
}

Future<bool> openShiftDialog(BuildContext context, {bool forCheckout = false}) async {
  final app = context.appRead;
  final result = await showFormDialog<bool>(
    context,
    title: 'Open shift',
    submit: 'Open shift',
    fields: [
      FieldSpec('openingCash', 'Cash in drawer',
          kind: FieldKind.money, value: 0, required: true, help: forCheckout ? 'A shift is needed before taking payment.' : null),
    ],
    onSubmit: (values) async {
      await app.mutate('/shifts/open', {'openingCash': ((double.tryParse('${values['openingCash']}') ?? 0) * 100).round()},
          'Shift opened.');
      return true;
    },
  );
  return result == true;
}

class _CheckoutDialog extends StatefulWidget {
  const _CheckoutDialog({required this.total});
  final int total;
  @override
  State<_CheckoutDialog> createState() => _CheckoutDialogState();
}

class _CheckoutDialogState extends State<_CheckoutDialog> {
  late String tender;
  late final TextEditingController amount = TextEditingController(text: (widget.total / 100).toStringAsFixed(2));
  final second = TextEditingController(text: '0.00');
  final reference = TextEditingController();
  late final TextEditingController place;
  String secondTender = '';
  bool split = false;
  bool confirmed = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    tender = app.tenderTypes.contains('Cash') ? 'Cash' : app.tenderTypes.first;
    secondTender = app.tenderTypes.firstWhere((t) => t != tender, orElse: () => tender);
    place = TextEditingController(
        text: '${app.customerById('${app.cart['customerId']}')?['stateCode'] ?? app.business['stateCode'] ?? ''}');
  }

  int _minor(String text) => ((double.tryParse(text) ?? 0) * 100).round();

  Future<void> _complete() async {
    final app = context.appRead;
    final paid = _minor(amount.text) + (split ? _minor(second.text) : 0);
    final cash = (tender == 'Cash' ? _minor(amount.text) : 0) + (split && secondTender == 'Cash' ? _minor(second.text) : 0);
    final nonCash = tender != 'Cash' || (split && secondTender != 'Cash');
    setState(() => error = null);
    if (paid < widget.total) return setState(() => error = 'Payment must cover the total.');
    if (paid - widget.total > cash) return setState(() => error = 'Change can only be given from cash.');
    if (nonCash && confirmed && reference.text.trim().isEmpty) {
      return setState(() => error = 'Enter the card or UPI payment reference.');
    }
    if (app.gst && !RegExp(r'^\d{2}$').hasMatch(place.text.trim())) {
      return setState(() => error = 'Enter the two-digit place-of-supply state code.');
    }
    final tenders = [
      {'type': tender, 'amount': _minor(amount.text), 'confirmed': tender == 'Cash' || confirmed, 'reference': reference.text.trim()},
      if (split && _minor(second.text) > 0)
        {'type': secondTender, 'amount': _minor(second.text), 'confirmed': secondTender == 'Cash' || confirmed, 'reference': reference.text.trim()},
    ];
    setState(() => busy = true);
    try {
      final invoice = await app.checkout(tenders: tenders, placeOfSupply: place.text);
      if (mounted) Navigator.pop(context, invoice);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final total = widget.total;
    final paid = _minor(amount.text) + (split ? _minor(second.text) : 0);
    final due = total - paid;
    final nonCash = tender != 'Cash' || (split && secondTender != 'Cash');
    final quick = <int>{
      total,
      for (final step in [10000, 20000, 50000, 200000]) (total / step).ceil() * step,
    }.where((v) => v >= total).take(4).toList();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _complete},
      child: AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Take payment')),
          Text(app.money(total), style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              segments: [
                for (final t in app.tenderTypes)
                  ButtonSegment(
                    value: t,
                    label: Text(t),
                    icon: Icon(t == 'Cash' ? Icons.payments_outlined : t == 'Card' ? Icons.credit_card : Icons.qr_code_2),
                  ),
              ],
              selected: {tender},
              onSelectionChanged: (v) => setState(() => tender = v.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: split ? '$tender amount' : 'Amount received'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _complete(),
            ),
            if (tender == 'Cash' && !split) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in quick)
                  ActionChip(
                    label: Text(v == total ? 'Exact' : app.money(v)),
                    onPressed: () => setState(() => amount.text = (v / 100).toStringAsFixed(2)),
                  ),
              ]),
            ],
            if (app.tenderTypes.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    split = !split;
                    second.text = split ? (max(0, total - _minor(amount.text)) / 100).toStringAsFixed(2) : '0.00';
                  }),
                  icon: Icon(split ? Icons.remove : Icons.call_split, size: 18),
                  label: Text(split ? 'Remove split payment' : 'Split payment'),
                ),
              ),
            if (split)
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: secondTender,
                    decoration: const InputDecoration(labelText: 'Second payment'),
                    items: [for (final t in app.tenderTypes) DropdownMenuItem(value: t, child: Text(t))],
                    onChanged: (v) => setState(() => secondTender = v ?? secondTender),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: second,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
            if (nonCash) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                onChanged: (v) => setState(() => confirmed = v),
                title: const Text('Payment confirmed by the card machine / UPI app'),
                subtitle: const Text('If not yet confirmed, the sale waits in Sync & audit.'),
              ),
              TextField(controller: reference, decoration: const InputDecoration(labelText: 'Payment reference')),
            ],
            if (app.gst) ...[
              const SizedBox(height: 12),
              TextField(
                controller: place,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Place of supply (state code)'),
              ),
            ],
            const SizedBox(height: 16),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: due > 0 ? const Color(0xFFFBEBE7) : Brand.mint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(due > 0 ? 'Still due' : 'Change to give',
                      style: TextStyle(fontWeight: FontWeight.w700, color: due > 0 ? Brand.danger : Brand.forest)),
                ),
                Text(app.money(due > 0 ? due : -due),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: due > 0 ? Brand.danger : Brand.forest)),
              ]),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: busy ? null : _complete,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            label: Text(app.online ? 'Complete sale' : 'Save sale'),
          ),
        ],
      ),
    );
  }
}

