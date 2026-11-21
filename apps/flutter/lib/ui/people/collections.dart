// WS-B: People › Collections: every customer who owes the shop, with
// collect-payment and a WhatsApp reminder carrying the amount due.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../purchasing/payments.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'account_actions.dart';

class CollectionsPage extends StatefulWidget {
  const CollectionsPage({super.key});
  @override
  State<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<CollectionsPage> {
  late Future<dynamic> data = _load();
  Future<dynamic> _load() => context.appRead.api('/collections');
  void _reload() => setState(() => data = _load());

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return FutureBuilder<dynamic>(
      future: data,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data is! Map) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(snap.hasError ? errorText(snap.error!) : 'Collections could not be loaded.'),
            TextButton(onPressed: _reload, child: const Text('Try again')),
          ]);
        }
        final result = snap.data as Map;
        final rows = [for (final r in result['rows'] as List) Map<String, dynamic>.from(r as Map)];
        final q = normalize(ShellScope.of(context).search.text);
        final shown = rows.where((r) => q.isEmpty || normalize('${r['name']} ${r['phone']}').contains(q)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            Text('Customers owe ${app.money(result['total'] as num? ?? 0)} in total',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.danger)),
            IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
          ]),
          DataList(
            rows: shown,
            empty: 'Nobody owes you. Credit (udhaar) sales appear here until paid.',
            emptyAction: q.isEmpty
                ? OutlinedButton.icon(onPressed: () => ShellScope.of(context).open('/people/customers'), icon: const Icon(Icons.people_outline), label: const Text('See all customers'))
                : null,
            onTap: (r) => ShellScope.of(context).open('/people/customers/${r['customerId']}'),
            columns: [
              Col('Customer', (r) => Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
              Col('Phone', (r) => Text('${r['phone'] ?? ''}'.isEmpty ? '—' : '${r['phone']}')),
              Col('Oldest due', (r) => Text(r['oldestDueDate'] == null ? '—' : '${r['oldestDueDays']} days')),
              Col('Limit', (r) => r['overLimit'] == true
                  ? const StatusChip('Over limit')
                  : Text(r['creditLimit'] == null ? '—' : app.money(r['creditLimit'] as num))),
              Col('Owes', (r) => Text(app.money(r['balance'] as num), style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w700)), numeric: true),
            ],
            actions: (r) => [
              if (app.canSell)
                OutlinedButton(
                  onPressed: () async {
                    final customer = app.customerById('${r['customerId']}') ?? {'id': r['customerId'], 'name': r['name']};
                    await recordPayment(context, 'customers', customer);
                    if (mounted) _reload();
                  },
                  child: const Text('Collect'),
                ),
              IconButton(
                tooltip: 'WhatsApp reminder',
                onPressed: () => sendReminder(context, phone: '${r['phone'] ?? ''}', name: '${r['name']}', amount: r['balance'] as int),
                icon: const Icon(Icons.chat_outlined),
              ),
            ],
          ),
        ]);
      },
    );
  }
}
