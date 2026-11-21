// WS-B: The scannable code a receipt carries so the return desk can find the bill.
//
// The counter's receipt layout can print it with [invoiceCodePdf] (Code 128 of
// the invoice number). The Returns screen accepts the scanned text as-is.
import 'package:barcode/barcode.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/billing.dart';

/// Text encoded in the receipt barcode: the invoice number.
String receiptInvoiceCode(Json invoice) => '${invoice['number'] ?? ''}';

/// A Code 128 barcode of [receiptInvoiceCode] for an 80 mm PDF receipt.
pw.Widget invoiceCodePdf(Json invoice, {double width = 180, double height = 34}) => pw.BarcodeWidget(
      barcode: Barcode.code128(),
      data: receiptInvoiceCode(invoice),
      width: width,
      height: height,
      drawText: false,
    );
