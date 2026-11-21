
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/receipt_print.dart';
import '../orders/invoice_code.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

export 'labels.dart';

/// Facts shown on a receipt or credit note, taken from the issued document so
/// later setting changes never alter a reprint.
class ReceiptView {
  ReceiptView(this.app, this.doc);
  final AppState app;
  final Json doc;

  bool get credit => doc['invoiceId'] != null;
  Json get business => Map<String, dynamic>.from(doc['business'] as Map? ?? app.business);
  String get kind => credit
      ? (doc['voided'] == true ? 'CREDIT NOTE · INVOICE VOID' : 'CREDIT NOTE')
      : (doc['taxScheme'] == 'india-gst' ? 'TAX INVOICE' : 'SALES RECEIPT');
  String money(num? v) => app.money(v, currency: '${doc['currency'] ?? app.settings['currency'] ?? 'INR'}');
  List<Json> get lines => (doc['lines'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  String lineName(Json l) => '${l['name'] ?? app.productName('${l['productId']}')}';
  int lineQty(Json l) => (l['qty'] ?? l['quantity'] ?? 0) as int;
  int taxable(Json l) =>
      ((l['subtotal'] ?? 0) as int) - ((l['discount'] ?? 0) as int) - (doc['taxMode'] == 'inclusive' ? (l['tax'] ?? 0) as int : 0);

  List<(String, String)> get totals => [
        if (doc['subtotal'] != null) ('Subtotal', money(doc['subtotal'] as num)),
        if ((doc['discount'] ?? 0) != 0)
          ('Discount${'${doc['discountReason'] ?? ''}'.isNotEmpty ? ' · ${doc['discountReason']}' : ''}', '−${money(doc['discount'] as num)}'),
        for (final c in (doc['taxComponents'] as List? ?? [])) ('${c['name']}', money(c['amount'] as num)),
        ('${doc['taxDisplayName'] ?? 'Tax'}${doc['taxMode'] == 'inclusive' ? ' included' : ''}', money(doc['tax'] as num? ?? 0)),
        if ((doc['coreTotal'] ?? 0) != 0) ('Core deposits', money(doc['coreTotal'] as num)),
        if ((doc['rounding'] ?? 0) != 0) ('Rounding', money(doc['rounding'] as num)),
      ];

  List<(String, String)> get payments => [
        // WS-B: an exchange credit note is set against the new bill; only any excess is paid back.
        if (credit && doc['exchangeApplied'] != null) ('Set against new bill', money(doc['exchangeApplied'] as num?)),
        // Paid back per method (refunds breakdown; older notes have one refundType).
        if (credit)
          for (final part in refundParts(doc))
            (part.type == 'Credit' ? 'Refund · to customer account' : 'Refund · ${part.type}', money(part.amount)),
        if (doc['exchange'] is Map)
          ('Exchange · credit note ${doc['exchange']['creditNoteNumber']} (bill ${doc['exchange']['originalInvoiceNumber']})',
              '−${money(doc['exchange']['applied'] as num?)}'),
        if ((doc['advanceApplied'] ?? 0) != 0) ('From advance', money(doc['advanceApplied'] as num?)),
        for (final t in doc['tenders'] as List? ?? [])
          ('Paid · ${t['type']}${'${t['reference'] ?? ''}'.isNotEmpty ? ' · ${t['reference']}' : ''}', money(t['amount'] as num)),
        if (doc['change'] != null) ('Change', money(doc['change'] as num)),
      ];

  List<String> get header => [
        if ('${business['tradingName'] ?? ''}'.isNotEmpty && business['tradingName'] != business['legalName']) '${business['tradingName']}',
        if ('${business['address'] ?? ''}'.isNotEmpty) '${business['address']}',
        if ('${business['taxRegistrationId'] ?? ''}'.isNotEmpty) 'GSTIN / Tax ID: ${business['taxRegistrationId']}',
        [business['phone'], business['email']].where((e) => e != null && '$e'.isNotEmpty).join(' · '),
        '${doc['branch']?['name'] ?? app.snapshot['branch']?['name'] ?? ''}',
      ].where((e) => e.isNotEmpty).toList();
}

Future<void> showReceipt(BuildContext context, Json doc) {
  final app = context.appRead;
  final r = ReceiptView(app, doc);
  return showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.kind, style: const TextStyle(color: Brand.forest, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          // One line: invoice numbers (MT-2026-00012) must not break at the hyphen.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('${doc['number'] ?? 'Pending'}', maxLines: 1, softWrap: false, style: Theme.of(context).textTheme.headlineMedium),
          ),
          Text('${r.business['legalName'] ?? r.business['tradingName'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
          for (final line in r.header) Text(line, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (r.credit) Text('Against invoice ${doc['invoiceNumber']} · Reason: ${doc['reason'] ?? '—'}'),
          if (doc['customer'] is Map)
            Text('Customer: ${doc['customer']['name']}${'${doc['customer']['taxRegistrationId'] ?? ''}'.isNotEmpty ? ' · ${doc['customer']['taxRegistrationId']}' : ''}'),
          if ('${doc['placeOfSupply'] ?? ''}'.isNotEmpty) Text('Place of supply: ${doc['placeOfSupply']}'),
          Text('${formatDate(doc['createdAt'])} · ${app.userName('${doc['cashierId'] ?? doc['userId']}')}',
              style: Theme.of(context).textTheme.bodySmall),
          if (!r.credit && doc['id'] != null && app.invoiceStatus(doc) != 'Finalized')
            Padding(padding: const EdgeInsets.only(top: 6), child: StatusChip(app.invoiceStatus(doc))),
          const SizedBox(height: 14),
          const Divider(),
          for (final l in r.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.lineName(l), style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '${r.lineQty(l)} ${l['unit'] ?? ''} · tax ${((l['taxRate'] ?? 0) as int) / 100}%'
                      '${'${l['hsnSac'] ?? ''}'.isNotEmpty ? ' · HSN ${l['hsnSac']}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]),
                ),
                Text(r.money(l['total'] as num? ?? 0), style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
          const Divider(),
          const SizedBox(height: 6),
          for (final (label, value) in r.totals) _row(label, value),
          const SizedBox(height: 6),
          _row(r.credit ? 'Total refunded' : 'Total', r.money(doc['total'] as num? ?? 0), big: true),
          for (final (label, value) in r.payments) _row(label, value),
          if ('${doc['receiptFooter'] ?? ''}'.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text('${doc['receiptFooter']}', style: Theme.of(context).textTheme.bodySmall)),
        ]),
      ),
      actions: [
        if (!r.credit)
          TextButton.icon(
            onPressed: () => shareReceiptWhatsApp(app, doc),
            icon: const Icon(Icons.chat_outlined),
            label: const Text('WhatsApp'),
          ),
        TextButton.icon(
          onPressed: () => shareReceipt(app, doc),
          icon: const Icon(Icons.ios_share),
          label: const Text('Share PDF'),
        ),
        OutlinedButton.icon(
          onPressed: () => printReceipt(app, doc),
          icon: const Icon(Icons.print_outlined),
          label: const Text('Print'),
        ),
        // WS-B: send the invoice or credit note as a PDF (WhatsApp, email) from the share sheet.
        OutlinedButton.icon(
          onPressed: () => shareReceipt(app, doc),
          icon: const Icon(Icons.share_outlined),
          label: const Text('Share'),
        ),
        FilledButton(onPressed: () => Navigator.pop(dialog), child: const Text('Done')),
      ],
    ),
  );
}

Widget _row(String label, String value, {bool big = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: big ? 18 : 13, fontWeight: big ? FontWeight.w800 : FontWeight.w400))),
        Text(value, style: TextStyle(fontSize: big ? 22 : 13, fontWeight: big ? FontWeight.w800 : FontWeight.w600)),
      ]),
    );

/// Receipts and labels use the bundled font (it has the rupee sign), so they
/// look the same on Windows, Android and the web and never need a download.
pw.ThemeData? _pdfTheme;
Future<pw.ThemeData> pdfTheme() async {
  return _pdfTheme ??= pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf')),
  );
}

/// 80 mm roll receipt. On Windows it goes straight to this device's receipt
/// printer (Settings › Counter); elsewhere the print dialog lets the shop pick A4.
Future<void> printReceipt(AppState app, Json doc) async {
  final message = await sendReceiptPdf(await buildReceiptPdf(app, doc), '${doc['number'] ?? 'receipt'}');
  if (message.isNotEmpty) app.toast(message);
}

/// Shares the receipt PDF through the system share sheet.
Future<void> shareReceipt(AppState app, Json doc) async =>
    shareReceiptPdf(await buildReceiptPdf(app, doc), '${doc['number'] ?? 'receipt'}.pdf');

/// Short receipt text for WhatsApp: shop, bill number, items, total and payment.
String receiptSummary(AppState app, Json doc) {
  final r = ReceiptView(app, doc);
  return [
    '${r.business['tradingName'] ?? r.business['legalName'] ?? ''}'.trim(),
    '${r.kind} ${doc['number'] ?? ''} · ${formatDate(doc['createdAt'])}',
    if (doc['customer'] is Map) 'Customer: ${doc['customer']['name']}',
    '',
    for (final l in r.lines) '${r.lineQty(l)} × ${r.lineName(l)} — ${r.money(l['total'] as num? ?? 0)}',
    '',
    if ((doc['discount'] ?? 0) != 0) 'Discount: −${r.money(doc['discount'] as num)}',
    '${r.credit ? 'Total refunded' : 'Total'}: ${r.money(doc['total'] as num? ?? 0)}',
    for (final (label, value) in r.payments) '$label: $value',
    if ('${doc['receiptFooter'] ?? ''}'.isNotEmpty) ...['', '${doc['receiptFooter']}'],
  ].join('\n').trim();
}

/// Opens WhatsApp (wa.me) with the receipt summary for the customer's number.
Future<void> shareReceiptWhatsApp(AppState app, Json doc) async {
  final customer = doc['customer'] is Map ? doc['customer'] as Map : app.customerById('${doc['customerId']}');
  await openWhatsApp(whatsappUri('${customer?['phone'] ?? ''}', receiptSummary(app, doc)), app.toast);
}

/// The receipt as an 80 mm roll PDF.
Future<Uint8List> buildReceiptPdf(AppState app, Json doc) async {
  final r = ReceiptView(app, doc);
  final pdf = pw.Document(theme: await pdfTheme());
  pw.Widget row(String a, String b, {bool strong = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text(a, style: pw.TextStyle(fontSize: strong ? 11 : 8, fontWeight: strong ? pw.FontWeight.bold : null))),
          pw.Flexible(flex: 2, child: pw.Text(b, textAlign: pw.TextAlign.right,
              style: pw.TextStyle(fontSize: strong ? 11 : 8, fontWeight: strong ? pw.FontWeight.bold : null))),
        ]),
      );
  pdf.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    margin: const pw.EdgeInsets.all(10),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Center(child: pw.Text('${r.business['legalName'] ?? r.business['tradingName'] ?? ''}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
      for (final line in r.header) pw.Center(child: pw.Text(line, style: const pw.TextStyle(fontSize: 7.5), textAlign: pw.TextAlign.center)),
      pw.SizedBox(height: 6),
      pw.Center(child: pw.Text(r.kind, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
      row('No.', '${doc['number'] ?? 'Pending'}'),
      row('Date', formatDate(doc['createdAt'])),
      if (r.credit) ...[
        row('Against', '${doc['invoiceNumber']}'),
        if (doc['invoiceDate'] != null) row('Invoice date', formatDate(doc['invoiceDate'])),
        row('Reason', '${doc['reason'] ?? ''}'),
      ],
      if (doc['customer'] is Map) ...[
        row('Customer', '${doc['customer']['name']}'),
        if ('${doc['customer']['address'] ?? ''}'.isNotEmpty) row('Customer address', '${doc['customer']['address']}'),
        if ('${doc['customer']['taxRegistrationId'] ?? ''}'.isNotEmpty) row('Customer tax ID', '${doc['customer']['taxRegistrationId']}'),
      ],
      if ('${doc['placeOfSupply'] ?? ''}'.isNotEmpty) row('Place of supply', '${doc['placeOfSupply']}'),
      pw.Divider(thickness: 0.5),
      for (final l in r.lines) ...[
        pw.Text(r.lineName(l), style: const pw.TextStyle(fontSize: 8.5)),
        row('${r.lineQty(l)} ${l['unit'] ?? ''}${l['unitPrice'] != null ? ' × ${r.money(l['unitPrice'])}' : ''}', r.money(l['total'] as num? ?? 0)),
        if ('${l['hsnSac'] ?? ''}'.isNotEmpty) row('HSN / SAC', '${l['hsnSac']}'),
        row('Taxable', r.money(r.taxable(l))),
        row('Tax ${((l['taxRate'] ?? 0) as int) / 100}%', r.money(l['tax'])),
        if ((l['serials'] as List? ?? []).isNotEmpty) row('Serials', (l['serials'] as List).join(', ')),
      ],
      pw.Divider(thickness: 0.5),
      for (final (a, b) in r.totals) row(a, b),
      row(r.credit ? 'TOTAL REFUNDED' : 'TOTAL', r.money(doc['total'] as num? ?? 0), strong: true),
      for (final (a, b) in r.payments) row(a, b),
      // Integration: the bill's code, scanned at the return desk (WS-B).
      if (!r.credit && receiptInvoiceCode(doc).isNotEmpty) ...[
        pw.SizedBox(height: 6),
        pw.Center(child: invoiceCodePdf(doc, width: 150, height: 26)),
        pw.Center(child: pw.Text(receiptInvoiceCode(doc), style: const pw.TextStyle(fontSize: 6.5))),
      ],
      if ('${doc['receiptFooter'] ?? ''}'.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        pw.Center(child: pw.Text('${doc['receiptFooter']}', style: const pw.TextStyle(fontSize: 7.5), textAlign: pw.TextAlign.center)),
      ],
    ]),
  ));
  return pdf.save();
}

