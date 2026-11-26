import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt.dart';
import '../orders/returns.dart' show startReturnForInvoice; // WS-B

// WS-D: the shift screens moved to lib/ui/shift/.
export '../shift/shift_dialogs.dart' show recordDrawerMovement, showDrawerActivity, closeShift;
export '../shift/shift_home.dart' show ShiftsScreen;

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  DateTimeRange? _dates;
  String? _status;

  DateTime? _documentDay(AppState app, Json doc) {
    final raw = '${doc['createdAt'] ?? ''}';
    final timestamp = DateTime.tryParse(raw);
    if (timestamp == null) return null;
    return DateUtils.dateOnly(raw.length == 10 ? timestamp : documentTime(app, doc, timestamp));
  }

  bool _inDates(AppState app, Json doc) {
    final dates = _dates;
    if (dates == null) return true;
    final day = _documentDay(app, doc);
    return day != null && !day.isBefore(dates.start) && !day.isAfter(dates.end);
  }

  Future<void> _pickDates() async {
    final app = context.appRead;
    final today = DateUtils.dateOnly(documentTime(app, const {}, DateTime.now()));
    var lastDay = today;
    // An issued document can use a different time zone from the current register.
    for (final kind in const ['invoices', 'returns']) {
      for (final doc in app.list(kind)) {
        final day = _documentDay(app, doc);
        if (day != null && day.isAfter(lastDay)) lastDay = day;
      }
    }
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: lastDay,
      initialDateRange: _dates,
      currentDate: today,
      helpText: 'Invoice dates',
    );
    if (mounted && picked != null) setState(() => _dates = picked);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final dates = _dates;
    String dateLabel(DateTime day) => formatDate(day.toIso8601String().substring(0, 10));
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        bool match(Json r) {
          if (!_inDates(app, r)) return false;
          if (q.isEmpty) return true;
          final terms = [
            r['number'],
            r['invoiceNumber'],
            r['customer']?['name'],
            r['customer']?['phone'],
            r['vehicle']?['regNo'],
            for (final l in (r['lines'] as List? ?? const [])) ...[
              (l as Map)['name'],
              l['sku'],
            ],
          ];
          return terms.any((t) => normalize(t).contains(q));
        }
        final invoices = app.list('invoices').reversed
            .where((row) => match(row) && (_status == null || app.invoiceStatus(row) == _status)).toList();
        final credits = app.list('returns').reversed.where(match).toList();
        final filtered = q.isNotEmpty || dates != null || _status != null;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            OutlinedButton.icon(
              onPressed: _pickDates,
              icon: const Icon(Icons.date_range_outlined),
              label: Text(dates == null
                  ? 'Invoice dates'
                  : dates.start == dates.end ? dateLabel(dates.start) : '${dateLabel(dates.start)} – ${dateLabel(dates.end)}'),
            ),
            if (dates != null)
              IconButton(tooltip: 'Clear date filter', onPressed: () => setState(() => _dates = null), icon: const Icon(Icons.close)),
            for (final status in const [null, 'Finalized', 'Partially returned', 'Returned', 'Voided'])
              ChoiceChip(
                label: Text(status ?? 'All statuses'),
                selected: _status == status,
                onSelected: (_) => setState(() => _status = status),
              ),
          ]),
          DataList(
            rows: invoices,
            empty: filtered ? 'No invoices match these filters.' : 'No invoices yet. Completed sales appear here.',
            emptyAction: !filtered && app.canSell
                ? FilledButton.icon(onPressed: () => shell.open('/counter'), icon: const Icon(Icons.point_of_sale_outlined), label: const Text('Go to Counter'))
                : null,
            onTap: (row) => showReceipt(context, row),
            columns: [
              // QA #7: the invoice number opens the receipt (view / reprint / share).
              Col('Invoice', (r) => InkWell(
                    onTap: () => showReceipt(context, r),
                    child: Text('${r['number']}',
                        style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)),
                  )),
              Col('Date', (r) => Text(formatDocumentDate(app, r))),
              Col('Customer', (r) => Text('${r['customer']?['name'] ?? 'Walk-in'}')),
              Col('Status', (r) => StatusChip(app.invoiceStatus(r))),
              Col('Total', (r) => Text(ReceiptView(app, r).money(r['total'] as num)), numeric: true),
            ],
            actions: (r) {
              final status = app.invoiceStatus(r);
              // QA #7: View receipt and Return stay one click; Void moves into the ⋮ menu.
              return [
                OutlinedButton.icon(
                  onPressed: () => showReceipt(context, r),
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('View receipt'),
                ),
                if (status != 'Voided' && status != 'Returned' && app.canSell)
                  OutlinedButton(onPressed: () => startReturnForInvoice(context, r), child: const Text('Return')), // WS-B
                if (app.isManager && status == 'Finalized')
                  PopupMenuButton<String>(
                    tooltip: 'More actions for ${r['number']}',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) {
                      if (v == 'void') voidInvoice(context, r);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'void',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.block, color: Brand.danger),
                          title: Text('Void invoice', style: TextStyle(color: Brand.danger)),
                        ),
                      ),
                    ],
                  ),
              ];
            },
          ),
          SectionTitle('Credit notes'),
          DataList(
            rows: credits,
            empty: q.isEmpty && dates == null ? 'No returns or voids.' : 'No credit notes match these filters.',
            onTap: (row) => showReceipt(context, row),
            columns: [
              Col('Credit note', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
              Col('Invoice', (r) => Text('${r['invoiceNumber']}')),
              Col('Date', (r) => Text(formatDocumentDate(app, r))),
              // WS-B: exchanges and per-line dispositions.
              Col('Type', (r) => Text(r['voided'] == true ? 'Void' : r['exchangeApplied'] != null ? 'Exchange' : 'Return · ${titleCase('${r['condition']}')}')),
              Col('Refund', (r) => Text(r['refundType'] == 'Exchange'
                  ? '${ReceiptView(app, r).money(r['total'] as num)} · Exchange'
                  : '${ReceiptView(app, r).money((r['refundTotal'] ?? r['total']) as num)} · ${r['refundType'] ?? 'Cash'}'), numeric: true),
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
        if (v['refundType'] != _sameAsPaid) 'refundType': v['refundType'],
        'lines': [
          {'lineId': v['lineId'], 'quantity': qty, 'binId': v['binId'], 'serials': splitList(v['serials'])},
        ],
      }, 'Return recorded and refund noted.');
    },
  );
}

Future<void> voidInvoice(BuildContext context, Json invoice) async {
  final app = context.appRead;
  final transactionId = uuid();
  final result = await showFormDialog<Json>(
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
      // "Same as paid" sends no refundType: the server pays each tender back by itself.
      final body = {...v}..removeWhere((k, value) => k == 'refundType' && value == _sameAsPaid);
      return Map<String, dynamic>.from(await app.mutate('/invoices/${invoice['id']}/void', {...body, 'transactionId': transactionId}));
    },
  );
  if (result != null && context.mounted) {
    await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
      title: const Text('Invoice voided'), content: Text(refundInstructions(app, result, includeCore: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Done'))],
    ));
  }
}

const _sameAsPaid = 'original';

/// Cash/Card/UPI tenders that brought money in on this bill.
Set<String> _paidBy(Json invoice) => {
      for (final t in invoice['tenders'] as List? ?? [])
        if (const ['Cash', 'Card', 'UPI'].contains(t['type']) && ((t['amount'] ?? 0) as num) > 0) '${t['type']}',
    };

/// A sale on credit is refunded to the customer's account by default; otherwise the
/// original tender (QA #3) — a split bill "the same way it was paid", like the server default.
String _refundDefault(Json invoice) {
  final types = {for (final t in invoice['tenders'] as List? ?? []) if ((t['amount'] ?? 0) > 0) t['type']};
  if (types.isEmpty) return 'Cash';
  if (types.length != 1 || !const ['Cash','Card','UPI','Credit'].contains(types.first)) return _sameAsPaid;
  return types.first as String;
}

List<(String, String)> _refundOptions(AppState app, Json invoice) => [
      if (_refundDefault(invoice) == _sameAsPaid) (_sameAsPaid, 'Same as paid'),
      for (final t in {...app.tenderTypes.where((t) => const ['Cash', 'Card', 'UPI'].contains(t)), ..._paidBy(invoice)})
        (t, t == 'Cash' ? 'Cash from the drawer' : _paidBy(invoice).contains(t) ? '$t (as paid)' : t),
      if (invoice['customerId'] != null) ('Credit', "Customer's account (reduce udhaar)"),
    ];
