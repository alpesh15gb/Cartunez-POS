import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'labels.dart';
import 'online.dart';

// WS-D: StaffScreen (staff and counter PINs) moved to lib/ui/shift/.
export '../shift/staff_screen.dart' show StaffScreen;

const _featureLabels = {
  'fitment': 'Vehicle fitment',
  'transfers': 'Branch transfers',
  'warranty': 'Warranty & cores',
  'onlineStore': 'Online store (Magento)',
  'negativeStock': 'Sell parts even when stock shows zero',
};

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final business = app.business;
    final incomplete = '${business['legalName'] ?? ''}'.isEmpty || '${business['address'] ?? ''}'.isEmpty;
    final cards = [
      if (app.isOwner)
        _Card(title: 'Shop', children: [
          Text('${business['tradingName'] ?? business['legalName'] ?? 'Your business'}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${app.snapshot['branch']?['name'] ?? ''}${'${business['taxRegistrationId'] ?? ''}'.isNotEmpty ? ' · GSTIN ${business['taxRegistrationId']}' : ''}'),
          Text('${app.gst ? 'India GST' : 'General tax'} · prices ${app.settings['taxMode'] == 'inclusive' ? 'include' : 'exclude'} tax · ${app.tenderTypes.join(', ')}'),
          Text('Modules on: ${allFeatures.where(app.feature).map((f) => _featureLabels[f]).join(', ').ifEmpty('billing and stock only')}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: () => editBusiness(context), child: const Text('Business details')),
            OutlinedButton(onPressed: () => editRegister(context), child: const Text('Register settings')),
            OutlinedButton(onPressed: () => editModules(context), child: const Text('Modules')),
          ]),
        ]),
      _Card(title: 'You', children: [
        Text('${app.session?.user['name'] ?? ''} · ${titleCase(app.role)}', style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('${app.snapshot['branch']?['name'] ?? ''} · signed in until ${formatDate(app.session?.expiresAt)}'),
        Text('Last updated ${formatDate(app.lastSync)}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (app.isManager) OutlinedButton(onPressed: () => issueApproval(context), child: const Text('Issue approval')),
          OutlinedButton.icon(
            onPressed: () async {
              if (app.pending.isNotEmpty &&
                  !await confirm(context, 'Sign out?', '${app.pending.length} sale(s) are still waiting to send. They stay on this device and send after the next sign-in.',
                      action: 'Sign out')) {
                return;
              }
              await app.logout();
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ]),
      ]),
      if (app.isManager && app.feature('onlineStore'))
        _Card(title: 'Online store', children: [
          Text(app.magentoConnected ? 'Magento: ${app.magento['baseUrl']}' : 'Magento not connected',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(app.magentoConnected ? 'Stock, prices and published parts are kept up to date automatically.' : 'Connect your Magento store to publish parts.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (app.isOwner) OutlinedButton(onPressed: () => editMagento(context), child: Text(app.magentoConnected ? 'Magento settings' : 'Connect Magento')),
            if (app.magentoConnected) OutlinedButton(onPressed: () => testMagento(context), child: const Text('Test connection')),
          ]),
        ]),
      _Card(title: 'Barcode labels', children: [
        Text(labelPrinterSummary(app), style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('Shows ${labelDesignSummary(app)}.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: () => editLabelDesign(context), child: Text(app.isOwner ? 'Design label' : 'View design')),
          OutlinedButton(onPressed: () => editLabelPrinter(context), child: const Text('Printer')),
          OutlinedButton.icon(onPressed: () => printTestLabel(context), icon: const Icon(Icons.qr_code_2, size: 18), label: const Text('Print test label')),
        ]),
      ]),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (app.isOwner && incomplete)
        Card(
          color: const Color(0xFFF2F7EE),
          child: ListTile(
            leading: const Icon(Icons.storefront, color: Brand.forest),
            title: const Text('Finish setting up your shop'),
            subtitle: const Text('Add the legal business name and address. They are printed on every receipt.'),
            trailing: FilledButton(onPressed: () => editBusiness(context), child: const Text('Add details')),
          ),
        ),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final two = c.maxWidth > 760 && cards.length > 1;
        return two
            ? IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (i, card) in cards.indexed) ...[if (i > 0) const SizedBox(width: 14), Expanded(child: card)],
                ]),
              )
            : Column(children: [for (final card in cards) Padding(padding: const EdgeInsets.only(bottom: 14), child: card)]);
      }),
      if (app.isOwner) ...[
        SectionTitle('Branches', trailing: OutlinedButton.icon(onPressed: () => editBranch(context, const {}), icon: const Icon(Icons.add), label: const Text('Add branch'))),
        DataList(
          rows: app.list('branches'),
          onTap: (b) => editBranch(context, b),
          columns: [
            Col('Code', (b) => Text('${b['id']}')),
            Col('Name', (b) => Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
            Col('Address', (b) => Text('${(b['address'] ?? '').toString().isEmpty ? '—' : b['address']}'), flex: 2),
          ],
        ),
      ],
    ]);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 3), child: c),
          ]),
        ),
      );
}

Future<void> editBusiness(BuildContext context) async {
  final app = context.appRead;
  final b = app.business;
  final branch = Map<String, dynamic>.from(app.snapshot['branch'] as Map? ?? {});
  await showFormDialog<void>(
    context,
    title: 'Business details',
    fields: [
      FieldSpec('legalName', 'Legal business name', value: b['legalName'], required: true),
      FieldSpec('tradingName', 'Shop name on receipts', value: b['tradingName']),
      FieldSpec('address', 'Registered address', kind: FieldKind.multiline, value: b['address'], required: true),
      FieldSpec('taxRegistrationId', 'GSTIN / tax registration', value: b['taxRegistrationId']),
      FieldSpec('stateCode', 'State code', value: b['stateCode']),
      FieldSpec('phone', 'Phone', kind: FieldKind.phone, value: b['phone']),
      FieldSpec('email', 'Email', kind: FieldKind.email, value: b['email']),
      FieldSpec('branchName', 'This branch name', value: branch['name'], required: true),
      FieldSpec('branchAddress', 'This branch address', kind: FieldKind.multiline, value: branch['address'], advanced: true),
      FieldSpec('branchStateCode', 'This branch state code', value: branch['stateCode'], advanced: true),
      FieldSpec('receiptFooter', 'Receipt footer', kind: FieldKind.multiline, value: app.settings['receiptFooter'], advanced: true),
    ],
    onSubmit: (v) async {
      final business = {for (final k in ['legalName', 'tradingName', 'address', 'taxRegistrationId', 'stateCode', 'phone', 'email']) k: v[k]};
      await app.mutate('/settings', {
        'business': business,
        'branchName': v['branchName'],
        'branchAddress': v['branchAddress'],
        'branchStateCode': v['branchStateCode'],
        'receiptFooter': v['receiptFooter'],
      }, 'Business details saved. Earlier receipts keep their original details.');
    },
  );
}

Future<void> editRegister(BuildContext context) async {
  final app = context.appRead;
  final s = app.settings;
  final symbol = app.money(0).replaceAll(RegExp(r'[\d.,\s]'), '');
  final rounding = [('1', 'No rounding'), ('50', 'Nearest ${symbol}0.50'), ('100', 'Nearest ${symbol}1'), ('1000', 'Nearest ${symbol}10')];
  await showFormDialog<void>(
    context,
    title: 'Register settings',
    fields: [
      FieldSpec('taxScheme', 'Tax', kind: FieldKind.select, value: s['taxScheme'] ?? 'general', options: const [
        ('general', 'General tax'),
        ('india-gst', 'India GST (domestic sales)'),
      ], help: 'GST needs the business GSTIN and state, and an HSN/SAC on each part.'),
      FieldSpec('taxMode', 'Catalog prices', kind: FieldKind.select, value: s['taxMode'] ?? 'exclusive', options: const [
        ('exclusive', 'Exclude tax (added at billing)'),
        ('inclusive', 'Include tax (MRP style)'),
      ]),
      FieldSpec('taxRates', 'Tax rates offered (%)', value: (s['taxRates'] as List? ?? []).map((r) => (r as int) / 100).join(', '), required: true),
      FieldSpec('tenderTypes', 'Payments accepted', kind: FieldKind.checks, value: app.tenderTypes, options: const [
        ('Cash', 'Cash'),
        ('Card', 'Card'),
        ('UPI', 'UPI'),
      ]),
      FieldSpec('roundingIncrement', 'Round bill totals to', kind: FieldKind.select, value: '${s['roundingIncrement'] ?? 1}', options: rounding),
      FieldSpec('cashierDiscountLimit', 'Cashier can discount up to', kind: FieldKind.money,
          value: ((s['cashierDiscountLimit'] ?? 0) as int) / 100, help: 'Larger discounts need a manager approval.'),
      FieldSpec('invoicePrefix', 'Invoice number prefix', value: s['invoicePrefix'], required: true),
      FieldSpec('creditNotePrefix', 'Credit note prefix', value: s['creditNotePrefix'] ?? 'CR', advanced: true),
      FieldSpec('nextInvoice', 'Next invoice number', kind: FieldKind.number, value: s['nextInvoice'], advanced: true, help: 'Can only move forward.'),
      FieldSpec('taxDisplayName', 'Tax label on receipts', value: s['taxDisplayName'] ?? 'Tax', advanced: true),
      FieldSpec('localTaxName', 'Local GST component', kind: FieldKind.select, value: s['localTaxName'] ?? 'SGST', advanced: true,
          options: const [('SGST', 'SGST (states)'), ('UTGST', 'UTGST (union territories)')]),
      FieldSpec('sessionHours', 'Sign staff out after (hours)', kind: FieldKind.number, value: s['sessionHours'], advanced: true),
    ],
    onSubmit: (v) async {
      if ((v['tenderTypes'] as List).isEmpty) throw FormProblem('Choose at least one payment type.');
      final rates = splitList(v['taxRates']).map(parsePaymentAmount).toList();
      if (rates.isEmpty || rates.any((r) => r == null || r > 10000)) {
        throw FormProblem('Enter tax rates between 0 and 100, separated by commas, with up to two decimal places.');
      }
      await app.mutate('/settings', {
        'taxScheme': v['taxScheme'],
        'taxMode': v['taxMode'],
        'taxRates': rates,
        'tenderTypes': v['tenderTypes'],
        'roundingIncrement': int.tryParse('${v['roundingIncrement']}') ?? 1,
        'cashierDiscountLimit': ((double.tryParse('${v['cashierDiscountLimit']}') ?? 0) * 100).round(),
        'invoicePrefix': v['invoicePrefix'],
        'creditNotePrefix': '${v['creditNotePrefix']}'.isEmpty ? 'CR' : v['creditNotePrefix'],
        'taxDisplayName': '${v['taxDisplayName']}'.isEmpty ? 'Tax' : v['taxDisplayName'],
        'localTaxName': v['localTaxName'],
        if ('${v['nextInvoice']}'.isNotEmpty && '${v['nextInvoice']}' != '${s['nextInvoice']}') 'nextInvoice': int.tryParse('${v['nextInvoice']}'),
        if ('${v['sessionHours']}'.isNotEmpty) 'sessionHours': int.tryParse('${v['sessionHours']}'),
      }, 'Register settings saved.');
    },
  );
}

Future<void> editModules(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'Modules',
    header: const Text('Switch on only what the shop uses. Hidden modules keep their records.'),
    fields: [
      FieldSpec('features', 'Modules', kind: FieldKind.checks,
          value: allFeatures.where(app.feature).toList(), options: [for (final f in _featureLabels.entries) (f.key, f.value)]),
    ],
    onSubmit: (v) async {
      final on = (v['features'] as List).toSet();
      await app.mutate('/settings', {'features': {for (final f in allFeatures) f: on.contains(f)}}, 'Modules updated.');
    },
  );
}

Future<void> editUser(BuildContext context, Json user) async {
  final app = context.appRead;
  final self = user['id'] == app.session?.userId;
  await showFormDialog<void>(
    context,
    title: user['id'] == null ? 'Add staff' : 'Edit ${user['name']}',
    fields: [
      FieldSpec('name', 'Name', value: user['name'], required: true),
      FieldSpec('email', 'Email (used to sign in)', kind: FieldKind.email, value: user['email'], required: true),
      FieldSpec('password', user['id'] == null ? 'Password (12+ characters)' : 'New password (leave blank to keep)',
          kind: FieldKind.password, required: user['id'] == null),
      FieldSpec('role', 'Role', kind: FieldKind.select, value: user['role'] ?? 'cashier', required: true, options: const [
        ('cashier', 'Cashier — sells and takes returns'),
        ('inventory', 'Inventory — stock and purchasing'),
        ('manager', 'Manager — everything except settings'),
        ('owner', 'Owner — full access'),
      ]),
      FieldSpec('branchIds', 'Branches',
          kind: FieldKind.checks,
          value: (user['branchIds'] as List?) ?? [app.session?.branchId],
          options: [for (final b in app.list('branches')) ('${b['id']}', '${b['name']}')]),
      FieldSpec('active', 'Access', kind: FieldKind.select, value: '${user['active'] ?? true}', options: const [
        ('true', 'Active'),
        ('false', 'Disabled'),
      ]),
    ],
    onSubmit: (v) async {
      if ((v['branchIds'] as List).isEmpty) throw FormProblem('Choose at least one branch.');
      final body = {...user, ...v, 'active': v['active'] == 'true'};
      if ('${v['password']}'.isEmpty) body.remove('password');
      await app.api('/users', body: body);
      if (self) {
        app.toast('Your access changed. Sign in again.');
        await app.logout();
      } else {
        await app.sync();
        app.toast('Staff saved.');
      }
    },
  );
}

Future<void> editBranch(BuildContext context, Json branch) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: branch['id'] == null ? 'Add branch' : 'Edit branch',
    fields: [
      if (branch['id'] == null) const FieldSpec('id', 'Branch code', required: true, help: 'Lowercase letters, numbers and hyphens.'),
      FieldSpec('name', 'Branch name', value: branch['name'], required: true),
      FieldSpec('address', 'Address', kind: FieldKind.multiline, value: branch['address']),
      FieldSpec('stateCode', 'State code', value: branch['stateCode']),
    ],
    onSubmit: (v) async => app.mutate('/branches', {...branch, ...v}, 'Branch saved.'),
  );
}

Future<void> issueApproval(BuildContext context) async {
  final app = context.appRead;
  final id = await showFormDialog<String>(
    context,
    title: 'Issue approval',
    submit: 'Issue',
    fields: const [
      FieldSpec('action', 'For', kind: FieldKind.select, required: true, options: [
        ('discount', 'Discount above the cashier limit'),
        ('return', 'Return or refund'),
        ('fitment', 'Part that may not fit the vehicle'),
        ('adjustment', 'Stock adjustment'),
      ]),
      FieldSpec('transactionId', 'Reference shown on the cashier\'s screen', required: true),
      FieldSpec('reason', 'Reason', required: true),
    ],
    onSubmit: (v) async => '${(await app.api('/approvals', body: v) as Map)['id']}',
  );
  if (id == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Approval issued'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Read this ID to the cashier. It works once and expires in 15 minutes.'),
        const SizedBox(height: 12),
        SelectableText(id, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      ]),
      actions: [FilledButton(onPressed: () => Navigator.pop(dialog), child: const Text('Done'))],
    ),
  );
}

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(
          onPressed: app.syncing ? null : () => app.sync(loud: true),
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
        ),
      ]),
      SectionTitle('Waiting on this device'),
      DataList(
        rows: app.pending,
        empty: 'Nothing waiting. Every sale has reached the server.',
        columns: [
          Col('Created', (e) => Text(formatDate(e['createdAt']))),
          Col('Total', (e) => Text(app.money(e['total'] as num?)), numeric: true),
          Col('Status', (e) => e['error'] != null
              ? Text('${e['error']}', style: const TextStyle(color: Brand.danger))
              : StatusChip(e['status'] == 'awaiting-payment' ? 'Awaiting payment' : 'Waiting to send')),
        ],
        actions: (e) => [
          if (e['status'] == 'awaiting-payment')
            FilledButton.tonal(
              onPressed: () => showFormDialog<void>(
                context,
                title: 'Confirm card / UPI payment',
                submit: 'Confirm',
                fields: [
                  for (final type in {for (final t in e['transaction']['tenders']) if (t['type'] != 'Cash' && t['confirmed'] != true) t['type']})
                    FieldSpec('$type', '$type payment reference', required: true),
                ],
                onSubmit: (v) => app.confirmPayment('${e['transaction']['transactionId']}', v),
              ),
              child: const Text('Confirm payment'),
            ),
          if (e['error'] != null || e['status'] == 'awaiting-payment')
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'Discard this sale?', 'It was never accepted by the server. Refund the customer if they paid.', action: 'Discard')) {
                  await app.discardPending('${e['transaction']['transactionId']}');
                }
              },
              child: const Text('Discard'),
            ),
        ],
      ),
      if (app.isManager && app.list('conflicts').isNotEmpty) ...[
        SectionTitle('Offline sale conflicts'),
        DataList(
          rows: app.list('conflicts'),
          columns: [
            Col('When', (c) => Text(formatDate(c['createdAt']))),
            Col('Problem', (c) => Text('${c['error'] ?? c['reason'] ?? ''}'), flex: 2),
            Col('Status', (c) => StatusChip(titleCase('${c['status']}'))),
          ],
          actions: (c) => [
            if (c['status'] == 'pending')
              OutlinedButton(
                onPressed: () => showFormDialog<void>(
                  context,
                  title: 'Resolve conflict',
                  fields: const [
                    FieldSpec('action', 'Decision', kind: FieldKind.select, required: true, options: [
                      ('accept', 'Accept the sale and record the stock difference'),
                      ('reject', 'Reject the sale and refund manually'),
                    ]),
                    FieldSpec('reason', 'Reason', required: true),
                  ],
                  onSubmit: (v) async => app.mutate('/conflicts/${c['id']}/resolve', v, 'Conflict resolved.'),
                ),
                child: const Text('Resolve'),
              ),
          ],
        ),
      ],
      if (app.isManager) ...[
        SectionTitle('Audit trail'),
        DataList(
          rows: app.list('audit').reversed.take(100).toList(),
          columns: [
            Col('Time', (a) => Text(formatDate(a['createdAt']))),
            Col('Who', (a) => Text(app.userName('${a['userId']}'))),
            Col('What', (a) => Text(humanize('${a['action']}'))),
            Col('Reason', (a) => Text('${a['reason'] ?? '—'}'), flex: 2),
          ],
        ),
      ],
    ]);
  }
}
