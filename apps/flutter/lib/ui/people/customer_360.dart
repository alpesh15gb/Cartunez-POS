// WS-B: Customer 360 at /people/customers/:id. Profile, vehicles, account
// (balance, advance, credit limit), bills still due, purchases, returns and the
// ledger, with collect-payment, advance and WhatsApp reminder actions.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../purchasing/common.dart';
import '../purchasing/payments.dart';
import '../screens/people.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import '../workshop/vehicles.dart' show editVehicle;
import 'account_actions.dart';

/// Loads the customer's summary from the server and shows [Customer360View].
class Customer360Page extends StatefulWidget {
  const Customer360Page({super.key, required this.id});
  final String id;
  @override
  State<Customer360Page> createState() => _Customer360PageState();
}

class _Customer360PageState extends State<Customer360Page> {
  late Future<dynamic> summary = _load();
  Future<dynamic> _load() => context.appRead.api('/customers/${Uri.encodeComponent(widget.id)}/summary');
  void _reload() => setState(() => summary = _load());

  @override
  void didUpdateWidget(Customer360Page old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: summary,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data is! Map) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _Back(),
            Text(snap.hasError ? errorText(snap.error!) : 'This customer could not be loaded.'),
            TextButton(onPressed: _reload, child: const Text('Try again')),
          ]);
        }
        return Customer360View(summary: Map<String, dynamic>.from(snap.data as Map), onChanged: _reload);
      },
    );
  }
}

class _Back extends StatelessWidget {
  const _Back();
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => ShellScope.of(context).open('/people/customers'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('All customers'),
        ),
      );
}

class Customer360View extends StatelessWidget {
  const Customer360View({super.key, required this.summary, this.onChanged});
  final Json summary;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final customer = Map<String, dynamic>.from(summary['customer'] as Map);
    final balance = (summary['balance'] ?? 0) as int;
    final advance = (summary['availableAdvance'] ?? 0) as int;
    final limit = summary['creditLimit'] as int?;
    final stats = Map<String, dynamic>.from(summary['stats'] as Map? ?? {});
    final vehicles = [for (final v in summary['vehicles'] as List? ?? const []) if (v is Map) Map<String, dynamic>.from(v)];
    final registered = app.list('customerVehicles').where((v) => v['customerId'] == customer['id']).toList();
    List<Json> rows(String key) => [for (final r in summary[key] as List? ?? const []) Map<String, dynamic>.from(r as Map)];
    Future<void> then(Future<bool> action) async {
      if (await action) onChanged?.call();
    }

    final details = [
      if ('${customer['phone'] ?? ''}'.isNotEmpty) '${customer['phone']}',
      if ('${customer['email'] ?? ''}'.isNotEmpty) '${customer['email']}',
      if ('${customer['taxRegistrationId'] ?? ''}'.isNotEmpty) 'GSTIN ${customer['taxRegistrationId']}',
    ].join(' · ');
    final head = <Widget>[
      const _Back(),
      Text('${customer['name']}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
      if (details.isNotEmpty) Text(details),
      if ('${customer['address'] ?? ''}'.isNotEmpty) Text('${customer['address']}', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      Toolbar([
        if (app.canSell && balance > 0)
          FilledButton.icon(
            onPressed: () => then(recordPayment(context, 'customers', customer).then((_) => true)),
            icon: const Icon(Icons.payments_outlined),
            label: const Text('Collect payment'),
          ),
        if (app.canSell && balance > 0)
          OutlinedButton.icon(onPressed: () => then(takeAdvance(context, customer)), icon: const Icon(Icons.savings_outlined), label: const Text('Take advance')),
        if (app.canSell && balance <= 0)
          FilledButton.icon(onPressed: () => then(takeAdvance(context, customer)), icon: const Icon(Icons.savings_outlined), label: const Text('Take advance')),
        if (app.canSell && advance > 0)
          OutlinedButton.icon(onPressed: () => then(refundAdvance(context, customer, advance)), icon: const Icon(Icons.undo), label: const Text('Give back advance')),
        if (balance > 0)
          OutlinedButton.icon(
            onPressed: () => sendReminder(context, phone: '${customer['phone'] ?? ''}', name: '${customer['name']}', amount: balance),
            icon: const Icon(Icons.chat_outlined),
            label: const Text('WhatsApp reminder'),
          ),
        OutlinedButton.icon(
          onPressed: () => editContact(context, 'customers', customer, onSaved: (_) => onChanged?.call()),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit'),
        ),
        if (app.isManager)
          OutlinedButton.icon(onPressed: () => then(editCreditLimit(context, customer)), icon: const Icon(Icons.speed_outlined), label: const Text('Set credit limit')),
      ]),
    ];
    // Profile, figures, vehicles and dues on one side; history and the ledger on the other.
    final profile = <Widget>[
      LayoutBuilder(builder: (context, c) {
        final figures = [
          _Figure('Balance', balanceText(app, 'customers', balance), color: balanceColor(balance)),
          if (advance > 0) _Figure('Advance held', app.money(advance), color: Brand.forest),
          _Figure('Credit limit', limit == null ? 'No limit' : app.money(limit),
              sub: limit == null ? null : '${app.money(summary['creditAvailable'] as int? ?? 0)} left'),
          _Figure('Bills', '${stats['bills'] ?? 0}', sub: 'Spent ${app.money(stats['spent'] as num? ?? 0)}'),
          _Figure('Last visit', stats['lastVisit'] == null ? '—' : formatDate(stats['lastVisit'])),
        ];
        // An even grid: two across in a narrow pane, otherwise up to five.
        final across = c.maxWidth < 640 ? 2 : figures.length;
        final width = (c.maxWidth - 12 * (across - 1)) / across;
        return Wrap(spacing: 12, runSpacing: 12, children: [for (final f in figures) SizedBox(width: width, child: f)]);
      }),
      SectionTitle('Vehicles', trailing: app.canSell
          ? TextButton.icon(
              onPressed: () => then(editVehicle(context, {'customerId': customer['id']}).then((vehicle) => vehicle != null)),
              icon: const Icon(Icons.add),
              label: const Text('Add vehicle'),
            )
          : null),
      // Integration: the customer's vehicles from the vehicle registry (WS-C), each
      // opening its page; the legacy saved vehicle shows only when none is registered.
      if (registered.isNotEmpty)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in registered)
            ActionChip(
              avatar: const Icon(Icons.directions_car_outlined, size: 18),
              tooltip: 'Open vehicle',
              label: Text([v['regNo'], v['make'], v['model'], v['variant'], v['year']]
                  .where((e) => e != null && '$e'.isNotEmpty).join(' ')),
              onPressed: () => ShellScope.of(context).open('/people/vehicles/${v['id']}'),
            ),
        ])
      else if (vehicles.isEmpty)
        const Text('No vehicle saved.')
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in vehicles)
            Chip(
              avatar: const Icon(Icons.directions_car_outlined, size: 18),
              label: Text([v['registration'] ?? v['regNumber'], v['make'], v['model'], v['year']]
                  .where((e) => e != null && '$e'.isNotEmpty).join(' ')),
            ),
        ]),
    ];
    final dues = <Widget>[
      SectionTitle('Bills still due'),
      DataList(
        rows: rows('dueBills'),
        empty: 'Nothing due.',
        onTap: (r) => '${r['invoiceId'] ?? ''}'.isEmpty ? null : ShellScope.of(context).open('/orders/invoices/${r['invoiceId']}'),
        columns: [
          Col('Bill', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Date', (r) => Text(formatDate(r['date']))),
          Col('Age', (r) => Text('${r['ageDays']} days')),
          Col('Due', (r) => Text(app.money(r['due'] as num), style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w700)), numeric: true),
        ],
      ),
    ];
    final history = <Widget>[
      SectionTitle('Purchases'),
      DataList(
        rows: rows('invoices'),
        empty: 'No bills yet.',
        onTap: (r) => ShellScope.of(context).open('/orders/invoices/${r['id']}'),
        columns: [
          Col('Invoice', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Date', (r) => Text(formatDate(r['createdAt']))),
          Col('Items', (r) => Text('${r['items']}')),
          Col('Paid by', (r) => Text((r['tenders'] as List).map((t) => t['type']).toSet().join(', '))),
          Col('Total', (r) => Text(app.money(r['total'] as num)), numeric: true),
        ],
      ),
      SectionTitle('Returns'),
      DataList(
        rows: rows('returns'),
        empty: 'No returns.',
        onTap: (r) => ShellScope.of(context).open('/orders/invoices/${r['id']}'),
        columns: [
          Col('Credit note', (r) => Text('${r['number']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Invoice', (r) => Text('${r['invoiceNumber']}')),
          Col('Date', (r) => Text(formatDate(r['createdAt']))),
          Col('Settled', (r) => Text(r['refundType'] == 'Exchange' ? 'Exchange' : '${r['refundType']} ${app.money(r['refund'] as num?)}')),
          Col('Credit', (r) => Text(app.money(r['total'] as num)), numeric: true),
        ],
      ),
    ];
    final account = <Widget>[
      SectionTitle('Account'),
      DataList(
        rows: rows('entries').reversed.toList(),
        empty: 'No account entries. Only credit sales, payments, advances and store credit appear here.',
        columns: [
          Col('Date', (r) => Text(formatDate(r['date']))),
          Col('Entry', (r) => Text([r['reference'], r['note']].where((e) => e != null && '$e'.isNotEmpty).join(' · ')), flex: 2),
          Col('Owes more', (r) => Text((r['debit'] ?? 0) == 0 ? '' : app.money(r['debit'] as num)), numeric: true),
          Col('Paid / credit', (r) => Text((r['credit'] ?? 0) == 0 ? '' : app.money(r['credit'] as num)), numeric: true),
          Col('Balance', (r) => Text(balanceText(app, 'customers', (r['balance'] ?? 0) as int),
              style: TextStyle(color: balanceColor((r['balance'] ?? 0) as int))), numeric: true),
        ],
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 1100) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, ...profile, ...dues, ...history, ...account]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...head,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...profile, ...dues])),
          const SizedBox(width: 24),
          // The right pane starts level with the figures.
          Expanded(flex: 6, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ...account.map((w) => w is SectionTitle && identical(w, account.first) ? _TopTitle(w) : w),
            ...history,
          ])),
        ]),
      ]);
    });
  }
}

/// A section title without the top gap, for the first item of a pane.
class _TopTitle extends StatelessWidget {
  const _TopTitle(this.title);
  final SectionTitle title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title.text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.sub, this.color});
  final String label;
  final String value;
  final String? sub;
  final Color? color;
  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          constraints: const BoxConstraints(minWidth: 150),
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
            if (sub != null) Text(sub!, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}
