import 'package:flutter/material.dart';

import '../../main.dart';
import '../../core/billing.dart';
import '../widgets.dart';
import 'receipt.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final today = app.businessTime(DateTime.now());
    bool isToday(Object? value) {
      final parsed = DateTime.tryParse('$value');
      final d = parsed == null ? null : app.businessTime(parsed);
      return d != null && d.year == today.year && d.month == today.month && d.day == today.day;
    }

    final sales = app.list('invoices').where((i) => isToday(i['createdAt'])).toList();
    final refunds = [...app.list('returns'), ...app.list('coreReturns')].where((r) => isToday(r['createdAt']) && (app.role != 'cashier' || r['userId'] == app.session?.userId));
    final gross = sales.fold<int>(0, (n, i) => n + (i['total'] as int));
    final refunded = refunds.fold<int>(0, (n, r) => n + (r['total'] as int));
    final low = app.list('reorderSuggestions');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        Metric('Sales today', '${sales.length}'),
        Metric('Net sales today', app.money(gross - refunded)),
        Metric('Refunds today', app.money(refunded)),
        Metric('Waiting to send', app.money(app.pending.fold<int>(0, (n, e) => n + ((e['total'] ?? 0) as int)))),
      ]),
      if (app.canStock) SectionTitle('Running low'),
      if (app.canStock) DataList(
        rows: low,
        empty: 'No parts have reached their reorder level.',
        actions: (p) => [
          if ((p['suggestedQuantity'] as int) > 0)
            TextButton(onPressed: app.online ? () => reviewReorder(context, p) : null, child: const Text('Reorder')),
        ],
        columns: [
          Col('Part', (p) => Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
          Col('In stock', (p) => Text('${p['available']}'), numeric: true),
          Col('Reorder at', (p) => Text('${p['reorderLevel']}'), numeric: true),
          Col('On order', (p) => Text('${p['onOrder']}'), numeric: true),
          Col('Suggested order', (p) => Text('${p['suggestedQuantity']}'), numeric: true),
        ],
      ),
      SectionTitle('Latest invoices'),
      DataList(
        rows: app.list('invoices').reversed.take(8).toList(),
        empty: 'No sales yet.',
        onTap: (i) => showReceipt(context, i),
        columns: [
          Col('Invoice', (i) => Text('${i['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Time', (i) => Text(formatDate(i['createdAt']))),
          Col('Status', (i) => StatusChip(app.invoiceStatus(i))),
          Col('Total', (i) => Text(app.money(i['total'] as num)), numeric: true),
        ],
      ),
    ]);
  }
}

Future<void> reviewReorder(BuildContext context, Json row) async {
  final app = context.appRead;
  final suppliers = app.list('suppliers');
  if (suppliers.isEmpty) {
    app.toast('Add a supplier in Purchasing before ordering parts.');
    return;
  }
  final part = app.productById('${row['productId']}');
  if (part == null) return;
  final transactionId = uuid();
  await showFormDialog<void>(context, title: 'Reorder ${row['sku']}', submit: 'Create purchase order',
    fields: [
      FieldSpec('supplier', 'Supplier', kind: FieldKind.select, required: true,
        options: optionsOf(suppliers), value: row['supplierId'] ?? (suppliers.length == 1 ? suppliers.single['id'] : null)),
      FieldSpec('qty', 'Quantity to order', kind: FieldKind.number, required: true, value: row['suggestedQuantity'],
        help: "${row['available']} available · ${row['onOrder']} already on order"),
      FieldSpec('cost', 'Unit purchase cost', kind: FieldKind.money, required: true,
        value: ((part['cost'] as num) / 100).toStringAsFixed(2)),
    ],
    onSubmit: (v) async {
      final qty = int.tryParse('${v['qty']}') ?? 0;
      if (qty < 1 || qty > row['suggestedQuantity']) throw FormProblem('Enter between 1 and ${row['suggestedQuantity']} units.');
      await app.mutate('/purchase-orders', {'transactionId': transactionId, 'replenishment': true, 'supplierId': v['supplier'],
        'lines': [{'productId': part['id'], 'quantity': qty, 'cost': (double.parse('${v['cost']}') * 100).round()}]},
        'Purchase order created. Open Purchasing to receive it.');
    },
  );
}
