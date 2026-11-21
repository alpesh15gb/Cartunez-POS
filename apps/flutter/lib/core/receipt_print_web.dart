// WS-A: browsers cannot print silently; the print dialog is used instead.
import 'package:printing/printing.dart';

bool get canPrintSilently => false;

Future<List<Printer>> receiptPrinters() async => [];
