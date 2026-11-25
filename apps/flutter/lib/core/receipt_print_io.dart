// WS-A: Windows prints receipts without a dialog; Android uses the print dialog.
import 'dart:io';

import 'package:printing/printing.dart';

bool get canPrintSilently => Platform.isWindows;

Future<List<Printer>> receiptPrinters() async {
  if (!Platform.isWindows) return [];
  try {
    return await Printing.listPrinters();
  } catch (_) {
    return [];
  }
}

void cleanupPrintFrame() {}
