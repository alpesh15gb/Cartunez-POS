import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([FilledButton.icon(onPressed: () => newOrder(context), icon: const Icon(Icons.add), label: const Text('New purchase order'))]),
      DataList(
        rows: app.list('purchaseOrders').reversed.toList(),
        empty: 'No purchase orders yet.',
        columns: [
          Col('Created', (o) => Text(formatDate(o['createdAt']))),
          Col('Supplier', (o) => Text('${app.list('suppliers').where((s) => s['id'] == o['supplierId']).firstOrNull?['name'] ?? '—'}',
              style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Parts', (o) => Text([for (final l in o['lines'] as List) '${app.productName('${l['productId']}')} ${l['received']}/${l['quantity']}'].join(', ')), flex: 2),
          Col('Value', (o) => Text(app.money((o['lines'] as List).fold<int>(0, (n, l) => n + (l['quantity'] as int) * (l['cost'] as int)))), numeric: true),
          Col('Status', (o) => StatusChip(titleCase('${o['status']}'))),
        ],
        actions: (o) => [
          if (o['status'] != 'received') FilledButton.tonal(onPressed: () => receiveOrder(context, o), child: const Text('Receive')),
        ],
      ),
    ]);
  }
}

Future<void> newOrder(BuildContext context) async {
  final app = context.appRead;
  if (app.list('suppliers').isEmpty) return app.toast('Add a supplier first (Purchasing › Suppliers).');
  await showFormDialog<void>(
    context,
    title: 'New purchase order',
    submit: 'Create order',
    fields: [
      FieldSpec('supplierId', 'Supplier', kind: FieldKind.select, required: true, options: optionsOf(app.list('suppliers'))),
      FieldSpec('productId', 'Part',
          kind: FieldKind.select,
          required: true,
          options: optionsOf(app.products.where((p) => p['type'] != 'service').toList(), (p) => '${p['sku']} · ${p['name']} · cost ${app.money(p['cost'] as num?)}')),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      const FieldSpec('cost', 'Unit cost', kind: FieldKind.money, help: 'Blank uses the part\'s current cost.'),
    ],
    onSubmit: (v) async {
      final product = app.productById('${v['productId']}')!;
      await app.mutate('/purchase-orders', {
        'supplierId': v['supplierId'],
        'lines': [
          {
            'productId': v['productId'],
            'quantity': int.tryParse('${v['quantity']}') ?? 0,
            'cost': '${v['cost']}'.isEmpty ? product['cost'] : ((double.tryParse('${v['cost']}') ?? 0) * 100).round(),
          },
        ],
      }, 'Purchase order created.');
    },
  );
}

Future<void> receiveOrder(BuildContext context, Json order) async {
  final app = context.appRead;
  final open = [for (final l in order['lines'] as List) if ((l['received'] as int) < (l['quantity'] as int)) l];
  await showFormDialog<void>(
    context,
    title: 'Receive goods',
    submit: 'Receive into stock',
    fields: [
      FieldSpec('productId', 'Part',
          kind: FieldKind.select,
          required: true,
          value: open.length == 1 ? open.first['productId'] : null,
          options: [for (final l in open) ('${l['productId']}', '${app.productName('${l['productId']}')} · ${l['quantity'] - l['received']} outstanding')]),
      FieldSpec('quantity', 'Quantity received', kind: FieldKind.number, required: true,
          value: open.length == 1 ? open.first['quantity'] - open.first['received'] : 1),
      FieldSpec('binId', 'Put away into', kind: FieldKind.select, required: true,
          value: app.sellableBins.firstOrNull?['id'], options: optionsOf(app.sellableBins, app.binName)),
      const FieldSpec('landedCost', 'Freight / landed cost for this delivery', kind: FieldKind.money, value: 0, advanced: true),
      const FieldSpec('serials', 'Serial numbers', advanced: true),
    ],
    onSubmit: (v) async => app.mutate('/purchase-orders/${order['id']}/receive', {
      'transactionId': uuid(),
      'landedCost': ((double.tryParse('${v['landedCost']}') ?? 0) * 100).round(),
      'lines': [
        {'productId': v['productId'], 'quantity': int.tryParse('${v['quantity']}') ?? 0, 'binId': v['binId'], 'serials': splitList(v['serials'])},
      ],
    }, 'Goods received.'),
  );
}
