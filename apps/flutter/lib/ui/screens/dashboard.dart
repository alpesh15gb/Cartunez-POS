import 'package:flutter/material.dart';

import '../../main.dart';
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
    final low = app.products
        .where((p) => p['type'] != 'service' && app.available('${p['id']}') <= (p['reorderLevel'] ?? 0))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        Metric('Sales today', '${sales.length}'),
        Metric('Net sales today', app.money(gross - refunded)),
        Metric('Refunds today', app.money(refunded)),
        Metric('Waiting to send', app.money(app.pending.fold<int>(0, (n, e) => n + ((e['total'] ?? 0) as int)))),
      ]),
      SectionTitle('Running low'),
      DataList(
        rows: low,
        empty: 'Nothing is below its reorder level.',
        columns: [
          Col('Part', (p) => Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
          Col('In stock', (p) => Text('${app.available('${p['id']}')}'), numeric: true),
          Col('Reorder at', (p) => Text('${p['reorderLevel']}'), numeric: true),
          Col('Suggested order', (p) => Text('${((p['reorderLevel'] as int) * 2 - app.available('${p['id']}')).clamp(0, 99999)}'), numeric: true),
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
