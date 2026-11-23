
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart' show isOnlineOnly;
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
  bool nonStock(Map row) => row['onlineOnly'] == true || isOnlineOnly(app.productById('${row['productId']}'));
  bool serialTracked(Map row) => !nonStock(row) && app.productById('${row['productId']}')?['serialTracked'] == true;
  final transactionId = uuid();
  final byProduct = <String, Json>{};
  if (bill != null) {
    for (final l in bill['lines'] as List) {
      final key = l['productId'] as String;
      final row = byProduct.putIfAbsent(key, () => {'productId': key, 'onlineOnly': l['onlineOnly'],
        'cost': l['cost'], 'binId': l['binId'], 'max': -(returned[key] ?? 0)});
      row['max'] = (row['max'] as int) + (l['quantity'] as int);
    }
  }
  final candidates = bill == null
      ? app.stockParts.map((p) => <String, dynamic>{'productId': p['id'], 'cost': p['cost'], 'max': null}).toList()
      : byProduct.values.where((row) => (row['max'] as int) > 0).toList();
  if (candidates.isEmpty) return app.toast(bill == null ? 'For website-only items, open the original supplier bill to record a return.' : 'Everything on this bill has already been returned.');
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
      if (candidates.any((c) => !nonStock(c))) FieldSpec('binId', 'Take from bin', kind: FieldKind.select, required: candidates.every((c) => !nonStock(c)),
          value: bill == null ? (app.sellableBins.firstOrNull?['id']) : ((bill['lines'] as List).firstOrNull?['binId']),
          barcodeChoice: app.binIdForCode,
          options: [for (final b in app.list('locations')) ('${b['id']}', app.binName(b))]),
      if (candidates.any(serialTracked))
        const FieldSpec('serials', 'Serial numbers', help: 'For tracked items, enter one serial per unit, separated by commas.'),
      const FieldSpec('cost', 'Credit per unit (blank = bill cost)', kind: FieldKind.money),
      const FieldSpec('reason', 'Reason', required: true, help: 'For example: damaged, wrong part, excess.'),
    ],
    onSubmit: (v) async {
      final c = candidates.firstWhere((c) => c['productId'] == v['productId']);
      if (!nonStock(c) && (v['binId'] ?? '') == '') throw FormProblem('Choose the bin where the item is held.');
      final q = int.tryParse('${v['quantity']}') ?? 0;
      if (q < 1) throw FormProblem('Enter the quantity.');
      if (c['max'] != null && q > (c['max'] as int)) throw FormProblem('Only ${c['max']} can be returned against this bill.');
      final serials = splitList(v['serials']);
      if (serialTracked(c) && (serials.length != q || serials.toSet().length != q)) {
        throw FormProblem('Enter one unique serial number per returned unit.');
      }
      await app.mutate('/purchase-returns', {
        'transactionId': transactionId,
        'supplierId': supplier['id'],
        if (bill != null) 'billId': bill['id'],
        'reason': v['reason'],
        'lines': [
          {'productId': v['productId'], 'quantity': q, 'binId': nonStock(c) ? null : v['binId'], if (serialTracked(c)) 'serials': serials, if ('${v['cost'] ?? ''}'.isNotEmpty) 'cost': amountMinor(v['cost'])},
        ],
      }, 'Supplier return recorded.');
    },
  );
}
