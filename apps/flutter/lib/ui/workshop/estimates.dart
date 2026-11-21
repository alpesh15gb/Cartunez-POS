// WS-C (workshop): estimates (Orders & bills › Estimates).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets.dart';
import 'common.dart';
import 'vehicles.dart';

/// A query parameter of the current address (null outside the router, e.g. single-widget tests).
String? queryParam(BuildContext context, String key) {
  try {
    return GoRouterState.of(context).uri.queryParameters[key];
  } catch (_) {
    return null;
  }
}

/// Picks customer and vehicle for a document. The vehicle's owner fills the customer.
class PartyPicker extends StatelessWidget {
  const PartyPicker({super.key, required this.customerId, required this.vehicleId, required this.onChanged, this.enabled = true});
  final String? customerId;
  final String? vehicleId;
  final void Function(String? customerId, String? vehicleId) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vehicle = vehicleById(app, vehicleId);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      ActionChip(
        avatar: const Icon(Icons.directions_car_outlined, size: 18),
        label: Text(vehicle == null ? 'Choose vehicle' : vehicleTitle(vehicle)),
        onPressed: !enabled
            ? null
            : () async {
                final picked = await pickVehicle(context);
                if (picked != null) onChanged((customerId ?? '').isEmpty ? picked['customerId'] as String? : customerId, '${picked['id']}');
              },
      ),
      ActionChip(
        avatar: const Icon(Icons.person_outline, size: 18),
        label: Text(customerLabel(app, customerId)),
        onPressed: !enabled
            ? null
            : () => showFormDialog<void>(
                  context,
                  title: 'Customer',
                  submit: 'Use customer',
                  fields: [
                    FieldSpec('customerId', 'Customer', kind: FieldKind.select, value: customerId ?? '',
                        options: [('', 'Walk-in customer'), ...optionsOf(app.list('customers'), (c) => '${c['name']} ${c['phone'] ?? ''}')]),
                  ],
                  onSubmit: (v) async => onChanged('${v['customerId']}'.isEmpty ? null : '${v['customerId']}', vehicleId),
                ),
      ),
    ]);
  }
}

/// Totals for unsaved lines, the same way the server works them out (no bill discount).
Json draftTotals(AppState app, List<Json> lines) {
  final inclusive = '${app.settings['taxMode'] ?? 'exclusive'}' == 'inclusive';
  int ratio(int v, int n, int d) => ((BigInt.from(v) * BigInt.from(n) + BigInt.from(d ~/ 2)) ~/ BigInt.from(d)).toInt();
  var subtotal = 0, tax = 0, core = 0;
  for (final l in lines) {
    final product = app.productById('${l['productId']}');
    final rate = ((l['taxRate'] ?? product?['taxRate'] ?? 0) as num).toInt();
    final amount = lineAmount(l);
    subtotal += amount;
    tax += inclusive ? amount - ratio(amount, 10000, 10000 + rate) : ratio(amount, rate, 10000);
    core += ((product?['coreCharge'] ?? 0) as num).toInt() * ((l['qty'] ?? 0) as num).toInt();
  }
  final unrounded = subtotal + (inclusive ? 0 : tax) + core;
  final increment = ((app.settings['roundingIncrement'] ?? 1) as num).toInt();
  final total = ratio(unrounded, 1, increment) * increment;
  return {'subtotal': subtotal, 'tax': tax, 'core': core, 'rounding': total - unrounded, 'total': total};
}

class EstimatesScreen extends StatelessWidget {
  const EstimatesScreen({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (id != null) {
      final existing = id == 'new' ? null : app.list('estimates').where((e) => e['id'] == id).firstOrNull;
      if (id != 'new' && existing == null) {
        return Column(children: [
          const EmptyState(message: 'This estimate is not on this device. Refresh, or go back to the list.'),
          TextButton(onPressed: () => context.go('/orders/estimates'), child: const Text('Back to estimates')),
        ]);
      }
      return EstimateEditor(
        key: ValueKey(existing?['id'] ?? 'new'),
        estimate: existing ?? {'vehicleId': queryParam(context, 'vehicle'), 'customerId': vehicleById(app, queryParam(context, 'vehicle'))?['customerId']},
      );
    }
    final rows = app.list('estimates').reversed.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(
          onPressed: () => context.go('/orders/estimates/new'),
          icon: const Icon(Icons.add),
          label: const Text('New estimate'),
        ),
        OutlinedButton.icon(onPressed: () => context.go('/orders/jobs'), icon: const Icon(Icons.view_kanban_outlined), label: const Text('Job board')),
      ]),
      DataList(
        rows: rows,
        empty: 'No estimates yet. Make one to quote parts and labour for a vehicle.',
        emptyAction: FilledButton.icon(onPressed: () => context.go('/orders/estimates/new'), icon: const Icon(Icons.add), label: const Text('New estimate')),
        onTap: (row) => context.go('/orders/estimates/${row['id']}'),
        columns: [
          Col('Estimate', (r) => Text('${r['number']}')),
          Col('Vehicle', (r) => Text(vehicleById(app, r['vehicleId'])?['regNo'] ?? '—')),
          Col('Customer', (r) => Text(customerLabel(app, r['customerId']))),
          Col('Status', (r) => StatusChip(estimateStatusLabels[r['status']] ?? '${r['status']}')),
          Col('Total', (r) => Text(app.money(r['total'] as num?)), numeric: true),
        ],
      ),
    ]);
  }
}

class EstimateEditor extends StatefulWidget {
  const EstimateEditor({super.key, required this.estimate});
  final Json estimate;
  @override
  State<EstimateEditor> createState() => _EstimateEditorState();
}

class _EstimateEditorState extends State<EstimateEditor> {
  late List<Json> lines = [for (final l in widget.estimate['lines'] as List? ?? const []) Map<String, dynamic>.from(l as Map)];
  late String? customerId = widget.estimate['customerId'] as String?;
  late String? vehicleId = widget.estimate['vehicleId'] as String?;
  late final notes = TextEditingController(text: '${widget.estimate['notes'] ?? ''}');
  late final validDays = TextEditingController(text: '15');
  bool dirty = false, busy = false;

  bool get locked => ['converted', 'rejected'].contains(widget.estimate['status']);
  String? get id => widget.estimate['id'] as String?;

  @override
  void dispose() {
    notes.dispose();
    validDays.dispose();
    super.dispose();
  }

  Future<Json?> _save() async {
    final app = context.appRead;
    if (lines.isEmpty) {
      app.toast('Add at least one part, labour or kit.');
      return null;
    }
    setState(() => busy = true);
    try {
      final saved = Map<String, dynamic>.from(await app.mutate('/estimates', {
        if (id != null) 'id': id,
        'customerId': customerId,
        'vehicleId': vehicleId,
        'notes': notes.text,
        if (id == null) 'validDays': int.tryParse(validDays.text) ?? 15,
        'lines': [
          for (final l in lines)
            {for (final k in ['id', 'productId', 'qty', 'unitPrice', 'description', 'staffId', 'kind']) if (l[k] != null) k: l[k]},
        ],
      }, 'Estimate saved.') as Map);
      dirty = false;
      if (mounted && id == null) context.go('/orders/estimates/${saved['id']}');
      return saved;
    } catch (e) {
      app.toast(errorText(e));
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _status(String status) async {
    final app = context.appRead;
    try {
      await app.mutate('/estimates/$id/status', {'status': status}, status == 'sent' ? 'Marked as sent.' : 'Estimate ${estimateStatusLabels[status]?.toLowerCase()}.');
    } catch (e) {
      app.toast(errorText(e));
    }
  }

  Future<void> _toJob() async {
    final app = context.appRead;
    if (dirty && await _save() == null) return;
    if (!mounted) return;
    await showFormDialog<void>(
      context,
      title: 'Approve and open job card',
      submit: 'Open job card',
      fields: [
        const FieldSpec('bay', 'Bay'),
        FieldSpec('technicianId', 'Technician', kind: FieldKind.select, options: [('', 'Not yet'), ...staffOptions(app)]),
        FieldSpec('odo', 'Odometer at check-in (km)', kind: FieldKind.number, value: vehicleById(app, vehicleId)?['odo']),
      ],
      onSubmit: (v) async {
        final job = await app.mutate('/estimates/$id/job', {
          'bay': v['bay'],
          'technicianId': '${v['technicianId']}'.isEmpty ? null : v['technicianId'],
          'odo': '${v['odo']}'.isEmpty ? null : int.tryParse('${v['odo']}'),
        }, 'Job card opened. Parts are reserved.');
        if (mounted) context.go('/orders/jobs/${job['id']}');
      },
    );
  }

  Future<void> _add() async {
    final product = await pickProduct(context);
    if (product == null) return;
    setState(() {
      final at = lines.indexWhere((l) => l['productId'] == product['id']);
      if (at >= 0) {
        lines[at] = {...lines[at], 'qty': (lines[at]['qty'] as int) + 1};
      } else {
        lines.add(newLine(product));
      }
      dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final doc = {...widget.estimate, ...draftTotals(app, lines), 'lines': lines, 'customerId': customerId, 'vehicleId': vehicleId};
    final status = '${widget.estimate['status'] ?? 'draft'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        TextButton.icon(onPressed: () => context.go('/orders/estimates'), icon: const Icon(Icons.arrow_back), label: const Text('Estimates')),
        Text(id == null ? 'New estimate' : 'Estimate ${widget.estimate['number']}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        if (id != null) StatusChip(estimateStatusLabels[status] ?? status),
      ]),
      if (widget.estimate['validUntil'] != null) Text('Valid until ${widget.estimate['validUntil']}'),
      if (widget.estimate['jobId'] != null)
        TextButton(onPressed: () => context.go('/orders/jobs/${widget.estimate['jobId']}'), child: Text('Open job card ${widget.estimate['jobNumber'] ?? ''}')),
      const SizedBox(height: 10),
      PartyPicker(
        customerId: customerId,
        vehicleId: vehicleId,
        enabled: !locked,
        onChanged: (c, v) => setState(() {
          customerId = c;
          vehicleId = v;
          dirty = true;
        }),
      ),
      SectionTitle('Parts, labour and kits',
          trailing: locked ? null : FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add'))),
      DocumentLines(lines: lines, onChanged: locked ? null : (next) => setState(() {
        lines = next;
        dirty = true;
      })),
      const SizedBox(height: 10),
      DocumentTotals(doc),
      const SizedBox(height: 10),
      TextField(
        controller: notes,
        enabled: !locked,
        maxLines: 2,
        decoration: const InputDecoration(labelText: 'Notes for the customer'),
        onChanged: (_) => dirty = true,
      ),
      if (id == null) ...[
        const SizedBox(height: 10),
        SizedBox(width: 200, child: TextField(controller: validDays, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Valid for (days)'))),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (!locked) FilledButton.icon(onPressed: busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Save')),
        if (id != null) ...[
          OutlinedButton.icon(
            onPressed: () async {
              await shareOnWhatsApp(context, doc, title: 'Estimate');
              if (status == 'draft') await _status('sent');
            },
            icon: const Icon(Icons.chat_outlined),
            label: const Text('WhatsApp'),
          ),
          OutlinedButton.icon(onPressed: () => shareDocumentPdf(context, doc, title: 'Estimate'), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Share PDF')),
          if (!locked) ...[
            FilledButton.icon(onPressed: busy ? null : _toJob, icon: const Icon(Icons.build_outlined), label: const Text('Approve → job card')),
            TextButton(onPressed: () => _status('rejected'), child: const Text('Customer declined')),
          ],
        ],
      ]),
      if (dirty && id != null) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Unsaved changes. Save before sharing.')),
    ]);
  }
}
