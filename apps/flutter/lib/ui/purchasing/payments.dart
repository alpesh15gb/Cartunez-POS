
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';
import 'common.dart';

// ---------------------------------------------------------------- payments and ledgers

/// Pay a supplier, or receive money from a customer. [refund] goes the other way.
Future<void> recordPayment(BuildContext context, String kind, Json party, {bool refund = false}) async {
  final app = context.appRead;
  final balance = app.partyBalance(kind, '${party['id']}');
  final supplier = kind == 'suppliers';
  final title = supplier
      ? (refund ? 'Money received back from ${party['name']}' : 'Pay ${party['name']}')
      : (refund ? 'Give money back to ${party['name']}' : 'Receive payment from ${party['name']}');
  await showFormDialog<void>(
    context,
    title: title,
    submit: 'Save',
    fields: [
      FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true,
          value: !refund && balance > 0 ? plainAmount(balance) : null, help: balanceText(app, kind, balance)),
      FieldSpec('mode', 'Paid by', kind: FieldKind.select, required: true, value: 'Cash', options: [for (final m in paymentModes) (m, m)]),
      const FieldSpec('reference', 'UPI / cheque / transaction reference'),
      FieldSpec('date', 'Date', value: billToday(), help: 'YYYY-MM-DD'),
      const FieldSpec('notes', 'Notes'),
    ],
    onSubmit: (v) async {
      final amount = amountMinor(v['amount']);
      if (amount <= 0) throw FormProblem('Enter the amount.');
      await app.mutate('/party-payments', {
        'partyKind': supplier ? 'supplier' : 'customer',
        'partyId': party['id'],
        'amount': amount,
        'mode': v['mode'],
        'reference': v['reference'] ?? '',
        'date': '${v['date'] ?? ''}'.trim().isEmpty ? billToday() : '${v['date']}'.trim(),
        'notes': v['notes'] ?? '',
        if (refund) 'refund': true,
      }, 'Payment saved.');
    },
  );
}
