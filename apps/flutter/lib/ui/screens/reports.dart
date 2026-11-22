import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/files.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';
import '../widgets/data_grid.dart';
import 'accounting_exports.dart';
import 'command_center.dart' show formatIsoDay;
import 'receipt.dart';
import 'tender_comparison.dart';

const _reports = [
  'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'shifts', 'tenders', 'valuation', 'stock-by-bin', 'stock-movement',
  'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'tax', 'warranty', 'cores', 'fitment', 'cash-movements',
];
const _stockReports = [
  'valuation', 'stock-by-bin', 'stock-movement', 'low-stock', 'fast-moving', 'slow-moving', 'aging', 'purchase-receipts', 'warranty',
];
const _moneyKeys = {
  'gross', 'returns', 'coreReturns', 'net', 'discount', 'tax', 'cost', 'margin', 'value', 'landedCost', 'total', 'openingCash',
  'cashSales', 'cashRefunds', 'cashIn', 'cashOut', 'netMovement',
  'expectedCash', 'countedCash', 'variance', 'collected', 'refunded', 'charged', 'outstanding', 'revenue', 'amount', 'taxable',
  'unitPrice', 'subtotal', 'coreCharge', 'coreDeposits', 'rounding', 'price', 'retailPrice', 'wholesalePrice', 'cgst', 'sgst', 'igst', 'utgst',
};
const _hidden = {'id', 'invoiceId', 'productId', 'returnId', 'purchaseOrderId', 'supplierId', 'lineId', 'binId'};
const _snapshotReports = {'valuation', 'stock-by-bin', 'low-stock', 'aging'};
const _cashierReports = {'cash-movements', 'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'shifts', 'tenders', 'tax', 'cores', 'fitment'};
const _tenderFilters = {'daily-sales', 'sales', 'returns', 'discounts', 'margin', 'tenders', 'tax', 'cores', 'fitment'};
const _reportColumns = {
  'sales': ['number', 'date', 'cashierId', 'total', 'discount', 'tax', 'cost'],
  'discounts': ['number', 'date', 'cashierId', 'discount', 'total'],
  'margin': ['number', 'date', 'total', 'tax', 'cost', 'margin'],
  'returns': ['number', 'invoiceNumber', 'createdAt', 'reason', 'refundType', 'total', 'tax'],
  'tax': ['document', 'date', 'sku', 'hsnSac', 'taxRate', 'taxable', 'tax', 'cgst', 'sgst', 'igst', 'utgst'],
  'shifts': ['userId', 'openedAt', 'closedAt', 'openingCash', 'cashIn', 'cashOut', 'expectedCash', 'countedCash', 'variance'],
  'stock-movement': ['createdAt', 'sku', 'name', 'location', 'quantity', 'reason', 'userId'],
  'purchase-receipts': ['date', 'source', 'sku', 'supplier', 'location', 'quantity', 'cost', 'landedCost', 'total'], // QA #2: source = Goods receipt / PO bill / Supplier bill
  'cash-movements': ['createdAt', 'userId', 'direction', 'amount', 'reason'],
  'tenders': ['type', 'collected', 'refunded', 'net'],
};
const _reportLabels = {
  'gross': 'Gross billed', 'net': 'Net after refunds', 'returns': 'Refunds',
  'cashierId': 'Cashier', 'userId': 'Staff member', 'hsnSac': 'HSN / SAC',
  'cgst': 'CGST', 'sgst': 'SGST', 'igst': 'IGST', 'utgst': 'UTGST',
};

String reportLabel(String key) => _reportLabels[key] ?? humanize(key);

String reportCsv(List<Map> rows, {required String currency}) {
  final keys = {for (final row in rows) ...row.keys.map((key) => '$key')};
  String header(String key) {
    if (_moneyKeys.contains(key)) return '$key ($currency)';
    return key == 'taxRate' ? 'taxRate (%)' : key;
  }
  String decimal(int value) {
    final magnitude = value.abs();
    return "${value < 0 ? '-' : ''}${magnitude ~/ 100}.${(magnitude % 100).toString().padLeft(2, '0')}";
  }
  Object? convert(String key, Object? value) {
    if (value is int && (_moneyKeys.contains(key) || key == 'taxRate')) return decimal(value);
    if (value is Map) return {for (final e in value.entries) header('${e.key}'): convert('${e.key}', e.value)};
    if (value is List) return value.map((v) => convert('', v)).toList();
    return value;
  }
  String quote(Object? value, {bool protectText = true}) {
    final raw = value is Map || value is List ? jsonEncode(value) : '${value ?? ''}';
    final safe = protectText && value is String && RegExp(r'^(?:\s*[=+@-]|[\t\r\n])').hasMatch(raw) ? "'$raw" : raw;
    return '"${safe.replaceAll('"', '""')}"';
  }
  return [
    keys.map((k) => quote(header(k))).join(','),
    for (final row in rows) keys.map((k) => quote(convert(k, row[k]), protectText: row[k] is String)).join(','),
  ].join('\r\n');
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.initial, this.onNameChanged});

  /// Report to open first (from the /reports/:name link).
  final String? initial;

  /// Called when the user picks another report, so the address can follow.
  final ValueChanged<String>? onNameChanged;

  /// Every report name, in menu order.
  static const names = _reports;
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
  int requestVersion = 0;
  String? errorMessage;
  int page = 0;
  /// Rows fetched per request. A report that fits in one request is sorted
  /// and paged in the grid; a bigger one is paged by the server.
  static const pageSize = 250;

  @override
  void initState() {
    super.initState();
    if (_reports.contains(widget.initial)) name = widget.initial!;
    final now = context.appRead.businessTime(DateTime.now());
    final end = DateTime(now.year, now.month, now.day);
    range = DateTimeRange(start: DateTime(now.year, now.month, now.day - 29), end: end);
  }

  @override
  void didUpdateWidget(ReportsScreen old) {
    super.didUpdateWidget(old);
    final next = widget.initial;
    if (next != old.initial && next != null && next != name && _reports.contains(next)) changeFilter(() => name = next);
  }

  String columnLabel(String key) {
    if (name == 'fast-moving' || name == 'slow-moving') {
      if (key == 'quantity') return 'Net units';
      if (key == 'revenue') return 'Net billed';
    }
    return reportLabel(key);
  }

  bool get hasPartFilters => !const {'cash-movements', 'tenders', 'shifts', 'warranty'}.contains(name);

  void changeFilter(VoidCallback change) => setState(() {
    change();
    requestVersion++;
    busy = false;
    report = null;
    errorMessage = null;
    page = 0;
  });

  Map<String, String> filters() {
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    return {
        if (range != null && !_snapshotReports.contains(name)) ...{
          'dateFrom': day(range!.start), 'dateTo': day(range!.end),
        },
        if (hasPartFilters && category.isNotEmpty) 'category': category,
        if (hasPartFilters && supplier.isNotEmpty) 'supplierId': supplier,
        if (_cashierReports.contains(name) && cashier.isNotEmpty) 'cashier': cashier,
        if (_tenderFilters.contains(name) && payment.isNotEmpty) 'paymentType': payment,
      };
  }

  Future<void> run({int nextPage = 0, bool continuing = false}) async {
    final version = ++requestVersion;
    final app = context.appRead;
    setState(() {
      busy = true;
      errorMessage = null;
    });
    try {
      final query = {
        ...filters(), 'page': '${nextPage + 1}', 'pageSize': '$pageSize',
        if (continuing && report?['revision'] != null) 'revision': '${report!['revision']}',
      };
      final result = await app.api('/reports/$name?${Uri(queryParameters: query).query}');
      if (mounted && version == requestVersion) {
        setState(() {
          report = Map<String, dynamic>.from(result as Map);
          page = nextPage;
        });
      }
    } catch (error) {
      if (mounted && version == requestVersion) setState(() => errorMessage = errorText(error));
    } finally {
      if (mounted && version == requestVersion) setState(() => busy = false);
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
    if (key == 'direction' && name == 'cash-movements') return value == 'in' ? 'Cash in' : 'Cash out';
    if (key == 'cashierId' || key == 'userId') return app.userName('$value');
    final timestamp = DateTime.tryParse('$value');
    if ('$value'.contains('T') && timestamp != null) {
      final time = timestamp.toUtc().add(report?['timeZone'] == 'Asia/Kolkata' ? const Duration(hours: 5, minutes: 30) : Duration.zero);
      return DateFormat('dd/MM/yyyy, h:mm a').format(time).replaceAll('AM', 'am').replaceAll('PM', 'pm');
    }
    // Plain days ("2026-11-21") in the app's dd/mm/yyyy.
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch('$value')) return formatIsoDay(value);
    return '$value';
  }

  Future<void> export() async {
    final snapshot = report!;
    final app = context.appRead;
    final rows = (snapshot['rows'] as List).cast<Map>();
    try {
      final String csv;
      if ((snapshot['totalRows'] ?? rows.length) > rows.length) {
        final query = {...filters(), 'format': 'csv-json', 'revision': '${snapshot['revision']}'};
        final data = await app.api('/reports/$name?${Uri(queryParameters: query).query}');
        csv = data['csv'] as String;
      } else {
        csv = reportCsv(rows, currency: '${snapshot['currency'] ?? app.settings['currency'] ?? 'INR'}');
      }
      final message = await saveTextFile('${snapshot['name']}-${DateTime.now().millisecondsSinceEpoch}.csv', '\uFEFF$csv');
      if (mounted) context.appRead.toast(message);
    } catch (error) {
      if (mounted) context.appRead.toast(errorText(error));
    }
  }

  /// WS-F: the whole report as an Excel workbook (built by the server).
  Future<void> exportExcel() async {
    final snapshot = report!;
    final app = context.appRead;
    try {
      final query = {...filters(), 'format': 'xlsx-json', if (snapshot['revision'] != null) 'revision': '${snapshot['revision']}'};
      final data = await app.api('/reports/$name?${Uri(queryParameters: query).query}');
      final message = await saveBytesFile('${snapshot['name']}-${DateTime.now().millisecondsSinceEpoch}.xlsx', base64Decode('${data['base64']}'),
          mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      if (mounted) context.appRead.toast(message);
    } catch (error) {
      if (mounted) context.appRead.toast(errorText(error));
    }
  }

  /// Filter width: fixed on wide screens, the full row on phones.
  double fieldWidth(double fixed) => MediaQuery.sizeOf(context).width < 600 ? double.infinity : fixed;

  Widget filter(String title, String value, List<(String, String)> choices, ValueChanged<String> setValue) => SizedBox(
    width: fieldWidth(200),
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
    final serverPaged = report?['totalRows'] is int;
    final totalRows = serverPaged ? report!['totalRows'] as int : rows.length;
    void goToPage(int next) {
      if (serverPaged) {
        run(nextPage: next, continuing: true);
      } else {
        setState(() => page = next);
      }
    }
    final keys = <String>{
      for (final r in rows)
        for (final e in r.entries)
          if (!_hidden.contains(e.key) && e.value is! Map && e.value is! List) e.key,
    }.toList();
    final visibleKeys = _reportColumns[name]?.where(keys.contains).toList() ?? keys.take(8).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: fieldWidth(240),
          child: DropdownButtonFormField<String>(
            key: ValueKey(name),
            isExpanded: true,
            initialValue: name,
            decoration: const InputDecoration(labelText: 'Report'),
            items: [for (final n in names) DropdownMenuItem(value: n, child: Text(humanize(n), overflow: TextOverflow.ellipsis))],
            onChanged: busy ? null : (v) {
              changeFilter(() => name = v ?? name);
              widget.onNameChanged?.call(name);
            },
          ),
        ),
        if (!_snapshotReports.contains(name)) OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(range == null ? 'All dates' : '${formatDay(range!.start)} – ${formatDay(range!.end)}'),
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
          onPressed: busy ? null : () => run(),
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
          label: const Text('Run report'),
        ),
        if (rows.isNotEmpty) MenuAnchor(
          alignmentOffset: const Offset(0, 4),
          style: MenuStyle(
            elevation: const WidgetStatePropertyAll(0),
            backgroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surface),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: Theme.of(context).dividerTheme.thickness ?? 1),
            )),
          ),
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: busy ? null : () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download), label: const Text('Export')),
          menuChildren: [
            MenuItemButton(onPressed: export, leadingIcon: const Icon(Icons.description_outlined), child: const Text('CSV (.csv)')),
            MenuItemButton(onPressed: exportExcel, leadingIcon: const Icon(Icons.grid_on_outlined), child: const Text('Excel (.xlsx)')),
          ],
        ),
        // WS-F: GSTR-1 and Tally, for the accountant.
        if (app.isManager) OutlinedButton.icon(onPressed: () => showAccountingExports(context, range: range),
            icon: const Icon(Icons.account_balance_outlined), label: const Text('GST & Tally')),
        if (app.canStock) TextButton.icon(onPressed: () => context.go('/catalog/import'),
            icon: const Icon(Icons.upload_file_outlined), label: const Text('Parts import')),
        if (name == 'tenders' && app.isManager && app.settings['currency'] == 'INR')
          OutlinedButton.icon(onPressed: busy ? null : () => compareTenderStatement(context, range: range, method: payment),
            icon: const Icon(Icons.compare_arrows), label: const Text('Compare provider CSV')),
      ]),
      if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (report != null) ...[
        SectionTitle('${humanize('${report!['name']}')} report'),
        Text('${app.branchName('${report!['branchId'] ?? app.session?.branchId}')} · ${report!['timeZone'] == 'Asia/Kolkata' ? 'IST' : 'UTC'} · Confirmed transactions'),
        if (name == 'tenders') const Text('Recorded payments less cash change and refunds. Card and UPI payouts are reconciled with your provider separately.'),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final phone = c.maxWidth < 600;
          final width = phone ? (c.maxWidth - 12) / 2 : 200.0;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final e in (report!['totals'] as Map? ?? {}).entries)
              SizedBox(width: width, child: Metric(columnLabel('${e.key}'), cell('${e.key}', e.value))),
          ]);
        }),
        if ((report!['pendingConflicts'] ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${report!['pendingConflicts']} offline sale conflict(s) await review and are excluded.'),
          ),
        const SizedBox(height: 16),
        DataGrid(
          key: ValueKey('grid-$name'),
          storageKey: 'report-$name',
          rows: rows,
          pageSize: serverPaged && totalRows > pageSize ? pageSize : 25,
          totalRows: serverPaged && totalRows > pageSize ? totalRows : null,
          page: serverPaged && totalRows > pageSize ? page : 0,
          onPage: serverPaged && totalRows > pageSize ? (next) {
            if (!busy) goToPage(next);
          } : null,
          empty: 'No rows for this period.',
          onRowTap: (r) {
            final invoice = app.list('invoices').where((i) => i['id'] == r['invoiceId']).firstOrNull;
            final credit = app.list('returns').where((item) => item['number'] == (r['document'] ?? r['number'])).firstOrNull;
            if (credit != null) {
              showReceipt(context, credit);
            } else if (invoice != null) {
              showReceipt(context, invoice);
            }
          },
          columns: [
            for (final k in keys)
              GridColumn(k, columnLabel(k), numeric: r0Numeric(rows, k), text: (r) => cell(k, r[k]),
                  visible: visibleKeys.contains(k),
                  width: const {'date', 'openedAt', 'closedAt', 'createdAt', 'reason', 'name'}.contains(k) ? 180 : null),
          ],
        ),
      ],
    ]);
  }

  bool r0Numeric(List<Json> rows, String key) => rows.any((r) => r[key] is num);
}
