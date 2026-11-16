import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../shell.dart';
import '../widgets.dart';

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
    ],
    onSubmit: (values) async {
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
          ]),
          DataList(
            rows: rows,
            empty: kind == 'customers' ? 'No customers yet. Walk-in sales need none.' : 'No suppliers yet.',
            onTap: (row) => editContact(context, kind, row),
            columns: [
              Col('Name', (r) => Text('${r['name']}'), flex: 2),
              Col('Phone', (r) => Text('${r['phone'] ?? '—'}')),
              Col('Email', (r) => Text('${(r['email'] ?? '').toString().isEmpty ? '—' : r['email']}'), flex: 2),
              Col('GSTIN', (r) => Text('${(r['taxRegistrationId'] ?? '').toString().isEmpty ? '—' : r['taxRegistrationId']}')),
            ],
          ),
        ]);
      },
    );
  }
}
