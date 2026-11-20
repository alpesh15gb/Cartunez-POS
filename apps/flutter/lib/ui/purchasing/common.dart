// Shared helpers for purchasing: supplier bills, returns, payments and ledgers.

import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../state/app_state.dart';
import '../theme.dart';

const paymentModes = ['Cash', 'UPI', 'Bank transfer', 'Cheque', 'Card'];

String billToday() => DateTime.now().toIso8601String().substring(0, 10);
int amountMinor(Object? text) => parsePaymentAmount('${text ?? ''}'.trim().isEmpty ? '0' : '$text') ?? 0;
String plainAmount(int minor) => (minor / 100).toStringAsFixed(2);
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
