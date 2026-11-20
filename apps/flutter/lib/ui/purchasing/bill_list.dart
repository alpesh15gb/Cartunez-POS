
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'bill_entry_dialog.dart';
import 'bill_detail.dart';

// ---------------------------------------------------------------- bills list

class BillsScreen extends StatelessWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final owed = app.list('suppliers').fold<int>(0, (n, s) => n + app.partyBalance('suppliers', '${s['id']}'));
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final rows = app.list('purchaseBills').reversed.where((b) => q.isEmpty ||
            normalize('${b['billNumber']} ${b['supplierName']} ${(b['lines'] as List).map((l) => '${l['name']} ${l['sku']}').join(' ')}').contains(q)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            FilledButton.icon(onPressed: () => enterBill(context), icon: const Icon(Icons.add), label: const Text('Enter supplier bill')),
            OutlinedButton.icon(onPressed: () => shell.open('suppliers'), icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(owed > 0 ? 'Supplier balances · you owe ${app.money(owed)}' : 'Supplier balances')),
            if (app.sellableBins.isEmpty) TextButton(onPressed: () => shell.open('bins'), child: const Text('Add a sellable bin first')),
          ]),
          DataList(
            rows: rows,
            empty: 'No supplier bills yet. When goods arrive, press "Enter supplier bill" and photograph the supplier\'s note.',
            onTap: (b) => showBill(context, b),
            actionWidth: 60,
            columns: [
              Col('Date', (b) => Text('${b['billDate']}')),
              Col('Supplier', (b) => Text('${b['supplierName'] ?? app.supplierById(b['supplierId'])?['name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
              Col('Bill no.', (b) => Text('${(b['billNumber'] ?? '').toString().isEmpty ? '—' : b['billNumber']}')),
              Col('Items', (b) => Text((b['lines'] as List).map((l) => '${l['name']} × ${l['quantity']}').join(', '), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 3),
              Col('Total', (b) => Text(app.money(b['total']), style: TextStyle(decoration: b['voided'] == true ? TextDecoration.lineThrough : null)), numeric: true),
              Col('', (b) => Wrap(spacing: 6, children: [
                    if (b['voided'] == true) const StatusChip('Cancelled'),
                    if (b['gst'] == true) const StatusChip('GST'),
                  ])),
            ],
            actions: (b) => [
              if ((b['photoIds'] as List? ?? []).isNotEmpty)
                const Tooltip(message: 'Has a photo of the supplier note', child: Icon(Icons.photo_outlined, color: Brand.muted)),
            ],
          ),
        ]);
      },
    );
  }
}
