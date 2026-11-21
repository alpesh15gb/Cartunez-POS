// WS-E: packing slip (A4 PDF) for an online order the POS invoiced.
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/billing.dart';
import '../../state/app_state.dart';
import '../screens/receipt.dart' show pdfTheme;
import '../widgets.dart';
import 'fulfilment.dart';

/// The invoice the POS made for [order], when it is on this device.
Json? orderInvoice(AppState app, Json order) {
  final id = (order['fulfilment'] as Map?)?['invoiceId'];
  return id == null ? null : app.list('invoices').where((i) => i['id'] == id).firstOrNull;
}

Future<Uint8List> packingSlipPdf(AppState app, Json order) async {
  final f = Map<String, dynamic>.from(order['fulfilment'] as Map? ?? {});
  final customer = Map<String, dynamic>.from(order['customer'] as Map? ?? {});
  final business = Map<String, dynamic>.from(app.settings['business'] as Map? ?? {});
  final invoice = orderInvoice(app, order);
  final serials = <String, List<String>>{};
  for (final l in invoice?['lines'] as List? ?? []) {
    final list = (l['serials'] as List? ?? []).map((s) => '$s').toList();
    if (list.isNotEmpty) serials.putIfAbsent('${l['productId']}', () => []).addAll(list);
  }
  final doc = pw.Document(theme: await pdfTheme());
  pw.Widget cell(String text, {bool bold = false, pw.TextAlign align = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        child: pw.Text(text, textAlign: align, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
      );
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('${business['tradingName'] ?? business['legalName'] ?? ''}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if ('${business['address'] ?? ''}'.isNotEmpty) pw.Text('${business['address']}', style: const pw.TextStyle(fontSize: 9)),
        ])),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('PACKING SLIP', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('Order #${order['number']}', style: const pw.TextStyle(fontSize: 10)),
          if (f['invoiceNumber'] != null) pw.Text('Invoice ${f['invoiceNumber']}', style: const pw.TextStyle(fontSize: 10)),
          pw.Text(formatDate(f['invoicedAt'] ?? order['createdAt']), style: const pw.TextStyle(fontSize: 10)),
        ]),
      ]),
      pw.SizedBox(height: 18),
      pw.Text('Ship to', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      pw.Text('${customer['name'] ?? ''}', style: const pw.TextStyle(fontSize: 11)),
      pw.Text('${order['shipTo'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
      if ('${order['shipRegion'] ?? ''}'.isNotEmpty) pw.Text('${order['shipRegion']}', style: const pw.TextStyle(fontSize: 10)),
      if ('${customer['phone'] ?? ''}'.isNotEmpty) pw.Text('Phone ${customer['phone']}', style: const pw.TextStyle(fontSize: 10)),
      pw.SizedBox(height: 14),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(5), 2: pw.FlexColumnWidth(1)},
        children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
            cell('SKU', bold: true), cell('Item', bold: true), cell('Qty', bold: true, align: pw.TextAlign.right),
          ]),
          for (final l in (order['lines'] as List? ?? []).cast<Map>())
            if (shippedQty(l) > 0)
              pw.TableRow(children: [
                cell('${l['sku']}'),
                cell([
                  '${l['name']}',
                  if (serials['${l['productId']}'] != null) 'Serial: ${serials['${l['productId']}']!.join(', ')}',
                ].join('\n')),
                cell('${shippedQty(l)}', align: pw.TextAlign.right),
              ]),
        ],
      ),
      pw.SizedBox(height: 14),
      pw.Text(
          f['cod'] == true
              ? 'Cash on delivery: collect ${app.money(f['invoiceTotal'] as num?)}'
              : f['paymentKind'] == 'bank'
                  ? 'Paid by bank transfer / UPI. Nothing to collect.'
                  : 'Paid online. Nothing to collect.',
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      if ((f['shipment'] as Map?)?['tracking'] != null)
        pw.Text('Courier ${(f['shipment'] as Map)['courier']} · Tracking ${(f['shipment'] as Map)['tracking']}', style: const pw.TextStyle(fontSize: 10)),
    ]),
  ));
  return doc.save();
}

Future<void> printPackingSlip(AppState app, Json order) async {
  final bytes = await packingSlipPdf(app, order);
  await Printing.layoutPdf(name: 'packing-slip-${order['number']}', onLayout: (_) async => bytes);
}
