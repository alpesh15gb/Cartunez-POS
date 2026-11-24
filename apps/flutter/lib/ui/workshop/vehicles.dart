// WS-C (workshop): the vehicle registry (People & vehicles › Vehicles).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../photos.dart';
import '../purchasing/file_thumbs.dart';
import '../shell.dart';
import '../widgets.dart';
import 'common.dart';

const fuels = ['Petrol', 'Diesel', 'CNG', 'LPG', 'Electric', 'Hybrid'];

/// Vehicles matching [query]: registration (any spacing, or its last digits), VIN, owner phone, make/model.
List<Json> searchVehicles(AppState app, String query) {
  final q = normalize(query);
  final scored = <(int, Json)>[];
  for (final v in app.list('customerVehicles')) {
    final reg = normalize(v['regKey'] ?? v['regNo']); // normalize() lower-cases both sides
    final customer = app.customerById('${v['customerId']}');
    final score = q.isEmpty
        ? 1
        : reg == q
            ? 100
            : reg.endsWith(q)
                ? 60
                : reg.contains(q)
                    ? 50
                    : normalize(v['vin']).contains(q)
                        ? 40
                        : normalize(customer?['phone']).contains(q)
                            ? 30
                            : normalize('${v['make']} ${v['model']} ${customer?['name'] ?? ''}').contains(q)
                                ? 20
                                : 0;
    if (score > 0) scored.add((score, v));
  }
  scored.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : '${b.$2['updatedAt']}'.compareTo('${a.$2['updatedAt']}'));
  return [for (final s in scored) s.$2];
}

/// Add or edit a vehicle. Returns the saved record.
Future<Json?> editVehicle(BuildContext context, Json vehicle) {
  final app = context.appRead;
  return showFormDialog<Json>(
    context,
    title: vehicle['id'] == null ? 'Add vehicle' : 'Edit ${vehicle['regNo']}',
    fields: [
      FieldSpec('regNo', 'Registration number', value: vehicle['regNo'], required: true, help: 'For example MH 12 AB 1234.'),
      FieldSpec('customerId', 'Owner', kind: FieldKind.select, value: vehicle['customerId'],
          options: [('', 'Not linked'), ...optionsOf(app.list('customers'), (c) => '${c['name']} ${c['phone'] ?? ''}')]),
      FieldSpec('make', 'Make', value: vehicle['make'], suggestions: {...app.list('vehicles').map((v) => '${v['make']}')}.toList()),
      FieldSpec('model', 'Model', value: vehicle['model'], suggestions: {...app.list('vehicles').map((v) => '${v['model']}')}.toList()),
      FieldSpec('variant', 'Variant', value: vehicle['variant']),
      FieldSpec('year', 'Year', kind: FieldKind.number, value: vehicle['year']),
      FieldSpec('fuel', 'Fuel', kind: FieldKind.select, value: vehicle['fuel'], options: [('', 'Not set'), for (final f in fuels) (f, f)]),
      FieldSpec('odo', 'Odometer (km)', kind: FieldKind.number, value: vehicle['odo']),
      FieldSpec('engine', 'Engine', value: vehicle['engine'], advanced: true, help: 'For example 1.2L; improves the fitment check.'),
      FieldSpec('vin', 'VIN / chassis number', value: vehicle['vin'], advanced: true),
      FieldSpec('notes', 'Notes', kind: FieldKind.multiline, value: vehicle['notes'], advanced: true),
    ],
    onSubmit: (v) async {
      final saved = await app.mutate('/customer-vehicles', {
        if (vehicle['id'] != null) 'id': vehicle['id'],
        ...v,
        'customerId': '${v['customerId']}'.isEmpty ? null : v['customerId'],
        'year': '${v['year']}'.isEmpty ? null : int.tryParse('${v['year']}'),
        'odo': '${v['odo']}'.isEmpty ? null : int.tryParse('${v['odo']}'),
      }, 'Vehicle saved.');
      return Map<String, dynamic>.from(saved as Map);
    },
  );
}

/// Find a vehicle by registration number (or add it). Used by the counter, estimates and jobs.
Future<Json?> pickVehicle(BuildContext context) =>
    showDialog<Json>(context: context, builder: (_) => const _VehiclePicker());

class _VehiclePicker extends StatefulWidget {
  const _VehiclePicker();
  @override
  State<_VehiclePicker> createState() => _VehiclePickerState();
}

class _VehiclePickerState extends State<_VehiclePicker> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final saved = await editVehicle(context, {'regNo': query.text.trim().toUpperCase()});
    if (saved != null && mounted) Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final rows = searchVehicles(app, query.text).take(40).toList();
    return AlertDialog(
      title: const Text('Find vehicle'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(children: [
          TextField(
            key: const ValueKey('vehicle-search'),
            controller: query,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Registration number, last digits or owner phone', prefixIcon: Icon(Icons.search)),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (rows.length == 1) Navigator.pop(context, rows.first);
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? EmptyState(message: query.text.isEmpty ? 'No vehicles registered yet.' : 'No vehicle matches ${query.text}. Add it.')
                : ListView(children: [
                    for (final v in rows)
                      ListTile(
                        leading: const Icon(Icons.directions_car_outlined),
                        title: Text('${v['regNo']}'),
                        subtitle: Text('${vehicleTitle(v).split(' · ').skip(1).join()} · ${customerLabel(app, v['customerId'])}'),
                        onTap: () => Navigator.pop(context, v),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add vehicle')),
      ],
    );
  }
}

/// The counter's fitment vehicle for a registry vehicle (keeps the registry id for invoice.vehicleId).
Json counterVehicle(Json vehicle) => {
      'make': vehicle['make'] ?? '',
      'model': vehicle['model'] ?? '',
      'year': vehicle['year'] ?? 0,
      if ('${vehicle['fuel'] ?? ''}'.isNotEmpty) 'fuel': vehicle['fuel'],
      if ('${vehicle['engine'] ?? ''}'.isNotEmpty) 'engine': vehicle['engine'],
      if ('${vehicle['variant'] ?? ''}'.isNotEmpty) 'trim': vehicle['variant'],
      'regNo': vehicle['regNo'],
      'customerVehicleId': vehicle['id'],
    };

/// People & vehicles › Vehicles: search, add, and open one (with its history).
class VehiclesScreen extends StatelessWidget {
  const VehiclesScreen({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (id != null) {
      final vehicle = vehicleById(app, id);
      if (vehicle == null) {
        return Column(children: [
          const EmptyState(message: 'This vehicle is not on this device. Refresh, or go back to the list.'),
          TextButton(onPressed: () => context.go('/people/vehicles'), child: const Text('Back to vehicles')),
        ]);
      }
      return VehicleDetail(key: ValueKey(vehicle['id']), vehicle: vehicle);
    }
    return ValueListenableBuilder(
      valueListenable: ShellScope.of(context).search,
      builder: (context, query, _) {
        final rows = searchVehicles(app, query.text);
        final addVehicle = FilledButton.icon(
          onPressed: () async {
            final saved = await editVehicle(context, {'regNo': query.text.trim().toUpperCase()});
            if (saved != null && context.mounted) context.go('/people/vehicles/${saved['id']}');
          },
          icon: const Icon(Icons.add),
          label: const Text('Add vehicle'),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (rows.isNotEmpty) Toolbar([addVehicle]),
          DataList(
            rows: rows,
            empty: query.text.isEmpty ? 'No vehicles yet.' : 'No vehicle matches your search.',
            emptyAction: addVehicle,
            onTap: (row) => context.go('/people/vehicles/${row['id']}'),
            columns: [
              Col('Registration', (r) => Text('${r['regNo']}'), flex: 2),
              Col('Vehicle', (r) => Text([r['make'], r['model'], r['variant'], r['year']].where((e) => e != null && '$e'.isNotEmpty).join(' ')), flex: 2),
              Col('Owner', (r) => Text(customerLabel(app, r['customerId']))),
              Col('Odometer', (r) => Text(r['odo'] == null ? '—' : '${r['odo']} km'), numeric: true),
            ],
          ),
        ]);
      },
    );
  }
}

class VehicleDetail extends StatefulWidget {
  const VehicleDetail({super.key, required this.vehicle});
  final Json vehicle;
  @override
  State<VehicleDetail> createState() => _VehicleDetailState();
}

class _VehicleDetailState extends State<VehicleDetail> {
  bool _busy = false;

  Future<void> _addPhotos(bool camera) async {
    final app = context.appRead;
    setState(() => _busy = true);
    try {
      final photos = camera ? [?await capturePhoto()] : await pickGalleryPhotos(app);
      if (photos.isEmpty) return;
      final ids = [for (final p in widget.vehicle['photos'] as List? ?? const []) p['id']];
      for (final photo in photos) {
        final saved = await app.api('/attachments', body: {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'name': 'vehicle.jpg'});
        ids.add(saved['id']);
      }
      await app.mutate('/customer-vehicles', {'id': widget.vehicle['id'], 'photoIds': ids}, 'Photos added.');
    } catch (e) {
      app.toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final v = widget.vehicle;
    final jobs = app.list('jobs').where((j) => j['vehicleId'] == v['id']).toList().reversed.toList();
    final estimates = app.list('estimates').where((e) => e['vehicleId'] == v['id']).toList().reversed.toList();
    final invoices = app.list('invoices').where((i) => i['vehicleId'] == v['id']).toList().reversed.toList();
    final photos = [for (final p in v['photos'] as List? ?? const []) Map<String, dynamic>.from(p as Map)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        TextButton.icon(onPressed: () => context.go('/people/vehicles'), icon: const Icon(Icons.arrow_back), label: const Text('Vehicles')),
        Text('${v['regNo']}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
      ]),
      const SizedBox(height: 8),
      Text(vehicleTitle(v).split(' · ').skip(1).join()),
      Text('Owner: ${customerLabel(app, v['customerId'])}${app.customerById('${v['customerId']}')?['phone'] == null ? '' : ' · ${app.customerById('${v['customerId']}')!['phone']}'}'),
      if (v['odo'] != null) Text('Odometer: ${v['odo']} km'),
      if ('${v['vin'] ?? ''}'.isNotEmpty) Text('VIN: ${v['vin']}'),
      if ('${v['notes'] ?? ''}'.isNotEmpty) Text('${v['notes']}'),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: () => context.go('/orders/jobs/new?vehicle=${v['id']}'),
          icon: const Icon(Icons.build_outlined),
          label: const Text('New job card'),
        ),
        OutlinedButton.icon(
          onPressed: () => context.go('/orders/estimates/new?vehicle=${v['id']}'),
          icon: const Icon(Icons.request_quote_outlined),
          label: const Text('New estimate'),
        ),
        OutlinedButton.icon(onPressed: () => editVehicle(context, v), icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
        if (canUseCamera)
          OutlinedButton.icon(onPressed: _busy ? null : () => _addPhotos(true), icon: const Icon(Icons.photo_camera_outlined), label: const Text('Take photo')),
        OutlinedButton.icon(onPressed: _busy ? null : () => _addPhotos(false), icon: const Icon(Icons.photo_library_outlined), label: const Text('Add photos')),
      ]),
      if (photos.isNotEmpty) ...[
        const SectionTitle('Photos'),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final p in photos) FileThumb(file: p)]),
      ],
      const SectionTitle('Job cards'),
      if (jobs.isEmpty) const Text('None yet.'),
      for (final j in jobs)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${j['number']} · ${jobStatusLabel(j['status'])}'),
          subtitle: Text(formatDate(j['createdAt'])),
          trailing: Text(app.money(j['total'] as num?)),
          onTap: () => context.go('/orders/jobs/${j['id']}'),
        ),
      const SectionTitle('Estimates'),
      if (estimates.isEmpty) const Text('None yet.'),
      for (final e in estimates)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${e['number']} · ${estimateStatusLabels[e['status']] ?? e['status']}'),
          subtitle: Text(formatDate(e['createdAt'])),
          trailing: Text(app.money(e['total'] as num?)),
          onTap: () => context.go('/orders/estimates/${e['id']}'),
        ),
      const SectionTitle('Invoices'),
      if (invoices.isEmpty) const Text('None on this device.'),
      for (final i in invoices)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${i['number']}'),
          subtitle: Text(formatDate(i['createdAt'])),
          trailing: Text(app.money(i['total'] as num?)),
          onTap: app.canSell ? () => context.go('/orders/invoices/${i['id']}') : null,
        ),
    ]);
  }
}
