// WS-C (workshop): job board and job card (Orders & bills › Job cards).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart' show ApiError;
import '../../core/billing.dart';
import '../../main.dart';
import '../barcode_scan.dart';
import '../photos.dart';
import '../purchasing/file_thumbs.dart';
import '../screens/receipt.dart';
import '../shift/shift_dialogs.dart' show showOpenShiftDialog;
import '../people/account_actions.dart' show availableAdvance, advanceModes;
import '../widgets.dart';
import 'common.dart';
import 'estimates.dart';
import 'vehicles.dart';

/// Opens a new job card: vehicle (by registration), customer, bay, technician, check-in ODO.
Future<void> newJob(BuildContext context, {String? vehicleId}) async {
  final app = context.appRead;
  var vehicle = vehicleById(app, vehicleId) ?? await pickVehicle(context);
  if (vehicle == null || !context.mounted) return;
  await showFormDialog<void>(
    context,
    title: 'New job card · ${vehicle['regNo']}',
    submit: 'Check in',
    fields: [
      FieldSpec('customerId', 'Customer', kind: FieldKind.select, value: vehicle['customerId'] ?? '',
          options: [('', 'Walk-in customer'), ...optionsOf(app.list('customers'), (c) => '${c['name']} ${c['phone'] ?? ''}')]),
      const FieldSpec('bay', 'Bay'),
      FieldSpec('technicianId', 'Technician', kind: FieldKind.select, options: [('', 'Not yet'), ...staffOptions(app)]),
      FieldSpec('odo', 'Odometer at check-in (km)', kind: FieldKind.number, value: vehicle['odo']),
      const FieldSpec('complaint', 'What the customer reports', kind: FieldKind.multiline),
    ],
    onSubmit: (v) async {
      final job = await app.mutate('/jobs', {
        'vehicleId': vehicle['id'],
        'customerId': '${v['customerId']}'.isEmpty ? null : v['customerId'],
        'bay': v['bay'],
        'technicianId': '${v['technicianId']}'.isEmpty ? null : v['technicianId'],
        'odo': '${v['odo']}'.isEmpty ? null : int.tryParse('${v['odo']}'),
        'complaint': v['complaint'],
      }, 'Vehicle checked in.');
      if (context.mounted) context.go('/orders/jobs/${job['id']}');
    },
  );
}

class JobsScreen extends StatelessWidget {
  const JobsScreen({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (id == 'new') {
      return _NewJobLauncher(vehicleId: queryParam(context, 'vehicle'));
    }
    if (id != null) {
      final job = app.list('jobs').where((j) => j['id'] == id || j['number'] == id).firstOrNull;
      if (job == null) {
        return Column(children: [
          const EmptyState(message: 'This job card is not on this device. Refresh, or go back to the board.'),
          TextButton(onPressed: () => context.go('/orders/jobs'), child: const Text('Back to job board')),
        ]);
      }
      return JobCard(key: ValueKey(job['id']), job: job);
    }
    return const JobBoard();
  }
}

/// /orders/jobs/new opens the check-in form, then goes back to the board if cancelled.
class _NewJobLauncher extends StatefulWidget {
  const _NewJobLauncher({this.vehicleId});
  final String? vehicleId;
  @override
  State<_NewJobLauncher> createState() => _NewJobLauncherState();
}

class _NewJobLauncherState extends State<_NewJobLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await newJob(context, vehicleId: widget.vehicleId);
      if (mounted && GoRouterState.of(context).uri.path.endsWith('/new')) context.go('/orders/jobs');
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Columns by status on wide screens; on phones a status filter and one list.
class JobBoard extends StatefulWidget {
  const JobBoard({super.key});
  @override
  State<JobBoard> createState() => _JobBoardState();
}

class _JobBoardState extends State<JobBoard> {
  String filter = 'open';

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final jobs = app.list('jobs').where((j) => j['status'] != 'cancelled').toList().reversed.toList();
    // Delivered jobs: only the last week on the board.
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final lanes = {for (final status in jobStatuses) status: <Json>[]};
    for (final job in jobs) {
      if (job['status'] == 'delivered' &&
          DateTime.tryParse('${job['deliveredAt'] ?? job['updatedAt']}')?.isAfter(weekAgo) != true) continue;
      lanes[job['status']]?.add(job);
    }
    final toolbar = Toolbar([
      FilledButton.icon(onPressed: () => newJob(context), icon: const Icon(Icons.add), label: const Text('New job card')),
      OutlinedButton.icon(onPressed: () => context.go('/orders/estimates/new'), icon: const Icon(Icons.request_quote_outlined), label: const Text('New estimate')),
    ]);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 900) {
        final scheme = Theme.of(context).colorScheme;
        // A lane flexes to the workspace, so the Delivered column is always in view.
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          toolbar,
          Row(
            spacing: 10,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in lanes.entries)
                Expanded(
                  child: Container(
                    key: ValueKey('job-lane-${entry.key}'),
                    constraints: const BoxConstraints(minHeight: 220),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                        child: Text('${jobStatusLabel(entry.key)} (${entry.value.length})',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      for (final job in entry.value)
                        Padding(padding: const EdgeInsets.only(bottom: 8), child: JobTile(job: job, compact: true)),
                      if (entry.value.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text('No jobs', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                        ),
                    ]),
                  ),
                ),
            ],
          ),
        ]);
      }
      final open = jobs.where((j) => j['status'] != 'delivered').toList();
      final shown = filter == 'open' ? open : lanes[filter] ?? const [];
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        toolbar,
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in ['open', ...jobStatuses])
            ChoiceChip(
              label: Text(s == 'open' ? 'Open (${open.length})' : '${jobStatusLabel(s)} (${lanes[s]!.length})'),
              selected: filter == s,
              onSelected: (_) => setState(() => filter = s),
            ),
        ]),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          EmptyState(
            message: 'No job cards here. Check in a vehicle to start one.',
            action: FilledButton.icon(onPressed: () => newJob(context), icon: const Icon(Icons.add), label: const Text('New job card')),
          ),
        for (final job in shown) JobTile(job: job, showStatus: true),
      ]);
    });
  }
}

/// "Bay 2" whether the bay was typed as "2" or "Bay 2".
String bayLabel(Object? bay) {
  final text = '${bay ?? ''}'.trim();
  if (text.isEmpty) return '';
  return text.toLowerCase().startsWith('bay') ? text : 'Bay $text';
}

class JobTile extends StatelessWidget {
  const JobTile({super.key, required this.job, this.showStatus = false, this.compact = false});
  final Json job;
  final bool showStatus;

  /// Board lanes: registration and number on separate lines, total underneath.
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vehicle = vehicleById(app, job['vehicleId']);
    final details = [
      if (vehicle != null) '${vehicle['make'] ?? ''} ${vehicle['model'] ?? ''}'.trim(),
      customerLabel(app, job['customerId']),
      bayLabel(job['bay']),
      if (job['technicianId'] != null) app.userName('${job['technicianId']}'),
    ].where((e) => e.isNotEmpty).join(' · ');
    if (compact) {
      final small = Theme.of(context).textTheme.bodySmall;
      return Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go('/orders/jobs/${job['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${vehicle?['regNo'] ?? 'No vehicle'}', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${job['number']}', style: small),
              const SizedBox(height: 4),
              Text(details, style: small),
              const SizedBox(height: 4),
              Text(app.money(job['total'] as num?), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
    }
    return Card(
      child: ListTile(
        title: Text('${vehicle?['regNo'] ?? 'No vehicle'} · ${job['number']}'),
        subtitle: Text(details),
        trailing: showStatus ? StatusChip(jobStatusLabel(job['status'])) : Text(app.money(job['total'] as num?)),
        onTap: () => context.go('/orders/jobs/${job['id']}'),
      ),
    );
  }
}

class JobCard extends StatefulWidget {
  const JobCard({super.key, required this.job});
  final Json job;
  @override
  State<JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<JobCard> {
  bool busy = false;
  Json get job => widget.job;
  bool get open => job['invoiceId'] == null && !['cancelled', 'delivered'].contains(job['status']);
  List<Json> get lines => [for (final l in job['lines'] as List? ?? const []) Map<String, dynamic>.from(l as Map)];

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) context.appRead.toast(errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveLines(List<Json> next, int revision) => _run(() async {
        final app = context.appRead;
        try {
          await app.mutate('/jobs/${job['id']}/lines', {
            'expectedLinesRevision': revision,
            'lines': [
              for (final l in next)
                {for (final k in ['id', 'productId', 'qty', 'unitPrice', 'description', 'staffId', 'kind', 'binId', 'serials']) if (l[k] != null) k: l[k]},
            ],
          });
        } on ApiError catch (error) {
          if (error.status == 409) await app.sync(afterMutation: true);
          rethrow;
        }
      });

  Future<void> _addProduct(Json product) async {
    final current = lines;
    final at = current.indexWhere((l) => l['productId'] == product['id']);
    if (at >= 0) {
      current[at] = {...current[at], 'qty': (current[at]['qty'] as int) + 1};
    } else {
      current.add(newLine(product));
    }
    await _saveLines(current, job['linesRevision'] as int? ?? 0);
    if (mounted && product['serialTracked'] == true) {
      context.appRead.toast('${product['sku']} tracks serials. Tap the line to scan them before billing.');
    }
  }

  Future<void> _scan() async {
    final app = context.appRead;
    final code = await requestBarcode(context);
    if (code == null || !mounted) return;
    final found = app.findByCode(scannedProductCode(code), forSale: true);
    if (found.length == 1) return _addProduct(found.first);
    final picked = await pickProduct(context, title: found.isEmpty ? 'No part has code $code — search instead' : 'Choose the part');
    if (picked != null) await _addProduct(picked);
  }

  Future<void> _status(String status) => _run(() async {
        if (status == 'cancelled' && !await confirm(context, 'Cancel job card?', 'Reserved parts are released. This cannot be undone.', action: 'Cancel job')) {
          return;
        }
        if (!mounted) return;
        await context.appRead.mutate('/jobs/${job['id']}/status', {'status': status}, 'Job ${jobStatusLabel(status).toLowerCase()}.');
      });

  Future<void> _photos(String tag, bool camera) => _run(() async {
        final app = context.appRead;
        final photos = camera ? [?await capturePhoto()] : await pickGalleryPhotos(app);
        if (photos.isEmpty) return;
        final ids = [];
        for (final photo in photos) {
          final saved = await app.api('/attachments', body: {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'name': '$tag.jpg'});
          ids.add(saved['id']);
        }
        await app.mutate('/jobs/${job['id']}/photos', {'photoIds': ids, 'tag': tag}, 'Photos added.');
      });

  Future<void> _editHeader() async {
    final app = context.appRead;
    await showFormDialog<void>(
      context,
      title: 'Job ${job['number']}',
      fields: [
        FieldSpec('bay', 'Bay', value: job['bay']),
        FieldSpec('technicianId', 'Technician', kind: FieldKind.select, value: job['technicianId'] ?? '',
            options: [('', 'Not yet'), ...staffOptions(app)]),
        FieldSpec('odo', 'Odometer at check-in (km)', kind: FieldKind.number, value: job['odoIn']),
        FieldSpec('complaint', 'What the customer reports', kind: FieldKind.multiline, value: job['complaint']),
        FieldSpec('notes', 'Workshop notes', kind: FieldKind.multiline, value: job['notes']),
      ],
      onSubmit: (v) async {
        await app.mutate('/jobs', {
          'id': job['id'],
          ...v,
          'technicianId': '${v['technicianId']}'.isEmpty ? null : v['technicianId'],
          'odo': '${v['odo']}'.isEmpty ? null : int.tryParse('${v['odo']}'),
        }, 'Job card saved.');
      },
    );
  }

  Future<void> _bill() async {
    final app = context.appRead;
    // QA #10: no shift yet? Open it right here and carry on billing this job.
    if (app.openShift == null) {
      final opened = await showOpenShiftDialog(context, forCheckout: true);
      if (!opened || !mounted) return;
    }
    final shift = app.openShift;
    if (shift == null) {
      app.toast('Open your shift before billing the job.');
      return;
    }
    final tenders = [...app.tenderTypes, if (job['customerId'] != null) 'Credit'];
    final total = ((job['total'] ?? 0) as num).toInt();
    // Money held for the customer (advances, store credit) is offered first, up to the bill.
    final held = job['customerId'] == null ? 0 : availableAdvance(app, '${job['customerId']}');
    final offer = held < total ? held : total;
    final invoice = await showFormDialog<Json>(
      context,
      title: 'Bill ${job['number']} · ${app.money(total)}',
      submit: 'Make ${invoiceTerm(app, lower: true)}', // QA #10: "invoice" unless GST registered
      fields: [
        if (held > 0)
          FieldSpec('advance', 'Use from advance', kind: FieldKind.money, value: (offer / 100).toStringAsFixed(2),
              help: '${app.money(held)} held for ${customerLabel(app, job['customerId'])}. Up to ${app.money(offer)} can be used.'),
        FieldSpec('type', held > 0 ? 'Rest paid by' : 'Paid by', kind: FieldKind.select, value: 'Cash', required: true,
            options: [for (final t in tenders) (t, t == 'Credit' ? 'On account (udhaar)' : t)]),
        const FieldSpec('reference', 'Card / UPI reference', help: 'Needed for card and UPI after you confirm the money arrived.'),
      ],
      onSubmit: (v) async {
        final type = '${v['type']}';
        final advance = held > 0 ? (parsePaymentAmount('${v['advance'] ?? ''}'.trim().isEmpty ? '0' : '${v['advance']}') ?? -1) : 0;
        if (advance < 0 || advance > offer) throw FormProblem('Use between ₹0 and ${app.money(offer)} from the advance.');
        final rest = total - advance;
        if (rest > 0 && type != 'Cash' && type != 'Credit' && '${v['reference']}'.trim().isEmpty) {
          throw FormProblem('Enter the $type reference once the payment is confirmed.');
        }
        final result = await app.mutate('/jobs/${job['id']}/invoice', {
          'shiftId': shift['id'],
          'expectedTotal': total,
          'tenders': [
            if (advance > 0) {'type': 'Advance', 'amount': advance},
            if (rest > 0) {'type': type, 'amount': rest, 'confirmed': true, 'reference': '${v['reference'] ?? ''}'.trim()},
          ],
        }, advance > 0 ? 'Invoice made with ${app.money(advance)} from the advance. Job delivered.' : 'Invoice made. Job delivered.');
        return Map<String, dynamic>.from(result as Map);
      },
    );
    if (invoice != null && mounted) await showReceipt(context, invoice);
  }

  Future<void> _takeAdvance() async {
    final app = context.appRead;
    final transactionId = uuid();
    await showFormDialog<void>(
      context,
      title: 'Advance for ${job['number']}',
      submit: 'Record advance',
      fields: [
        const FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true),
        FieldSpec('mode', 'Paid by', kind: FieldKind.select, required: true, value: 'Cash', options: [for (final m in advanceModes) (m, m)]),
        const FieldSpec('reference', 'UPI / card reference'),
        const FieldSpec('notes', 'For', help: 'For example: parts on order for this job.'),
      ],
      onSubmit: (v) async {
        final amount = parsePaymentAmount('${v['amount']}') ?? 0;
        if (amount <= 0) throw FormProblem('Enter the amount received.');
        if (v['mode'] != 'Cash' && '${v['reference'] ?? ''}'.trim().isEmpty) throw FormProblem('Enter the ${v['mode']} reference.');
        await app.mutate('/jobs/${job['id']}/advances', {
          'transactionId': transactionId,
          'amount': amount,
          'mode': v['mode'],
          'reference': v['reference'] ?? '',
          'notes': v['notes'] ?? '',
        }, 'Advance of ${app.money(amount)} recorded on ${job['number']}.');
      },
    );
  }

  /// Why "Bill job" is switched off, in plain words (null when it is on).
  String? _billBlocked(bool canSell) {
    if (!canSell) return 'Only cashiers, managers and owners can bill.';
    if (lines.isEmpty) return 'Add parts or labour before billing.';
    if (busy) return 'Saving…';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vehicle = vehicleById(app, job['vehicleId']);
    final jobAdvances = app.list('partyPayments').where((p) => p['jobId'] == job['id'] && p['voided'] != true &&
      p['reversed'] != true && p['reversesId'] == null && p['refund'] != true).toList();
    final held = job['customerId'] == null ? 0 : availableAdvance(app, '${job['customerId']}');
    final blocked = _billBlocked(app.canSell);
    final photos = [for (final p in job['photos'] as List? ?? const []) Map<String, dynamic>.from(p as Map)];
    // Keep the version that produced the visible list, even when a background
    // sync refreshes this card while a line-edit dialog is open.
    final revision = job['linesRevision'] as int? ?? 0;
    final status = '${job['status']}';
    final next = switch (status) {
      'checked-in' => 'in-progress',
      'in-progress' => 'ready',
      'waiting-parts' => 'in-progress',
      _ => null,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        TextButton.icon(onPressed: () => context.go('/orders/jobs'), icon: const Icon(Icons.arrow_back), label: const Text('Job board')),
        Text('Job ${job['number']}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        StatusChip(jobStatusLabel(status)),
      ]),
      const SizedBox(height: 6),
      InkWell(
        onTap: vehicle == null ? null : () => context.go('/people/vehicles/${vehicle['id']}'),
        child: Text(vehicleTitle(vehicle), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      Text([
        customerLabel(app, job['customerId']),
        if (bayLabel(job['bay']).isNotEmpty) bayLabel(job['bay']),
        'Technician: ${job['technicianId'] == null ? 'not set' : app.userName('${job['technicianId']}')}',
        if (job['odoIn'] != null) 'ODO in ${job['odoIn']} km',
      ].join(' · ')),
      if ('${job['complaint'] ?? ''}'.isNotEmpty) Text('Reported: ${job['complaint']}'),
      if ('${job['notes'] ?? ''}'.isNotEmpty) Text('Notes: ${job['notes']}'),
      if (job['estimateId'] != null || (job['invoiceId'] != null && app.canSell))
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (job['estimateId'] != null)
            TextButton(onPressed: () => context.go('/orders/estimates/${job['estimateId']}'), child: const Text('Open the estimate')),
          if (job['invoiceId'] != null && app.canSell)
            TextButton(onPressed: () => context.go('/orders/invoices/${job['invoiceId']}'), child: Text('Invoice ${job['invoiceNumber'] ?? ''}')),
        ]),
      const SizedBox(height: 10),
      if (open)
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (next != null)
            FilledButton.tonal(onPressed: busy ? null : () => _status(next), child: Text('Move to ${jobStatusLabel(next).toLowerCase()}')),
          if (status != 'waiting-parts')
            OutlinedButton(onPressed: busy ? null : () => _status('waiting-parts'), child: const Text('Waiting parts')),
          OutlinedButton.icon(onPressed: busy ? null : _editHeader, icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
          if (app.isManager) TextButton(onPressed: busy ? null : () => _status('cancelled'), child: const Text('Cancel job')),
        ]),
      SectionTitle('Parts and labour',
          trailing: open
              ? Wrap(spacing: 6, children: [
                  IconButton.filledTonal(tooltip: 'Scan part', onPressed: busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner)),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : () async {
                      final p = await pickProduct(context);
                      if (p != null) await _addProduct(p);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
                ])
              : null),
      DocumentLines(lines: lines, job: true, onChanged: open && !busy ? (next) => _saveLines(next, revision) : null),
      if (open && lines.isNotEmpty)
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('Parts on an open job are reserved and appear under Held bills at the counter.')),
      const SizedBox(height: 10),
      DocumentTotals(job),
      const SizedBox(height: 10),
      if (jobAdvances.isNotEmpty || (open && held > 0))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final a in jobAdvances)
              Text('Advance ${app.money(a['amount'] as num?)} by ${a['mode']} on ${formatDate(a['createdAt'])}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            if (open && held > 0)
              Text('${app.money(held)} is held for ${customerLabel(app, job['customerId'])}; billing offers it first.',
                  style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (open && app.canSell)
          FilledButton.icon(onPressed: blocked != null ? null : _bill, icon: const Icon(Icons.receipt_long_outlined), label: Text('Bill job (${invoiceTerm(app, lower: true)})')),
        if (open && app.canSell && job['customerId'] != null)
          OutlinedButton.icon(onPressed: busy ? null : _takeAdvance, icon: const Icon(Icons.savings_outlined), label: const Text('Take advance')),
        OutlinedButton.icon(onPressed: () => shareOnWhatsApp(context, job, title: 'Job card'), icon: const Icon(Icons.chat_outlined), label: const Text('WhatsApp')),
        OutlinedButton.icon(onPressed: () => shareDocumentPdf(context, job, title: 'Job card'), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Share PDF')),
      ]),
      if (open && blocked != null && app.canSell)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(blocked, key: const ValueKey('bill-blocked'), style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
      for (final tag in ['walkaround', 'defect']) ...[
        SectionTitle(tag == 'walkaround' ? 'Walk-around photos' : 'Defect photos',
            trailing: Wrap(spacing: 6, children: [
              if (canUseCamera)
                IconButton(tooltip: 'Take photo', onPressed: busy ? null : () => _photos(tag, true), icon: const Icon(Icons.photo_camera_outlined)),
              IconButton(tooltip: 'Add photos', onPressed: busy ? null : () => _photos(tag, false), icon: const Icon(Icons.add_photo_alternate_outlined)),
            ])),
        if (!photos.any((p) => p['tag'] == tag)) Text(tag == 'walkaround' ? 'Photograph all four sides at check-in.' : 'None recorded.'),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final p in photos.where((p) => p['tag'] == tag)) FileThumb(file: p)]),
      ],
      const SectionTitle('History'),
      for (final h in (job['history'] as List? ?? const []).reversed)
        Text('${formatDate(h['at'])} · ${jobStatusLabel(h['status'])} · ${app.userName('${h['by']}')}${h['note'] == null ? '' : ' · ${h['note']}'}'),
      const SizedBox(height: 24),
    ]);
  }
}
