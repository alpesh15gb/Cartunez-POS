
import 'dart:math' show min;

import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart' show isOnlineOnly;
import '../widgets.dart';
import 'common.dart';

// ---------------------------------------------------------------- returns to supplier

Future<void> supplierReturn(BuildContext context, Json supplier, {Json? bill}) async {
  final app = context.appRead;
  bool nonStock(Map row) => row['onlineOnly'] == true || isOnlineOnly(app.productById('${row['productId']}'));
  bool serialTracked(Map row) => !nonStock(row) && app.productById('${row['productId']}')?['serialTracked'] == true;
  final transactionId = uuid();
  final rows = <String, Json>{};
  if (bill != null) {
    final lines = (bill['lines'] as List).cast<Map>();
    final remaining = [for (final line in lines) line['quantity'] as int];
    final returns = app.list('purchaseReturns').where((r) => r['billId'] == bill['id']).toList()
      ..sort((a, b) => '${a['createdAt'] ?? ''}'.compareTo('${b['createdAt'] ?? ''}'));
    for (final returned in returns.expand((r) => (r['lines'] as List).cast<Map>())) {
      var quantity = returned['quantity'] as int;
      final serials = (returned['serials'] as List? ?? const []).toSet();
      for (final (index, line) in lines.indexed) {
        if (quantity == 0) break;
        if (line['productId'] != returned['productId']) continue;
        final returnedLineId = returned['billLineId'];
        if (returnedLineId != null && line['id'] != returnedLineId) continue;
        final eligible = returnedLineId == null && serials.isNotEmpty
            ? (line['serials'] as List? ?? const []).where(serials.contains).length
            : quantity;
        final consumed = min(min(remaining[index], quantity), eligible);
        remaining[index] -= consumed;
        quantity -= consumed;
      }
    }
    for (final (index, line) in lines.indexed) {
      final productId = '${line['productId']}';
      final sameProduct = lines.where((l) => l['productId'] == productId);
      final lineId = sameProduct.every((l) => '${l['id'] ?? ''}'.isNotEmpty) ? line['id'] as String : null;
      final key = lineId ?? productId;
      final row = rows.putIfAbsent(key, () => {
        ...line, 'billLineId': lineId,
        if (lineId != null && sameProduct.length > 1) 'lineNumber': index + 1,
        'max': 0,
      });
      row['max'] = (row['max'] as int) + remaining[index];
    }
  } else {
    for (final part in app.stockParts) {
      rows['${part['id']}'] = {'productId': part['id'], 'cost': part['cost']};
    }
  }
  final candidates = rows.entries.where((entry) => (entry.value['max'] as int? ?? 1) > 0).toList();
  if (candidates.isEmpty) return app.toast(bill == null ? 'For website-only items, open the original supplier bill to record a return.' : 'Everything on this bill has already been returned.');
  final stockRows = candidates.map((entry) => entry.value).where((row) => !nonStock(row)).toList();
  final sourceBins = stockRows.map((row) => row['binId']).toSet();
  final bins = app.list('locations');
  final defaultBin = bill == null ? (app.sellableBins.firstOrNull?['id']) : sourceBins.singleOrNull;
  String optionLabel(Json row) => [
    app.productName('${row['productId']}'),
    if (row['lineNumber'] != null) 'Line ${row['lineNumber']}',
    if (row['max'] != null) 'up to ${row['max']}',
    '${app.money(row['cost'])} purchase cost / unit',
  ].join(' · ');
  await showFormDialog<void>(
    context,
    title: 'Return to ${supplier['name']}',
    submit: 'Return and adjust balance',
    fields: [
      FieldSpec('item', bill == null ? 'Part' : 'Bill item', kind: FieldKind.select, required: true,
          value: candidates.singleOrNull?.key,
          barcodeChoice: (code) {
            final productId = app.uniqueProductIdForCode(code);
            return candidates.where((c) => c.value['productId'] == productId).singleOrNull?.key;
          },
          options: [for (final c in candidates) (c.key, optionLabel(c.value))]),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      if (stockRows.isNotEmpty) FieldSpec('binId', 'Take from bin', kind: FieldKind.select, required: stockRows.length == candidates.length,
          value: bins.any((bin) => bin['id'] == defaultBin) ? defaultBin : null,
          barcodeChoice: app.binIdForCode,
          options: [for (final b in bins) ('${b['id']}', app.binName(b))]),
      if (stockRows.any(serialTracked))
        const FieldSpec('serials', 'Serial numbers', help: 'For tracked items, enter one serial per unit, separated by commas.'),
      const FieldSpec('cost', 'Credit per unit (blank = bill cost)', kind: FieldKind.money),
      const FieldSpec('reason', 'Reason', required: true, help: 'For example: damaged, wrong part, excess.'),
    ],
    onSubmit: (v) async {
      final c = rows[v['item']]!;
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
          {
            'productId': c['productId'],
            if (c['billLineId'] != null) 'billLineId': c['billLineId'],
            'quantity': q,
            'binId': nonStock(c) ? null : v['binId'],
            if (serialTracked(c)) 'serials': serials,
            if ('${v['cost'] ?? ''}'.isNotEmpty) 'cost': amountMinor(v['cost']),
          },
        ],
      }, 'Supplier return recorded.');
    },
  );
}
