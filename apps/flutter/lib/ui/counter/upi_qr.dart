import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/receipt_print.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

// WS-A: full-screen static UPI QR (upi://pay?pa=<shop UPI ID>&am=<amount>).
// No gateway: the cashier checks the customer's phone / the shop's UPI app and
// taps "Confirm received".

/// Result of the QR screen: the reference to record, or null when cancelled.
Future<String?> showUpiQr(BuildContext context, {required int amount, String note = ''}) {
  final app = context.appRead;
  return Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => AppScope(state: app, child: UpiQrScreen(amount: amount, note: note)),
  ));
}

class UpiQrScreen extends StatefulWidget {
  const UpiQrScreen({super.key, required this.amount, this.note = ''});
  final int amount;
  final String note;
  @override
  State<UpiQrScreen> createState() => _UpiQrScreenState();
}

class _UpiQrScreenState extends State<UpiQrScreen> {
  final reference = TextEditingController();

  @override
  void dispose() {
    reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vpa = '${app.settings['upiVpa'] ?? ''}'.trim();
    final payee = '${app.settings['upiPayeeName'] ?? app.business['tradingName'] ?? app.business['legalName'] ?? ''}'.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('Pay by UPI')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: vpa.isEmpty ? _noVpa(context, app) : _qr(context, app, vpa, payee),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noVpa(BuildContext context, AppState app) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.qr_code_2, size: 64),
        const SizedBox(height: 12),
        const Text('No UPI ID is set for this shop.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: 6),
        const Text('The owner adds it in Settings › Counter payments. Until then, take the payment on the shop\'s UPI app and confirm it here.',
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              // Leave checkout and go to Settings; the cart stays on the counter.
              final router = GoRouter.maybeOf(context);
              Navigator.of(context).popUntil((r) => r.isFirst);
              router?.go('/settings');
            },
            label: const Text('Open Settings'),
          ),
          FilledButton(onPressed: () => _confirm(context), child: const Text('Confirm received')),
        ]),
        const SizedBox(height: 10),
        _referenceField(),
      ]);

  Widget _qr(BuildContext context, AppState app, String vpa, String payee) {
    final uri = upiPayUri(vpa: vpa, payee: payee, amountMinor: widget.amount, note: widget.note);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(app.money(widget.amount),
          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
      Text('to $payee · $vpa', textAlign: TextAlign.center),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final side = c.maxWidth.clamp(180.0, 360.0);
        return Container(
          color: Colors.white,
          padding: const EdgeInsets.all(14),
          child: SizedBox(width: side, height: side, child: CustomPaint(key: const ValueKey('upi-qr'), painter: QrPainter(uri))),
        );
      }),
      const SizedBox(height: 10),
      const Text('Ask the customer to scan with any UPI app. Check the payment arrived, then confirm.', textAlign: TextAlign.center),
      const SizedBox(height: 10),
      _referenceField(),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back'))),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => _confirm(context),
            icon: const Icon(Icons.check),
            label: const Text('Confirm received'),
          ),
        ),
      ]),
    ]);
  }

  Widget _referenceField() => TextField(
        controller: reference,
        decoration: const InputDecoration(labelText: 'UPI reference / UTR (optional)'),
        onSubmitted: (_) => _confirm(context),
      );

  void _confirm(BuildContext context) {
    final app = context.appRead;
    final typed = reference.text.trim();
    Navigator.pop(context, typed.isNotEmpty ? typed : 'UPI QR · confirmed by ${app.userName(app.session?.userId)} · ${formatDate(DateTime.now().toIso8601String())}');
  }
}

/// Draws a QR code with the barcode package (no network, no images).
class QrPainter extends CustomPainter {
  QrPainter(this.data);
  final String data;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    for (final e in Barcode.qrCode().make(data, width: size.width, height: size.height)) {
      if (e is BarcodeBar && e.black) canvas.drawRect(Rect.fromLTWH(e.left, e.top, e.width, e.height), paint);
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}
