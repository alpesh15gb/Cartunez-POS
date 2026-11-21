import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'billing.dart';
import 'receipt.dart';
import '../orders/returns.dart' show startReturnForInvoice; // WS-B

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
                  OutlinedButton(onPressed: () => startReturnForInvoice(context, r), child: const Text('Return')), // WS-B
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
              // WS-B: exchanges and per-line dispositions.
              Col('Type', (r) => Text(r['voided'] == true ? 'Void' : r['exchangeApplied'] != null ? 'Exchange' : 'Return · ${titleCase('${r['condition']}')}')),
              Col('Refund', (r) => Text(r['refundType'] == 'Exchange'
                  ? '${app.money(r['total'] as num)} · Exchange'
                  : '${app.money((r['refundTotal'] ?? r['total']) as num)} · ${r['refundType'] ?? 'Cash'}'), numeric: true),
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

class ShiftsScreen extends StatelessWidget {
  const ShiftsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final mine = app.openShift;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        if (mine == null)
          FilledButton.icon(onPressed: () => openShiftDialog(context), icon: const Icon(Icons.lock_open), label: const Text('Open shift'))
        else ...[
          OutlinedButton.icon(onPressed: app.online ? () => recordDrawerMovement(context, mine, 'in') : null,
            icon: const Icon(Icons.add), label: const Text('Cash in')),
          OutlinedButton.icon(onPressed: app.online ? () => recordDrawerMovement(context, mine, 'out') : null,
            icon: const Icon(Icons.remove), label: const Text('Cash out')),
          FilledButton.icon(onPressed: () => closeShift(context, mine), icon: const Icon(Icons.lock_outline), label: const Text('Close my shift')),
        ],
      ]),
      DataList(
        onTap: (shift) => showDrawerActivity(context, shift),
        rows: app.list('shifts').reversed.toList(),
        empty: 'No shifts yet.',
        columns: [
          Col('Cashier', (s) => Text(app.userName('${s['userId']}'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Opened', (s) => Text(formatDate(s['openedAt'])), flex: 2),
          Col('Closed', (s) => Text(s['closedAt'] == null ? '—' : formatDate(s['closedAt'])), flex: 2),
          Col('Expected', (s) => Text(s['closedAt'] != null ? app.money(s['expectedCash'] as num?) : app.isManager ? app.money(app.expectedCash(s)) : '—'), numeric: true),
          Col('Counted', (s) => Text(s['closedAt'] == null ? '—' : app.money(s['countedCash'] as num?)), numeric: true),
          Col('Variance', (s) => s['closedAt'] == null
              ? const Text('—')
              : Text(app.money(s['variance'] as num?), style: TextStyle(color: (s['variance'] ?? 0) == 0 ? Brand.forest : Brand.danger, fontWeight: FontWeight.w700)), numeric: true),
          Col('Status', (s) => StatusChip(s['closedAt'] == null ? 'Open' : 'Closed')),
        ],
        actionWidth: 90,
        actions: !app.isManager ? null : (s) => [
          if (s['closedAt'] == null && s['userId'] != app.session?.userId && app.isManager)
            OutlinedButton(onPressed: () => closeShift(context, s), child: const Text('Close')),
        ],
      ),
    ]);
  }
}

Future<void> recordDrawerMovement(BuildContext context, Json shift, String direction) async {
  final app = context.appRead;
  final transactionId = uuid();
  await showFormDialog<void>(context,
    title: direction == 'in' ? 'Cash in' : 'Cash out',
    submit: 'Record movement',
    fields: const [
      FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true),
      FieldSpec('reason', 'Reason', required: true),
    ],
    onSubmit: (values) async {
      final amount = parsePaymentAmount('${values['amount']}');
      if (amount == null || amount < 1) throw FormProblem('Enter an amount above zero with up to two decimal places.');
      await app.mutate('/shifts/${shift['id']}/cash-movements', {
        'transactionId': transactionId, 'direction': direction, 'amount': amount, 'reason': values['reason'],
      }, 'Drawer movement recorded.');
    },
  );
}

Future<void> showDrawerActivity(BuildContext context, Json shift) async {
  final app = context.appRead;
  final entries = app.list('cashMovements').where((m) => m['shiftId'] == shift['id']).toList().reversed;
  final staff = app.userName(shift['userId']);
  await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
    title: const Text('Shift cash activity'),
    content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$staff · ${formatDate(shift['openedAt'])}'),
        Text('Opening cash   ${app.money(shift['openingCash'])}'),
        if (app.isManager || shift['closedAt'] != null)
          Text('Expected cash   ${app.money(shift['expectedCash'] ?? app.expectedCash(shift))}'),
        if (shift['closedAt'] != null) Text('Counted cash   ${app.money(shift['countedCash'])}'),
        const Divider(),
        if (entries.isEmpty) const Text('No cash-in or cash-out entries.'),
        for (final entry in entries) ListTile(contentPadding: EdgeInsets.zero,
          title: Text('${entry['direction'] == 'in' ? 'Cash in' : 'Cash out'} · ${app.money(entry['amount'])}'),
          subtitle: Text('${formatDate(entry['createdAt'])} · ${app.userName(entry['userId'])}\n${entry['reason']}'),
        ),
      ],
    ))),
    actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close'))],
  ));
}

Future<void> closeShift(BuildContext context, Json shift) async {
  final app = context.appRead;
  if (app.pending.any((e) => e['transaction']['shiftId'] == shift['id'])) {
    app.toast('Resolve waiting payments in Settings › Sync & audit before closing this shift.');
    return;
  }
  await showFormDialog<void>(
    context,
    title: 'Close shift',
    submit: 'Close shift',
    fields: [
      FieldSpec('countedCash', 'Cash counted in drawer',
          kind: FieldKind.money,
          required: true,
          help: app.isManager ? 'Expected about ${app.money(app.expectedCash(shift))}.' : 'Count the drawer. Any difference is recorded.'),
      const FieldSpec('reason', 'Note', value: 'Shift close'),
    ],
    onSubmit: (v) async {
      final result = await app.mutate('/shifts/${shift['id']}/close', {
        'countedCash': parsePaymentAmount('${v['countedCash']}'),
        'reason': '${v['reason']}'.isEmpty ? 'Shift close' : v['reason'],
      }) as Map;
      final variance = (result['variance'] ?? 0) as int;
      app.toast(variance == 0 ? 'Shift closed. The drawer balances.' : 'Shift closed with a difference of ${app.money(variance)}.');
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
