// WS-E: reorder alerts (parts at or below their reorder level) and one-click
// draft purchase orders, one per usual supplier.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';

/// Parts that need ordering and are not already covered by an order.
List<Json> reorderAlerts(AppState app) =>
    app.list('reorderSuggestions').where((s) => ((s['suggestedQuantity'] as num?) ?? 0) > 0).toList();

/// A "Reorder alerts" button with a count badge, for purchasing screens.
class ReorderAlertsButton extends StatelessWidget {
  const ReorderAlertsButton({super.key});
  @override
  Widget build(BuildContext context) {
    final count = reorderAlerts(context.app).length;
    return OutlinedButton.icon(
      onPressed: () => ShellScope.of(context).open('reorder'),
      icon: Badge(isLabelVisible: count > 0, label: Text('$count'), child: const Icon(Icons.notifications_active_outlined)),
      label: Text(count == 0 ? 'Reorder alerts' : 'Reorder alerts · $count'),
    );
  }
}

class ReorderScreen extends StatefulWidget {
  const ReorderScreen({super.key});
  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  final skipped = <String>{};
  final quantities = <String, TextEditingController>{};
  bool busy = false;

  @override
  void dispose() {
    for (final c in quantities.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _qty(Json row) =>
      quantities.putIfAbsent('${row['productId']}', () => TextEditingController(text: '${row['suggestedQuantity']}'));

  Future<void> _create(List<Json> rows) async {
    final app = context.appRead;
    final chosen = rows.where((r) => !skipped.contains(r['productId']) && r['supplierId'] != null && '${r['supplierId']}'.isNotEmpty).toList();
    if (chosen.isEmpty) return app.toast('Choose at least one part that has a supplier.');
    final lines = <Json>[];
    for (final r in chosen) {
      final n = int.tryParse(_qty(r).text.trim());
      if (n == null || n < 1) return app.toast('Enter a quantity of at least 1 for ${r['name']}.');
      lines.add({'productId': r['productId'], 'quantity': n});
    }
    setState(() => busy = true);
    try {
      final result = await app.mutate('/purchase-orders/from-suggestions', {'lines': lines});
      final made = ((result as Map?)?['purchaseOrders'] as List? ?? []).length;
      app.toast('$made draft purchase order(s) created. Review and place them in Purchase orders.');
      if (mounted) ShellScope.of(context).open('orders');
    } catch (e) {
      app.toast(errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final rows = reorderAlerts(app);
    final bySupplier = <String, List<Json>>{};
    for (final r in rows) {
      bySupplier.putIfAbsent('${r['supplierId'] ?? ''}', () => []).add(r);
    }
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(
          onPressed: busy || rows.isEmpty ? null : () => _create(rows),
          icon: const Icon(Icons.playlist_add),
          label: const Text('Create draft purchase orders'),
        ),
        TextButton(onPressed: () => ShellScope.of(context).open('orders'), child: const Text('Go to purchase orders')),
      ]),
      if (rows.isEmpty)
        const EmptyState(message: 'No part is at or below its reorder level. Set a reorder level on a part to get alerts.', icon: Icons.check_circle_outline),
      for (final entry in bySupplier.entries) ...[
        SectionTitle(entry.key.isEmpty ? 'No usual supplier' : (app.supplierById(entry.key)?['name'] as String? ?? 'Supplier')),
        if (entry.key.isEmpty)
          Text('Set a supplier on these parts to order them here.', style: small?.copyWith(color: Brand.danger)),
        for (final r in entry.value)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                Checkbox(
                  value: entry.key.isNotEmpty && !skipped.contains(r['productId']),
                  onChanged: entry.key.isEmpty ? null : (v) => setState(() => v == true ? skipped.remove(r['productId']) : skipped.add('${r['productId']}')),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${r['sku']} · ${r['available']} on the shelf · reorder at ${r['reorderLevel']}'
                        '${((r['onOrder'] as num?) ?? 0) > 0 ? ' · ${r['onOrder']} on order' : ''}', style: small),
                  ]),
                ),
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: _qty(r),
                    enabled: entry.key.isNotEmpty,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(labelText: 'Order'),
                  ),
                ),
              ]),
            ),
          ),
      ],
    ]);
  }
}
