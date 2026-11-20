import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../widgets.dart';

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
        if (app.sellableBins.isEmpty && app.list('purchaseOrders').isNotEmpty)
          TextButton(onPressed: () => shell.open('bins'), child: const Text('Add a sellable bin to receive stock')),
      ]),
      DataList(
        rows: app.list('purchaseOrders').reversed.toList(),
        empty: 'No purchase orders yet.',
        actionWidth: 112,
        columns: [
          Col('Created', (o) => Text(formatDate(o['createdAt']))),
          Col('Supplier', (o) => Text('${app.list('suppliers').where((s) => s['id'] == o['supplierId']).firstOrNull?['name'] ?? '—'}',
              style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Parts', (o) => Text([for (final l in o['lines'] as List) '${app.productName('${l['productId']}')} ${l['received']}/${l['quantity']}'].join(', ')), flex: 2),
          Col('Value', (o) => Text(app.money((o['lines'] as List).fold<int>(0, (n, l) => n + (l['quantity'] as int) * (l['cost'] as int)))), numeric: true),
          Col('Status', (o) => StatusChip(titleCase('${o['status']}'))),
        ],
        actions: (o) => [
          if (o['status'] != 'received') FilledButton.tonal(onPressed: app.sellableBins.isEmpty ? null : () => receiveOrder(context, o), child: const Text('Receive')),
        ],
      ),
    ]);
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
  await showFormDialog<void>(
    context,
    title: receiving ? 'Receive goods' : 'New purchase order',
    submit: receiving ? 'Receive into stock' : 'Create order',
    fields: [
      if (!receiving)
        FieldSpec('supplierId', 'Supplier', kind: FieldKind.select, required: true, options: optionsOf(app.list('suppliers'))),
      if (receiving)
        const FieldSpec('landedCost', 'Freight / landed cost for this delivery', kind: FieldKind.money, value: 0),
    ],
    header: _PurchaseLines(app: app, lines: lines, order: order),
    onSubmit: (values) async {
      if (lines.isEmpty) throw FormProblem('Add at least one part.');
      await app.mutate(receiving ? '/purchase-orders/${order['id']}/receive' : '/purchase-orders', {
        'transactionId': transactionId,
        if (receiving) 'landedCost': ((double.tryParse('${values['landedCost']}') ?? 0) * 100).round()
        else 'supplierId': values['supplierId'],
        'lines': List<Json>.from(lines),
      }, receiving ? 'Goods received.' : 'Purchase order created.');
    },
  );
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
          FieldSpec('binId', 'Put away into', kind: FieldKind.select, required: true,
            value: original?['binId'] ?? app.sellableBins.firstOrNull?['id'],
            barcodeChoice: app.binIdForCode, options: optionsOf(app.sellableBins, app.binName)),
          FieldSpec('serials', 'Serial numbers', value: (original?['serials'] as List? ?? []).join(', '),
            help: 'For tracked parts, enter a serial for each unit, separated by commas.'),
        ],
      ],
      onSubmit: (v) async {
        final id = v['productId'] as String;
        final product = app.productById(id)!;
        final quantity = int.tryParse('${v['quantity']}') ?? 0;
        if (quantity < 1) throw FormProblem('Enter at least one unit.');
        if (receiving && quantity > remaining[id]!) throw FormProblem('Only ${remaining[id]} units are outstanding.');
        final serials = splitList(v['serials']);
        if (receiving && product['serialTracked'] == true &&
            (serials.length != quantity || serials.toSet().length != quantity)) {
          throw FormProblem('Enter one unique serial number per unit.');
        }
        return {
          'productId': id, 'quantity': quantity,
          if (receiving) ...{'binId': v['binId'], 'serials': serials}
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
              : '${line['quantity']} units · ${app.locationName(line['binId'])}'),
          onTap: () => edit(index),
          trailing: IconButton(tooltip: 'Remove line', icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => setState(() => widget.lines.removeAt(index)))),
      OutlinedButton.icon(onPressed: edit, icon: const Icon(Icons.add), label: const Text('Add part')),
    ]);
  }
}
