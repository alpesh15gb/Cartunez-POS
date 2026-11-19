import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'online.dart';

const _orderStates = {
  'reserved': 'Reserved',
  'awaiting': 'Awaiting stock',
  'sold': 'Sold',
  'cancelled': 'Cancelled',
  'refunded': 'Refunded',
  'unmatched': 'Unknown parts',
};

Widget _orderChip(String state) {
  final label = _orderStates[state] ?? state;
  final (bg, fg) = switch (state) {
    'sold' => (Brand.mint, Brand.forest),
    'awaiting' || 'unmatched' => (const Color(0xFFFBEBE7), Brand.danger),
    'reserved' => (const Color(0xFFFDF3DF), Brand.warning),
    _ => (const Color(0xFFEEF1EF), Brand.muted),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
    child: Text(label, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
  );
}

bool _short(Json o) => (o['lines'] as List? ?? []).any((l) => (((l as Map)['shortage'] as num?) ?? 0) > 0);

/// Orders from the Magento store and what the POS has done with their stock.
class OnlineOrdersScreen extends StatefulWidget {
  const OnlineOrdersScreen({super.key});
  @override
  State<OnlineOrdersScreen> createState() => _OnlineOrdersScreenState();
}

class _OnlineOrdersScreenState extends State<OnlineOrdersScreen> {
  String filter = 'open';
  bool checking = false;

  static const filters = [
    ('open', 'Needs attention'),
    ('reserved', 'Reserved'),
    ('awaiting', 'Awaiting stock'),
    ('sold', 'Sold'),
    ('cancelled', 'Cancelled'),
    ('all', 'All'),
  ];

  Future<void> _check() async {
    final app = context.appRead;
    setState(() => checking = true);
    try {
      final r = await app.api('/integrations/magento/orders/poll', body: {});
      await app.sync();
      app.toast((r['imported'] ?? 0) == 0 ? 'No new or changed orders.' : '${r['imported']} order update(s) read from Magento.');
    } catch (e) {
      await app.sync();
      app.toast('Magento: ${errorText(e)}');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  bool _keep(Json o) {
    final state = '${o['posState']}';
    return switch (filter) {
      'open' => state == 'reserved' || state == 'awaiting' || state == 'unmatched' || _short(o),
      'all' => true,
      _ => state == filter,
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final check = app.snapshot['onlineOrdersCheck'] as Map?;
    final orders = app.list('onlineOrders')..sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
    final small = Theme.of(context).textTheme.bodySmall;
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final rows = orders.where(_keep).where((o) {
          if (q.isEmpty) return true;
          final c = (o['customer'] as Map?) ?? {};
          return [o['number'], c['name'], c['email'], c['phone'], ...(o['lines'] as List? ?? []).map((l) => (l as Map)['sku'])]
              .any((v) => normalize(v).contains(q));
        }).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!app.magentoConnected)
            const Card(
              color: Color(0xFFFFF7E8),
              child: ListTile(
                leading: Icon(Icons.link_off, color: Brand.warning),
                title: Text('Magento is not connected'),
                subtitle: Text('Connect the store in Settings to receive online orders.'),
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  const Icon(Icons.shopping_bag_outlined, color: Brand.forest),
                  Text(
                    check?['at'] == null ? 'Orders are read from Magento every minute.' : 'Last checked ${formatDate(check!['at'] as String?)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (check?['error'] != null) Text('${check!['error']}', style: const TextStyle(color: Brand.danger)),
                  FilledButton.tonalIcon(
                    onPressed: checking ? null : _check,
                    icon: checking
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync, size: 18),
                    label: const Text('Check now'),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, label) in filters)
              ChoiceChip(label: Text(label), selected: filter == key, onSelected: (_) => setState(() => filter = key)),
          ]),
          const SizedBox(height: 12),
          DataList(
            rows: rows,
            empty: orders.isEmpty ? 'No online orders yet. New Magento orders appear here within a minute.' : 'No order matches.',
            onTap: (o) => showOnlineOrder(context, o),
            columns: [
              Col('Order', (o) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('#${o['number']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(formatDate(o['createdAt'] as String?), style: small),
                  ]), flex: 2),
              Col('Customer', (o) {
                final c = (o['customer'] as Map?) ?? {};
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['name'] ?? ''}'),
                  Text('${o['shipTo'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                ]);
              }, flex: 3),
              Col('Items', (o) {
                final lines = (o['lines'] as List? ?? []).cast<Map>();
                return Text(lines.map((l) => '${l['ordered']}× ${l['sku']}').join(', '), maxLines: 2, overflow: TextOverflow.ellipsis);
              }, flex: 3),
              Col('Status', (o) => Wrap(spacing: 6, runSpacing: 4, children: [
                    _orderChip('${o['posState']}'),
                    if (_short(o) && o['posState'] != 'awaiting') _orderChip('awaiting'),
                  ]), flex: 2),
              Col('Total', (o) => Text(app.money(o['total'] as num?)), numeric: true),
            ],
          ),
        ]);
      },
    );
  }
}

/// One online order: what was ordered, what the POS holds or has taken, and actions.
Future<void> showOnlineOrder(BuildContext context, Json order) =>
    showDialog<void>(context: context, builder: (_) => _OnlineOrderDialog(orderId: '${order['id']}'));

class _OnlineOrderDialog extends StatefulWidget {
  const _OnlineOrderDialog({required this.orderId});
  final String orderId;
  @override
  State<_OnlineOrderDialog> createState() => _OnlineOrderDialogState();
}

class _OnlineOrderDialogState extends State<_OnlineOrderDialog> {
  bool busy = false;

  Future<void> _run(String path, String done) async {
    final app = context.appRead;
    setState(() => busy = true);
    try {
      await app.mutate(path, {}, done);
    } catch (e) {
      app.toast(errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _lineState(Map l) {
    if (l['productId'] == null) return 'Not in the POS catalogue (SKU ${l['sku']})';
    final parts = [
      if ((l['reserved'] ?? 0) > 0) '${l['reserved']} reserved',
      if ((l['deducted'] ?? 0) > 0) '${l['deducted']} taken from stock',
      if ((l['awaiting'] ?? 0) > 0) '${l['awaiting']} waiting for stock',
      if ((l['canceled'] ?? 0) > 0) '${l['canceled']} cancelled',
      if ((l['refunded'] ?? 0) > 0) '${l['refunded']} refunded',
      // Units already invoiced but not in stock are "waiting"; "short" is for orders not yet invoiced.
      if ((l['shortage'] ?? 0) > (l['awaiting'] ?? 0)) '${(l['shortage'] as num) - ((l['awaiting'] as num?) ?? 0)} short in the shop',
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final o = app.list('onlineOrders').where((x) => x['id'] == widget.orderId).firstOrNull;
    if (o == null) return const AlertDialog(content: Text('This order is no longer available.'));
    final c = (o['customer'] as Map?) ?? {};
    final lines = (o['lines'] as List? ?? []).cast<Map>();
    final small = Theme.of(context).textTheme.bodySmall;
    final awaiting = lines.any((l) => ((l['awaiting'] as num?) ?? 0) > 0);
    final short = _short(o);
    final contact = [c['name'], c['phone'], c['email']].where((v) => '${v ?? ''}'.isNotEmpty).join(' · ');
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text('Online order #${o['number']}')),
        _orderChip('${o['posState']}'),
      ]),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(contact),
            if ('${o['shipTo'] ?? ''}'.isNotEmpty) Text('Ship to ${o['shipTo']}', style: small),
            Text('Placed ${formatDate(o['createdAt'] as String?)} · Magento status: ${o['status']}', style: small),
            const SizedBox(height: 14),
            for (final l in lines)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Brand.line))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${l['ordered']} × ${l['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(_lineState(l),
                          style: small?.copyWith(color: (l['shortage'] ?? 0) > 0 || l['productId'] == null ? Brand.danger : null)),
                    ]),
                  ),
                  Text(app.money(((l['price'] as num?) ?? 0) * ((l['ordered'] as num?) ?? 0))),
                ]),
              ),
            const Divider(),
            Align(
              alignment: Alignment.centerRight,
              child: Text('Total ${app.money(o['total'] as num?)}', style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            if ((o['purchaseOrderIds'] as List? ?? []).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Purchase order(s) created: ${(o['purchaseOrderIds'] as List).join(', ')}', style: small),
              ),
            const SizedBox(height: 8),
            Text('Invoices, shipping and refunds are done in Magento; the POS follows them within a minute.', style: small),
          ]),
        ),
      ),
      actions: [
        if (short)
          OutlinedButton.icon(
            onPressed: busy ? null : () => _run('/online-orders/${o['id']}/purchase-order', 'Purchase order created. Find it in Purchasing › Orders.'),
            icon: const Icon(Icons.local_shipping_outlined, size: 18),
            label: const Text('Order missing parts'),
          ),
        if (awaiting)
          FilledButton(
            onPressed: busy ? null : () => _run('/online-orders/${o['id']}/fulfil', 'Stock taken for the order.'),
            child: const Text('Fulfil from stock'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
