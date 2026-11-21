import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';
import '../screens/receipt.dart';
import '../shift/shift_dialogs.dart' show showOpenShiftDialog; // WS-D

// ---------------- checkout ----------------

Future<void> startCheckout(BuildContext context) async {
  final app = context.appRead;
  if ((app.cart['lines'] as List).isEmpty || !app.canSell) return;
  if (!app.online) {
    app.toast('Reconnect before taking payment. Your cart is saved on this counter.');
    return;
  }
  if (app.openShift == null) {
    final opened = await openShiftDialog(context, forCheckout: true);
    if (!opened || !context.mounted) return;
  }
  Quote bill;
  try {
    bill = app.currentQuote();
  } catch (error) {
    app.toast(errorText(error));
    return;
  }
  final invoice = await showDialog<Json>(
    context: context,
    builder: (_) => AppScope(state: app, child: CheckoutDialog(total: bill.total)),
  );
  if (invoice != null && context.mounted) await showReceipt(context, invoice);
}

// WS-D: opening float with quick amounts lives in lib/ui/shift/shift_dialogs.dart.
Future<bool> openShiftDialog(BuildContext context, {bool forCheckout = false}) =>
    showOpenShiftDialog(context, forCheckout: forCheckout);

class CheckoutDialog extends StatefulWidget {
  const CheckoutDialog({super.key, required this.total});
  final int total;
  @override
  State<CheckoutDialog> createState() => CheckoutDialogState();
}

class CheckoutDialogState extends State<CheckoutDialog> {
  late String tender;
  late final TextEditingController amount = TextEditingController(text: (widget.total / 100).toStringAsFixed(2));
  final second = TextEditingController(text: '0.00');
  final references = {for (final type in ['Card', 'UPI']) type: TextEditingController()};
  late final TextEditingController place;
  String secondTender = '';
  bool split = false;
  bool confirmed = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    tender = app.tenderTypes.contains('Cash') ? 'Cash' : app.tenderTypes.first;
    secondTender = _types.firstWhere((t) => t != tender, orElse: () => tender);
    place = TextEditingController(
        text: '${app.customerById('${app.cart['customerId']}')?['stateCode'] ?? app.business['stateCode'] ?? ''}');
  }

  int _minor(String text) => parsePaymentAmount(text) ?? 0;

  /// Payment types for this sale: "Credit" (on the customer's account) needs a chosen customer.
  List<String> get _types {
    final app = context.appRead;
    final customer = app.customerById('${app.cart['customerId']}');
    return [...app.tenderTypes, if (customer != null) 'Credit'];
  }

  static bool _external(String type) => type != 'Cash' && type != 'Credit';

  @override
  void dispose() {
    amount.dispose();
    second.dispose();
    for (final c in references.values) { c.dispose(); }
    place.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (busy) return;
    final app = context.appRead;
    final paid = _minor(amount.text) + (split ? _minor(second.text) : 0);
    final cash = (tender == 'Cash' ? _minor(amount.text) : 0) + (split && secondTender == 'Cash' ? _minor(second.text) : 0);
    final nonCash = _external(tender) || (split && _external(secondTender));
    setState(() => error = null);
    if (parsePaymentAmount(amount.text) == null || (split && (parsePaymentAmount(second.text) ?? 0) <= 0)) {
      return setState(() => error = 'Enter a valid amount for each payment, with up to two decimal places.');
    }
    if (split && (_minor(amount.text) == 0 || tender == secondTender)) {
      return setState(() => error = 'Choose two different payment methods and enter an amount for each.');
    }
    if (paid < widget.total) return setState(() => error = 'Payment must cover the total.');
    if (paid - widget.total > cash) return setState(() => error = 'Change can only be given from cash.');
    if (nonCash && confirmed) {
      for (final type in [tender, if (split) secondTender]) {
        if (_external(type) && references[type]!.text.trim().isEmpty) {
          return setState(() => error = 'Enter the $type payment reference.');
        }
      }
    }
    if (app.gst && !RegExp(r'^\d{2}$').hasMatch(place.text.trim())) {
      return setState(() => error = 'Enter the two-digit place-of-supply state code.');
    }
    final tenders = [
      {'type': tender, 'amount': _minor(amount.text), 'confirmed': !_external(tender) || confirmed, 'reference': references[tender]?.text.trim() ?? ''},
      if (split && _minor(second.text) > 0)
        {'type': secondTender, 'amount': _minor(second.text), 'confirmed': !_external(secondTender) || confirmed, 'reference': references[secondTender]?.text.trim() ?? ''},
    ];
    setState(() => busy = true);
    try {
      final invoice = await app.checkout(tenders: tenders, expectedTotal: widget.total, placeOfSupply: place.text);
      if (mounted) Navigator.pop(context, invoice);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final total = widget.total;
    final paid = _minor(amount.text) + (split ? _minor(second.text) : 0);
    final due = total - paid;
    final nonCash = _external(tender) || (split && _external(secondTender));
    final types = _types;
    if (secondTender == tender || !types.contains(secondTender)) {
      secondTender = types.firstWhere((t) => t != tender, orElse: () => tender);
    }
    final customer = app.customerById('${app.cart['customerId']}');
    final quick = <int>{
      total,
      for (final step in [10000, 20000, 50000, 200000]) (total / step).ceil() * step,
    }.where((v) => v >= total).take(4).toList();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _complete},
      child: PopScope(canPop: !busy, child: AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Take payment')),
          Text(app.money(total), style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              segments: [
                for (final t in types)
                  ButtonSegment(
                    value: t,
                    label: Text(t),
                    icon: Icon(t == 'Cash' ? Icons.payments_outlined : t == 'Card' ? Icons.credit_card : t == 'Credit' ? Icons.menu_book_outlined : Icons.qr_code_2),
                  ),
              ],
              selected: {tender},
              onSelectionChanged: (v) => setState(() {
                tender = v.first;
                if (secondTender == tender) secondTender = types.firstWhere((t) => t != tender, orElse: () => tender);
                confirmed = false;
                for (final c in references.values) { c.clear(); }
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: split ? '$tender amount' : 'Amount received'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _complete(),
            ),
            if (tender == 'Cash' && !split) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in quick)
                  ActionChip(
                    label: Text(v == total ? 'Exact' : app.money(v)),
                    onPressed: () => setState(() => amount.text = (v / 100).toStringAsFixed(2)),
                  ),
              ]),
            ],
            if (tender == 'Credit' && customer != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  "Added to ${customer['name']}'s account (udhaar). Balance before this sale: ${app.money(app.partyBalance('customers', '${customer['id']}'))}.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (types.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    split = !split;
                    second.text = split ? (max(0, total - _minor(amount.text)) / 100).toStringAsFixed(2) : '0.00';
                  }),
                  icon: Icon(split ? Icons.remove : Icons.call_split, size: 18),
                  label: Text(split ? 'Remove split payment' : 'Split payment'),
                ),
              ),
            if (split)
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey((tender, secondTender)),
                    initialValue: secondTender,
                    decoration: const InputDecoration(labelText: 'Second payment'),
                    items: [for (final t in types.where((t) => t != tender)) DropdownMenuItem(value: t, child: Text(t))],
                    onChanged: (v) => setState(() => secondTender = v ?? secondTender),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: second,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
            if (nonCash) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                onChanged: (v) => setState(() => confirmed = v),
                title: const Text('Payment confirmed by the card machine / UPI app'),
                subtitle: const Text('If not yet confirmed, the sale waits in Sync & audit.'),
              ),
              for (final type in {tender, if (split) secondTender}.where(_external))
                TextField(controller: references[type], decoration: InputDecoration(labelText: '$type payment reference')),
            ],
            if (app.gst) ...[
              const SizedBox(height: 12),
              TextField(
                controller: place,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Place of supply (state code)'),
              ),
            ],
            const SizedBox(height: 16),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: due > 0 ? const Color(0xFFFBEBE7) : Brand.mint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(due > 0 ? 'Still due' : 'Change to give',
                      style: TextStyle(fontWeight: FontWeight.w700, color: due > 0 ? Brand.danger : Brand.forest)),
                ),
                Text(app.money(due > 0 ? due : -due),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: due > 0 ? Brand.danger : Brand.forest, fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: busy || !app.online ? null : _complete,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            label: Text(app.online ? 'Complete sale' : 'Reconnect to complete sale'),
          ),
        ],
      )),
    );
  }
}
