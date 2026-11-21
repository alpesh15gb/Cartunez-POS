// WS-B: Returns desk. Find the original bill (invoice number or scanned receipt,
// phone number or serial), choose what comes back and where it goes (shelf,
// damaged bin or supplier warranty), then settle: exchange at the counter,
// refund through the shift, or store credit on the customer's account.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../barcode_scan.dart';
import '../screens/receipt.dart';
import '../theme.dart';
import '../widgets.dart';
import 'exchange.dart';

const dispositionLabels = {
  'restock': 'Back on the shelf',
  'damaged': 'Damaged',
  'rma': 'Supplier warranty (RMA)',
};

int _ratio(int value, int numerator, int denominator) =>
    ((BigInt.from(value) * BigInt.from(numerator) + BigInt.from(denominator ~/ 2)) ~/ BigInt.from(denominator)).toInt();

/// Credit for returning [qty] more units of a looked-up line (same rule as the server).
int creditFor(Json line, int qty) {
  final lineQty = (line['qty'] ?? 0) as int;
  if (qty <= 0 || lineQty <= 0) return 0;
  final returned = (line['returnedQty'] ?? 0) as int;
  final value = _ratio((line['refundable'] ?? 0) as int, returned + qty, lineQty) - ((line['refundedSoFar'] ?? 0) as int);
  return value < 0 ? 0 : value;
}

Future<List<Json>> findReturnable(AppState app, String query) async {
  final result = await app.api('/returns/lookup?q=${Uri.encodeQueryComponent(query.trim())}');
  return [for (final row in result as List) Map<String, dynamic>.from(row as Map)];
}

/// Orders › Returns & exchange.
class ReturnsPage extends StatefulWidget {
  const ReturnsPage({super.key});
  @override
  State<ReturnsPage> createState() => _ReturnsPageState();
}

class _ReturnsPageState extends State<ReturnsPage> {
  final query = TextEditingController();
  List<Json>? results;
  String? error;
  bool busy = false;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _find([String? text]) async {
    if (text != null) query.text = text;
    if (query.text.trim().length < 2) return setState(() => error = 'Enter the invoice number, phone number or serial number.');
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found = await findReturnable(context.appRead, query.text);
      if (mounted) setState(() => results = found);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final rows = results;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Find the original bill', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TextField(
            controller: query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Invoice number, receipt barcode, phone or serial',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (_) => _find(),
          ),
        ),
        FilledButton.icon(onPressed: busy || !app.online ? null : _find, icon: const Icon(Icons.search), label: const Text('Find bill')),
        if (supportsBarcodeCamera)
          OutlinedButton.icon(
            onPressed: busy || !app.online
                ? null
                : () async {
                    final code = await requestBarcode(context);
                    if (code != null && code.trim().isNotEmpty) await _find(code);
                  },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan receipt'),
          ),
      ]),
      if (!app.online)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('Reconnect to look up bills for a return.')),
      if (error != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Brand.danger))),
      const SizedBox(height: 16),
      if (rows != null)
        DataList(
          rows: rows,
          empty: 'No bill found. Check the number, or try the customer\'s phone number.',
          onTap: (row) => startReturn(context, row),
          columns: [
            Col('Invoice', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
            Col('Date', (r) => Text(formatDate(r['createdAt']))),
            Col('Customer', (r) => Text('${r['customer']?['name'] ?? 'Walk-in'}')),
            Col('Returnable', (r) {
              final left = (r['lines'] as List).fold<int>(0, (n, l) => n + ((l['returnableQty'] ?? 0) as int));
              return r['voided'] == true ? const StatusChip('Voided') : left == 0 ? const StatusChip('Returned') : Text('$left item(s)');
            }),
            Col('Total', (r) => Text(app.money(r['total'] as num)), numeric: true),
          ],
          actions: (r) => [
            OutlinedButton(onPressed: () => startReturn(context, r), child: const Text('Return items')),
          ],
        ),
    ]);
  }
}

/// Opens the return form for a looked-up bill. A refund or store credit shows
/// the credit note (print or share); an exchange goes to the counter.
Future<void> startReturn(BuildContext context, Json invoice) async {
  final app = context.appRead;
  if (invoice['voided'] == true) return app.toast('This invoice was voided. Nothing on it can be returned.');
  if (!(invoice['lines'] as List).any((l) => ((l['returnableQty'] ?? 0) as int) > 0)) {
    return app.toast('Everything on this invoice has already been returned.');
  }
  final outcome = await showDialog<Object>(
    context: context,
    builder: (_) => AppScope(state: app, child: ReturnDialog(invoice: invoice)),
  );
  if (!context.mounted) return;
  if (outcome == 'exchange') {
    GoRouter.maybeOf(context)?.go('/counter');
  } else if (outcome is Map) {
    await showReceipt(context, Map<String, dynamic>.from(outcome));
  }
}

/// Opens a return from an invoice already on this device (Invoices list).
Future<void> startReturnForInvoice(BuildContext context, Json invoice) async {
  final app = context.appRead;
  if (!app.online) return app.toast('Reconnect to take a return.');
  try {
    final found = (await findReturnable(app, '${invoice['number']}')).where((r) => r['id'] == invoice['id']);
    if (!context.mounted) return;
    if (found.isEmpty) return app.toast('That invoice could not be found on the server.');
    await startReturn(context, found.first);
  } catch (e) {
    app.toast(errorText(e));
  }
}

class ReturnDialog extends StatefulWidget {
  const ReturnDialog({super.key, required this.invoice});
  final Json invoice;
  @override
  State<ReturnDialog> createState() => ReturnDialogState();
}

class ReturnDialogState extends State<ReturnDialog> {
  final transactionId = uuid();
  final qty = <String, int>{};
  final disposition = <String, String>{};
  final supplier = <String, String>{};
  final serials = <String, Set<String>>{};
  final reason = TextEditingController();
  final approval = TextEditingController();
  late String settle = 'exchange';
  late String refundType;
  bool busy = false;
  String? error;

  List<Json> get lines => [
        for (final l in widget.invoice['lines'] as List)
          if (((l['returnableQty'] ?? 0) as int) > 0) Map<String, dynamic>.from(l as Map),
      ];
  bool get hasCustomer => widget.invoice['customerId'] != null;
  bool get soldOnCredit => (widget.invoice['tenders'] as List? ?? []).any((t) => t['type'] == 'Credit');

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    refundType = app.tenderTypes.contains('Cash') ? 'Cash' : app.tenderTypes.first;
    if (soldOnCredit) settle = 'credit';
    final all = lines;
    for (final l in all) {
      disposition['${l['lineId']}'] = 'restock';
      supplier['${l['lineId']}'] = '${l['supplierId'] ?? ''}';
      serials['${l['lineId']}'] = {};
      if (all.length == 1 && (l['serials'] as List? ?? []).isEmpty) qty['${l['lineId']}'] = 1;
    }
  }

  @override
  void dispose() {
    reason.dispose();
    approval.dispose();
    super.dispose();
  }

  bool _serialised(Json l) => (l['serials'] as List? ?? []).isNotEmpty;
  int _qty(Json l) => _serialised(l) ? serials['${l['lineId']}']!.length : qty['${l['lineId']}'] ?? 0;
  int get credit => lines.fold(0, (n, l) => n + creditFor(l, _qty(l)));

  List<Json> _chosen() => [
        for (final l in lines)
          if (_qty(l) > 0)
            {
              'lineId': l['lineId'],
              'productId': l['productId'],
              'name': l['name'],
              'quantity': _qty(l),
              'disposition': disposition['${l['lineId']}'],
              'serials': serials['${l['lineId']}']!.toList(),
              if (disposition['${l['lineId']}'] == 'rma' && supplier['${l['lineId']}']!.isNotEmpty) 'supplierId': supplier['${l['lineId']}'],
              'credit': creditFor(l, _qty(l)),
            },
      ];

  Future<void> _submit() async {
    final app = context.appRead;
    final chosen = _chosen();
    setState(() => error = null);
    if (chosen.isEmpty) return setState(() => error = 'Choose at least one item coming back.');
    for (final c in chosen) {
      if (c['disposition'] == 'rma' && c['supplierId'] == null) {
        return setState(() => error = 'Choose the supplier to claim the warranty on ${c['name']} from.');
      }
    }
    if (settle == 'exchange') {
      final existing = exchangeReturns(app.cart);
      if (existing.isNotEmpty && existing.first['invoiceId'] != widget.invoice['id']) {
        final replace = await confirm(context, 'Replace the exchange?',
            'The counter already has items coming back from ${existing.first['invoiceNumber']}. Exchange items from one bill at a time.',
            action: 'Replace');
        if (!replace) return;
      }
      addExchangeReturns(app, widget.invoice, chosen, reason.text.trim());
      app.toast('Items added to the counter as an exchange. Add the replacement and take payment.');
      if (mounted) Navigator.pop(context, 'exchange');
      return;
    }
    if (reason.text.trim().isEmpty) return setState(() => error = 'Enter the reason for the return.');
    if (!app.isManager && approval.text.trim().isEmpty) {
      return setState(() => error = 'A manager approval ID is needed. Reference $transactionId');
    }
    setState(() => busy = true);
    try {
      final note = await app.mutate('/invoices/${widget.invoice['id']}/returns', {
        'transactionId': transactionId,
        if (!app.isManager) 'approvalId': approval.text.trim(),
        'reason': reason.text.trim(),
        'refundType': settle == 'credit' ? 'Credit' : refundType,
        'lines': [
          for (final c in chosen)
            {
              'lineId': c['lineId'],
              'quantity': c['quantity'],
              'disposition': c['disposition'],
              'serials': c['serials'],
              if (c['supplierId'] != null) 'supplierId': c['supplierId'],
            },
        ],
      }, settle == 'credit' ? 'Return recorded. Store credit added to the customer\'s account.' : 'Return recorded. Give the refund from the drawer.');
      if (mounted) Navigator.pop(context, note is Map ? note : null);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _line(BuildContext context, AppState app, Json l) {
    final id = '${l['lineId']}';
    final left = (l['returnableQty'] ?? 0) as int;
    final service = l['type'] == 'service';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${l['sku'] ?? ''} · $left of ${l['qty']} can come back', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (_serialised(l))
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in (l['serials'] as List).map((e) => '$e'))
                FilterChip(
                  label: Text(s),
                  selected: serials[id]!.contains(s),
                  onSelected: (on) => setState(() => on ? serials[id]!.add(s) : serials[id]!.remove(s)),
                ),
            ])
          else
            Row(children: [
              IconButton.outlined(
                tooltip: 'Fewer of ${l['name']}',
                onPressed: (qty[id] ?? 0) > 0 ? () => setState(() => qty[id] = (qty[id] ?? 0) - 1) : null,
                icon: const Icon(Icons.remove, size: 16),
              ),
              SizedBox(width: 40, child: Text('${qty[id] ?? 0}', key: ValueKey('qty-$id'), textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              IconButton.outlined(
                tooltip: 'More of ${l['name']}',
                onPressed: (qty[id] ?? 0) < left ? () => setState(() => qty[id] = (qty[id] ?? 0) + 1) : null,
                icon: const Icon(Icons.add, size: 16),
              ),
              const Spacer(),
              Text(app.money(creditFor(l, _qty(l))), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          if (!service && _qty(l) > 0) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('disposition-$id'),
              initialValue: disposition[id],
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Where does it go?'),
              items: [for (final e in dispositionLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => disposition[id] = v ?? 'restock'),
            ),
            // Security: cashiers get no supplier list; the part's usual supplier is used.
            if (disposition[id] == 'rma' && app.list('suppliers').isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('The claim goes to the usual supplier of this part. A manager can change it later.'),
              )
            else if (disposition[id] == 'rma')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DropdownButtonFormField<String>(
                  initialValue: supplier[id]!.isEmpty ? null : supplier[id],
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Claim from supplier'),
                  items: [for (final s in app.list('suppliers')) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}'))],
                  onChanged: (v) => setState(() => supplier[id] = v ?? ''),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final customer = widget.invoice['customer'] as Map?;
    return AlertDialog(
      scrollable: true,
      title: Text('Return from ${widget.invoice['number']}'),
      content: SizedBox(
        width: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${formatDate(widget.invoice['createdAt'])} · ${customer?['name'] ?? 'Walk-in'} · ${app.money(widget.invoice['total'] as num?)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          for (final l in lines) _line(context, app, l),
          Text('Credit for these items: ${app.money(credit)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 'exchange', label: Text('Exchange'), icon: Icon(Icons.swap_horiz)),
              const ButtonSegment(value: 'refund', label: Text('Refund'), icon: Icon(Icons.payments_outlined)),
              if (hasCustomer) const ButtonSegment(value: 'credit', label: Text('Store credit'), icon: Icon(Icons.menu_book_outlined)),
            ],
            selected: {settle},
            onSelectionChanged: (v) => setState(() => settle = v.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (settle) {
              'exchange' => 'The items go on the counter bill as a credit. Add the replacement; the customer pays or gets back the difference.',
              'credit' => 'The credit goes on ${customer?['name'] ?? 'the customer'}\'s account and can pay later bills.',
              _ => 'Give the money back from your shift.',
            },
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (settle == 'refund') ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: refundType,
              decoration: const InputDecoration(labelText: 'Refund by'),
              items: [for (final t in app.tenderTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: (v) => setState(() => refundType = v ?? refundType),
            ),
          ],
          const SizedBox(height: 8),
          TextField(controller: reason, decoration: InputDecoration(labelText: settle == 'exchange' ? 'Reason (optional)' : 'Reason')),
          if (!app.isManager && settle != 'exchange')
            TextField(
              controller: approval,
              decoration: InputDecoration(labelText: 'Manager approval ID', helperText: 'Reference $transactionId'),
            ),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: busy || (!app.online && settle != 'exchange') ? null : _submit,
          icon: Icon(settle == 'exchange' ? Icons.point_of_sale_outlined : Icons.check),
          label: Text(settle == 'exchange' ? 'Add to counter' : 'Record return'),
        ),
      ],
    );
  }
}
