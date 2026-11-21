import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../screens/people.dart';
import 'counter_actions.dart';
import 'counter_keys.dart' show KeyCap;
import 'tender_sheet.dart';
import '../orders/exchange.dart' show ExchangeReturnsPanel; // WS-B

const _figures = [FontFeature.tabularFigures()];

/// The current sale: customer, price level, lines, totals, Hold and Checkout.
/// Listens to the cart (every scan) and to the register (online, catalog);
/// nothing above it rebuilds when a line is added.
class CartPanel extends StatelessWidget {
  const CartPanel({super.key, this.inSheet = false});
  final bool inSheet;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: Listenable.merge([app.cartState, app]),
      builder: (context, _) => _content(context, app),
    );
  }

  Widget _content(BuildContext context, AppState app) {
    final cart = app.cart;
    final lines = (cart['lines'] as List).cast<Map>();
    Quote? bill;
    String? billError;
    try {
      bill = app.currentQuote();
    } catch (error) {
      billError = errorText(error);
    }
    final vehicle = cart['vehicle'] as Map?;
    final needsApproval = vehicle != null &&
        lines.any((line) {
          final product = app.productById('${line['productId']}');
          return product != null &&
              fitment(product, Map<String, dynamic>.from(vehicle)).needsOverride &&
              '${line['overrideReason'] ?? ''}'.isEmpty;
        });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 10, 6),
        child: Row(children: [
          Expanded(child: Text('Current sale', style: Theme.of(context).textTheme.titleLarge)),
          if (lines.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'Clear this sale?', 'All items will be removed from the current bill.', action: 'Clear')) {
                  app.clearCart();
                }
              },
              child: const Text('Clear'),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: '${cart['customerId'] ?? ''}',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Walk-in customer')),
                for (final c in app.list('customers')) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')),
              ],
              onChanged: (value) => app.updateCart({'customerId': value ?? ''}),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.outlined(
            tooltip: 'New customer',
            onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) => app.updateCart({'customerId': saved['id']})),
            icon: const Icon(Icons.person_add_alt),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: 'retail', label: Text('Retail')), ButtonSegment(value: 'wholesale', label: Text('Wholesale'))],
          selected: {'${cart['priceLevel'] ?? 'retail'}'},
          onSelectionChanged: (v) => app.updateCart({'priceLevel': v.first}),
        ),
      ),
      const Divider(),
      Expanded(
        child: lines.isEmpty
            ? const EmptyState(message: 'No items yet.\nScan a barcode or tap a part.', icon: Icons.qr_code_2)
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                itemCount: lines.length,
                separatorBuilder: (_, _) => const Divider(height: 18),
                itemBuilder: (context, index) => _CartLine(index: index, line: bill?.lines.elementAtOrNull(index)),
              ),
      ),
      const ExchangeReturnsPanel(), // WS-B: items coming back in an exchange
      if (billError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: Text(billError, style: const TextStyle(color: Brand.danger)),
        ),
      if (needsApproval)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.verified_user_outlined, color: Brand.danger),
            onPressed: () => approveFitment(context),
            label: const Text('Record fitment approval'),
          ),
        ),
      Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Brand.line)), color: Color(0xFFFBFCFB)),
        child: Column(children: [
          _TotalRow('Subtotal${bill?.taxMode == 'inclusive' ? ' (incl. tax)' : ''}', app.money(bill?.subtotal ?? 0)),
          _TotalRow('${app.settings['taxDisplayName'] ?? 'Tax'}${bill?.taxMode == 'inclusive' ? ' included' : ''}',
              app.money(bill?.tax ?? 0)),
          if ((bill?.core ?? 0) > 0) _TotalRow('Core deposits', app.money(bill!.core)),
          InkWell(
            onTap: lines.isEmpty ? null : () => editDiscount(context),
            child: _TotalRow(
              'Discount',
              (bill?.discount ?? 0) > 0 ? '−${app.money(bill!.discount)}' : 'Add',
              accent: true,
            ),
          ),
          if ((bill?.rounding ?? 0) != 0) _TotalRow('Rounding', app.money(bill!.rounding)),
          const SizedBox(height: 6),
          Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            Text(app.money(bill?.total ?? 0), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8, fontFeatures: _figures)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: lines.isEmpty || billError != null || !app.online ? null : () => holdSale(context),
              icon: const Icon(Icons.pause, size: 18),
              label: const Text('Hold'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: lines.isEmpty || needsApproval || billError != null ? null : () async {
                  final transactionId = app.cart['transactionId'];
                  await startCheckout(context);
                  if (inSheet && context.mounted && app.cart['transactionId'] != transactionId &&
                      (app.cart['lines'] as List).isEmpty && ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.payments_outlined),
                label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Checkout'), KeyCap('F6', onDark: true)]),
              ),
            ),
          ]),
          if (!app.isManager)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText('Approval reference ${cart['transactionId']}',
                  style: const TextStyle(fontSize: 10, color: Brand.muted, fontFamily: 'monospace')),
            ),
        ]),
      ),
    ]);
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.value, {this.accent = false});
  final String label;
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: accent ? Brand.forest : Brand.muted, fontWeight: accent ? FontWeight.w700 : null))),
          Text(value, style: TextStyle(color: accent ? Brand.forest : Brand.ink, fontWeight: FontWeight.w600, fontFeatures: _figures)),
        ]),
      );
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.index, required this.line});
  final int index;
  final QuoteLine? line;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final raw = Map<String, dynamic>.from((app.cart['lines'] as List)[index] as Map);
    final product = app.productById('${raw['productId']}');
    final serial = product?['serialTracked'] == true;
    final vehicle = app.cart['vehicle'] as Map?;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${product?['name'] ?? raw['productId']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            '${app.money(line?.unitPrice ?? 0)} each${raw['binId'] != null ? ' · ${app.locationName('${raw['binId']}')}' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: _figures),
          ),
          if (vehicle != null && product != null)
            Text(
              '${titleCase(fitment(product, Map<String, dynamic>.from(vehicle)).status)}'
              '${'${raw['overrideReason'] ?? ''}'.isNotEmpty ? ' · override recorded' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: _figures),
            ),
          if ((raw['serials'] as List? ?? []).isNotEmpty)
            Text('Serials ${(raw['serials'] as List).join(', ')}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          _Stepper(
            value: raw['qty'] as int,
            enabled: !serial && product?['salesStopped'] != true,
            onChanged: (qty) => setLineQuantity(context, index, qty),
          ),
        ]),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          onPressed: () => setLineQuantity(context, index, 0),
          icon: const Icon(Icons.close, size: 18),
        ),
        Text(app.money(line?.total ?? 0), style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
      ]),
    ]);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged, this.enabled = true});
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Decrease quantity',
            onPressed: enabled ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove, size: 16),
          ),
          SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures))),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Increase quantity',
            onPressed: enabled ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add, size: 16),
          ),
        ]),
      );
}
