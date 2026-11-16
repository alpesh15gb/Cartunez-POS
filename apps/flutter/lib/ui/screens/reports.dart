import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';
import 'receipt.dart';

const _reports = [
  'sales', 'returns', 'discounts', 'margin', 'shifts', 'tenders', 'valuation', 'stock-by-bin', 'stock-movement',
  'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'tax', 'warranty', 'cores', 'fitment',
];
const _stockReports = [
  'valuation', 'stock-by-bin', 'stock-movement', 'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'warranty',
];
const _moneyKeys = {
  'gross', 'returns', 'coreReturns', 'net', 'discount', 'tax', 'cost', 'margin', 'value', 'landedCost', 'total', 'openingCash',
  'expectedCash', 'countedCash', 'variance', 'collected', 'refunded', 'charged', 'outstanding', 'revenue', 'amount', 'taxable',
  'unitPrice', 'subtotal', 'coreCharge', 'rounding', 'price', 'retailPrice', 'wholesalePrice',
};
const _hidden = {'id', 'invoiceId', 'productId', 'returnId', 'purchaseOrderId', 'supplierId', 'lineId', 'binId'};

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String name = 'sales';
  DateTimeRange? range;
  Json? report;
  bool busy = false;

  Future<void> run() async {
    final app = context.appRead;
    setState(() => busy = true);
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    try {
      final query = {
        if (range != null) 'dateFrom': day(range!.start),
        if (range != null) 'dateTo': day(range!.end),
      };
      final result = await app.api('/reports/$name${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}');
      setState(() => report = Map<String, dynamic>.from(result as Map));
    } catch (error) {
      app.toast(errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String cell(String key, Object? value) {
    final app = context.appRead;
    if (value == null || '$value'.isEmpty) return '—';
    if (value is num) {
      if (_moneyKeys.contains(key)) return app.money(value);
      if (key == 'taxRate') return '${value / 100}%';
      return '$value';
    }
    if (value is bool) return value ? 'Yes' : 'No';
    if (key == 'cashierId' || key == 'userId') return app.userName('$value');
    if (RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch('$value')) return formatDate(value);
    return '$value';
  }

  Future<void> export() async {
    final rows = (report!['rows'] as List).cast<Map>();
    final keys = {for (final r in rows) ...r.keys.map((k) => '$k')}.toList();
    String esc(Object? v) {
      final raw = v is Map || v is List ? jsonEncode(v) : '${v ?? ''}';
      final safe = RegExp(r'^[=+@-]').hasMatch(raw) ? "'$raw" : raw;
      return '"${safe.replaceAll('"', '""')}"';
    }

    final csv = [keys.map(esc).join(','), for (final r in rows) keys.map((k) => esc(r[k])).join(',')].join('\r\n');
    final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${report!['name']}-${DateTime.now().millisecondsSinceEpoch}.csv');
    await file.writeAsString('﻿$csv');
    if (Platform.isAndroid) {
      await Printing.sharePdf(bytes: await file.readAsBytes(), filename: file.uri.pathSegments.last);
    }
    if (mounted) context.appRead.toast('Saved ${file.path}');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final names = _reports.where((r) => app.isManager || _stockReports.contains(r)).toList();
    if (!names.contains(name)) name = names.first;
    final rows = ((report?['rows'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final keys = <String>{
      for (final r in rows.take(50))
        for (final e in r.entries)
          if (!_hidden.contains(e.key) && e.value is! Map && e.value is! List) e.key,
    }.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 240,
          child: DropdownButtonFormField<String>(
            initialValue: name,
            decoration: const InputDecoration(labelText: 'Report'),
            items: [for (final n in names) DropdownMenuItem(value: n, child: Text(humanize(n)))],
            onChanged: (v) => setState(() => name = v ?? name),
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(range == null ? 'All dates' : '${range!.start.day}/${range!.start.month} – ${range!.end.day}/${range!.end.month}/${range!.end.year}'),
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 5), lastDate: now, initialDateRange: range);
            setState(() => range = picked);
          },
        ),
        if (range != null) IconButton(tooltip: 'All dates', onPressed: () => setState(() => range = null), icon: const Icon(Icons.close)),
        FilledButton.icon(
          onPressed: busy ? null : run,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
          label: const Text('Run report'),
        ),
        if (rows.isNotEmpty) OutlinedButton.icon(onPressed: export, icon: const Icon(Icons.download), label: const Text('Export CSV')),
      ]),
      if (report != null) ...[
        SectionTitle('${humanize('${report!['name']}')} report'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final e in (report!['totals'] as Map? ?? {}).entries) Metric(humanize('${e.key}'), cell('${e.key}', e.value)),
        ]),
        if ((report!['pendingConflicts'] ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${report!['pendingConflicts']} offline sale conflict(s) await review and are excluded.'),
          ),
        const SizedBox(height: 16),
        DataList(
          rows: rows,
          empty: 'No rows for this period.',
          onTap: (r) {
            final invoice = app.list('invoices').where((i) => i['id'] == r['invoiceId']).firstOrNull;
            if (invoice != null) showReceipt(context, invoice);
          },
          columns: [
            for (final k in keys.take(8))
              Col(humanize(k.replaceAll(RegExp(r'^(cashier|user)Id$'), k.startsWith('cashier') ? 'cashier' : 'user')),
                  (r) => Text(cell(k, r[k])), numeric: r0Numeric(rows, k)),
          ],
        ),
      ],
    ]);
  }

  bool r0Numeric(List<Json> rows, String key) => rows.any((r) => r[key] is num);
}
