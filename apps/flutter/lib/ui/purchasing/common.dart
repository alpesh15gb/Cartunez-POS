// Shared helpers for purchasing: supplier bills, returns, payments and ledgers.

import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../state/app_state.dart';
import '../theme.dart';

const paymentModes = ['Cash', 'UPI', 'Bank transfer', 'Cheque', 'Card'];

String billToday() => DateTime.now().toIso8601String().substring(0, 10);
int amountMinor(Object? text) => parsePaymentAmount('${text ?? ''}'.trim().isEmpty ? '0' : '$text') ?? 0;
String plainAmount(int minor) => (minor / 100).toStringAsFixed(2);
/// Supplier bill totals, the same rules the API posts (purchasing.ts `billTotals`):
/// items (+ GST per line on a GST bill, rounded half up) + freight − discount.
({int subtotal, int tax, int total}) supplierBillTotals(Iterable<Json> lines, {required bool gst, int otherCharges = 0, int discount = 0}) {
  var subtotal = 0, tax = 0;
  for (final l in lines) {
    final amount = ((l['quantity'] ?? 0) as num).toInt() * ((l['cost'] ?? 0) as num).toInt();
    subtotal += amount;
    if (gst) tax += (amount * ((l['taxRate'] ?? 0) as num).toInt() + 5000) ~/ 10000;
  }
  return (subtotal: subtotal, tax: tax, total: subtotal + tax + otherCharges - discount);
}

/// What stays on the supplier's account after paying [paid] now (never below zero).
/// Plain comparison, no `clamp(0, 1 << 40)`: on the web `1 << 40` is 0, which made the preview always ₹0.
int supplierBillDue(int total, int paid) => total - paid > 0 ? total - paid : 0;

String percentText(int basis) => basis % 100 == 0 ? '${basis ~/ 100}' : (basis / 100).toStringAsFixed(2);

/// "We owe ₹4,300" / "Advance ₹200" for suppliers; "Owes us" / "Advance" for customers.
String balanceText(AppState app, String kind, int balance) {
  if (balance == 0) return 'Settled';
  if (kind == 'suppliers') return balance > 0 ? 'You owe ${app.money(balance)}' : 'Advance ${app.money(-balance)}';
  return balance > 0 ? 'Owes ${app.money(balance)}' : 'Advance ${app.money(-balance)}';
}

Color balanceColor(int balance) => balance > 0 ? Brand.danger : balance < 0 ? Brand.forest : Brand.muted;

Widget sumRow(String label, String value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
        Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 17 : null)),
      ]),
    );

String? defaultBin(AppState app, String productId) {
  final stocked = app.list('stock').where((s) => s['productId'] == productId && ((s['quantity'] ?? 0) as num) > 0)
      .map((s) => '${s['binId']}').where((id) => app.sellableBins.any((b) => b['id'] == id));
  return stocked.firstOrNull ?? app.sellableBins.firstOrNull?['id'] as String?;
}
