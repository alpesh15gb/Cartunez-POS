import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt.dart';

// WS-D: the shift screens moved to lib/ui/shift/.
export '../shift/shift_dialogs.dart' show recordDrawerMovement, showDrawerActivity, closeShift;
export '../shift/shift_home.dart' show ShiftsScreen;

class InvoicesScreen extends StatelessWidget {
  const InvoicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        bool match(Json r) => q.isEmpty || normalize('${r['number']} ${r['invoiceNumber']} ${r['customer']?['name']}').contains(q);
        final invoices = app.list('invoices').reversed.where(match).toList();
        final credits = app.list('returns').reversed.where(match).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DataList(
            rows: invoices,
            empty: 'No invoices yet. Completed sales appear here.',
            onTap: (row) => showReceipt(context, row),
            columns: [
              Col('Invoice', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
              Col('Date', (r) => Text(formatDate(r['createdAt']))),
              Col('Customer', (r) => Text('${r['customer']?['name'] ?? 'Walk-in'}')),
              Col('Status', (r) => StatusChip(app.invoiceStatus(r))),
              Col('Total', (r) => Text(app.money(r['total'] as num)), numeric: true),
            ],
            actions: (r) {
              final status = app.invoiceStatus(r);
              return [
                if (status != 'Voided' && status != 'Returned' && app.canSell)
                  OutlinedButton(onPressed: () => returnInvoice(context, r), child: const Text('Return')),
                if (app.isManager && status == 'Finalized')
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Brand.danger),
                    onPressed: () => voidInvoice(context, r),
                    child: const Text('Void'),
                  ),
              ];
            },
          ),
          SectionTitle('Credit notes'),
          DataList(
            rows: credits,
            empty: 'No returns or voids.',
            onTap: (row) => showReceipt(context, row),
            columns: [
              Col('Credit note', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
              Col('Invoice', (r) => Text('${r['invoiceNumber']}')),
              Col('Date', (r) => Text(formatDate(r['createdAt']))),
              Col('Type', (r) => Text(r['voided'] == true ? 'Void' : 'Return · ${titleCase('${r['condition']}')}')),
              Col('Refund', (r) => Text('${app.money(r['total'] as num)} · ${r['refundType'] ?? 'Cash'}'), numeric: true),
            ],
          ),
        ]);
      },
    );
  }
}

Future<void> returnInvoice(BuildContext context, Json invoice) async {
  final app = context.appRead;
  final transactionId = uuid();
  final returnable = [
    for (final raw in invoice['lines'] as List)
      if ((raw['qty'] as int) - app.returnedQuantity(invoice, '${raw['id']}') > 0)
        (Map<String, dynamic>.from(raw as Map), (raw['qty'] as int) - app.returnedQuantity(invoice, '${raw['id']}')),
  ];
  if (returnable.isEmpty) return app.toast('Everything on this invoice has been returned.');
  await showFormDialog<void>(
    context,
    title: 'Return from ${invoice['number']}',
    submit: 'Record return',
    fields: [
      FieldSpec('lineId', 'Item',
          kind: FieldKind.select,
          required: true,
          value: returnable.length == 1 ? returnable.first.$1['id'] : null,
          options: [for (final (l, left) in returnable) ('${l['id']}', '${l['name']} · $left of ${l['qty']} returnable')]),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      const FieldSpec('condition', 'Condition',
          kind: FieldKind.select,
          value: 'sellable',
          required: true,
          options: [('sellable', 'Good — back on the shelf'), ('damaged', 'Damaged'), ('warranty', 'Warranty claim')]),
      FieldSpec('binId', 'Put into bin',
          kind: FieldKind.select,
          value: app.sellableBins.firstOrNull?['id'],
          options: [for (final b in app.bins) ('${b['id']}', '${app.binName(b)} · ${b['kind']}')],
          help: 'Must match the condition. Not needed for services.'),
      const FieldSpec('reason', 'Reason', required: true),
      FieldSpec('refundType', 'Refund by',
          kind: FieldKind.select,
          required: true,
          value: _refundDefault(invoice),
          options: _refundOptions(app, invoice)),
      const FieldSpec('serials', 'Serial numbers', advanced: true, help: 'Serial-tracked parts only, separated by commas.'),
      if (!app.isManager) FieldSpec('approvalId', 'Manager approval ID', required: true, help: 'Reference $transactionId'),
    ],
    onSubmit: (v) async {
      final entry = returnable.firstWhere((e) => e.$1['id'] == v['lineId']);
      final qty = int.tryParse('${v['quantity']}') ?? 0;
      if (qty < 1 || qty > entry.$2) throw FormProblem('Return between 1 and ${entry.$2}.');
      if (entry.$1['type'] != 'service' && app.binById('${v['binId']}')?['kind'] != v['condition']) {
        throw FormProblem('Choose a ${v['condition']} bin for ${v['condition']} returns.');
      }
      await app.mutate('/invoices/${invoice['id']}/returns', {
        'transactionId': transactionId,
        'approvalId': v['approvalId'],
        'reason': v['reason'],
        'condition': v['condition'],
        'refundType': v['refundType'],
        'lines': [
          {'lineId': v['lineId'], 'quantity': qty, 'binId': v['binId'], 'serials': splitList(v['serials'])},
        ],
      }, 'Return recorded and refund noted.');
    },
  );
}

Future<void> voidInvoice(BuildContext context, Json invoice) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'Void ${invoice['number']}',
    submit: 'Void invoice',
    header: Text('All items go back into stock and a credit note for ${app.money(invoice['total'] as num)} is issued.'),
    fields: [
      const FieldSpec('reason', 'Reason', required: true),
      FieldSpec('refundType', 'Refund by',
          kind: FieldKind.select,
          required: true,
          value: _refundDefault(invoice),
          options: _refundOptions(app, invoice)),
    ],
    onSubmit: (v) async {
      final result = await app.mutate('/invoices/${invoice['id']}/void', v) as Map;
      app.toast('Invoice voided. Refund ${app.money(result['totalRefund'] as num? ?? 0)} by ${v['refundType']}.');
    },
  );
}

/// A sale on credit is refunded to the customer's account by default.
String _refundDefault(Json invoice) {
  final tenders = (invoice['tenders'] as List? ?? []);
  if (tenders.any((t) => t['type'] == 'Credit')) return 'Credit';
  return '${tenders.firstOrNull?['type'] ?? 'Cash'}';
}

List<(String, String)> _refundOptions(AppState app, Json invoice) => [
      for (final t in app.tenderTypes) (t, t),
      if (invoice['customerId'] != null) ('Credit', "Customer's account (reduce udhaar)"),
    ];
