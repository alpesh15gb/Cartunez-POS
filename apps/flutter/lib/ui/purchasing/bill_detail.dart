
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../screens/labels.dart';
import 'common.dart';
import 'file_thumbs.dart';
import 'supplier_return.dart';

// ---------------------------------------------------------------- one bill

Future<void> showBill(BuildContext context, Json bill) async {
  final app = context.appRead;
  final photos = (bill['photos'] as List? ?? [for (final id in bill['photoIds'] as List? ?? []) {'id': id, 'contentType': 'image/jpeg'}])
      .map((e) => Map<String, dynamic>.from(e as Map)).toList();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Bill ${(bill['billNumber'] ?? '').toString().isEmpty ? '' : '${bill['billNumber']} '}· ${bill['supplierName'] ?? ''}'),
      scrollable: true,
      content: SizedBox(
        width: 720,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, children: [
            Text('Date ${formatDate(bill['billDate'])}'),
            if (bill['gst'] == true) StatusChip(bill['interState'] == true ? 'GST · IGST' : 'GST'),
            if (bill['voided'] == true) const StatusChip('Cancelled'),
          ]),
          if (bill['voided'] == true) Text('Cancelled: ${bill['voidReason'] ?? ''}', style: const TextStyle(color: Brand.danger)),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final p in photos) FileThumb(file: p, size: 110),
            ]),
          ],
          const SizedBox(height: 12),
          for (final l in bill['lines'] as List)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${l['name']}'),
              subtitle: Text('${l['sku']} · ${l['quantity']} × ${app.money(l['cost'])}${bill['gst'] == true ? ' · GST ${percentText((l['taxRate'] ?? 0) as int)}%' : ''} · ${app.locationName(l['binId'])}'),
              trailing: Text(app.money((l['amount'] ?? (l['quantity'] as int) * (l['cost'] as int)) as int)),
            ),
          const Divider(),
          sumRow('Items', app.money(bill['subtotal'])),
          if (bill['gst'] == true) sumRow('GST', app.money(bill['tax'])),
          if (((bill['otherCharges'] ?? 0) as int) > 0) sumRow('Freight / other', app.money(bill['otherCharges'])),
          if (((bill['discount'] ?? 0) as int) > 0) sumRow('Discount', '− ${app.money(bill['discount'])}'),
          sumRow('Bill total', app.money(bill['total']), bold: true),
          if ('${bill['notes'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Notes: ${bill['notes']}')),
        ]),
      ),
      actions: [
        if (bill['voided'] != true)
          TextButton.icon(
            icon: const Icon(Icons.print_outlined),
            label: const Text('Print labels'),
            onPressed: () async {
              final labels = <({LabelItem item, int quantity})>[];
              for (final l in bill['lines'] as List) {
                final part = app.productById('${l['productId']}');
                if (part == null || isOnlineOnly(part)) continue;
                labels.add((item: productLabel(app, part, binId: '${l['binId']}'), quantity: l['quantity'] as int));
              }
              try {
                await printReceiptLineLabels(context, labels);
              } catch (e) {
                app.toast('Labels could not be printed. ${errorText(e)}');
              }
            },
          ),
        if (bill['voided'] != true && app.canStock)
          TextButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Return items to supplier'),
            onPressed: () {
              Navigator.pop(dialogContext);
              supplierReturn(context, app.supplierById('${bill['supplierId']}') ?? {'id': bill['supplierId'], 'name': bill['supplierName']}, bill: bill);
            },
          ),
        if (bill['voided'] != true && app.isManager)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Brand.danger),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await showFormDialog<void>(
                context,
                title: 'Cancel this bill?',
                submit: 'Cancel bill',
                fields: const [FieldSpec('reason', 'Reason', required: true, help: 'Its stock is taken back out. Payments stay; cancel them separately if needed.')],
                onSubmit: (v) async => app.mutate('/purchase-bills/${bill['id']}/void', {'reason': v['reason']}, 'Bill cancelled.'),
              );
            },
            child: const Text('Cancel bill'),
          ),
        FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
      ],
    ),
  );
}
