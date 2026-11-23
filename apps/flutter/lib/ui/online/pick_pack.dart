// WS-E: pick & pack one online order: scan items (and serials), invoice & pack
// (a GST invoice from the POS), packing slip, courier + tracking to Magento,
// delivered (cash on delivery collected), bank transfer / UPI payment received,
// and the credit note when the website cancelled or refunded after invoicing.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../barcode_scan.dart';
import '../orders/returns.dart' show findReturnable, startReturn;
import '../purchasing/common.dart' show paymentModes, amountMinor, plainAmount;
import '../theme.dart';
import '../widgets.dart';
import 'fulfilment.dart';
import 'packing_slip.dart';

Future<void> openPickPack(BuildContext context, String orderId) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PickPackPage(orderId: orderId)),
    );

/// Online only: a line the shop orders from the supplier for this customer
/// (nothing to pick; invoiced as a non-stock line).
bool orderFromSupplierLine(AppState app, Map line) =>
    line['onlineOnly'] == true || isOnlineOnly(app.productById('${line['productId']}'));

/// Online-only lines of the order still to send.
bool hasSupplierLines(AppState app, Json order) =>
    order['mode'] == 'pos' &&
    (order['supplierPurchaseNeeded'] as bool? ?? (order['lines'] as List? ?? []).cast<Map>().any((l) => shippedQty(l) > ((l['shipped'] ?? 0) as num) && orderFromSupplierLine(app, l)));

/// "Create purchase order": draft orders to each online-only part's usual
/// supplier, linked to the website order. Parts without a supplier are asked for.
Future<void> createOrderPurchase(BuildContext context, Json order) async {
  final app = context.appRead;
  final path = '/online-orders/${order['id']}/purchase-order';
  try {
    final result = await app.mutate(path, {}) as Map?;
    final created = (result?['purchaseOrderIds'] as List? ?? []).length;
    final missing = (result?['needsSupplier'] as List? ?? []).cast<Map>();
    if (missing.isEmpty) {
      app.toast('$created purchase order${created == 1 ? '' : 's'} created as draft. Check and place ${created == 1 ? 'it' : 'them'} in Purchasing › Orders.');
      return;
    }
    if (!context.mounted) return;
    final suppliers = app.list('suppliers');
    if (suppliers.isEmpty) {
      app.toast('Add a supplier in Purchasing first, then create the purchase order.');
      return;
    }
    await showFormDialog<void>(
      context,
      title: 'Choose the supplier',
      submit: 'Create purchase order',
      fields: [
        for (final m in missing)
          FieldSpec('${m['productId']}', '${m['quantity']} × ${m['name']}', kind: FieldKind.select, required: true, options: optionsOf(suppliers),
              help: '${m['sku']} has no usual supplier.'),
      ],
      onSubmit: (v) async {
        final again = await app.mutate(path, {'suppliers': v}) as Map?;
        final more = created + (again?['purchaseOrderIds'] as List? ?? []).length;
        app.toast('$more purchase order${more == 1 ? '' : 's'} created as draft. Check and place ${more == 1 ? 'it' : 'them'} in Purchasing › Orders.');
      },
    );
  } catch (e) {
    app.toast(errorText(e));
  }
}

class PickPackPage extends StatefulWidget {
  const PickPackPage({super.key, required this.orderId});
  final String orderId;
  @override
  State<PickPackPage> createState() => _PickPackPageState();
}

class _PickPackPageState extends State<PickPackPage> {
  /// itemId → picked units and serials.
  final picked = <Object, ({int qty, List<String> serials})>{};
  final scan = TextEditingController();
  final scanFocus = FocusNode();
  final courier = TextEditingController();
  final tracking = TextEditingController();
  bool busy = false;
  String? message;
  bool messageIsError = false;

  @override
  void dispose() {
    for (final c in [scan, courier, tracking]) {
      c.dispose();
    }
    scanFocus.dispose();
    super.dispose();
  }

  Json? get order => context.appRead.list('onlineOrders').where((o) => o['id'] == widget.orderId).firstOrNull;

  List<Map> _due(Json o) => (o['lines'] as List? ?? []).cast<Map>().where((l) => toPickQty(l) > 0).toList();

  /// Lines picked from the shelves (online-only lines come from the supplier).
  List<Map> _toPick(Json o) => _due(o).where((l) => !orderFromSupplierLine(context.appRead, l)).toList();

  int _picked(Map line) => picked[line['itemId']]?.qty ?? 0;

  void _say(String text, {bool error = false}) => setState(() {
        message = text;
        messageIsError = error;
      });

  bool _serialTracked(AppState app, Map line) => app.productById('${line['productId']}')?['serialTracked'] == true;

  Future<void> _add(Map line, {String? serial}) async {
    final app = context.appRead;
    final current = picked[line['itemId']] ?? (qty: 0, serials: <String>[]);
    if (current.qty >= toPickQty(line)) return _say('All ${toPickQty(line)} × ${line['name']} are already picked.', error: true);
    var serials = current.serials;
    if (_serialTracked(app, line)) {
      serial ??= await _askSerial(line);
      if (serial == null || serial.trim().isEmpty) return;
      if (serials.contains(serial.trim())) return _say('Serial $serial is already picked.', error: true);
      serials = [...serials, serial.trim()];
    }
    setState(() => picked[line['itemId'] as Object] = (qty: current.qty + 1, serials: serials));
    _say('Picked ${line['name']} (${current.qty + 1} of ${toPickQty(line)}).');
  }

  void _remove(Map line) {
    final current = picked[line['itemId']];
    if (current == null || current.qty == 0) return;
    setState(() => picked[line['itemId'] as Object] =
        (qty: current.qty - 1, serials: current.serials.isEmpty ? current.serials : current.serials.sublist(0, current.serials.length - 1)));
  }

  Future<String?> _askSerial(Map line) => showFormDialog<String>(
        context,
        title: 'Serial number',
        submit: 'Add',
        fields: [FieldSpec('serial', 'Serial of ${line['name']}', required: true, barcodeInput: true)],
        onSubmit: (v) async => '${v['serial']}'.trim(),
      );

  /// A scanned barcode or SKU picks one unit of the matching line.
  Future<void> handleCode(String raw) async {
    final code = raw.trim();
    scan.clear();
    if (code.isEmpty) return;
    final app = context.appRead;
    final o = order;
    if (o == null) return;
    final productId = app.uniqueProductIdForCode(code);
    final supplierLine = _due(o).where((l) => orderFromSupplierLine(app, l) &&
        ((productId != null && l['productId'] == productId) || '${l['sku']}'.toUpperCase() == code.toUpperCase())).firstOrNull;
    if (supplierLine != null) {
      _say('${supplierLine['name']} is ordered from the supplier. Nothing to pick.', error: true);
      if (mounted) scanFocus.requestFocus();
      return;
    }
    final lines = _toPick(o);
    final match = lines.where((l) => productId != null && l['productId'] == productId).toList()
      ..addAll(lines.where((l) => '${l['sku']}'.toUpperCase() == code.toUpperCase()));
    final open = match.where((l) => _picked(l) < toPickQty(l)).firstOrNull;
    if (match.isEmpty) {
      _say('$code is not on this order. Check the item.', error: true);
    } else if (open == null) {
      _say('All units of ${match.first['name']} are already picked.', error: true);
    } else {
      await _add(open);
    }
    if (mounted) scanFocus.requestFocus();
  }

  Future<void> _camera() async {
    final code = await requestBarcode(context);
    if (code != null && mounted) await handleCode(code);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      _say(errorText(e), error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _invoice(Json o) => _run(() async {
        final app = context.appRead;
        final result = await app.mutate('/online-orders/${o['id']}/invoice', {
          'picks': [
            for (final l in _toPick(o))
              {'itemId': l['itemId'], 'qty': _picked(l), if ((picked[l['itemId']]?.serials ?? []).isNotEmpty) 'serials': picked[l['itemId']]!.serials},
          ],
        }, 'Invoice made. Pack the order and print the packing slip.');
        final number = ((result as Map?)?['invoice'] as Map?)?['number'];
        _say('Invoiced${number == null ? '' : ' as $number'}. Print the packing slip, then enter the courier.');
      });

  Future<void> _ship(Json o) => _run(() async {
        final app = context.appRead;
        if (courier.text.trim().isEmpty || tracking.text.trim().isEmpty) {
          throw FormProblem('Enter the courier and the tracking number.');
        }
        await app.mutate('/online-orders/${o['id']}/ship', {'courier': courier.text.trim(), 'tracking': tracking.text.trim()});
        await _push();
      });

  Future<void> _push() async {
    final app = context.appRead;
    try {
      final r = await app.api('/online-orders/shipments/push', body: {});
      await app.sync();
      _say((r as Map?)?['failed'] == 0 ? 'Shipment and tracking sent to Magento.' : 'Magento did not take the shipment yet. It will be retried.',
          error: r?['failed'] != 0);
    } catch (e) {
      await app.sync();
      _say('Saved. Magento will be updated shortly (${errorText(e)}).', error: true);
    }
  }

  Future<void> _retry(Json o) => _run(() async {
        await context.appRead.mutate('/online-orders/${o['id']}/shipment/retry', {});
        await _push();
      });

  /// Bank transfer / UPI: the customer's money arrived; recorded with its reference.
  Future<void> _paymentReceived(Json o) async {
    final app = context.appRead;
    final f = fulfilmentOf(o);
    await showFormDialog<void>(
      context,
      title: 'Payment received',
      submit: 'Record payment',
      fields: [
        FieldSpec('amount', 'Amount received', kind: FieldKind.money, required: true, value: plainAmount(paymentDue(f)),
            help: 'For invoice ${f['invoiceNumber']}. It is recorded on the customer\'s account, then Magento is invoiced.'),
        FieldSpec('mode', 'Received by', kind: FieldKind.select, value: 'UPI',
          options: [('UPI', 'UPI'), ('Bank transfer', 'Bank transfer'), if (f['cod'] == true) ('Cash','Cash')]),
        if (f['cod'] == true) const FieldSpec('cashSource', 'For cash collections', kind: FieldKind.select, value: 'courier',
          options: [('courier','Held outside the drawer'),('drawer','Received in counter drawer')]),
        const FieldSpec('reference', 'UPI / bank reference (UTR)', required: true),
      ],
      onSubmit: (v) async {
        await app.mutate('/online-orders/${o['id']}/payment-received', {
          'amount': amountMinor(v['amount']),
          'mode': v['mode'],
          if (v['mode'] == 'Cash') 'fromDrawer': v['cashSource'] == 'drawer',
          'reference': '${v['reference']}'.trim(),
        }, 'Payment recorded. Magento will be invoiced.');
        await _push();
      },
    );
  }

  /// Opens the return form for the order's invoice (Orders › Returns & exchange).
  Future<void> _makeCreditNote(Map flag) => _run(() async {
        final app = context.appRead;
        final rows = await findReturnable(app, '${flag['invoiceNumber']}');
        final row = rows.where((r) => r['id'] == flag['invoiceId']).firstOrNull;
        if (row == null) throw FormProblem('Invoice ${flag['invoiceNumber']} was not found. Open Orders › Returns & exchange.');
        if (!mounted) return;
        await startReturn(context, row);
      });

  Future<void> _resolveCreditNote(Json o, {bool notNeeded = false}) async {
    final app = context.appRead;
    if (!notNeeded) {
      return _run(() async {
        await app.mutate('/online-orders/${o['id']}/credit-note/resolve', {}, 'Credit note recorded. The shipment can go now.');
      });
    }
    await showFormDialog<void>(
      context,
      title: 'No credit note needed',
      submit: 'Save',
      fields: [const FieldSpec('reason', 'Why no credit note is needed', required: true)],
      onSubmit: (v) async {
        await app.mutate('/online-orders/${o['id']}/credit-note/resolve', {'reason': '${v['reason']}'.trim()}, 'Saved.');
      },
    );
  }

  Future<void> _delivered(Json o) async {
    final app = context.appRead;
    final f = fulfilmentOf(o);
    final cod = f['cod'] == true && ((f['codDue'] as num?) ?? 0) > 0 && f['invoiceVoided'] == null;
    await showFormDialog<void>(
      context,
      title: 'Mark delivered',
      submit: cod ? 'Record payment · delivered' : 'Mark delivered',
      fields: [
        if (cod) ...[
          FieldSpec('amount', 'Amount collected', kind: FieldKind.money, required: true, value: plainAmount((f['codDue'] as num).toInt()),
              help: 'Cash on delivery for invoice ${f['invoiceNumber']}. It is recorded on the customer\'s account.'),
          FieldSpec('mode', 'Received by', kind: FieldKind.select, value: 'Bank transfer', options: [for (final m in paymentModes) (m, m)]),
          const FieldSpec('reference', 'Courier remittance reference'),
          const FieldSpec('cashSource', 'For cash collections', kind: FieldKind.select, value: 'courier',
            options: [('courier','Held outside the drawer'),('drawer','Received in counter drawer')]),
        ],
      ],
      onSubmit: (v) async {
        await app.mutate('/online-orders/${o['id']}/delivered', {
          if (cod) ...{'amount': amountMinor(v['amount']), 'mode': v['mode'], if (v['mode'] == 'Cash') 'fromDrawer': v['cashSource'] == 'drawer',
            if ('${v['reference'] ?? ''}'.isNotEmpty) 'reference': v['reference']},
        }, cod ? 'Payment recorded. Order delivered.' : 'Order marked delivered.');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final o = order;
    if (o == null) {
      return Scaffold(appBar: AppBar(title: const Text('Pick & pack')), body: const EmptyState(message: 'This order is no longer on this device.'));
    }
    final f = fulfilmentOf(o);
    final shipment = f['shipment'] == null ? null : Map<String, dynamic>.from(f['shipment'] as Map);
    final due = _due(o);
    final invoicing = canInvoice(o);
    final toPick = _toPick(o);
    final allPicked = due.isNotEmpty && toPick.every((l) => _picked(l) == toPickQty(l));
    final supplierLines = due.where((l) => orderFromSupplierLine(app, l)).toList();
    final unknown = due.where((l) => l['productId'] == null).toList();
    final small = Theme.of(context).textTheme.bodySmall;
    final customer = (o['customer'] as Map?) ?? {};
    return Scaffold(
      appBar: AppBar(title: Text('Order #${o['number']}'), actions: [
        Padding(padding: const EdgeInsets.only(right: 12), child: Center(child: stageChip(fulfilmentStage(o)))),
      ]),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text('${customer['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              if ('${o['shipTo'] ?? ''}'.isNotEmpty) Text('${o['shipTo']}', style: small),
              Text([
                'Total ${app.money(o['total'] as num?)}',
                if ('${(o['payment'] as Map?)?['title'] ?? ''}'.isNotEmpty) '${(o['payment'] as Map)['title']}',
              ].join(' · '), style: small),
              if (message != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: messageIsError ? const Color(0xFFFBEBE7) : Brand.mint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(message!, style: TextStyle(color: messageIsError ? Brand.danger : Brand.forest, fontWeight: FontWeight.w600)),
                ),
              if (creditNoteNeeded(o) case final flag?)
                Container(
                  key: const ValueKey('credit-note-needed'),
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFFBEBE7), borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Credit note needed', style: TextStyle(color: Brand.danger, fontWeight: FontWeight.w800)),
                    Text('The website cancelled or refunded ${[
                      for (final l in (flag['lines'] as List? ?? []).cast<Map>()) '${l['qty']} × ${l['name'] ?? l['sku']}',
                    ].join(', ')} after invoice ${flag['invoiceNumber']} was made. Make the credit note for those items; the shipment waits until then.'),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                          onPressed: busy ? null : () => _makeCreditNote(flag),
                          icon: const Icon(Icons.assignment_return_outlined),
                          label: const Text('Make credit note')),
                      OutlinedButton(onPressed: busy ? null : () => _resolveCreditNote(o), child: const Text('Credit note made')),
                      TextButton(onPressed: busy ? null : () => _resolveCreditNote(o, notNeeded: true), child: const Text('Not needed')),
                    ]),
                  ]),
                ),
              if (f['invoiceVoided'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Invoice ${(f['invoiceVoided'] as Map)['invoiceNumber']} was voided after the goods left. Nothing can be collected against it.',
                      style: const TextStyle(color: Brand.danger)),
                ),
              if (o['mode'] != 'pos' && f['invoiceId'] == null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('This older order had its stock taken when Magento invoiced it. Ship it without a POS invoice.'),
                ),
              if (hasSupplierLines(app, o))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      onPressed: busy || !app.isManager ? null : () => createOrderPurchase(context, o),
                      icon: const Icon(Icons.add_shopping_cart, size: 18),
                      label: const Text('Create purchase order'),
                    ),
                  ),
                ),
              // ---------- 1. Pick ----------
              if (invoicing) ...[
                const SectionTitle('1. Pick'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('pick-scan'),
                      controller: scan,
                      focusNode: scanFocus,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: handleCode,
                      decoration: const InputDecoration(labelText: 'Scan or type barcode / SKU', prefixIcon: Icon(Icons.qr_code_scanner)),
                    ),
                  ),
                  if (supportsBarcodeCamera)
                    IconButton(tooltip: 'Scan with camera', onPressed: _camera, icon: const Icon(Icons.photo_camera_outlined)),
                ]),
                const SizedBox(height: 8),
                // Online only: ordered from the supplier for this customer, no scan or bin.
                for (final l in supplierLines)
                  Card(
                    key: ValueKey('supplier-line-${l['itemId']}'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        const Icon(Icons.local_shipping_outlined, color: Brand.forest),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text('${l['sku']} · Order from supplier', style: small),
                          ]),
                        ),
                        Text('${toPickQty(l)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
                for (final l in toPick)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Icon(_picked(l) == toPickQty(l) ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: _picked(l) == toPickQty(l) ? Brand.forest : Brand.muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text([
                              '${l['sku']}',
                              if (l['productId'] != null) _bins(app, '${l['productId']}'),
                              if ((picked[l['itemId']]?.serials ?? []).isNotEmpty) 'Serials ${picked[l['itemId']]!.serials.join(', ')}',
                            ].where((s) => s.isNotEmpty).join(' · '), style: small),
                          ]),
                        ),
                        Text('${_picked(l)} / ${toPickQty(l)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        IconButton(tooltip: 'Remove one', onPressed: _picked(l) > 0 ? () => _remove(l) : null, icon: const Icon(Icons.remove_circle_outline)),
                        IconButton(tooltip: 'Pick one', onPressed: l['productId'] == null || _picked(l) >= toPickQty(l) ? null : () => _add(l),
                            icon: const Icon(Icons.add_circle_outline)),
                      ]),
                    ),
                  ),
                if (unknown.isNotEmpty)
                  Text('${unknown.map((l) => l['sku']).join(', ')} is not in the POS catalogue. Add a part with that SKU first.',
                      style: const TextStyle(color: Brand.danger)),
                // ---------- 2. Invoice & pack ----------
                const SectionTitle('2. Invoice & pack'),
                FilledButton.icon(
                  onPressed: busy || !allPicked ? null : () => _invoice(o),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(allPicked ? 'Invoice & pack' : 'Pick every item to invoice'),
                ),
              ],
              if (f['invoiceId'] != null) ...[
                const SectionTitle('Invoice & packing slip'),
                Text('Invoice ${f['invoiceNumber']} · ${app.money(f['invoiceTotal'] as num?)} · ${paymentLabel(f)}'
                    '${paymentDue(f) > 0 ? ' · ${app.money(paymentDue(f))} not received yet' : f['paymentKind'] == 'bank' ? ' · received' : ''}'),
                if (f['magentoInvoice'] is Map)
                  Text(switch ((f['magentoInvoice'] as Map)['state']) {
                    'sent' => 'Magento invoice made.',
                    'skipped' => 'Magento was already invoiced.',
                    'queued' => 'Magento invoice waiting to be made.',
                    _ => 'Magento invoice not made yet: ${(f['magentoInvoice'] as Map)['error'] ?? ''}',
                  }, style: small),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (paymentDue(f) > 0)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : () => _paymentReceived(o),
                      icon: const Icon(Icons.currency_rupee),
                      label: const Text('Payment received'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await printPackingSlip(app, o);
                      } catch (e) {
                        _say('The packing slip could not be printed. ${errorText(e)}', error: true);
                      }
                    },
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print packing slip'),
                  ),
                ]),
              ],
              // ---------- 3. Ship ----------
              if (canShip(o) && (shipment == null || shipment['state'] == 'error' || shipment['state'] == 'failed')) ...[
                const SectionTitle('3. Courier & tracking'),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  SizedBox(width: 220, child: TextField(controller: courier, decoration: const InputDecoration(labelText: 'Courier'))),
                  SizedBox(width: 260, child: TextField(controller: tracking, decoration: const InputDecoration(labelText: 'Tracking number'))),
                ]),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: busy ? null : () => _ship(o),
                  icon: const Icon(Icons.local_shipping_outlined),
                  label: Text(shipment == null ? 'Ship & send tracking to Magento' : 'Send with this tracking'),
                ),
              ],
              if (shipment != null) ...[
                const SectionTitle('Shipment'),
                Text('${shipment['courier']} · ${shipment['tracking']}'),
                Text(switch (shipment['state']) {
                  'sent' when shipment['note'] != null => 'On Magento. ${shipment['note']}',
                  'sent' => 'On Magento. The customer was notified.',
                  'queued' => 'Waiting to send to Magento.',
                  'held' => '${shipment['error']}',
                  'cancelled' => '${shipment['error'] ?? 'Nothing is left to ship on Magento.'}',
                  'failed' => 'Magento did not accept it after several tries: ${shipment['error']}',
                  _ => 'Not sent yet (${shipment['attempts'] ?? 0} tries): ${shipment['error']}. It is retried automatically.',
                }, style: TextStyle(color: shipment['state'] == 'sent' ? Brand.forest : shipment['state'] == 'queued' ? null : Brand.danger)),
                if (shipment['state'] != 'sent' && shipment['state'] != 'cancelled' && creditNoteNeeded(o) == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(onPressed: busy ? null : () => _retry(o), icon: const Icon(Icons.refresh), label: const Text('Send again now')),
                  ),
              ],
              // ---------- 4. Delivered ----------
              if (shipment != null && shipment['state'] != 'cancelled' && f['status'] != 'delivered') ...[
                const SectionTitle('4. Delivery'),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => _delivered(o),
                  icon: const Icon(Icons.done_all),
                  label: Text(f['cod'] == true && f['invoiceVoided'] == null ? 'Delivered · record COD payment' : 'Mark delivered'),
                ),
              ],
              if (f['status'] == 'delivered')
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('Delivered ${formatDate(f['deliveredAt'])}.', style: const TextStyle(color: Brand.forest, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back), label: const Text('Back to online orders')),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Where to find the part: bins with stock, fullest first.
  String _bins(AppState app, String productId) {
    final rows = app.list('stock').where((s) => s['productId'] == productId && ((s['quantity'] as num?) ?? 0) > 0).toList()
      ..sort((a, b) => ((b['quantity'] as num?) ?? 0).compareTo((a['quantity'] as num?) ?? 0));
    if (rows.isEmpty) return 'No stock recorded';
    return rows.take(2).map((s) => '${app.locationName('${s['binId']}')} (${s['quantity']})').join(', ');
  }
}
