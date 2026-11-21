// WS-B: Customer account actions: advances, credit limit, WhatsApp reminders,
// and the notes the checkout shows for the Credit and Advance tenders.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../purchasing/common.dart';
import '../theme.dart';
import '../widgets.dart';
import '../../core/receipt_print.dart' show openWhatsApp, whatsappUri;

const advanceModes = ['Cash', 'UPI', 'Card'];

/// The customer's credit limit in paise, or null when none is set.
int? creditLimitOf(Json? customer) {
  final limit = customer?['creditLimit'];
  return limit is num ? limit.toInt() : null;
}

/// Money held for the customer (advances and store credit) that a bill can use.
int availableAdvance(AppState app, String? customerId) {
  final balance = app.partyBalance('customers', customerId);
  return balance < 0 ? -balance : 0;
}

/// Take an advance (booking, part on order). Cash goes through the shift drawer.
Future<bool> takeAdvance(BuildContext context, Json customer) async {
  final app = context.appRead;
  final transactionId = uuid();
  final saved = await showFormDialog<bool>(
    context,
    title: 'Advance from ${customer['name']}',
    submit: 'Record advance',
    fields: [
      const FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true),
      FieldSpec('mode', 'Paid by', kind: FieldKind.select, required: true, value: 'Cash', options: [for (final m in advanceModes) (m, m)]),
      const FieldSpec('reference', 'UPI / card reference'),
      const FieldSpec('notes', 'For', help: 'For example: seat covers on order, booking for Saturday fitting.'),
    ],
    onSubmit: (v) async {
      final amount = amountMinor(v['amount']);
      if (amount <= 0) throw FormProblem('Enter the amount received.');
      if (v['mode'] != 'Cash' && '${v['reference'] ?? ''}'.trim().isEmpty) throw FormProblem('Enter the ${v['mode']} reference.');
      await app.mutate('/customers/${customer['id']}/advances', {
        'transactionId': transactionId,
        'amount': amount,
        'mode': v['mode'],
        'reference': v['reference'] ?? '',
        'notes': v['notes'] ?? '',
      }, 'Advance of ${app.money(amount)} recorded.');
      return true;
    },
  );
  return saved == true;
}

/// Give an advance back. Needs a manager (cashiers enter an approval ID).
Future<bool> refundAdvance(BuildContext context, Json customer, int available) async {
  final app = context.appRead;
  final transactionId = uuid();
  final saved = await showFormDialog<bool>(
    context,
    title: 'Give back advance to ${customer['name']}',
    submit: 'Give back',
    header: Text('Held for them: ${app.money(available)}'),
    fields: [
      FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true, value: plainAmount(available)),
      FieldSpec('mode', 'Given back by', kind: FieldKind.select, required: true, value: 'Cash', options: [for (final m in advanceModes) (m, m)]),
      const FieldSpec('reference', 'UPI / card reference'),
      const FieldSpec('reason', 'Reason', required: true),
      if (!app.isManager) FieldSpec('approvalId', 'Manager approval ID', required: true, help: 'Reference $transactionId'),
    ],
    onSubmit: (v) async {
      final amount = amountMinor(v['amount']);
      if (amount <= 0 || amount > available) throw FormProblem('Enter an amount up to ${app.money(available)}.');
      await app.mutate('/customers/${customer['id']}/advances/refund', {
        'transactionId': transactionId,
        'amount': amount,
        'mode': v['mode'],
        'reference': v['reference'] ?? '',
        'reason': v['reason'],
        if (!app.isManager) 'approvalId': v['approvalId'],
      }, 'Advance of ${app.money(amount)} given back.');
      return true;
    },
  );
  return saved == true;
}

/// Owner/manager: set or remove the customer's credit limit.
Future<bool> editCreditLimit(BuildContext context, Json customer) async {
  final app = context.appRead;
  final limit = creditLimitOf(customer);
  final saved = await showFormDialog<bool>(
    context,
    title: 'Credit limit for ${customer['name']}',
    fields: [
      FieldSpec('creditLimit', 'Most they may owe', kind: FieldKind.money, value: limit == null ? '' : plainAmount(limit),
          help: 'Leave empty for no limit. Enter 0 to stop selling on credit without a manager.'),
    ],
    onSubmit: (v) async {
      final text = '${v['creditLimit'] ?? ''}'.trim();
      final value = text.isEmpty ? null : parsePaymentAmount(text);
      if (text.isNotEmpty && value == null) throw FormProblem('Enter the limit in rupees, for example 5000.');
      await app.mutate('/customers/${customer['id']}/credit-limit', {'creditLimit': value},
          value == null ? 'Credit limit removed.' : 'Credit limit set to ${app.money(value)}.');
      return true;
    },
  );
  return saved == true;
}

/// wa.me link with the amount due (owner decision: share link, no Business API).
String reminderLink(AppState app, {required String phone, required String name, required int amount}) {
  final shop = '${app.business['tradingName'] ?? app.business['legalName'] ?? 'our shop'}';
  final text = 'Hello $name, this is a reminder from $shop. Your balance due is ${app.money(amount)}. '
      'Please pay at the counter or by UPI. Thank you.';
  return whatsappUri(phone, text).toString();
}

Future<void> sendReminder(BuildContext context, {required String phone, required String name, required int amount}) async {
  final app = context.appRead;
  if (phone.replaceAll(RegExp(r'\D'), '').length < 10) return app.toast('Add a 10-digit phone number for $name first.');
  // Integration: the shared WhatsApp launcher (opens on Android, web and Windows).
  await openWhatsApp(Uri.parse(reminderLink(app, phone: phone, name: name, amount: amount)), app.toast);
}

/// Shown in checkout under the Credit or Advance tender (tender_sheet.dart).
class AccountTenderNote extends StatelessWidget {
  const AccountTenderNote({super.key, required this.tender, required this.amount, required this.total});
  final String tender;
  final int amount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final customer = app.customerById('${app.cart['customerId']}');
    if (customer == null) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodySmall;
    if (tender == 'Advance') {
      final held = availableAdvance(app, '${customer['id']}');
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          amount > held
              ? 'Only ${app.money(held)} is held for ${customer['name']}.'
              : 'From ${customer['name']}\'s advance (${app.money(held)} held). ${app.money(held - amount)} stays on their account.',
          style: amount > held ? const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600) : style,
        ),
      );
    }
    if (tender != 'Credit') return const SizedBox.shrink();
    final limit = creditLimitOf(customer);
    if (limit == null) return const SizedBox.shrink();
    final after = app.partyBalance('customers', '${customer['id']}') + amount;
    if (after <= limit) {
      return Padding(padding: const EdgeInsets.only(top: 4), child: Text('Credit limit ${app.money(limit)}; they will owe ${app.money(after)}.', style: style));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('This takes ${customer['name']} to ${app.money(after)}, above their credit limit of ${app.money(limit)}.',
            style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
        if (!app.isManager)
          TextFormField(
            initialValue: '${app.cart['creditApprovalId'] ?? ''}',
            decoration: InputDecoration(labelText: 'Manager approval ID (credit limit)', helperText: 'Reference ${app.cart['transactionId']}'),
            onChanged: (v) => app.updateCart({'creditApprovalId': v.trim()}),
          ),
      ]),
    );
  }
}
