// WS-D: shift summary — sales by tender, refunds, drawer movements, cash party
// payments, expected and counted cash — on screen, as a PDF and as CSV.
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/receipt.dart' show pdfTheme;
import '../theme.dart';
import '../widgets.dart';
import 'shift_dialogs.dart' show cashNotes;

/// One printed line: a section heading (value null) or a label and amount.
typedef SummaryLine = ({String label, String? value, bool strong});

SummaryLine _h(String label) => (label: label, value: null, strong: true);
SummaryLine _r(String label, String value, {bool strong = false}) => (label: label, value: value, strong: strong);

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// The summary as lines, shared by the screen, the PDF and the CSV.
List<SummaryLine> shiftSummaryLines(AppState app, Json s) {
  final tenders = Map<String, dynamic>.from(s['tenders'] as Map? ?? {});
  final refunds = Map<String, dynamic>.from(s['refunds'] as Map? ?? {});
  final movements = (s['cashMovements'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  final payments = (s['partyPayments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  final closed = s['closedAt'] != null;
  String party(Json p) {
    final kind = p['partyKind'] == 'supplier' ? 'suppliers' : 'customers';
    final row = app.list(kind).where((r) => r['id'] == p['partyId']).firstOrNull;
    return '${row?['name'] ?? (p['partyKind'] == 'supplier' ? 'Supplier' : 'Customer')}';
  }

  final denominations = Map<String, dynamic>.from(s['denominations'] as Map? ?? {});
  return [
    _r('Cashier', app.userName('${s['userId']}')),
    _r('Opened', formatDate(s['openedAt'])),
    _r('Closed', closed ? formatDate(s['closedAt']) : 'Still open'),
    _h('Sales'),
    _r('Bills', '${_int(s['invoices'])}'),
    _r('Sales total', app.money(_int(s['gross'])), strong: true),
    for (final e in tenders.entries) _r('  ${e.key}${e.key == 'Cash' ? ' (after change)' : ''}', app.money(_int(e.value))),
    _h('Refunds'),
    if (refunds.isEmpty) _r('No refunds', app.money(0)),
    for (final e in refunds.entries) _r('  ${e.key == 'Credit' ? 'To customer account' : e.key}', app.money(_int(e.value))),
    if (refunds.isNotEmpty) _r('Refunds total (${_int(s['refundCount'])})', app.money(_int(s['refundTotal'])), strong: true),
    _h('Cash movements'),
    if (movements.isEmpty) _r('No cash in or out', app.money(0)),
    for (final m in movements)
      _r('  ${m['direction'] == 'in' ? 'In' : 'Out'} · ${m['reason']}', '${m['direction'] == 'in' ? '' : '−'}${app.money(_int(m['amount']))}'),
    if (payments.isNotEmpty) ...[
      _h('Party payments in cash'),
      for (final p in payments)
        _r('  ${p['direction'] == 'in' ? 'From' : 'To'} ${party(p)}', '${p['direction'] == 'in' ? '' : '−'}${app.money(_int(p['amount']))}'),
    ],
    _h('Drawer'),
    _r('Opening cash', app.money(_int(s['openingCash']))),
    _r('+ Cash sales', app.money(_int(s['cashSales']))),
    _r('− Cash refunds', app.money(_int(s['cashRefunds']))),
    _r('+ Cash in', app.money(_int(s['cashIn']))),
    _r('− Cash out', app.money(_int(s['cashOut']))),
    _r('Expected cash', app.money(_int(s['expectedCash'])), strong: true),
    if (closed) ...[
      _r('Counted cash', app.money(_int(s['countedCash'])), strong: true),
      _r('Difference', app.money(_int(s['variance'])), strong: true),
    ],
    if (denominations.isNotEmpty) ...[
      _h('Note count'),
      for (final n in cashNotes)
        if (_int(denominations['$n']) > 0) _r('  ${app.money(n).replaceAll('.00', '')} × ${denominations['$n']}', app.money(n * _int(denominations['$n']))),
      if (_int(denominations['coins']) > 0) _r('  Coins', app.money(_int(denominations['coins']))),
    ],
  ];
}

/// CSV (section, item, amount) for a spreadsheet or the accountant.
String shiftSummaryCsv(List<SummaryLine> lines) {
  String q(String v) => '"${v.replaceAll('"', '""')}"';
  var section = 'Shift';
  final rows = <String>['Section,Item,Value'];
  for (final l in lines) {
    if (l.value == null) {
      section = l.label;
      continue;
    }
    rows.add([q(section), q(l.label.trim()), q(l.value!)].join(','));
  }
  return rows.join('\r\n');
}

Future<pw.Document> shiftSummaryPdf(AppState app, Json summary) async {
  final lines = shiftSummaryLines(app, summary);
  final business = app.business;
  final pdf = pw.Document(theme: await pdfTheme());
  pdf.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    margin: const pw.EdgeInsets.all(10),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Center(child: pw.Text('${business['tradingName'] ?? business['legalName'] ?? ''}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))),
      pw.Center(child: pw.Text('Shift summary · ${app.snapshot['branch']?['name'] ?? ''}', style: const pw.TextStyle(fontSize: 9))),
      pw.SizedBox(height: 6),
      for (final l in lines)
        l.value == null
            ? pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6, bottom: 2),
                child: pw.Text(l.label.toUpperCase(), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)))
            : pw.Row(children: [
                pw.Expanded(child: pw.Text(l.label, style: pw.TextStyle(fontSize: 8, fontWeight: l.strong ? pw.FontWeight.bold : null))),
                pw.Text(l.value!, style: pw.TextStyle(fontSize: 8, fontWeight: l.strong ? pw.FontWeight.bold : null)),
              ]),
      pw.SizedBox(height: 8),
      pw.Text('Printed ${formatDate(DateTime.now().toIso8601String())}', style: const pw.TextStyle(fontSize: 7)),
    ]),
  ));
  return pdf;
}

String _fileName(Json s) => 'shift-${'${s['openedAt'] ?? ''}'.split('T').first}-${'${s['shiftId'] ?? s['id']}'.split('-').last}';

/// Loads the summary from the server and shows it.
Future<void> showShiftSummary(BuildContext context, Json shift) async {
  final app = context.appRead;
  Json summary;
  try {
    summary = Map<String, dynamic>.from(await app.api('/shifts/${shift['id']}/summary') as Map);
  } catch (error) {
    app.toast('Could not load the shift summary: ${errorText(error)}');
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => AppScope(state: app, child: ShiftSummaryDialog(summary: summary)));
}

class ShiftSummaryDialog extends StatelessWidget {
  const ShiftSummaryDialog({super.key, required this.summary});
  final Json summary;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final lines = shiftSummaryLines(app, summary);
    final variance = _int(summary['variance']);
    Future<void> run(Future<String?> Function() task) async {
      try {
        final message = await task();
        if (message != null) app.toast(message);
      } catch (error) {
        app.toast(errorText(error));
      }
    }

    return AlertDialog(
      title: const Text('Shift summary'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final l in lines)
              l.value == null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 4),
                      child: Text(l.label, style: Theme.of(context).textTheme.titleSmall),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Text(l.label, style: TextStyle(fontWeight: l.strong ? FontWeight.w700 : null))),
                        const SizedBox(width: 12),
                        Text(l.value!,
                            style: TextStyle(
                              fontWeight: l.strong ? FontWeight.w800 : FontWeight.w500,
                              color: l.label == 'Difference' ? (variance == 0 ? Brand.forest : Brand.danger) : null,
                            )),
                      ]),
                    ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        OutlinedButton.icon(
          onPressed: () => run(() async {
            await saveTextFile('${_fileName(summary)}.csv', '﻿${shiftSummaryCsv(lines)}');
            return 'Shift summary saved as CSV.';
          }),
          icon: const Icon(Icons.table_view_outlined, size: 18),
          label: const Text('CSV'),
        ),
        OutlinedButton.icon(
          onPressed: () => run(() async {
            final pdf = await shiftSummaryPdf(app, summary);
            await Printing.sharePdf(bytes: await pdf.save(), filename: '${_fileName(summary)}.pdf');
            return null;
          }),
          icon: const Icon(Icons.share_outlined, size: 18),
          label: const Text('Share PDF'),
        ),
        FilledButton.icon(
          onPressed: () => run(() async {
            final pdf = await shiftSummaryPdf(app, summary);
            await Printing.layoutPdf(name: _fileName(summary), onLayout: (_) => pdf.save());
            return null;
          }),
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Print'),
        ),
      ],
    );
  }
}
