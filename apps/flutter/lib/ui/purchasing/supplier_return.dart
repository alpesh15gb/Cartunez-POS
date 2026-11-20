
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';
import 'common.dart';

// ---------------------------------------------------------------- returns to supplier

Future<void> supplierReturn(BuildContext context, Json supplier, {Json? bill}) async {
  final app = context.appRead;
  final returned = <String, int>{};
  if (bill != null) {
    for (final r in app.list('purchaseReturns').where((r) => r['billId'] == bill['id'])) {
      for (final l in r['lines'] as List) {
        returned.update('${l['productId']}', (n) => n + (l['quantity'] as int), ifAbsent: () => l['quantity'] as int);
      }
    }
  }
  final candidates = bill == null
      ? app.products.where((p) => p['type'] != 'service').map((p) => {'productId': p['id'], 'cost': p['cost'], 'max': null}).toList()
      : [
          for (final l in bill['lines'] as List)
            if ((l['quantity'] as int) - (returned['${l['productId']}'] ?? 0) > 0)
              {'productId': l['productId'], 'cost': l['cost'], 'binId': l['binId'], 'max': (l['quantity'] as int) - (returned['${l['productId']}'] ?? 0)},
        ];
  if (candidates.isEmpty) return app.toast('Everything on this bill has already been returned.');
  await showFormDialog<void>(
    context,
    title: 'Return to ${supplier['name']}',
    submit: 'Return and adjust balance',
    fields: [
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true,
          value: candidates.length == 1 ? candidates.single['productId'] : null,
          barcodeChoice: app.uniqueProductIdForCode,
          options: [
            for (final c in candidates)
              ('${c['productId']}', '${app.productName('${c['productId']}')}${c['max'] == null ? '' : ' · up to ${c['max']}'} · ${app.money(c['cost'])} each'),
          ]),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      FieldSpec('binId', 'Take from bin', kind: FieldKind.select, required: true,
          value: bill == null ? (app.sellableBins.firstOrNull?['id']) : ((bill['lines'] as List).firstOrNull?['binId']),
          barcodeChoice: app.binIdForCode,
          options: [for (final b in app.list('locations')) ('${b['id']}', app.binName(b))]),
      const FieldSpec('cost', 'Credit per unit (blank = bill cost)', kind: FieldKind.money),
      const FieldSpec('reason', 'Reason', required: true, help: 'For example: damaged, wrong part, excess.'),
    ],
    onSubmit: (v) async {
      final c = candidates.firstWhere((c) => c['productId'] == v['productId']);
      final q = int.tryParse('${v['quantity']}') ?? 0;
      if (q < 1) throw FormProblem('Enter the quantity.');
      if (c['max'] != null && q > (c['max'] as int)) throw FormProblem('Only ${c['max']} can be returned against this bill.');
      await app.mutate('/purchase-returns', {
        'supplierId': supplier['id'],
        if (bill != null) 'billId': bill['id'],
        'reason': v['reason'],
        'lines': [
          {'productId': v['productId'], 'quantity': q, 'binId': v['binId'], 'cost': '${v['cost'] ?? ''}'.isEmpty ? c['cost'] : amountMinor(v['cost'])},
        ],
      }, 'Returned. Stock and the supplier balance are updated.');
    },
  );
}
