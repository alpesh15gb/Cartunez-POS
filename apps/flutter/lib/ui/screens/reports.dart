import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/files.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';
import 'receipt.dart';

const _reports = [
  'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'shifts', 'tenders', 'valuation', 'stock-by-bin', 'stock-movement',
  'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'tax', 'warranty', 'cores', 'fitment',
];
const _stockReports = [
  'valuation', 'stock-by-bin', 'stock-movement', 'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'warranty',
];
const _moneyKeys = {
  'gross', 'returns', 'coreReturns', 'net', 'discount', 'tax', 'cost', 'margin', 'value', 'landedCost', 'total', 'openingCash',
  'expectedCash', 'countedCash', 'variance', 'collected', 'refunded', 'charged', 'outstanding', 'revenue', 'amount', 'taxable',
  'unitPrice', 'subtotal', 'coreCharge', 'coreDeposits', 'rounding', 'price', 'retailPrice', 'wholesalePrice', 'cgst', 'sgst', 'igst', 'utgst',
};
const _hidden = {'id', 'invoiceId', 'productId', 'returnId', 'purchaseOrderId', 'supplierId', 'lineId', 'binId'};
const _snapshotReports = {'valuation', 'stock-by-bin', 'low-stock', 'aging'};
const _cashierReports = {'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'shifts', 'tenders', 'tax', 'cores', 'fitment'};
const _tenderFilters = {'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'tenders', 'tax', 'cores', 'fitment'};
const _reportColumns = {
  'sales': ['number', 'date', 'cashierId', 'total', 'discount', 'tax', 'cost'],
  'discounts': ['number', 'date', 'cashierId', 'discount', 'total'],
  'margin': ['number', 'date', 'total', 'tax', 'cost', 'margin'],
  'returns': ['number', 'invoiceNumber', 'createdAt', 'reason', 'refundType', 'total', 'tax'],
  'tax': ['document', 'date', 'sku', 'hsnSac', 'taxRate', 'taxable', 'tax', 'cgst', 'sgst', 'igst', 'utgst'],
  'shifts': ['userId', 'openedAt', 'closedAt', 'openingCash', 'expectedCash', 'countedCash', 'variance'],
  'tenders': ['type', 'collected', 'refunded', 'net'],
};
const _reportLabels = {
  'gross': 'Gross billed', 'net': 'Net after refunds', 'returns': 'Refunds',
  'cashierId': 'Cashier', 'userId': 'Staff member', 'hsnSac': 'HSN / SAC',
  'cgst': 'CGST', 'sgst': 'SGST', 'igst': 'IGST', 'utgst': 'UTGST',
};

String reportLabel(String key) => _reportLabels[key] ?? humanize(key);

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String name = 'daily-sales';
  DateTimeRange? range;
  String category = '';
  String supplier = '';
  String cashier = '';
  String payment = '';
  Json? report;
  bool busy = false;
  String? errorMessage;
  int page = 0;
  static const pageSize = 25;

  @override
  void initState() {
    super.initState();
    final now = context.appRead.businessTime(DateTime.now());
    final end = DateTime(now.year, now.month, now.day);
    range = DateTimeRange(start: DateTime(now.year, now.month, now.day - 29), end: end);
  }

  bool get hasPartFilters => !const {'tenders', 'shifts', 'warranty'}.contains(name);

  void changeFilter(VoidCallback change) => setState(() {
    change();
    report = null;
    errorMessage = null;
    page = 0;
  });

  Future<void> run() async {
    final app = context.appRead;
    setState(() {
      busy = true;
      errorMessage = null;
    });
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    try {
      final query = {
        if (range != null && !_snapshotReports.contains(name)) ...{
          'dateFrom': day(range!.start), 'dateTo': day(range!.end),
        },
        if (hasPartFilters && category.isNotEmpty) 'category': category,
        if (hasPartFilters && supplier.isNotEmpty) 'supplierId': supplier,
        if (_cashierReports.contains(name) && cashier.isNotEmpty) 'cashier': cashier,
        if (_tenderFilters.contains(name) && payment.isNotEmpty) 'paymentType': payment,
      };
      final result = await app.api('/reports/$name${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}');
      if (mounted) {
        setState(() {
          report = Map<String, dynamic>.from(result as Map);
          page = 0;
        });
      }
    } catch (error) {
      if (mounted) setState(() => errorMessage = errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String cell(String key, Object? value) {
    final app = context.appRead;
    if (value == null || '$value'.isEmpty) {
      return '—';
    }
    if (value is num) {
      if (_moneyKeys.contains(key)) return app.money(value);
      if (key == 'taxRate') return '${value / 100}%';
      return '$value';
    }
    if (value is bool) return value ? 'Yes' : 'No';
    if (key == 'cashierId' || key == 'userId') return app.userName('$value');
    final timestamp = DateTime.tryParse('$value');
    if ('$value'.contains('T') && timestamp != null) {
      final time = timestamp.toUtc().add(report?['timeZone'] == 'Asia/Kolkata' ? const Duration(hours: 5, minutes: 30) : Duration.zero);
      return DateFormat('dd MMM yyyy, HH:mm').format(time);
    }
    return '$value';
  }

  Future<void> export() async {
    final rows = (report!['rows'] as List).cast<Map>();
    final keys = {for (final r in rows) ...r.keys.map((k) => '$k')}.toList();
    String esc(Object? v) {
      final raw = v is Map || v is List ? jsonEncode(v) : '${v ?? ''}';
      final safe = v is String && RegExp(r'^(?:\s*[=+@-]|[\t\r\n])').hasMatch(raw) ? "'$raw" : raw;
      return '"${safe.replaceAll('"', '""')}"';
    }

    final csv = [keys.map(esc).join(','), for (final r in rows) keys.map((k) => esc(r[k])).join(',')].join('\r\n');
    try {
      final message = await saveTextFile('${report!['name']}-${DateTime.now().millisecondsSinceEpoch}.csv', '﻿$csv');
      if (mounted) context.appRead.toast(message);
    } catch (error) {
      if (mounted) context.appRead.toast(errorText(error));
    }
  }

  Widget filter(String title, String value, List<(String, String)> choices, ValueChanged<String> setValue) => SizedBox(
    width: 200,
    child: DropdownButtonFormField<String>(
      key: ValueKey((title, value)),
      initialValue: choices.any((choice) => choice.$1 == value) ? value : '',
      isExpanded: true,
      decoration: InputDecoration(labelText: title),
      items: [const DropdownMenuItem(value: '', child: Text('All')), for (final choice in choices) DropdownMenuItem(value: choice.$1, child: Text(choice.$2, overflow: TextOverflow.ellipsis))],
      onChanged: busy ? null : (value) => changeFilter(() => setValue(value ?? '')),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final names = _reports.where((r) => app.isManager || _stockReports.contains(r)).toList();
    if (!names.contains(name)) name = names.first;
    final categories = app.products.map((p) => '${p['category']}').where((value) => value.isNotEmpty).toSet().toList()..sort();
    final users = <String>{
      for (final user in app.list('users')) '${user['id']}',
      for (final shift in app.list('shifts')) '${shift['userId']}',
      for (final invoice in app.list('invoices')) '${invoice['cashierId']}',
    }..remove('null');
    final rows = ((report?['rows'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final keys = <String>{
      for (final r in rows)
        for (final e in r.entries)
          if (!_hidden.contains(e.key) && e.value is! Map && e.value is! List) e.key,
    }.toList();
    final visibleKeys = _reportColumns[name]?.where(keys.contains).toList() ?? keys.take(8).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 240,
          child: DropdownButtonFormField<String>(
            initialValue: name,
            decoration: const InputDecoration(labelText: 'Report'),
            items: [for (final n in names) DropdownMenuItem(value: n, child: Text(humanize(n)))],
            onChanged: busy ? null : (v) => changeFilter(() => name = v ?? name),
          ),
        ),
        if (!_snapshotReports.contains(name)) OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(range == null ? 'All dates' : '${range!.start.day}/${range!.start.month} – ${range!.end.day}/${range!.end.month}/${range!.end.year}'),
          onPressed: busy ? null : () async {
            final now = app.businessTime(DateTime.now());
            final picked = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 5), lastDate: now, initialDateRange: range);
            if (mounted && picked != null) changeFilter(() => range = picked);
          },
        ),
        if (range != null && !_snapshotReports.contains(name)) IconButton(tooltip: 'All dates', onPressed: busy ? null : () => changeFilter(() => range = null), icon: const Icon(Icons.close)),
        if (hasPartFilters && categories.isNotEmpty) filter('Category', category, [for (final value in categories) (value, value)], (value) => category = value),
        if (hasPartFilters && app.list('suppliers').isNotEmpty) filter('Supplier', supplier, optionsOf(app.list('suppliers')), (value) => supplier = value),
        if (_cashierReports.contains(name) && users.isNotEmpty) filter('Cashier', cashier, [for (final user in users) (user, app.userName(user))], (value) => cashier = value),
        if (_tenderFilters.contains(name)) filter('Payment', payment, const [('Cash', 'Cash'), ('Card', 'Card'), ('UPI', 'UPI')], (value) => payment = value),
        FilledButton.icon(
          onPressed: busy ? null : run,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
          label: const Text('Run report'),
        ),
        if (rows.isNotEmpty) OutlinedButton.icon(onPressed: busy ? null : export, icon: const Icon(Icons.download), label: const Text('Export CSV')),
      ]),
      if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (report != null) ...[
        SectionTitle('${humanize('${report!['name']}')} report'),
        Text('${app.branchName('${report!['branchId'] ?? app.session?.branchId}')} · ${report!['timeZone'] == 'Asia/Kolkata' ? 'IST' : 'UTC'} · Confirmed transactions'),
        if (name == 'tenders') const Text('Recorded payments less cash change and refunds. Card and UPI payouts are reconciled with your provider separately.'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final e in (report!['totals'] as Map? ?? {}).entries) Metric(reportLabel('${e.key}'), cell('${e.key}', e.value)),
        ]),
        if ((report!['pendingConflicts'] ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${report!['pendingConflicts']} offline sale conflict(s) await review and are excluded.'),
          ),
        const SizedBox(height: 16),
        DataList(
          rows: rows.skip(page * pageSize).take(pageSize).toList(),
          empty: 'No rows for this period.',
          onTap: (r) {
            final invoice = app.list('invoices').where((i) => i['id'] == r['invoiceId']).firstOrNull;
            final credit = app.list('returns').where((item) => item['number'] == (r['document'] ?? r['number'])).firstOrNull;
            if (credit != null) {
              showReceipt(context, credit);
            } else if (invoice != null) {
              showReceipt(context, invoice);
            }
          },
          columns: [
            for (final k in visibleKeys)
              Col(reportLabel(k), (r) => Text(cell(k, r[k])), numeric: r0Numeric(rows, k),
                  flex: const {'date', 'openedAt', 'closedAt', 'createdAt', 'reason'}.contains(k) ? 2 : 1),
          ],
        ),
        if (rows.length > pageSize) Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          IconButton(tooltip: 'Previous page', onPressed: page == 0 ? null : () => setState(() => page--), icon: const Icon(Icons.chevron_left)),
          Text('${page * pageSize + 1}–${(page * pageSize + pageSize).clamp(0, rows.length)} of ${rows.length}'),
          IconButton(tooltip: 'Next page', onPressed: (page + 1) * pageSize >= rows.length ? null : () => setState(() => page++), icon: const Icon(Icons.chevron_right)),
        ]),
      ],
    ]);
  }

  bool r0Numeric(List<Json> rows, String key) => rows.any((r) => r[key] is num);
}
