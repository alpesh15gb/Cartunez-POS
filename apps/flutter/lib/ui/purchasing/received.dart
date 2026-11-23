// WS-E: after goods are received (supplier bill or purchase-order receipt):
// cost-hike warnings per line, 1-click labels for exactly the received
// quantities, and 1-click website update with the sync state of each part.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/labels.dart';
import '../theme.dart';
import '../widgets.dart';
import 'cost_changes.dart';

/// Shows what was received. [lines]: productId, quantity, binId and the server's costHike (if any).
Future<void> showReceivedGoods(BuildContext context, List<Json> lines, {String title = 'Goods received'}) =>
    showDialog<void>(context: context, builder: (_) => ReceivedGoodsDialog(lines: lines, title: title));

const _syncLabels = {
  'synced': 'On the website',
  'queued': 'Waiting to send',
  'pending': 'Waiting to send',
  'error': 'Website update failed',
  'not-online': 'Not sold online',
  'not-connected': 'Website not connected',
  'unpublished': 'Hidden online',
};

class ReceivedGoodsDialog extends StatefulWidget {
  const ReceivedGoodsDialog({super.key, required this.lines, required this.title});
  final List<Json> lines;
  final String title;
  @override
  State<ReceivedGoodsDialog> createState() => _ReceivedGoodsDialogState();
}

class _ReceivedGoodsDialogState extends State<ReceivedGoodsDialog> {
  Map<String, Json> sync = {};
  final repriced = <String>{};
  bool busy = false;
  String? error;

  List<String> get ids => {for (final l in widget.lines) '${l['productId']}'}.toList();

  @override
  void initState() {
    super.initState();
    _status();
  }

  void _take(dynamic result) {
    final parts = ((result as Map?)?['parts'] as List? ?? []).map((p) => Map<String, dynamic>.from(p as Map));
    if (mounted) setState(() => sync = {for (final p in parts) '${p['productId']}': p});
  }

  Future<void> _status() async {
    try {
      _take(await context.appRead.api('/purchasing/sync-status?productIds=${Uri.encodeQueryComponent(ids.join(','))}'));
    } catch (e) {
      if (mounted) setState(() => error = 'Website status unavailable: ${errorText(e)}');
    }
  }

  Future<void> _syncNow() async {
    final app = context.appRead;
    setState(() => busy = true);
    try {
      _take(await app.mutate('/purchasing/sync-online', {'productIds': ids}, 'Received parts queued for the website.'));
    } catch (e) {
      setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _labels() async {
    final app = context.appRead;
    final labels = <({LabelItem item, int quantity})>[];
    for (final l in widget.lines) {
      final part = app.productById('${l['productId']}');
      if (part == null || l['onlineOnly'] == true || isOnlineOnly(part)) continue;
      labels.add((item: productLabel(app, part, binId: l['binId'] as String?), quantity: (l['quantity'] as num).toInt()));
    }
    try {
      await printReceiptLineLabels(context, labels);
    } catch (e) {
      app.toast('Labels could not be printed. ${errorText(e)}');
    }
  }

  Widget _syncChip(String? state) {
    final label = _syncLabels[state] ?? (state ?? 'Checking…');
    final (bg, fg) = switch (state) {
      'synced' => (Brand.mint, Brand.forest),
      'error' => (const Color(0xFFFBEBE7), Brand.danger),
      'queued' || 'pending' => (const Color(0xFFFDF3DF), Brand.warning),
      _ => (const Color(0xFFEEF1EF), Brand.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final hikes = widget.lines.where((l) => l['costHike'] != null).length;
    final units = widget.lines.where((l) => l['onlineOnly'] != true && !isOnlineOnly(app.productById(l['productId']))).fold<int>(0, (n, l) => n + (l['quantity'] as num).toInt());
    final online = sync.values.any((p) => !{'not-online', 'not-connected'}.contains(p['state']));
    return AlertDialog(
      insetPadding: MediaQuery.sizeOf(context).width < 600 ? const EdgeInsets.all(12) : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 640,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hikes > 0)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: const Color(0xFFFBEBE7), borderRadius: BorderRadius.circular(10)),
              child: Text('$hikes part(s) cost more than last time. Check the selling price.',
                  style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w700)),
            ),
          for (final l in widget.lines)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${l['quantity']} × ${app.productName('${l['productId']}')}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  _syncChip(sync['${l['productId']}']?['state'] as String?),
                ]),
                Text(l['binId'] == null && isOnlineOnly(app.productById('${l['productId']}'))
                    ? 'Online only · straight to the customer' : app.locationName(l['binId'] as String?), style: Theme.of(context).textTheme.bodySmall),
                if ('${sync['${l['productId']}']?['error'] ?? ''}'.isNotEmpty)
                  Text('${sync['${l['productId']}']!['error']}', style: const TextStyle(color: Brand.danger, fontSize: 12)),
                if (l['costHike'] != null) ...[
                  Row(children: [
                    const Icon(Icons.trending_up, size: 18, color: Brand.danger),
                    const SizedBox(width: 6),
                    Expanded(child: Text(costHikeText(app, l['costHike'] as Map), style: const TextStyle(color: Brand.danger, fontSize: 12.5))),
                  ]),
                  if (app.isManager && !repriced.contains('${l['productId']}'))
                    TextButton.icon(
                      onPressed: () async {
                        final hike = Map<String, dynamic>.from(l['costHike'] as Map);
                        final part = app.productById('${l['productId']}');
                        if (await updateSellingPrice(context, {...hike, 'name': part?['name'] ?? '', 'retailPrice': part?['retailPrice']})) {
                          setState(() => repriced.add('${l['productId']}'));
                          _status();
                        }
                      },
                      icon: const Icon(Icons.sell_outlined, size: 18),
                      label: const Text('Update selling price'),
                    ),
                ],
              ]),
            ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Brand.danger))),
        ]),
      ),
      actions: [
        if (units > 0) OutlinedButton.icon(onPressed: _labels, icon: const Icon(Icons.print_outlined), label: Text('Print $units label(s)')),
        if (online)
          OutlinedButton.icon(onPressed: busy ? null : _syncNow, icon: const Icon(Icons.cloud_upload_outlined), label: const Text('Update website now')),
        if (online) IconButton(tooltip: 'Refresh website status', onPressed: _status, icon: const Icon(Icons.refresh)),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

/// Lines of a saved bill or receipt, in the shape [showReceivedGoods] takes.
List<Json> receivedLines(Object? saved) => [
      for (final l in ((saved as Map?)?['lines'] as List? ?? []))
        {'productId': l['productId'], 'quantity': l['quantity'], 'binId': l['binId'], if (l['costHike'] != null) 'costHike': l['costHike']},
    ];

/// The cost-hike warning shown while entering a line, before it is saved.
String? costWarning(AppState app, String productId, int unitCost) {
  final part = app.productById(productId);
  if (part == null) return null;
  final previous = ((part['lastPurchaseCost'] ?? part['cost'] ?? 0) as num).toInt();
  final threshold = (((app.settings['purchasing'] as Map?)?['costHikeThreshold'] ?? 500) as num).toInt();
  if (previous <= 0 || unitCost <= previous) return null;
  final rise = ((unitCost - previous) * 10000 / previous).round();
  if (rise <= threshold) return null;
  return 'Cost up ${(rise / 100).toStringAsFixed(1)}% on last purchase (${app.money(previous)})';
}
