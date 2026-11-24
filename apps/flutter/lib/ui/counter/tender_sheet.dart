import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../shift/shift_dialogs.dart' show showOpenShiftDialog; // WS-D
import 'counter_flow.dart'; // WS-A: after-sale screen
import 'upi_qr.dart'; // WS-A: static UPI QR
import '../orders/exchange.dart' show exchangeReturns, exchangeCheckout; // WS-B
import '../people/account_actions.dart' show AccountTenderNote, availableAdvance; // WS-B

// ---------------- checkout ----------------

/// WS-A: [split] opens with a second payment (F10), [tender] preselects a
/// payment type, [print] prints the receipt as soon as the sale completes (F12).
Future<void> startCheckout(BuildContext context, {bool split = false, String? tender, bool print = false}) async {
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
  final blocker = checkoutBlocker(app);
  if (blocker != null) {
    app.toast(blocker);
    return;
  }
  final bill = app.currentQuote();
  // WS-B: a bill with items coming back (exchange) settles only the difference.
  if (exchangeReturns(app.cart).isNotEmpty) {
    final swapped = await exchangeCheckout(context, bill);
    // WS-A after-sale screen (print, WhatsApp, next customer) for exchanges too.
    if (swapped != null && context.mounted) await afterSale(context, swapped, print: print);
    return;
  }
  final invoice = await showDialog<Json>(
    context: context,
    builder: (_) => AppScope(state: app, child: CheckoutDialog(total: bill.total, initialSplit: split, initialTender: tender)),
  );
  if (invoice != null && context.mounted) await afterSale(context, invoice, print: print);
}

/// QA #9: the UPI QR needs the shop's UPI ID (Settings › Counter payments).
bool upiQrAvailable(AppState app) => app.settings['currency'] == 'INR' && '${app.settings['upiVpa'] ?? ''}'.trim().isNotEmpty;

// WS-D: opening float with quick amounts lives in lib/ui/shift/shift_dialogs.dart.
Future<bool> openShiftDialog(BuildContext context, {bool forCheckout = false}) =>
    showOpenShiftDialog(context, forCheckout: forCheckout);

class CheckoutDialog extends StatefulWidget {
  const CheckoutDialog({super.key, required this.total, this.initialSplit = false, this.initialTender});
  final int total;
  final bool initialSplit;
  final String? initialTender;
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
  // QA #9: true when the UPI part was confirmed from the QR screen (vs checked by hand).
  bool viaQr = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    tender = widget.initialTender != null && _types.contains(widget.initialTender)
        ? widget.initialTender!
        : app.tenderTypes.contains('Cash') ? 'Cash' : app.tenderTypes.first;
    secondTender = _types.firstWhere((t) => t != tender, orElse: () => tender);
    if (widget.initialSplit && _types.length > 1) {
      split = true;
      amount.text = '0.00';
      second.text = (widget.total / 100).toStringAsFixed(2);
    }
    place = TextEditingController(
        text: '${app.customerById('${app.cart['customerId']}')?['stateCode'] ?? app.business['stateCode'] ?? ''}');
  }

  int _minor(String text) => parsePaymentAmount(text) ?? 0;

  /// Payment types for this sale: "Credit" (on the customer's account) needs a chosen customer.
  List<String> get _types {
    final app = context.appRead;
    final customer = app.customerById('${app.cart['customerId']}');
    return [
      ...app.tenderTypes,
      if (customer != null) 'Credit',
      // WS-B: offered when money is held for the customer (advance or store credit).
      if (customer != null && availableAdvance(app, '${customer['id']}') > 0) 'Advance',
    ];
  }

  static bool _external(String type) => type != 'Cash' && type != 'Credit' && type != 'Advance'; // WS-B: Advance

  String? _paymentAllocationError(int? firstAmount, int? secondAmount) {
    if (firstAmount == null || secondAmount == null) {
      return 'Enter a valid amount for each payment, with up to two decimal places.';
    }
    if (split && (firstAmount == 0 || secondAmount == 0 || tender == secondTender)) {
      return 'Choose two different payment methods and enter an amount for each.';
    }
    final nonCash = (tender == 'Cash' ? 0 : firstAmount) + (secondTender == 'Cash' ? 0 : secondAmount);
    return nonCash > widget.total ? 'Non-cash payments cannot exceed the bill total.' : null;
  }

  void resetConfirmation() {
    confirmed = false;
    viaQr = false;
    error = null;
    for (final controller in references.values) { controller.clear(); }
  }

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
    if (!app.online) return;
    final firstAmount = parsePaymentAmount(amount.text);
    final secondAmount = split ? parsePaymentAmount(second.text) : 0;
    final allocationError = _paymentAllocationError(firstAmount, secondAmount);
    final nonCash = _external(tender) || (split && _external(secondTender));
    setState(() => error = null);
    if (allocationError != null) return setState(() => error = allocationError);
    if (firstAmount! + secondAmount! < widget.total) return setState(() => error = 'Payment must cover the total.');
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
      {'type': tender, 'amount': firstAmount, 'confirmed': !_external(tender) || confirmed, 'reference': references[tender]?.text.trim() ?? ''},
      if (split)
        {'type': secondTender, 'amount': secondAmount, 'confirmed': !_external(secondTender) || confirmed, 'reference': references[secondTender]?.text.trim() ?? ''},
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

  /// UI polish: a centred dialog on tablets and desktops; on phones a
  /// full-screen sheet with a spaced title row and the actions pinned below.
  Widget _frame({required bool phone, required String amountText, required Widget content, required List<Widget> actions}) {
    const figures = [FontFeature.tabularFigures()];
    if (!phone) {
      return AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Take payment')),
          const SizedBox(width: 16),
          Text(amountText, style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: figures)),
        ]),
        scrollable: true,
        content: content,
        actions: actions,
      );
    }
    final theme = Theme.of(context);
    return Dialog.fullscreen(
      key: const ValueKey('checkout-fullscreen'),
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
            child: Row(children: [
              IconButton(tooltip: 'Cancel', onPressed: busy ? null : () => Navigator.pop(context), icon: const Icon(Icons.close)),
              const SizedBox(width: 4),
              Expanded(child: Text('Take payment', style: theme.textTheme.titleLarge)),
              const SizedBox(width: 12),
              Text(amountText, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontFeatures: figures)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), child: content)),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                i == actions.length - 1 ? Expanded(child: actions[i]) : actions[i],
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final total = widget.total;
    final phone = MediaQuery.sizeOf(context).width < 600;
    final types = _types;
    if (secondTender == tender || !types.contains(secondTender)) {
      secondTender = types.firstWhere((t) => t != tender, orElse: () => tender);
    }
    final firstAmount = parsePaymentAmount(amount.text);
    final secondAmount = split ? parsePaymentAmount(second.text) : 0;
    final due = total - (firstAmount ?? 0) - (secondAmount ?? 0);
    final allocationError = _paymentAllocationError(firstAmount, secondAmount);
    final canPay = allocationError == null && due <= 0;
    final statusError = allocationError ?? error;
    final nonCash = _external(tender) || (split && _external(secondTender));
    final upiAmount = (tender == 'UPI' ? firstAmount : secondAmount) ?? 0;
    final customer = app.customerById('${app.cart['customerId']}');
    final quick = <int>{
      total,
      for (final step in [10000, 20000, 50000, 200000]) (total / step).ceil() * step,
    }.where((v) => v >= total).take(4).toList();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _complete},
      child: PopScope(canPop: !busy, child: _frame(
        phone: phone,
        amountText: app.money(total),
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
                    label: Text(t, maxLines: 1, softWrap: false),
                    icon: phone && types.length > 3 ? null : Icon(t == 'Cash' ? Icons.payments_outlined : t == 'Card' ? Icons.credit_card : t == 'Credit' ? Icons.menu_book_outlined : Icons.qr_code_2),
                  ),
              ],
              selected: {tender},
              onSelectionChanged: (v) => setState(() {
                tender = v.first;
                // WS-B: offer the customer's advance, up to the bill total.
                if (tender == 'Advance') {
                  final held = availableAdvance(app, '${app.cart['customerId']}');
                  amount.text = (min(held, total) / 100).toStringAsFixed(2);
                  if (held < total) split = true;
                  second.text = (max(0, total - held) / 100).toStringAsFixed(2);
                } else if (!split && tender != 'Cash') {
                  amount.text = (total / 100).toStringAsFixed(2);
                }
                if (secondTender == tender) secondTender = types.firstWhere((t) => t != tender, orElse: () => tender);
                resetConfirmation();
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
              onChanged: (_) => setState(resetConfirmation),
              onSubmitted: (_) => _complete(),
            ),
            if (tender == 'Cash' && !split) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in quick)
                  ActionChip(
                    label: Text(v == total ? 'Exact' : app.money(v)),
                    onPressed: () => setState(() {
                      amount.text = (v / 100).toStringAsFixed(2);
                      resetConfirmation();
                    }),
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
            // WS-B: credit limit and advance notes.
            for (final t in {tender, if (split) secondTender})
              AccountTenderNote(tender: t, amount: (t == tender ? firstAmount : secondAmount) ?? 0, total: total),
            if (types.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    split = !split;
                    if (!split && tender != 'Cash' && tender != 'Advance') {
                      amount.text = (total / 100).toStringAsFixed(2);
                    }
                    resetConfirmation();
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
                    onChanged: (v) => setState(() { secondTender = v ?? secondTender; resetConfirmation(); }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: second,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount'),
                    onChanged: (_) => setState(resetConfirmation),
                  ),
                ),
              ]),
            // WS-A: static UPI QR for the UPI part of the payment.
            // QA #9: offered only when the shop has a UPI ID; otherwise disabled with a Settings link.
            if (tender == 'UPI' || (split && secondTender == 'UPI'))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('show-upi-qr'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: busy || !app.online || !canPay || !upiQrAvailable(app) || upiAmount <= 0
                        ? null
                        : () async {
                            final ref = await showUpiQr(context, amount: upiAmount, note: 'Bill ${app.cart['transactionId']}'.substring(0, 13));
                            if (ref == null || !mounted) return;
                            setState(() {
                              // A QR confirmation covers only its UPI leg. A second external tender needs a separate manual check.
                              confirmed = !split || !_external(tender == 'UPI' ? secondTender : tender);
                              viaQr = true;
                              references['UPI']!.text = ref;
                            });
                          },
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(canPay && upiAmount > 0 ? 'UPI QR checkout · ${app.money(upiAmount)}' : 'UPI QR checkout'),
                  ),
                  if (app.settings['currency'] != 'INR')
                    const Text('UPI QR requires an INR bill.')
                  else if (!upiQrAvailable(app))
                    Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text('No UPI ID set, so no QR.', style: Theme.of(context).textTheme.bodySmall),
                      if (app.isManager)
                        TextButton(
                          key: const ValueKey('set-upi-id'),
                          onPressed: busy
                              ? null
                              : () {
                                  // Leave checkout for Settings; the cart stays on the counter.
                                  final router = GoRouter.maybeOf(context);
                                  Navigator.pop(context);
                                  router?.go('/settings');
                                },
                          child: const Text('Set UPI ID in Settings'),
                        )
                      else
                        Text(' Ask the owner to set the UPI ID in Settings.', style: Theme.of(context).textTheme.bodySmall),
                    ])
                  else if (viaQr && confirmed)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Confirmed on the UPI QR screen.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.forest)),
                    ),
                ]),
              ),
            if (nonCash) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                onChanged: !canPay ? null : (v) => setState(() {
                  confirmed = v;
                  viaQr = false;
                }),
                // QA #9: this is the manually verified path (no QR): the cashier checked the machine / app.
                title: Text(phone ? 'Payment confirmed (checked manually)' : 'Payment confirmed: checked on the card machine / UPI app'),
                subtitle: Text(confirmed
                    ? 'The sale is saved as paid.'
                    : phone
                        ? 'Off: the sale is saved as a pending payment in Sync & audit until someone confirms it.'
                        : 'Off: saved as a pending payment in Sync & audit until confirmed.'),
              ),
              for (final type in {tender, if (split) secondTender}.where(_external))
                TextField(controller: references[type], decoration: InputDecoration(labelText: '$type payment reference'),
                  onChanged: (_) {
                    if (viaQr && type == 'UPI') setState(() { confirmed = false; viaQr = false; });
                  }),
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
            if (allocationError == null && due != 0) AnimatedContainer(
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
            if (statusError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(statusError, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: busy || !app.online || !canPay ? null : _complete,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            // QA #8: with card / UPI not confirmed, the sale is saved as a pending payment.
            label: Text(!app.online
                ? 'Reconnect to complete sale'
                : nonCash && !confirmed
                    ? 'Save pending payment'
                    : 'Complete sale'),
          ),
        ],
      )),
    );
  }
}
