import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../widgets.dart';

Future<void> compareTenderStatement(BuildContext context, {DateTimeRange? range, String method = 'Both'}) {
  final app = context.appRead;
  final now = app.businessTime(DateTime.now());
  final today = DateTime(now.year, now.month, now.day);
  return showDialog<void>(
    context: context, barrierDismissible: false,
    builder: (_) => AppScope(state: app, child: _Comparison(
      range: range ?? DateTimeRange(start: DateTime(today.year, today.month, today.day - 29), end: today),
      method: const ['Card', 'UPI'].contains(method) ? method : 'Both')),
  );
}

class _Comparison extends StatefulWidget {
  const _Comparison({required this.range, required this.method});
  final DateTimeRange range;
  final String method;
  @override
  State<_Comparison> createState() => _ComparisonState();
}

class _ComparisonState extends State<_Comparison> {
  final input = TextEditingController();
  late DateTimeRange range = widget.range;
  late String method = widget.method;
  Json? result;
  bool busy = false;
  String? error;
  int page = 0;
  static const pageSize = 10;
  static const maxBytes = 512 * 1024;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  String day(DateTime value) => value.toIso8601String().substring(0, 10);
  void reset() => setState(() { result = null; error = null; page = 0; });

  Future<void> work(Future<void> Function() fn) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pick() => work(() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (!mounted || files.isEmpty) return;
    if ((await files.single.length() ?? 0) > maxBytes) throw FormProblem('Choose a CSV up to 512 KiB.');
    final bytes = await files.single.readAsBytes();
    if (bytes.length > maxBytes) throw FormProblem('Choose a CSV up to 512 KiB.');
    String csv;
    try {
      csv = utf8.decode(bytes);
    } on FormatException {
      throw FormProblem('Save the statement as UTF-8 CSV and choose it again.');
    }
    if (!mounted) return;
    input.text = csv;
    reset();
  });

  Future<void> compare() => work(() async {
    if (utf8.encode(input.text).length > maxBytes) throw FormProblem('Choose a CSV up to 512 KiB.');
    final app = context.appRead;
    final response = await app.api('/reports/tenders/compare', body: {
      'branchId': app.session?.branchId, 'from': day(range.start), 'to': day(range.end),
      'type': method, 'csv': input.text,
    });
    if (mounted) setState(() { result = Map<String, dynamic>.from(response as Map); page = 0; });
  });

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final summary = result;
    final rows = (summary?['rows'] as List? ?? []).cast<Map>();
    return PopScope(canPop: !busy, child: AlertDialog(
      title: const Text('Compare provider statement'),
      content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('${app.branchName(app.session?.branchId)} · All cashiers · IST'),
          const Text('Use successful INR captures before fees, refunds and payouts. Enter the capture date as YYYY-MM-DD, the exact provider reference and the gross amount in rupees.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(icon: const Icon(Icons.date_range), label: Text('${day(range.start)} – ${day(range.end)}'),
              onPressed: busy ? null : () async {
                final today = app.businessTime(DateTime.now());
                final next = await showDateRangePicker(context: context, firstDate: DateTime(2000),
                  lastDate: today, initialDateRange: range);
                if (mounted && next != null) { range = next; reset(); }
              }),
            DropdownButton<String>(value: method,
              items: [for (final value in ['Both', 'Card', 'UPI']) DropdownMenuItem(
                value: value, child: Text(value == 'Both' ? 'Card and UPI' : value))],
              onChanged: busy ? null : (next) { if (next != null) { method = next; reset(); } }),
          ]),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: busy ? null : pick, child: const Text('Choose CSV')),
            TextButton(onPressed: busy ? null : () => work(() async {
              final message = await saveTextFile('provider-captures.csv', '\uFEFFdate,type,reference,gross_inr\r\n');
              if (mounted) app.toast(message);
            }), child: const Text('Download template')),
          ]),
          TextField(controller: input, minLines: 2, maxLines: 4, readOnly: busy, onChanged: (_) => reset(),
            decoration: const InputDecoration(labelText: 'Statement CSV', hintText: 'date,type,reference,gross_inr')),
          if (summary != null) ...[
            const Divider(),
            Text("${summary['matched']} matched · ${summary['exceptions']} exception groups",
              style: Theme.of(context).textTheme.titleMedium),
            Text("POS ${app.money(summary['posGross'])} (${summary['posCount']} captures)"),
            Text("Statement ${app.money(summary['statementGross'])} (${summary['statementCount']} captures)"),
            Text("Statement minus POS   ${app.money(summary['difference'])}"),
            if (summary['excluded'] != 0) Text("${summary['excluded']} CSV rows outside this period or payment type."),
            for (final row in rows.skip(pageSize * page).take(pageSize)) ExpansionTile(
              key: ValueKey((summary, row['type'], row['reference'])), tilePadding: EdgeInsets.zero,
              title: Text("${row['type']} · ${row['reference'] == '' ? 'No reference' : row['reference']}"),
              subtitle: Text("${row['status']}"),
              children: [for (final source in ['pos', 'statement']) for (final entry in row[source] as List)
                Align(alignment: Alignment.centerLeft, child: SelectableText(
                  "${entry['document']} · ${entry['date']} · ${app.money(entry['amount'])}"))]),
            if (rows.length > pageSize) Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              IconButton(tooltip: 'Previous references', icon: const Icon(Icons.chevron_left),
                onPressed: page == 0 ? null : () => setState(() => page--)),
              Text('${page + 1} / ${(rows.length / pageSize).ceil()}'),
              IconButton(tooltip: 'Next references', icon: const Icon(Icons.chevron_right),
                onPressed: (page + 1) * pageSize >= rows.length ? null : () => setState(() => page++)),
            ]),
          ],
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ))),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(onPressed: busy || input.text.trim().isEmpty ? null : compare, child: Text(busy ? 'Working…' : 'Compare captures')),
      ],
    ));
  }
}
