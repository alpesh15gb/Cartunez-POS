import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../shell.dart';
import '../widgets.dart';
import 'bills.dart';

Future<void> editContact(BuildContext context, String kind, Json contact, {void Function(Json saved)? onSaved}) async {
  final app = context.appRead;
  final gst = app.gst;
  final noun = kind == 'customers' ? 'customer' : 'supplier';
  await showFormDialog<void>(
    context,
    title: '${contact['id'] == null ? 'Add' : 'Edit'} $noun',
    expanded: ['email', 'address', 'taxRegistrationId', 'stateCode'].any((k) => '${contact[k] ?? ''}'.isNotEmpty),
    fields: [
      FieldSpec('name', 'Name', value: contact['name'], required: true),
      FieldSpec('phone', 'Phone', kind: FieldKind.phone, value: contact['phone']),
      FieldSpec('email', 'Email', kind: FieldKind.email, value: contact['email'], advanced: true),
      FieldSpec('address', 'Address', kind: FieldKind.multiline, value: contact['address'], advanced: !gst),
      FieldSpec('taxRegistrationId', 'GSTIN / tax registration', value: contact['taxRegistrationId'], advanced: !gst),
      FieldSpec('stateCode', 'State code',
          value: contact['stateCode'], advanced: !gst, help: gst ? 'Two digits, for example 27 for Maharashtra.' : null),
      if (app.isManager)
      FieldSpec('openingBalance', kind == 'customers' ? 'Old balance they owe you' : 'Old balance you owe them',
          value: ((contact['openingBalance'] ?? 0) as num) % 100 == 0
              ? '${((contact['openingBalance'] ?? 0) as num) ~/ 100}'
              : (((contact['openingBalance'] ?? 0) as num) / 100).toStringAsFixed(2),
          advanced: contact['id'] != null,
          help: 'From before using the POS, in rupees. Use a minus sign for an advance.'),
    ],
    onSubmit: (values) async {
      if (app.isManager) {
        final opening = double.tryParse('${values['openingBalance'] ?? '0'}'.trim().isEmpty ? '0' : '${values['openingBalance']}'.trim());
        if (opening == null) throw FormProblem('Enter the old balance as a number, for example 1500 or -200.');
        values['openingBalance'] = (opening * 100).round();
        // Dated once, so it stays before the bills and sales that follow.
        if ('${contact['openingDate'] ?? ''}'.isEmpty && values['openingBalance'] != 0) {
          values['openingDate'] = DateTime.now().toIso8601String().substring(0, 10);
        }
      }
      final saved = await app.mutate('/$kind', {...contact, ...values}, '${titleCase(noun)} saved.');
      onSaved?.call(Map<String, dynamic>.from(saved as Map));
    },
  );
}

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key, required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final rows = app.list(kind).where((r) => q.isEmpty || normalize('${r['name']} ${r['phone']} ${r['email']} ${r['taxRegistrationId']}').contains(q)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            FilledButton.icon(
              onPressed: () => editContact(context, kind, const {}),
              icon: const Icon(Icons.add),
              label: Text(kind == 'customers' ? 'Add customer' : 'Add supplier'),
            ),
            Builder(builder: (context) {
              final total = rows.fold<int>(0, (n, r) => n + app.partyBalance(kind, '${r['id']}'));
              if (total == 0) return const SizedBox.shrink();
              return Text(kind == 'customers' ? 'Customers owe you ${app.money(total)} in total' : 'You owe suppliers ${app.money(total)} in total',
                  style: TextStyle(fontWeight: FontWeight.w700, color: balanceColor(total)));
            }),
          ]),
          DataList(
            rows: rows,
            empty: kind == 'customers' ? 'No customers yet. Walk-in sales need none.' : 'No suppliers yet.',
            // WS-B: a customer opens their 360 page; suppliers keep the ledger.
            onTap: (row) => kind == 'customers' ? shell.open('/people/customers/${row['id']}') : showLedger(context, kind, row),
            columns: [
              Col('Name', (r) => Text('${r['name']}'), flex: 2),
              for (final (title, key) in const [('Phone', 'phone'), ('GSTIN', 'taxRegistrationId')])
                Col(title, (r) {
                  final value = '${r[key] ?? ''}'.trim();
                  return Text(value.isEmpty ? '—' : value);
                }),
              Col('Balance', (r) {
                final balance = app.partyBalance(kind, '${r['id']}');
                return Text(balanceText(app, kind, balance), style: TextStyle(color: balanceColor(balance), fontWeight: FontWeight.w700));
              }, numeric: true),
            ],
          ),
        ]);
      },
    );
  }
}
