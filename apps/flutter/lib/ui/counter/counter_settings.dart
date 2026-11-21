import 'package:flutter/material.dart';

import '../../core/receipt_print.dart';
import '../../main.dart';
import '../widgets.dart';

// WS-A: Settings › Counter payments & receipts. The UPI ID is the shop's
// (server); the receipt printer and auto-print are this device's.

List<Widget> counterSettingsRows(BuildContext context) {
  final app = context.app;
  final vpa = '${app.settings['upiVpa'] ?? ''}';
  final prefs = ReceiptPrinterPrefs.instance;
  prefs.load();
  return [
    Text(vpa.isEmpty ? 'UPI QR: no UPI ID set' : 'UPI QR to $vpa', style: const TextStyle(fontWeight: FontWeight.w700)),
    ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Text(
        '${canPrintSilently ? 'Receipts print to ${prefs.printer.isEmpty ? 'the Windows default printer' : prefs.printer}' : 'Receipts open the print dialog'}'
        '${prefs.autoPrint ? ' after every sale' : ' when asked'} (this device).',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: [
      if (app.isOwner) OutlinedButton(onPressed: () => editUpi(context), child: Text(vpa.isEmpty ? 'Set UPI ID' : 'UPI ID')),
      OutlinedButton(onPressed: () => editReceiptPrinter(context), child: const Text('Receipt printer')),
    ]),
  ];
}

Future<void> editUpi(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'UPI QR at the counter',
    fields: [
      FieldSpec('upiVpa', 'Shop UPI ID', value: app.settings['upiVpa'], help: 'For example cartunez@okhdfcbank. Leave empty to turn the QR off.'),
      FieldSpec('upiPayeeName', 'Name shown to the customer', value: app.settings['upiPayeeName'] ?? app.business['tradingName']),
    ],
    onSubmit: (v) async {
      final vpa = '${v['upiVpa'] ?? ''}'.trim();
      if (vpa.isNotEmpty && !RegExp(r'^[A-Za-z0-9._-]{2,256}@[A-Za-z][A-Za-z0-9.-]{1,63}$').hasMatch(vpa)) {
        throw FormProblem("Enter the shop's UPI ID in the form name@bank.");
      }
      await app.mutate('/settings', {'upiVpa': vpa, 'upiPayeeName': '${v['upiPayeeName'] ?? ''}'.trim()}, 'UPI ID saved.');
    },
  );
}

Future<void> editReceiptPrinter(BuildContext context) async {
  final prefs = ReceiptPrinterPrefs.instance;
  await prefs.load();
  final printers = await receiptPrinters();
  if (!context.mounted) return;
  await showFormDialog<void>(
    context,
    title: 'Receipt printer (this device)',
    fields: [
      if (canPrintSilently)
        FieldSpec('printer', 'Printer', kind: FieldKind.select, value: prefs.printer, options: [
          ('', 'Windows default printer'),
          for (final p in printers) (p.name, p.name),
        ], help: 'Receipts print straight to this printer, without a dialog.'),
      FieldSpec('autoPrint', 'Print', kind: FieldKind.select, value: prefs.autoPrint ? 'yes' : 'no', options: const [
        ('no', 'Only when I press Print (F12 prints too)'),
        ('yes', 'After every sale'),
      ]),
    ],
    onSubmit: (v) async {
      await prefs.save(printer: canPrintSilently ? '${v['printer'] ?? ''}' : null, autoPrint: v['autoPrint'] == 'yes');
    },
  );
}
