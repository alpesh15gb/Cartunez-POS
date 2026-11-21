// WS-E: batch pick list for several online orders, walked in bin order.
import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'pick_pack.dart';

Future<void> openBatchPick(BuildContext context, List<String> orderIds) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BatchPickPage(orderIds: orderIds)),
    );

class BatchPickPage extends StatefulWidget {
  const BatchPickPage({super.key, required this.orderIds});
  final List<String> orderIds;
  @override
  State<BatchPickPage> createState() => _BatchPickPageState();
}

class _BatchPickPageState extends State<BatchPickPage> {
  late Future<dynamic> list = _load();
  final done = <String>{};

  Future<dynamic> _load() => context.appRead.api('/online-orders/pick-list?ids=${Uri.encodeQueryComponent(widget.orderIds.join(','))}');

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      appBar: AppBar(title: Text('Pick list · ${widget.orderIds.length} order(s)'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: () => setState(() => list = _load()), icon: const Icon(Icons.refresh)),
      ]),
      body: SafeArea(
        child: FutureBuilder<dynamic>(
          future: list,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(errorText(snapshot.error!), textAlign: TextAlign.center),
                TextButton(onPressed: () => setState(() => list = _load()), child: const Text('Try again')),
              ])));
            }
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final items = ((snapshot.data as Map)['items'] as List).cast<Map>();
            final orders = ((snapshot.data as Map)['orders'] as List).cast<Map>();
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  Text('Collect these parts in bin order, then pack each order.', style: small),
                  const SizedBox(height: 8),
                  if (items.isEmpty) const EmptyState(message: 'Nothing left to pick on these orders.'),
                  for (final item in items)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: done.contains('${item['productId']}'),
                      onChanged: (v) => setState(() => v == true ? done.add('${item['productId']}') : done.remove('${item['productId']}')),
                      title: Text('${item['qty']} × ${item['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        '${item['sku']}',
                        (item['bins'] as List).isEmpty
                            ? 'No stock recorded'
                            : (item['bins'] as List).take(3).map((b) => '${b['location']} (${b['onHand']})').join(', '),
                        'Orders ${(item['orders'] as List).map((o) => '#${o['number']} × ${o['qty']}').join(', ')}',
                      ].join('\n')),
                      isThreeLine: true,
                    ),
                  const SectionTitle('Pack each order'),
                  for (final o in orders)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.inventory_2_outlined, color: Brand.forest),
                      title: Text('#${o['number']} · ${o['customer']}'),
                      subtitle: Text('${(o['lines'] as List).length} item line(s)'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openPickPack(context, '${o['id']}'),
                    ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}
