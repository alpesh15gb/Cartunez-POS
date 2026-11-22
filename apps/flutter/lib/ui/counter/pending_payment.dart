// QA #8: a card / UPI sale saved with "payment confirmed" off waits in Sync & audit.
// Confirming it shows the tender, amount, items and pending status together, carries
// the reference entered at checkout, and after posting names the invoice with "Open invoice".
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/receipt.dart';
import '../widgets.dart';

/// Unconfirmed card / UPI tenders of a pending sale.
List<Json> unconfirmedTenders(Json entry) => [
      for (final t in entry['transaction']['tenders'] as List)
        if (t['type'] != 'Cash' && t['confirmed'] != true) Map<String, dynamic>.from(t as Map),
    ];

/// "2 × Engine oil, 1 × Air filter" for a pending sale.
String pendingItemSummary(AppState app, Json entry) {
  final lines = entry['transaction']['lines'] as List? ?? [];
  final parts = [
    for (final l in lines)
      '${l['qty'] ?? 1} × ${l['name'] ?? app.productById('${l['productId']}')?['name'] ?? 'Item'}',
  ];
  return parts.isEmpty ? 'No items' : parts.join(', ');
}

/// The Sync & audit row actions for a sale awaiting card / UPI confirmation.
Future<void> confirmPendingPayment(BuildContext context, Json entry) async {
  final app = context.appRead;
  final transactionId = '${entry['transaction']['transactionId']}';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AppScope(state: app, child: ConfirmPendingPaymentDialog(entry: entry)),
  );
  if (confirmed != true || !context.mounted) return;
  // The sale was sent by the confirm; find the invoice the server made from it.
  final invoice = app.list('invoices').where((i) => i['transactionId'] == transactionId).firstOrNull;
  if (invoice == null) {
    app.toast('Payment confirmed. The sale sends with the next sync.');
    return;
  }
  final open = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Payment confirmed'),
      content: Text('Invoice ${invoice['number']} is saved for ${app.money(invoice['total'] as num?)}.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Done')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialog, true),
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('Open invoice'),
        ),
      ],
    ),
  );
  if (open == true && context.mounted) await showReceipt(context, invoice);
}

class ConfirmPendingPaymentDialog extends StatefulWidget {
  const ConfirmPendingPaymentDialog({super.key, required this.entry});
  final Json entry;
  @override
  State<ConfirmPendingPaymentDialog> createState() => _ConfirmPendingPaymentDialogState();
}

class _ConfirmPendingPaymentDialogState extends State<ConfirmPendingPaymentDialog> {
  late final tenders = unconfirmedTenders(widget.entry);
  // The reference typed at checkout is carried over (QA #8).
  late final refs = {for (final t in tenders) '${t['type']}': TextEditingController(text: '${t['reference'] ?? ''}')};
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final c in refs.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final app = context.appRead;
    for (final e in refs.entries) {
      if (e.value.text.trim().isEmpty) return setState(() => error = 'Enter the ${e.key} payment reference.');
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await app.confirmPayment('${widget.entry['transaction']['transactionId']}', {for (final e in refs.entries) e.key: e.value.text.trim()});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      scrollable: true,
      title: const Text('Confirm card / UPI payment'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Sale total ${app.money(widget.entry['total'] as num?)}', style: const TextStyle(fontWeight: FontWeight.w800))),
            const StatusChip('Awaiting payment'),
          ]),
          const SizedBox(height: 6),
          Text('Items: ${pendingItemSummary(app, widget.entry)}', key: const ValueKey('pending-items'), style: small),
          Text('Saved ${formatDate(widget.entry['createdAt'])}', style: small),
          const SizedBox(height: 12),
          for (final t in tenders) ...[
            Text('${t['type']} · ${app.money(t['amount'] as num?)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            TextField(
              controller: refs['${t['type']}'],
              decoration: InputDecoration(labelText: '${t['type']} payment reference'),
            ),
            const SizedBox(height: 10),
          ],
          Text('Check the card machine or UPI app shows this payment received before confirming.', style: small),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: busy ? null : _submit, child: const Text('Confirm and save invoice')),
      ],
    );
  }
}
