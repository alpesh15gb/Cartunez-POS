// WS-E: supplier cost hikes found while receiving goods: old and new cost,
// what it does to the margin, and a quick "update selling price".
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'common.dart';

String marginText(Object? basis) => basis == null ? '—' : '${percentText((basis as num).toInt())}%';

/// "Cost up 17% (₹171.00 → ₹200.00) · margin 40% → 29.82%"
String costHikeText(AppState app, Map hike) =>
    'Cost up ${percentText(((hike['increase'] as num?) ?? 0).toInt())}% (${app.money(hike['oldCost'] as num?)} → ${app.money(hike['newCost'] as num?)})'
    ' · margin ${marginText(hike['oldMargin'])} → ${marginText(hike['newMargin'])}';

/// Asks for the new selling price (suggested: keeps the old margin) and saves it.
Future<bool> updateSellingPrice(BuildContext context, Map change) async {
  final app = context.appRead;
  final saved = await showFormDialog<bool>(
    context,
    title: 'Update selling price',
    submit: 'Save price',
    fields: [
      FieldSpec('price', 'New selling price for ${change['name']}', kind: FieldKind.money, required: true,
          value: plainAmount(((change['suggestedPrice'] ?? change['retailPrice'] ?? 0) as num).toInt()),
          help: 'Now ${app.money(change['retailPrice'] as num?)}. The suggestion keeps the old margin. The website price follows.'),
    ],
    onSubmit: (v) async {
      final price = amountMinor(v['price']);
      if (price < 1) throw FormProblem('Enter a selling price.');
      await app.mutate('/cost-changes/${change['costChangeId'] ?? change['id']}/apply', {'retailPrice': price}, 'Selling price updated.');
      return true;
    },
  );
  return saved == true;
}

class CostChangesScreen extends StatefulWidget {
  const CostChangesScreen({super.key});
  @override
  State<CostChangesScreen> createState() => _CostChangesScreenState();
}

class _CostChangesScreenState extends State<CostChangesScreen> {
  String status = 'open';
  late Future<dynamic> list = _load();

  Future<dynamic> _load() => context.appRead.api('/cost-changes?status=$status');
  void _reload() => setState(() => list = _load());

  Future<void> _threshold(int current) async {
    final app = context.appRead;
    await showFormDialog<void>(
      context,
      title: 'Cost alert',
      submit: 'Save',
      fields: [FieldSpec('percent', 'Flag a cost more than this % above the last purchase', kind: FieldKind.number, required: true, value: current ~/ 100)],
      onSubmit: (v) async {
        final n = int.tryParse('${v['percent']}');
        if (n == null || n < 0 || n > 100) throw FormProblem('Enter a percentage from 0 to 100.');
        await app.mutate('/purchasing/settings', {'costHikeThreshold': n * 100}, 'Cost alert saved.');
      },
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return FutureBuilder<dynamic>(
      future: list,
      builder: (context, snapshot) {
        final data = snapshot.data as Map?;
        final rows = (data?['changes'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final threshold = ((data?['threshold'] as num?) ?? 500).toInt();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            for (final (key, label) in const [('open', 'To review'), ('all', 'All')])
              ChoiceChip(label: Text(label), selected: status == key, onSelected: (_) {
                status = key;
                _reload();
              }),
            if (app.isManager)
              OutlinedButton.icon(onPressed: () => _threshold(threshold), icon: const Icon(Icons.tune), label: Text('Alert above ${percentText(threshold)}%')),
            IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
          ]),
          if (snapshot.hasError) Text(errorText(snapshot.error!), style: const TextStyle(color: Brand.danger)),
          if (!snapshot.hasData && !snapshot.hasError) const Center(child: CircularProgressIndicator()),
          if (snapshot.hasData)
            DataList(
              rows: rows,
              empty: 'No supplier cost rose more than ${percentText(threshold)}% above the last purchase.',
              actionWidth: 260,
              columns: [
                Col('Part', (c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${c['sku']} · ${c['sourceLabel']} · ${formatDate(c['createdAt'])}', style: Theme.of(context).textTheme.bodySmall),
                    ]), flex: 3),
                Col('Old cost', (c) => Text(app.money(c['oldCost'] as num?)), numeric: true),
                Col('New cost', (c) => Text(app.money(c['newCost'] as num?), style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w700)), numeric: true),
                Col('Rise', (c) => Text('+${percentText(((c['increase'] as num?) ?? 0).toInt())}%'), numeric: true),
                Col('Margin', (c) => Text('${marginText(c['oldMargin'])} → ${marginText(c['newMargin'])}'), flex: 2),
                Col('Price', (c) => Text(c['status'] == 'priceUpdated'
                    ? '${app.money(c['retailPrice'] as num?)} → ${app.money(c['newRetailPrice'] as num?)}'
                    : app.money(c['retailPrice'] as num?)), numeric: true),
              ],
              actions: (c) => [
                if (c['status'] == 'open' && app.isManager)
                  FilledButton.tonal(
                    onPressed: () async {
                      if (await updateSellingPrice(context, c)) _reload();
                    },
                    child: const Text('Update price'),
                  ),
                if (c['status'] == 'open')
                  TextButton(
                    onPressed: () async {
                      try {
                        await app.mutate('/cost-changes/${c['id']}/dismiss', {}, 'Kept the current price.');
                      } catch (e) {
                        app.toast(errorText(e));
                      }
                      _reload();
                    },
                    child: const Text('Keep price'),
                  ),
                if (c['status'] != 'open') StatusChip(switch (c['status']) {
                  'priceUpdated' => 'Price updated',
                  'cancelled' => 'Bill cancelled',
                  _ => 'Kept price',
                }),
              ],
            ),
        ]);
      },
    );
  }
}
