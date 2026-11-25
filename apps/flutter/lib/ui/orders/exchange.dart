// WS-B: Instant exchange on the counter bill.
//
// Items coming back sit in cart['returns'] (returnRef lines) beside the new
// items in cart['lines'], so the counter's pricing of new items is unchanged.
// At checkout the server issues the credit note and the invoice together
// (apps/api/src/hooks/exchange.ts); the customer pays the difference, or gets
// the excess back by cash/card/UPI or on their account.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../counter/tender_sheet.dart' show upiQrAvailable;
import '../counter/upi_qr.dart' show showUpiQr;
import '../theme.dart';
import '../widgets.dart';
import 'returns.dart';

List<Json> exchangeReturns(Json cart) =>
    [for (final r in cart['returns'] as List? ?? const []) Map<String, dynamic>.from(r as Map)];

/// Credit for everything coming back on the counter bill.
int exchangeCredit(Json cart) => exchangeReturns(cart).fold(0, (n, r) => n + ((r['credit'] ?? 0) as int));

/// Puts the chosen items of [invoice] on the counter as an exchange.
void addExchangeReturns(AppState app, Json invoice, List<Json> chosen, String reason) {
  final cart = app.cart;
  final customerId = '${cart['customerId'] ?? ''}'.isEmpty ? (invoice['customerId'] ?? '') : cart['customerId'];
  app.updateCart({
    'customerId': customerId,
    'returnReason': reason.isEmpty ? 'Exchange' : reason,
    'returns': [
      for (final c in chosen)
        {
          'kind': 'returnRef',
          'invoiceId': invoice['id'],
          'invoiceNumber': invoice['number'],
          'invoiceCustomerId': invoice['customerId'],
          'lineId': c['lineId'],
          'productId': c['productId'],
          'name': c['name'],
          'qty': c['quantity'],
          'disposition': c['disposition'],
          'serials': c['serials'],
          if (c['supplierId'] != null) 'supplierId': c['supplierId'],
          'credit': c['credit'],
        },
    ],
  });
}

void removeExchangeReturn(AppState app, int index) {
  final list = exchangeReturns(app.cart)..removeAt(index);
  app.updateCart({'returns': list});
}

/// The items coming back, shown in the counter cart (cart_table.dart).
class ExchangeReturnsPanel extends StatelessWidget {
  const ExchangeReturnsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: app.cartState,
      builder: (context, _) {
        final returns = exchangeReturns(app.cart);
        if (returns.isEmpty) return const SizedBox.shrink();
        int total;
        try {
          total = app.currentQuote().total;
        } catch (_) {
          total = 0;
        }
        final net = total - exchangeCredit(app.cart);
        return Container(
          margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Brand.mint, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Coming back · exchange against ${returns.first['invoiceNumber']}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.forest)),
            for (final (i, r) in returns.indexed)
              Row(children: [
                Expanded(child: Text('${r['name']} × ${r['qty']} · ${dispositionLabels[r['disposition']] ?? ''}')),
                Text('−${app.money(r['credit'] as num?)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                IconButton(
                  tooltip: 'Remove from exchange',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => removeExchangeReturn(app, i),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ]),
            const Divider(height: 12),
            Row(children: [
              Expanded(child: Text(net >= 0 ? 'Customer pays after exchange' : 'Credit remaining after exchange',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
              Text(app.money(net.abs()), style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
          ]),
        );
      },
    );
  }
}

/// Checkout for a bill with an exchange: settles the difference only.
Future<Json?> exchangeCheckout(BuildContext context, Quote bill) {
  final app = context.appRead;
  return showDialog<Json>(context: context, builder: (_) => AppScope(state: app, child: ExchangeCheckoutDialog(total: bill.total)));
}

class ExchangeCheckoutDialog extends StatefulWidget {
  const ExchangeCheckoutDialog({super.key, required this.total});
  final int total;
  @override
  State<ExchangeCheckoutDialog> createState() => _ExchangeCheckoutDialogState();
}

class _ExchangeCheckoutDialogState extends State<ExchangeCheckoutDialog> {
  late String method;
  late final TextEditingController cashReceived = TextEditingController(text: net > 0 ? (net / 100).toStringAsFixed(2) : '0.00');
  final reference = TextEditingController();
  final approval = TextEditingController();
  late final TextEditingController place;
  bool busy = false;
  String? error;

  int get credit => exchangeCredit(context.appRead.cart);
  int get net => widget.total - credit;

  List<String> get methods {
    final app = context.appRead;
    final cart = app.cart;
    final returns = exchangeReturns(cart);
    // Credit back to an account needs the original bill's customer; paying on credit needs this bill's customer.
    final account = net >= 0
        ? app.customerById('${cart['customerId']}') != null
        : returns.isNotEmpty && returns.first['invoiceCustomerId'] != null;
    return [if (net < 0) 'Original', ...app.tenderTypes, if (account) 'Credit'];
  }

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    method = methods.first;
    place = TextEditingController(
        text: '${app.customerById('${app.cart['customerId']}')?['stateCode'] ?? app.business['stateCode'] ?? ''}');
  }

  @override
  void dispose() {
    cashReceived.dispose();
    reference.dispose();
    approval.dispose();
    place.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    final app = context.appRead;
    setState(() => error = null);
    final external = method == 'Card' || method == 'UPI';
    int? cashAmount;
    if (net > 0 && method == 'Cash') {
      cashAmount = parsePaymentAmount(cashReceived.text);
      if (cashAmount == null || cashAmount < net) {
        return setState(() => error = 'Enter cash received of at least ${app.money(net)}.');
      }
    }
    if (net > 0 && external && reference.text.trim().isEmpty) return setState(() => error = 'Enter the $method payment reference.');
    if (!app.isManager && approval.text.trim().isEmpty) {
      return setState(() => error = 'A manager approval ID is needed for the return. Reference ${app.cart['transactionId']}');
    }
    if (app.gst && !RegExp(r'^\d{2}$').hasMatch(place.text.trim())) {
      return setState(() => error = 'Enter the two-digit place-of-supply state code.');
    }
    app.updateCart({
      if (!app.isManager) 'returnApprovalId': approval.text.trim(),
      'exchangeRefundType': net < 0 && method != 'Original' ? method : null,
    });
    final tenders = net > 0
        ? [{'type': method, 'amount': method == 'Cash' ? cashAmount! : net, 'confirmed': true, 'reference': reference.text.trim()}]
        : [{'type': 'Cash', 'amount': 0, 'confirmed': true, 'reference': ''}];
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
    final list = methods;
    if (!list.contains(method)) method = list.first;
    final cashParsed = net > 0 && method == 'Cash' ? parsePaymentAmount(cashReceived.text) : null;
    final cashChange = cashParsed != null && cashParsed > net ? cashParsed - net : 0;
    final quickCash = net <= 0
        ? const <int>[]
        : <int>{net, for (final step in [10000, 20000, 50000, 200000]) (net / step).ceil() * step}
            .where((v) => v >= net)
            .take(4)
            .toList();
    return AlertDialog(
      scrollable: true,
      title: const Text('Exchange'),
      content: SizedBox(
        width: 440,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _row('New items', app.money(widget.total)),
          _row('Credit for items coming back', '−${app.money(credit)}'),
          const Divider(),
          _row(net >= 0 ? 'Customer pays' : 'Credit remaining', app.money(net.abs()), big: true),
          if (net < 0) const Text('Complete the exchange to see the refund for each payment method.'),
          const SizedBox(height: 12),
          if (net != 0) ...[
            Text(net > 0 ? 'Paid by' : 'Give back by', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final m in list)
                ChoiceChip(
                  label: Text(m == 'Original' ? 'Same as paid' : m == 'Credit' ? (net > 0 ? 'On account' : 'Store credit') : m),
                  selected: method == m,
                  onSelected: (_) => setState(() => method = m),
                ),
            ]),
          ],
          if (net > 0 && method == 'Cash') ...[
            const SizedBox(height: 10),
            TextField(
              controller: cashReceived,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: 'Cash received'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final v in quickCash)
                ActionChip(
                  label: Text(v == net ? 'Exact' : app.money(v)),
                  onPressed: () => setState(() => cashReceived.text = (v / 100).toStringAsFixed(2)),
                ),
            ]),
            if (cashChange > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Change to give: ${app.money(cashChange)}',
                    style: const TextStyle(color: Brand.forest, fontWeight: FontWeight.w700)),
              ),
          ],
          if (net > 0 && method == 'UPI' && upiQrAvailable(app))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: FilledButton.tonalIcon(
                onPressed: busy
                    ? null
                    : () async {
                        final ref = await showUpiQr(context, amount: net, note: 'Exch ${app.cart['transactionId']}'.substring(0, 14));
                        if (ref != null && mounted) setState(() => reference.text = ref);
                      },
                icon: const Icon(Icons.qr_code_2),
                label: Text('UPI QR checkout · ${app.money(net)}'),
              ),
            ),
          if (net > 0 && (method == 'Card' || method == 'UPI')) ...[
            const SizedBox(height: 8),
            TextField(controller: reference, decoration: InputDecoration(labelText: '$method payment reference')),
          ],
          if (!app.isManager) ...[
            const SizedBox(height: 8),
            TextField(
              controller: approval,
              decoration: InputDecoration(labelText: 'Manager approval ID (return)', helperText: 'Reference ${app.cart['transactionId']}'),
            ),
          ],
          if (app.gst) ...[
            const SizedBox(height: 8),
            TextField(controller: place, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Place of supply (state code)')),
          ],
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: busy || !app.online ? null : _complete,
          icon: const Icon(Icons.check),
          label: Text(app.online ? 'Complete exchange' : 'Reconnect to complete'),
        ),
      ],
    );
  }
}

Widget _row(String label, String value, {bool big = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: big ? 17 : 13, fontWeight: big ? FontWeight.w800 : FontWeight.w400))),
        Text(value, style: TextStyle(fontSize: big ? 20 : 13, fontWeight: big ? FontWeight.w800 : FontWeight.w600)),
      ]),
    );
