// WS-F: GSTR-1 and Tally exports for the accountant, opened from Reports.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../widgets.dart';

const gstr1Sections = [
  ('b2b', 'B2B invoices (registered customers)'),
  ('b2cl', 'B2C large (inter-state above Rs 1 lakh)'),
  ('b2cs', 'B2C small (summary by state and rate)'),
  ('cdnr', 'Credit notes to registered customers'),
  ('cdnur', 'Credit notes on B2C large invoices'),
  ('hsn-b2b', 'HSN summary, B2B'),
  ('hsn-b2c', 'HSN summary, B2C'),
];

Future<void> showAccountingExports(BuildContext context, {DateTimeRange? range}) => showDialog<void>(
      context: context,
      builder: (_) => AccountingExports(range: range),
    );

class AccountingExports extends StatefulWidget {
  const AccountingExports({super.key, this.range});
  final DateTimeRange? range;
  @override
  State<AccountingExports> createState() => _AccountingExportsState();
}

class _AccountingExportsState extends State<AccountingExports> {
  late DateTimeRange range;
  bool allBranches = false;
  bool busy = false;
  Json? summary;
  String? problem;

  @override
  void initState() {
    super.initState();
    final now = context.appRead.businessTime(DateTime.now());
    // GSTR-1 is filed for the previous month by default.
    range = widget.range ?? DateTimeRange(start: DateTime(now.year, now.month - 1, 1), end: DateTime(now.year, now.month, 0));
  }

  String _day(DateTime d) => d.toIso8601String().substring(0, 10);
  Map<String, String> get _query => {
        'dateFrom': _day(range.start),
        'dateTo': _day(range.end),
        if (allBranches) 'branches': 'all',
      };

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      await job();
    } catch (error) {
      if (mounted) setState(() => problem = errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _download(String path, Map<String, String> extra) => _run(() async {
        final app = context.appRead;
        final data = await app.api('$path?${Uri(queryParameters: {..._query, ...extra, 'delivery': 'json'}).query}') as Map;
        final name = '${data['fileName']}';
        final message = data['base64'] != null
            ? await saveBytesFile(name, base64Decode('${data['base64']}'),
                mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
            : await saveTextFile(name, '${data['content']}');
        if (mounted) app.toast(message);
      });

  Future<void> _check() => _run(() async {
        final data = await context.appRead.api('/exports/gstr1?${Uri(queryParameters: _query).query}') as Map;
        if (mounted) setState(() => summary = Map<String, dynamic>.from(data['summary'] as Map));
      });

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final text = Theme.of(context).textTheme;
    final s = summary;
    return AlertDialog(
      title: const Text('GST and Tally exports'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range),
                label: Text('${formatDay(range.start)} – ${formatDay(range.end)}'),
                onPressed: busy ? null : () async {
                  final now = app.businessTime(DateTime.now());
                  final picked = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 5), lastDate: now, initialDateRange: range);
                  if (picked != null && mounted) setState(() { range = picked; summary = null; });
                },
              ),
              if (app.isOwner)
                FilterChip(label: const Text('All branches (one GSTIN)'), selected: allBranches,
                    onSelected: busy ? null : (v) => setState(() { allBranches = v; summary = null; })),
            ]),
            if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (problem != null)
              Padding(padding: const EdgeInsets.only(top: 12),
                  child: Text(problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 16),
            Text('GSTR-1', style: text.titleMedium),
            const SizedBox(height: 4),
            Text('Sales invoices and credit notes for the period. Upload the JSON on the GST portal (Returns > GSTR-1 > '
                'Prepare offline > Upload), or open the Excel/CSV in the GST offline tool. No e-invoice data is included.',
                style: text.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: busy ? null : _check, child: const Text('Check totals')),
              FilledButton.icon(onPressed: busy ? null : () => _download('/exports/gstr1', {'format': 'portal'}),
                  icon: const Icon(Icons.download), label: const Text('Portal JSON')),
              OutlinedButton.icon(onPressed: busy ? null : () => _download('/exports/gstr1', {'format': 'xlsx'}),
                  icon: const Icon(Icons.grid_on_outlined), label: const Text('Excel (all sections)')),
              MenuAnchor(
                builder: (context, controller, _) => OutlinedButton.icon(
                    onPressed: busy ? null : () => controller.isOpen ? controller.close() : controller.open(),
                    icon: const Icon(Icons.description_outlined), label: const Text('CSV section')),
                menuChildren: [
                  for (final (key, label) in gstr1Sections)
                    MenuItemButton(onPressed: () => _download('/exports/gstr1', {'format': 'csv', 'section': key}), child: Text(label)),
                ],
              ),
            ]),
            if (s != null) ...[
              const SizedBox(height: 10),
              Text('GSTIN ${s['gstin']} · period ${s['period']} · ${s['invoices']} invoices, ${s['creditNotes']} credit notes '
                  '(${s['b2bInvoices']} B2B)', style: text.bodySmall),
              Text('Net taxable ${app.money(s['taxable'] as num)} · IGST ${app.money(s['igst'] as num)} · '
                  'CGST ${app.money(s['cgst'] as num)} · SGST ${app.money(s['sgst'] as num)}', style: text.bodyMedium),
              Text('These match the Tax report for the same dates.', style: text.bodySmall),
              if (s['multipleMonths'] == true)
                Text('The dates cover more than one month. GSTR-1 is filed per month (or quarter); the period is taken from the end date.',
                    style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            Text('Tally', style: text.titleMedium),
            const SizedBox(height: 4),
            Text('Tally XML for TallyPrime or Tally ERP 9: Gateway of Tally > Import > Masters (ledgers file, once), '
                'then Import > Transactions (vouchers). Sales and returns come as Sales and Credit Note vouchers; '
                'supplier bills and returns as Purchase and Debit Note vouchers.', style: text.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: busy ? null : () => _download('/exports/tally', {'vouchers': 'ledgers'}), child: const Text('Ledgers (masters)')),
              FilledButton.icon(onPressed: busy ? null : () => _download('/exports/tally', {'vouchers': 'sales'}),
                  icon: const Icon(Icons.download), label: const Text('Sales vouchers')),
              OutlinedButton.icon(onPressed: busy ? null : () => _download('/exports/tally', {'vouchers': 'purchases'}),
                  icon: const Icon(Icons.download), label: const Text('Purchase vouchers')),
            ]),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

String formatDay(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
