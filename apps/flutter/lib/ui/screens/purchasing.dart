import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../widgets.dart';
import 'bills.dart';
import 'labels.dart';
import '../purchasing/received.dart'; // WS-E
import '../purchasing/reorder.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final hasSuppliers = app.list('suppliers').isNotEmpty;
    final hasParts = app.products.any((p) => p['type'] != 'service');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(onPressed: hasSuppliers && hasParts ? () => newOrder(context) : null, icon: const Icon(Icons.add), label: const Text('New purchase order')),
        if (!hasSuppliers) TextButton(onPressed: () => shell.open('suppliers'), child: const Text('Add a supplier')),
        if (!hasParts) TextButton(onPressed: () => shell.open('parts'), child: const Text('Add a part')),
        if (app.sellableBins.isEmpty && app.stockParts.isNotEmpty && app.list('purchaseOrders').isNotEmpty)
          TextButton(onPressed: () => shell.open('bins'), child: const Text('Add a sellable bin to receive stock')),
        // WS-E: reorder alerts (badge) and supplier cost rises.
        const ReorderAlertsButton(),
        OutlinedButton.icon(onPressed: () => shell.open('cost-changes'), icon: const Icon(Icons.trending_up), label: const Text('Cost changes')),
      ]),
      DataList(
        rows: app.list('purchaseOrders').reversed.toList(),
        empty: 'No purchase orders yet.',
        actionWidth: 230,
        columns: [
          Col('Created', (o) => Text(formatDate(o['createdAt']))),
          Col('Supplier', (o) => Text('${app.list('suppliers').where((s) => s['id'] == o['supplierId']).firstOrNull?['name'] ?? '—'}',
              style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Parts', (o) => Text([for (final l in o['lines'] as List) '${app.productName('${l['productId']}')} ${l['received']}/${l['quantity']}'].join(', ')), flex: 2),
          Col('Value', (o) => Text(app.money((o['lines'] as List).fold<int>(0, (n, l) => n + (l['quantity'] as int) * (l['cost'] as int)))), numeric: true),
          Col('Status', (o) => StatusChip(titleCase('${o['status']}'))),
        ],
        actions: (o) => [
          // WS-E: drafts from reorder alerts are placed (or cancelled) first.
          if (o['status'] == 'draft')
            FilledButton.tonal(onPressed: () => _place(context, o), child: const Text('Place order')),
          if (o['status'] != 'received' && o['status'] != 'cancelled' && o['status'] != 'draft')
            FilledButton.tonal(onPressed: () => enterBill(context, order: o), child: const Text('Enter bill')),
          if (o['status'] == 'open' || o['status'] == 'partial')
            IconButton(tooltip: 'Receive goods without a bill', icon: const Icon(Icons.move_to_inbox_outlined),
                onPressed: () => receiveOrder(context, o)),
          if ((o['status'] == 'draft' || o['status'] == 'open') && (o['lines'] as List).every((l) => (l['received'] ?? 0) == 0))
            IconButton(tooltip: 'Cancel order', icon: const Icon(Icons.close), onPressed: () => _cancel(context, o)),
          if ((o['lines'] as List).any((line) => (line['received'] ?? 0) > 0))
            IconButton(tooltip: 'Print receipt labels', icon: const Icon(Icons.print_outlined),
                onPressed: () => _receiptLabels(context, o)),
        ],
      ),
    ]);
  }
}

/// WS-E: a draft becomes an open order sent to the supplier.
Future<void> _place(BuildContext context, Json order) async {
  final app = context.appRead;
  try {
    await app.mutate('/purchase-orders/${order['id']}/place', {}, 'Order placed. Enter the bill when the goods arrive.');
  } catch (e) {
    app.toast(errorText(e));
  }
}

Future<void> _cancel(BuildContext context, Json order) async {
  final app = context.appRead;
  if (!await confirm(context, 'Cancel this purchase order?', 'Nothing has been received on it. Its parts will show in reorder alerts again.', action: 'Cancel order')) return;
  try {
    await app.mutate('/purchase-orders/${order['id']}/cancel', {}, 'Purchase order cancelled.');
  } catch (e) {
    app.toast(errorText(e));
  }
}

Future<void> _receiptLabels(BuildContext context, Json order) async {
  final app = context.appRead;
  late final history = Future.sync(() => app.api('/purchase-orders/${order['id']}/receipts'));
  final receipt = await showDialog<Json>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Choose a goods receipt'),
      children: [
        FutureBuilder<dynamic>(
          future: history,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text(errorText(snapshot.error!)));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final receipts = (snapshot.data['receipts'] as List).cast<Json>();
            if (receipts.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('No deliveries recorded.'));
            return Column(mainAxisSize: MainAxisSize.min, children: [
              for (final receipt in receipts)
                ListTile(title: Text(formatDate(receipt['createdAt'])), isThreeLine: true,
                    subtitle: Text('${receipt['id']}\n${(receipt['lines'] as List).map((line) => "${app.productName(line['productId'])} × ${line['quantity']}").join(', ')}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, receipt)),
            ]);
          },
        ),
        SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    ),
  );
  if (!context.mounted || receipt == null) return;
  final labels = <({LabelItem item, int quantity})>[];
  for (final line in receipt['lines'] as List) {
    final part = app.productById(line['productId']);
    if (line['onlineOnly'] == true || isOnlineOnly(part)) continue;
    final item = part == null
        ? LabelItem(app.productName(line['productId']), '', sku: 'Unavailable', bin: app.locationName(line['binId']))
        : productLabel(app, part, binId: line['binId']);
    labels.add((item: item, quantity: line['quantity'] as int));
  }
  try {
    await printReceiptLineLabels(context, labels);
  } catch (e) {
    app.toast('Labels could not be printed. ${errorText(e)}');
  }
}

Future<void> newOrder(BuildContext context) async {
  final app = context.appRead;
  if (app.list('suppliers').isEmpty) return app.toast('Add a supplier first (Purchasing › Suppliers).');
  await _purchaseDialog(context, app);
}

Future<void> receiveOrder(BuildContext context, Json order) =>
    _purchaseDialog(context, context.appRead, order: order);

Future<void> _purchaseDialog(BuildContext context, AppState app, {Json? order}) async {
  final receiving = order != null;
  final lines = <Json>[];
  final transactionId = uuid();
  Object? received;
  await showFormDialog<void>(
    context,
    title: receiving ? 'Receive goods' : 'New purchase order',
    submit: !receiving ? 'Create order' : (order['lines'] as List).every((l) => isOnlineOnly(app.productById(l['productId']))) ? 'Record delivery' : 'Receive into stock',
    fields: [
      if (!receiving)
        FieldSpec('supplierId', 'Supplier', kind: FieldKind.select, required: true, options: optionsOf(app.list('suppliers'))),
      if (receiving)
        const FieldSpec('landedCost', 'Freight / landed cost for this delivery', kind: FieldKind.money, value: 0),
    ],
    header: _PurchaseLines(app: app, lines: lines, order: order),
    onSubmit: (values) async {
      if (lines.isEmpty) throw FormProblem('Add at least one part.');
      final saved = await app.mutate(receiving ? '/purchase-orders/${order['id']}/receive' : '/purchase-orders', {
        'transactionId': transactionId,
        if (receiving) 'landedCost': ((double.tryParse('${values['landedCost']}') ?? 0) * 100).round()
        else 'supplierId': values['supplierId'],
        'lines': List<Json>.from(lines),
      }, receiving ? 'Goods received.' : 'Purchase order created.');
      if (receiving) received = saved;
    },
  );
  // WS-E: cost hikes, labels for exactly what arrived, website update.
  if (received != null && context.mounted) await showReceivedGoods(context, receivedLines(received));
}

class _PurchaseLines extends StatefulWidget {
  const _PurchaseLines({required this.app, required this.lines, this.order});
  final AppState app;
  final List<Json> lines;
  final Json? order;

  @override
  State<_PurchaseLines> createState() => _PurchaseLinesState();
}

class _PurchaseLinesState extends State<_PurchaseLines> {
  Future<void> edit([int? index]) async {
    final app = widget.app;
    final original = index == null ? null : widget.lines[index];
    final receiving = widget.order != null;
    final remaining = <String, int>{
      for (final l in widget.order?['lines'] as List? ?? [])
        l['productId'] as String: (l['quantity'] - l['received']) as int,
    };
    final used = <String>{};
    for (final line in widget.lines) {
      if (identical(line, original)) continue;
      final id = line['productId'] as String;
      used.add(id);
      if (receiving) remaining[id] = remaining[id]! - (line['quantity'] as int);
    }
    final parts = app.products.where((p) => p['type'] != 'service' &&
        (receiving ? (remaining[p['id']] ?? 0) > 0 : !used.contains(p['id']))).toList();
    if (parts.isEmpty) {
      app.toast(receiving ? 'All outstanding units are in this receipt.' : 'All available parts are in this order.');
      return;
    }
    final line = await showFormDialog<Json>(
      context,
      title: receiving ? 'Receive a part' : 'Purchase order line',
      submit: index == null ? 'Add line' : 'Update line',
      fields: [
        FieldSpec('productId', 'Part', kind: FieldKind.select, required: true,
          value: original?['productId'] ?? (parts.length == 1 ? parts.single['id'] : null),
          barcodeChoice: app.uniqueProductIdForCode,
          options: optionsOf(parts, (p) => '${p['sku']} · ${p['name']} · ${receiving ? "${remaining[p['id']]} outstanding" : app.money(p['cost'])}')),
        FieldSpec('quantity', 'Quantity', kind: FieldKind.number, required: true,
          value: original?['quantity'] ?? (receiving && parts.length == 1 ? remaining[parts.single['id']] : 1)),
        if (!receiving)
          FieldSpec('cost', 'Unit cost', kind: FieldKind.money,
            value: original == null ? '' : (original['cost'] / 100).toStringAsFixed(2), help: 'Blank uses the current catalog cost.'),
        if (receiving) ...[
          // Online-only parts go straight to the website customer, so they need no bin.
          if (parts.any((p) => !isOnlineOnly(p))) FieldSpec('binId', 'Put away into', kind: FieldKind.select, required: !parts.any(isOnlineOnly),
            value: original?['binId'] ?? app.sellableBins.firstOrNull?['id'],
            help: parts.any(isOnlineOnly) ? 'Not used for online-only parts: they go straight to the customer.' : null,
            barcodeChoice: app.binIdForCode, options: optionsOf(app.sellableBins, app.binName)),
          FieldSpec('serials', 'Serial numbers', value: (original?['serials'] as List? ?? []).join(', '),
            help: 'For tracked parts, enter a serial for each unit, separated by commas.'),
          // WS-E: the supplier's actual unit cost (cost rises are flagged).
          FieldSpec('cost', 'Unit cost on this delivery', kind: FieldKind.money,
            value: original?['cost'] == null ? '' : (original!['cost'] / 100).toStringAsFixed(2), help: 'Blank uses the ordered cost.'),
        ],
      ],
      onSubmit: (v) async {
        final id = v['productId'] as String;
        final product = app.productById(id)!;
        final quantity = int.tryParse('${v['quantity']}') ?? 0;
        if (quantity < 1) throw FormProblem('Enter at least one unit.');
        if (receiving && quantity > remaining[id]!) throw FormProblem('Only ${remaining[id]} units are outstanding.');
        final onlineOnly = isOnlineOnly(product);
        if (receiving && !onlineOnly && '${v['binId'] ?? ''}'.isEmpty) throw FormProblem('Choose the bin to put the part away into.');
        final serials = splitList(v['serials']);
        if (receiving && product['serialTracked'] == true &&
            (serials.length != quantity || serials.toSet().length != quantity)) {
          throw FormProblem('Enter one unique serial number per unit.');
        }
        return {
          'productId': id, 'quantity': quantity,
          if (receiving) ...{'binId': onlineOnly ? null : v['binId'], 'serials': serials, if ('${v['cost'] ?? ''}'.isNotEmpty) 'cost': (double.parse(v['cost']) * 100).round()}
          else 'cost': v['cost'] == '' ? product['cost'] : (double.parse(v['cost']) * 100).round(),
        };
      },
    );
    if (mounted && line != null) {
      setState(() {
        if (index == null) { widget.lines.add(line); } else { widget.lines[index] = line; }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (index, line) in widget.lines.indexed)
        ListTile(contentPadding: EdgeInsets.zero, title: Text(app.productName(line['productId'])),
          subtitle: Text(widget.order == null
              ? '${line['quantity']} × ${app.money(line['cost'])}'
              : [
                  '${line['quantity']} units · ${isOnlineOnly(app.productById('${line['productId']}')) ? 'Online only · to the customer' : app.locationName(line['binId'])}',
                  if (line['cost'] != null) '${app.money(line['cost'])} each',
                  if (line['cost'] != null) ?costWarning(app, '${line['productId']}', line['cost'] as int),
                ].join(' · ')),
          onTap: () => edit(index),
          trailing: IconButton(tooltip: 'Remove line', icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => setState(() => widget.lines.removeAt(index)))),
      OutlinedButton.icon(onPressed: edit, icon: const Icon(Icons.add), label: const Text('Add part')),
    ]);
  }
}
