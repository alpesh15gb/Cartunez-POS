// WS-E: shared helpers for online order fulfilment (pick, invoice & pack, ship).
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../theme.dart';

int _n(Object? v) => (v as num?)?.toInt() ?? 0;

/// Units of a line the customer still gets: ordered less cancelled and refunded.
int shippedQty(Map line) => (_n(line['ordered']) - _n(line['canceled']) - _n(line['refunded'])).clamp(0, 1 << 30);

/// Units still to pick and invoice (not yet on a POS invoice).
int toPickQty(Map line) => (shippedQty(line) - _n(line['posInvoiced'])).clamp(0, 1 << 30);

Map<String, dynamic> fulfilmentOf(Json order) => Map<String, dynamic>.from(order['fulfilment'] as Map? ?? {});

/// Where the order is in Pick → Invoice & pack → Ship → Delivered.
String fulfilmentStage(Json order) {
  final f = fulfilmentOf(order);
  final shipment = f['shipment'] as Map?;
  if (f['status'] == 'delivered') return 'Delivered';
  if (shipment?['state'] == 'sent') return 'Shipped';
  if (shipment?['state'] == 'error' || shipment?['state'] == 'failed') return 'Shipment not sent';
  if (shipment != null) return 'Sending shipment';
  if (f['invoiceId'] != null) return 'Packed';
  return 'To pick';
}

/// Can the POS invoice this order? (Older orders had their stock taken when Magento invoiced them.)
bool canInvoice(Json order) =>
    order['mode'] == 'pos' && fulfilmentOf(order)['invoiceId'] == null &&
    (order['lines'] as List? ?? []).cast<Map>().any((l) => toPickQty(l) > 0);

bool canShip(Json order) {
  final f = fulfilmentOf(order);
  final sent = (f['shipment'] as Map?)?['state'] == 'sent';
  return !sent && (f['invoiceId'] != null || (order['mode'] != 'pos' && order['posState'] == 'sold'));
}

Widget stageChip(String stage) {
  final (bg, fg) = switch (stage) {
    'Delivered' || 'Shipped' => (Brand.mint, Brand.forest),
    'Shipment not sent' => (const Color(0xFFFBEBE7), Brand.danger),
    'Packed' || 'Sending shipment' => (const Color(0xFFFDF3DF), Brand.warning),
    _ => (const Color(0xFFEEF1EF), Brand.muted),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
    child: Text(stage, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
  );
}
