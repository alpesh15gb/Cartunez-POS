// WS-A: browsers cannot print silently; the print dialog is used instead.
import 'package:printing/printing.dart';
import 'package:web/web.dart' as web;

bool get canPrintSilently => false;

Future<List<Printer>> receiptPrinters() async => [];

void cleanupPrintFrame() {
  try {
    web.document.getElementById('__net_nfet_printing__')?.remove();
  } catch (_) {}
}
