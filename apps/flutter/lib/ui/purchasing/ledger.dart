
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';
import '../screens/people.dart';
import 'common.dart';
import 'bill_entry_dialog.dart';
import 'bill_detail.dart';
import 'supplier_return.dart';
import 'payments.dart';

/// Everything with one supplier or customer, with the running balance.
Future<void> showLedger(BuildContext context, String kind, Json party) =>
    showDialog<void>(context: context, builder: (_) => _LedgerDialog(kind: kind, party: party));

class _LedgerDialog extends StatefulWidget {
  const _LedgerDialog({required this.kind, required this.party});
  final String kind;
  final Json party;
  @override
  State<_LedgerDialog> createState() => _LedgerDialogState();
}

class _LedgerDialogState extends State<_LedgerDialog> {
  late Future<dynamic> ledger = _load();
  Future<dynamic> _load() => context.appRead.api('/parties/${widget.kind}/${widget.party['id']}/ledger');
  void _reload() => setState(() => ledger = _load());

  Future<void> _then(Future<void> action) async {
    await action;
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final supplier = widget.kind == 'suppliers';
    final party = app.list(widget.kind).where((p) => p['id'] == widget.party['id']).firstOrNull ?? widget.party;
    return AlertDialog(
      insetPadding: MediaQuery.sizeOf(context).width < 600 ? const EdgeInsets.all(12) : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: Row(children: [
        Expanded(child: Text('${party['name']}')),
        IconButton(tooltip: 'Edit details', icon: const Icon(Icons.edit_outlined), onPressed: () async {
          await editContact(context, widget.kind, party);
          if (mounted) _reload();
        }),
      ]),
      content: SizedBox(
        width: 820,
        height: 520,
        child: FutureBuilder<dynamic>(
          future: ledger,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text(errorText(snap.error!)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final balance = (snap.data['balance'] as num).toInt();
            final entries = (snap.data['entries'] as List).cast<Map>().reversed.toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Brand.mint, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text('${party['phone'] ?? ''}')),
                  Text(balanceText(app, widget.kind, balance), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: balanceColor(balance))),
                ]),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(supplier ? 'Pay supplier' : 'Receive payment'),
                  onPressed: () => _then(recordPayment(context, widget.kind, party)),
                ),
                if (supplier && app.canStock) ...[
                  OutlinedButton.icon(icon: const Icon(Icons.receipt_long_outlined), label: const Text('Enter bill'),
                      onPressed: () => _then(enterBill(context, supplierId: '${party['id']}'))),
                  OutlinedButton.icon(icon: const Icon(Icons.undo), label: const Text('Return parts'),
                      onPressed: () => _then(supplierReturn(context, party))),
                ],
                TextButton(
                  onPressed: () => _then(recordPayment(context, widget.kind, party, refund: true)),
                  child: Text(supplier ? 'Refund received' : 'Give money back'),
                ),
              ]),
              const SizedBox(height: 10),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('Nothing yet.'))
                    : ListView.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final debit = (e['debit'] as num).toInt();
                          final credit = (e['credit'] as num).toInt();
                          final payment = e['type'] == 'payment' || e['type'] == 'refund';
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${e['reference']}'),
                            subtitle: Text('${e['date'] == '0000-00-00' ? 'Before the POS' : e['date']}${'${e['note']}'.isEmpty ? '' : ' · ${e['note']}'}'),
                            onTap: e['type'] == 'bill'
                                ? () {
                                    final bill = app.list('purchaseBills').where((b) => b['id'] == e['id']).firstOrNull;
                                    if (bill != null) showBill(context, bill);
                                  }
                                : null,
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(debit > 0 ? '+ ${app.money(debit)}' : '− ${app.money(credit)}',
                                    style: TextStyle(color: debit > 0 ? Brand.danger : Brand.forest, fontWeight: FontWeight.w600)),
                                Text('Bal. ${app.money(e['balance'])}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ]),
                              if (payment && e['reversible'] != false && app.isManager)
                                IconButton(
                                  tooltip: 'Cancel this payment',
                                  icon: const Icon(Icons.block, size: 18),
                                  onPressed: () => _then(showFormDialog<void>(
                                    context,
                                    title: 'Record a payment reversal?',
                                    header: const Text('A drawer payment is reversed through your open shift. The original entry stays on the ledger.'),
                                    submit: 'Record reversal',
                                    fields: const [FieldSpec('reason', 'Reason', required: true)],
                                    onSubmit: (v) async => app.mutate('/party-payments/${e['id']}/void', {'reason': v['reason']}, 'Payment cancelled.'),
                                  )),
                                )
                              else
                                const SizedBox(width: 8),
                            ]),
                          );
                        },
                      ),
              ),
            ]);
          },
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
