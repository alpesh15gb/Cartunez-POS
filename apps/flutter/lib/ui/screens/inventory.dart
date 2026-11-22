import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart' show isOnlineOnly;
import '../shell.dart';
import '../photos.dart';
import '../purchasing/bill_entry_dialog.dart'; // QA #6: receive a new part against a supplier bill
import '../widgets.dart';
import '../workshop/kits.dart'; // WS-C
import 'receipt.dart';
import 'catalog_import.dart';
import 'physical_count.dart';

int _minor(Object? value) => ((double.tryParse('$value') ?? 0) * 100).round();

class PartsScreen extends StatefulWidget {
  const PartsScreen({super.key});

  @override
  State<PartsScreen> createState() => _PartsScreenState();
}

class _PartsScreenState extends State<PartsScreen> {
  /// Online only filter: 'all', 'shop' (shop stock) or 'online' (website only).
  String _kind = 'all';

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final anyOnlineOnly = app.products.any(isOnlineOnly);
    final shell = ShellScope.of(context);
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final exactIds = {for (final part in app.findByCode(search.text)) part['id']};
        final rows = app.products
            .where((p) => exactIds.isNotEmpty ? exactIds.contains(p['id']) : q.isEmpty ||
                [p['name'], p['sku'], p['partNumber'], p['brand'], p['category'], ...(p['barcodes'] as List? ?? []), ...(p['oemReferences'] as List? ?? [])]
                    .any((v) => normalize(v).contains(q)))
            .where((p) => !anyOnlineOnly || _kind == 'all' || (_kind == 'online') == isOnlineOnly(p))
            .toList();
        // Online-only parts have no shelf, so they need no labels.
        final labelRows = rows.where((p) => !isOnlineOnly(p)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (app.canStock)
            Toolbar([
              FilledButton.icon(onPressed: () => editProduct(context, const {}), icon: const Icon(Icons.add), label: const Text('Add part')),
              OutlinedButton.icon(onPressed: app.online ? () => importCatalog(context) : null, icon: const Icon(Icons.upload_file), label: const Text('Import parts')),
              if (app.isManager && app.list('removedProducts').isNotEmpty)
                OutlinedButton(onPressed: () => restorePart(context), child: const Text('Restore part')),
              OutlinedButton(onPressed: app.products.isEmpty || app.bins.isEmpty ? null : () => stockOperation(context, 'adjust'), child: const Text('Adjust stock')),
              OutlinedButton(onPressed: app.online && app.bins.isNotEmpty && app.stockParts.isNotEmpty
                  ? () => startPhysicalCount(context) : null, child: const Text('Stock count')),
              if (app.list('stockCounts').isNotEmpty)
                OutlinedButton(onPressed: app.online ? () => openPhysicalCounts(context) : null,
                  child: Text("Open counts (${app.list('stockCounts').length})")),
              OutlinedButton.icon(
                onPressed: labelRows.isEmpty ? null : () => printLabels(context, [for (final p in labelRows) productLabel(context.appRead, p)]),
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: Text(q.isEmpty ? 'Print all labels' : 'Print ${labelRows.length} ${labelRows.length == 1 ? 'label' : 'labels'}'),
              ),
            ]),
          if (anyOnlineOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                for (final (key, label) in const [('all', 'All parts'), ('shop', 'Shop stock'), ('online', 'Online only')])
                  ChoiceChip(label: Text(label), selected: _kind == key, onSelected: (_) => setState(() => _kind = key)),
              ]),
            ),
          if (app.canStock && app.bins.isEmpty && app.products.isNotEmpty)
            Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => shell.open('bins'), child: const Text('Add a bin to receive or adjust stock'))),
          LayoutBuilder(builder: (context, c) {
            final empty = q.isEmpty ? 'No parts yet. Add your first part.' : 'No part matches.';
            final emptyAction = q.isEmpty && app.canStock
                ? FilledButton.icon(onPressed: () => editProduct(context, const {}), icon: const Icon(Icons.add), label: const Text('Add part'))
                : null;
            // Phones: a compact two-line tile per part, the less common actions in a menu.
            if (c.maxWidth < 700) {
              if (rows.isEmpty) return EmptyState(message: empty, action: emptyAction);
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, p) in rows.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _PartTile(part: p),
                  ],
                ]),
              );
            }
            return DataList(
              rows: rows,
              dense: true,
              empty: empty,
              emptyAction: emptyAction,
              onTap: app.canStock ? (p) => editProduct(context, p) : null,
              columns: [
                Col('Part', (p) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (p['salesStopped'] == true) const StatusChip('Sales stopped'),
                      if (isOnlineOnly(p)) const StatusChip('Online only'),
                      Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('${p['sku']}${'${p['partNumber'] ?? ''}'.isNotEmpty ? ' · ${p['partNumber']}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]), flex: 3),
                Col('Barcode', (p) => Text('${(p['barcodes'] as List? ?? []).firstOrNull ?? '—'}'), flex: 2),
                Col('Stock', (p) => _StockText(part: p)),
                Col('Retail', (p) => Text(app.money(p['retailPrice'] as num?)), numeric: true),
                if (app.canStock) Col('Cost', (p) => Text(app.money(p['cost'] as num?)), numeric: true),
              ],
              actionWidth: 100,
              actions: app.canStock
                  ? (p) => [
                        // 36px buttons keep the row near 50px high.
                        SizedBox(height: 36, width: 40, child: IconButton(tooltip: 'Print label', padding: EdgeInsets.zero,
                            onPressed: () => printLabels(context, [productLabel(context.appRead, p)]), icon: const Icon(Icons.qr_code_2))),
                        SizedBox(height: 36, width: 40, child: _PartMenu(part: p)),
                      ]
                  : null,
            );
          }),
        ]);
      },
    );
  }

}

/// Stock figure with a Low / Out of stock chip (services show "Service").
class _StockText extends StatelessWidget {
  const _StockText({required this.part});
  final Json part;
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (part['type'] == 'service') return const Text('Service');
    // Online only: ordered from the supplier when sold on the website; no shop stock.
    if (isOnlineOnly(part)) return const Text('Website');
    final n = app.available('${part['id']}');
    return Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text('$n', style: const TextStyle(fontWeight: FontWeight.w700)),
      if (n <= (part['reorderLevel'] ?? 0)) StatusChip(n <= 0 ? 'Out of stock' : 'Low'),
    ]);
  }
}

/// Edit, photos, label and (managers) remove, behind one ⋮ button.
class _PartMenu extends StatelessWidget {
  const _PartMenu({required this.part});
  final Json part;
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PopupMenuButton<String>(
      tooltip: 'More for ${part['name']}',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert),
      onSelected: (choice) async {
        switch (choice) {
          case 'edit':
            await editProduct(context, part);
          case 'photos':
            await editPhotos(context, part);
          case 'label':
            await printLabels(context, [productLabel(context.appRead, part)]);
          case 'remove':
            if (!await confirm(context, 'Remove ${part['sku']}?',
                'This removes an unused part from Billing and Inventory. You can restore it from Inventory.', action: 'Remove')) {
              return;
            }
            try {
              await app.mutate('/products/${part['id']}/remove', {}, 'Part removed.');
            } catch (error) {
              app.toast(errorText(error));
            }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit part'), contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(value: 'photos', child: ListTile(leading: Icon(Icons.photo_library_outlined), title: Text('Photos'), contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(value: 'label', child: ListTile(leading: Icon(Icons.qr_code_2), title: Text('Print label'), contentPadding: EdgeInsets.zero)),
        if (app.isManager) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove part'), contentPadding: EdgeInsets.zero)),
        ],
      ],
    );
  }
}

/// Phone row: name, then SKU and stock; price on the right, menu last.
class _PartTile extends StatelessWidget {
  const _PartTile({required this.part});
  final Json part;
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final small = Theme.of(context).textTheme.bodySmall;
    return InkWell(
      onTap: app.canStock ? () => editProduct(context, part) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('${part['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              if (part['salesStopped'] == true) ...[const SizedBox(width: 6), const StatusChip('Sales stopped')],
              if (isOnlineOnly(part)) ...[const SizedBox(width: 6), const StatusChip('Online only')],
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Flexible(child: Text('${part['sku']} · Stock ', maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
              _StockText(part: part),
            ]),
          ])),
          const SizedBox(width: 8),
          Text(app.money(part['retailPrice'] as num?), style: const TextStyle(fontWeight: FontWeight.w700)),
          if (app.canStock) _PartMenu(part: part) else const SizedBox(width: 12),
        ]),
      ),
    );
  }
}

Future<void> restorePart(BuildContext context) async {
  final app = context.appRead;
  final removed = app.list('removedProducts');
  await showFormDialog<bool>(context, title: 'Restore part', submit: 'Restore',
    fields: [FieldSpec('part', 'Removed part', kind: FieldKind.select, required: true,
      options: [for (final p in removed) ('${p['id']}', '${p['sku']} · ${p['name']}')])],
    onSubmit: (v) async {
      await app.mutate('/products/${v['part']}/restore', {}, 'Part restored.');
      return true;
    },
  );
}

/// [onSaved] gets the saved part (used when a new item is created from a purchase bill).
Future<void> editProduct(BuildContext context, Json product, {void Function(Json saved)? onSaved}) async {
  final app = context.appRead;
  final counts = <int, int>{};
  for (final p in app.products) {
    counts.update((p['taxRate'] ?? 0) as int, (n) => n + 1, ifAbsent: () => 1);
  }
  final commonRate = counts.entries.isEmpty
      ? ((app.settings['taxRates'] as List?)?.firstOrNull ?? 0) as int
      : (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  String? money(String key) => product[key] == null ? null : ((product[key] as int) / 100).toStringAsFixed(2);
  String joined(String key) => (product[key] as List? ?? []).join(', ');
  final fitmentOn = app.feature('fitment');
  // Photos taken or chosen in the form; uploaded after the part is saved.
  final pendingPhotos = <({Uint8List bytes, int width, int height})>[];
  Json? createdPart; // QA #6: a part added here (not from a supplier bill) gets a next-step offer.
  await showFormDialog<void>(
    context,
    title: product['id'] == null ? 'Add part' : 'Edit ${product['name']}',
    header: PendingPartPhotos(photos: pendingPhotos),
    fields: [
      // QA #6: the required name and price (and fitment when that module is on) come first;
      // everything else is marked optional.
      FieldSpec('name', 'Part name', value: product['name'], required: true),
      FieldSpec('retailPrice', 'Retail price', kind: FieldKind.money, value: money('retailPrice'), required: true),
      FieldSpec('universal', 'Fits',
          kind: FieldKind.select,
          value: '${product['universal'] ?? !fitmentOn}',
          options: const [('true', 'All vehicles (universal)'), ('false', 'Specific vehicles only')],
          help: fitmentOn ? 'For specific vehicles, add them under Fitment after saving.' : null,
          advanced: !fitmentOn),
      FieldSpec('onlineOnly', 'Online only (sold on the website, not at the counter)',
          kind: FieldKind.toggle,
          value: product['onlineOnly'] == true,
          help: 'For parts you do not keep in the shop: listed only on shop.cartunez.in and ordered from the supplier '
              'when a customer buys one. The website always shows it as available. It never counts as shop stock '
              'and is hidden from Billing, stock counts and reorder alerts.'),
      FieldSpec('sku', product['id'] == null ? 'SKU / item code (optional)' : 'SKU / item code', value: product['sku'], required: product['id'] != null,
          help: product['id'] == null ? 'Leave blank to create one automatically.' : null),
      if (product['id'] != null && app.isManager)
        FieldSpec('salesAction', 'New sales', kind: FieldKind.select, value: 'keep', options: [
          ('keep', product['salesStopped'] == true ? 'Sales stopped' : 'Available for sale'),
          if (product['salesStopped'] == true) ('resume', 'Resume sales') else ('stop', 'Stop new sales'),
        ]),
      FieldSpec('brand', 'Brand (optional)', value: product['brand']),
      FieldSpec('category', 'Category (optional)',
          value: product['category'], suggestions: {...app.products.map((p) => '${p['category']}')}.toList()),
      FieldSpec('partNumber', 'Manufacturer part number (optional)', value: product['partNumber']),
      FieldSpec('barcodes', 'Barcodes (optional)', value: joined('barcodes'), help: 'Scan into this field or separate codes with commas. Leave empty to generate one.', barcodeInput: true),
      FieldSpec('wholesalePrice', 'Wholesale price (optional)', kind: FieldKind.money, value: money('wholesalePrice'), help: 'Blank uses the retail price.'),
      FieldSpec('cost', 'Purchase cost (optional)', kind: FieldKind.money, value: money('cost'), help: 'Supplier bills update it.'),
      // Not GST registered: prices are final, so there is no tax rate or HSN to enter.
      if (!app.noTax) ...[
        FieldSpec('taxRate', 'Tax rate (%)', kind: FieldKind.money, value: ((product['taxRate'] ?? commonRate) as int) / 100, required: true),
        FieldSpec('hsnSac', app.gst ? 'HSN / SAC' : 'HSN / SAC (optional)', value: product['hsnSac'], advanced: !app.gst, required: app.gst),
      ],
      FieldSpec('reorderLevel', 'Reorder when stock falls to (optional)', kind: FieldKind.number, value: product['reorderLevel'] ?? 0),
      FieldSpec('generateBarcode', 'If no barcode',
          kind: FieldKind.select,
          value: '${(product['barcodes'] as List? ?? []).isEmpty}',
          options: const [('true', 'Create an in-store barcode'), ('false', 'None (labels print the SKU)')],
          advanced: true),
      FieldSpec('description', 'Description', value: product['description'], advanced: true),
      FieldSpec('unit', 'Unit', value: product['unit'] ?? 'Each', advanced: true),
      FieldSpec('supplierId', 'Usual supplier', kind: FieldKind.select, value: product['supplierId'], options: optionsOf(app.list('suppliers')), advanced: true),
      FieldSpec('oemReferences', 'OEM references', value: joined('oemReferences'), advanced: true, help: 'Separate with commas.'),
      FieldSpec('supplierReferences', 'Supplier part references', value: joined('supplierReferences'), advanced: true),
      FieldSpec('supersedes', 'Replaces part numbers', value: joined('supersedes'), advanced: true),
      FieldSpec('interchanges', 'Interchange references', value: joined('interchanges'), advanced: true),
      FieldSpec('coreCharge', 'Refundable core deposit', kind: FieldKind.money, value: money('coreCharge') ?? '0', advanced: true),
      FieldSpec('packSize', 'Pack size', kind: FieldKind.number, value: product['packSize'] ?? 1, advanced: true),
      FieldSpec('serialTracked', 'Serial numbers',
          kind: FieldKind.select,
          value: '${product['serialTracked'] ?? false}',
          options: const [('false', 'Not tracked'), ('true', 'Record a serial for every unit')],
          advanced: true),
      // WS-C (workshop): warranty months and kit components.
      FieldSpec('warrantyMonths', 'Warranty (months)', kind: FieldKind.number, value: product['warrantyMonths'] ?? 0, advanced: true,
          help: 'Serial-tracked parts show warranty until the sale date plus this many months.'),
      FieldSpec('kitComponents', 'Kit components', value: kitComponentsText(app, product), advanced: true,
          help: 'Makes this a kit / installation package: SKU x quantity, separated by commas, '
              'for example ML-BRAKE-01 x1, ML-SERVICE-01 x1. Components leave stock when the kit is sold.'),
    ],
    onSubmit: (v) async {
      final barcodes = {...splitList(v['barcodes'])}.toList();
      final taken = {
        for (final p in app.products)
          if (p['id'] != product['id']) ...(p['barcodes'] as List? ?? []).map((e) => '$e'),
      };
      for (final code in barcodes) {
        if (taken.contains(code)) {
          final owner = app.products.firstWhere((p) => (p['barcodes'] as List? ?? []).contains(code));
          throw FormProblem('Barcode $code already belongs to ${owner['name']}.');
        }
        if (!(product['barcodes'] as List? ?? []).contains(code) && code.length == 13 && RegExp(r'^\d+$').hasMatch(code) && !gs1Valid(code)) {
          throw FormProblem('$code has a wrong check digit. Scan it again from the box.');
        }
      }
      String? created;
      if (barcodes.isEmpty && v['generateBarcode'] == 'true') {
        created = inStoreBarcode(taken);
        barcodes.add(created);
      }
      final retail = _minor(v['retailPrice']);
      final body = {
        ...product,
        ...v,
        'barcodes': barcodes,
        'retailPrice': retail,
        'wholesalePrice': '${v['wholesalePrice']}'.isEmpty ? retail : _minor(v['wholesalePrice']),
        'cost': '${v['cost'] ?? ''}'.trim().isEmpty && product['id'] != null ? (product['cost'] ?? 0) : _minor(v['cost']),
        'coreCharge': _minor(v['coreCharge']),
        'taxRate': app.noTax ? 0 : _minor(v['taxRate']),
        'reorderLevel': int.tryParse('${v['reorderLevel']}') ?? 0,
        'packSize': int.tryParse('${v['packSize']}') ?? 1,
        'universal': v['universal'] == 'true',
        // An online-only part takes no serial numbers (the website cannot record them).
        'serialTracked': v['serialTracked'] == 'true' && v['onlineOnly'] != true,
        'onlineOnly': v['onlineOnly'] == true,
        'unit': '${v['unit']}'.isEmpty ? 'Each' : v['unit'],
        for (final k in ['oemReferences', 'supplierReferences', 'supersedes', 'interchanges']) k: splitList(v[k]),
        // WS-C (workshop)
        'warrantyMonths': int.tryParse('${v['warrantyMonths']}') ?? 0,
        'components': parseKitComponents(app, '${v['kitComponents'] ?? ''}', product['id'] as String?),
      }..remove('generateBarcode')..remove('kitComponents');
      if (body['salesAction'] == 'keep') body.remove('salesAction');
      final saved = await app.mutate('/products', body, created == null ? 'Part saved.' : 'Part saved with barcode $created.');
      if (saved is Map) {
        if (pendingPhotos.isNotEmpty) {
          try {
            await uploadPartPhotos(app, '${saved['id']}', pendingPhotos);
            await app.sync();
          } catch (e) {
            app.toast('Part saved, but a photo could not be uploaded. Add it from Photos. ${errorText(e)}');
          }
        }
        onSaved?.call(Map<String, dynamic>.from(saved));
        if (product['id'] == null && onSaved == null) createdPart = Map<String, dynamic>.from(saved);
      }
    },
  );
  final newPart = createdPart;
  // Online-only parts carry no shop stock, so there is no first stock to add.
  if (newPart != null && !isOnlineOnly(newPart) && context.mounted) await offerFirstStock(context, newPart);
}

/// QA #6: a new part starts with no stock, so offer the two ways to add it.
Future<void> offerFirstStock(BuildContext context, Json part) async {
  final barcodes = part['barcodes'] as List? ?? [];
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('${part['name']} saved'),
      content: Text([
        'It has no stock yet. Add the units you have now.',
        if (barcodes.isNotEmpty) 'Barcode ${barcodes.first}.',
      ].join(' ')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Later')),
        OutlinedButton.icon(onPressed: () => Navigator.pop(dialogContext, 'adjust'), icon: const Icon(Icons.tune), label: const Text('Adjust stock')),
        FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, 'bill'), icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Receive against a supplier bill')),
      ],
    ),
  );
  if (!context.mounted) return;
  if (choice == 'bill') await enterBill(context, part: part, supplierId: part['supplierId'] as String?);
  if (choice == 'adjust') await stockOperation(context, 'adjust', productId: '${part['id']}');
}

/// [productId] pre-selects the part (QA #6: adding first stock to a new part).
Future<void> stockOperation(BuildContext context, String kind, {String? productId}) async {
  final app = context.appRead;
  final transactionId = uuid();
  final parts = optionsOf(app.stockParts, (p) => '${p['sku']} · ${p['name']}');
  final allBins = optionsOf(app.bins, (b) => '${app.binName(b)} · ${b['kind']}');
  await showFormDialog<void>(
    context,
    title: kind == 'adjust' ? 'Adjust stock' : 'Move stock',
    fields: [
      FieldSpec('productId', 'Part', kind: FieldKind.select, value: productId, options: parts, required: true, barcodeChoice: app.uniqueProductIdForCode),
      if (kind == 'move') ...[
        FieldSpec('fromBinId', 'From bin', kind: FieldKind.select, options: allBins, required: true, barcodeChoice: app.binIdForCode),
        FieldSpec('toBinId', 'To bin', kind: FieldKind.select, options: allBins, required: true, barcodeChoice: app.binIdForCode),
      ] else
        FieldSpec('binId', 'Bin', kind: FieldKind.select, options: allBins, required: true, barcodeChoice: app.binIdForCode),
      FieldSpec('quantity', kind == 'move' ? 'Quantity' : 'Change (+ adds, − removes)',
          kind: kind == 'adjust' ? FieldKind.signedNumber : FieldKind.number, required: true),
      const FieldSpec('reason', 'Reason', required: true),
      const FieldSpec('serials', 'Serial numbers', advanced: true, help: 'Serial-tracked parts only, separated by commas.'),
      if (!app.isManager && kind != 'move') FieldSpec('approvalId', 'Manager approval ID', required: true, help: 'Reference $transactionId'),
    ],
    onSubmit: (v) async {
      await app.mutate('/inventory/$kind', {
        ...v,
        'transactionId': transactionId,
        'serials': splitList(v['serials']),
        if (v['quantity'] != null) 'quantity': int.tryParse('${v['quantity']}') ?? 0,
      }, 'Stock updated.');
    },
  );
}

class BinsScreen extends StatelessWidget {
  const BinsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final search = ShellScope.of(context).search;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(onPressed: () => editBin(context, const {}), icon: const Icon(Icons.add), label: const Text('Add bin')),
        OutlinedButton(onPressed: () => stockOperation(context, 'move'), child: const Text('Move stock')),
        OutlinedButton.icon(
          onPressed: () => printLabels(context, [for (final b in app.bins) LabelItem(app.binName(b), '${b['id']}', sku: '${b['kind']}')]),
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: const Text('Print bin labels'),
        ),
      ]),
      ValueListenableBuilder(valueListenable: search, builder: (context, value, _) => DataList(
        rows: app.bins.where((b) => normalize(b['id']) == normalize(value.text) || normalize(app.binName(b)).contains(normalize(value.text))).toList(),
        empty: app.bins.isEmpty ? 'No bins yet. Add where stock is kept.' : 'No matching bins.',
        onTap: (b) => editBin(context, b),
        columns: [
          Col('Bin', (b) => Text(app.binName(b), style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
          Col('Condition', (b) => StatusChip(titleCase('${b['kind']}'))),
          Col('Units', (b) => Text('${app.stock.where((s) => s['binId'] == b['id']).fold<int>(0, (n, s) => n + ((s['quantity'] ?? 0) as int))}'), numeric: true),
        ],
      )),
    ]);
  }
}

Future<void> editBin(BuildContext context, Json bin) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: bin['id'] == null ? 'Add bin' : 'Rename bin',
    fields: [
      for (final k in ['area', 'rack', 'shelf', 'bin']) FieldSpec(k, titleCase(k), value: bin[k], required: true),
      if (bin['id'] == null)
        const FieldSpec('kind', 'Holds', kind: FieldKind.select, value: 'sellable', options: [
          ('sellable', 'Sellable stock'),
          ('damaged', 'Damaged returns'),
          ('warranty', 'Warranty returns'),
        ]),
    ],
    onSubmit: (v) async => app.mutate('/locations', {...bin, ...v}, 'Bin saved.'),
  );
}

class FitmentScreen extends StatelessWidget {
  const FitmentScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final rows = [
      for (final p in app.products)
        for (final f in p['fitments'] as List? ?? []) {...Map<String, dynamic>.from(f as Map), 'productId': p['id']},
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([FilledButton.icon(onPressed: () => addFitment(context), icon: const Icon(Icons.add), label: const Text('Add fitment rule'))]),
      DataList(
        rows: rows,
        empty: 'No fitment rules.',
        columns: [
          Col('Part', (f) => Text(app.productName('${f['productId']}'), style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
          Col('Vehicle', (f) => Text('${f['make']} ${f['model']}')),
          Col('Years', (f) => Text('${f['yearFrom']}–${f['yearTo']}')),
          Col('Details', (f) => Text([f['engine'], f['fuel'], f['trim']].where((e) => e != null && '$e'.isNotEmpty).join(' · '))),
        ],
      ),
    ]);
  }
}

Future<void> addFitment(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'Add fitment rule',
    fields: [
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true, options: optionsOf(app.products, (p) => '${p['sku']} · ${p['name']}')),
      const FieldSpec('make', 'Make', required: true),
      const FieldSpec('model', 'Model', required: true),
      const FieldSpec('yearFrom', 'First year', kind: FieldKind.number, required: true),
      const FieldSpec('yearTo', 'Last year', kind: FieldKind.number, required: true),
      const FieldSpec('source', 'Data source', required: true, help: 'Catalogue or supplier this comes from.'),
      for (final k in ['engine', 'fuel', 'trim', 'drivetrain', 'market']) FieldSpec(k, titleCase(k), advanced: true),
    ],
    onSubmit: (v) async => app.mutate('/fitments', {
      ...v,
      'yearFrom': int.tryParse('${v['yearFrom']}') ?? 0,
      'yearTo': int.tryParse('${v['yearTo']}') ?? 0,
      'exclusions': [],
      'effectiveFrom': DateTime.now().toIso8601String().substring(0, 10),
      'effectiveTo': null,
    }, 'Fitment rule added.'),
  );
}

class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([FilledButton.icon(onPressed: () => dispatchTransfer(context), icon: const Icon(Icons.send_outlined), label: const Text('Send stock'))]),
      DataList(
        rows: app.list('transfers').reversed.toList(),
        empty: 'No transfers.',
        columns: [
          Col('Date', (t) => Text(formatDate(t['createdAt']))),
          Col('From → To', (t) => Text('${app.branchName('${t['branchId']}')} → ${app.branchName('${t['destinationBranchId']}')}'), flex: 2),
          Col('Parts', (t) => Text([for (final l in t['lines'] as List) '${app.productName('${l['productId']}')} ${l['received']}/${l['quantity']}'].join(', ')), flex: 2),
          Col('Status', (t) => StatusChip(titleCase('${t['status']}'))),
        ],
        actions: (t) => [
          if (t['status'] != 'received' && t['destinationBranchId'] == app.session?.branchId)
            OutlinedButton(onPressed: () => receiveTransfer(context, t), child: const Text('Receive')),
        ],
      ),
    ]);
  }
}

Future<void> dispatchTransfer(BuildContext context) async {
  final app = context.appRead;
  final destinations = app.list('branches').where((b) => b['id'] != app.session?.branchId).toList();
  // QA #16: with no second branch there is nowhere to send stock; say so
  // instead of opening a form with an empty branch list.
  if (destinations.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Add a second branch first'),
        content: Text(app.isOwner
            ? 'Transfers move stock between your branches, and this shop has only one. Add the other branch in Settings › Branches, then send stock to it.'
            : 'Transfers move stock between branches, and this shop has only one. Ask the owner to add the other branch in Settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')),
          if (app.isOwner)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialog);
                ShellScope.of(context).open('settings');
              },
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) return;
  await showFormDialog<void>(
    context,
    title: 'Send stock to another branch',
    submit: 'Send',
    requireComplete: true, // QA #16: Send stays disabled until the form is complete.
    fields: [
      FieldSpec('destinationBranchId', 'To branch',
          kind: FieldKind.select, required: true, value: destinations.length == 1 ? destinations.single['id'] : null,
          options: optionsOf(destinations)),
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true, barcodeChoice: app.uniqueProductIdForCode, options: optionsOf(app.stockParts, (p) => '${p['sku']} · ${p['name']}')),
      FieldSpec('binId', 'From bin', kind: FieldKind.select, required: true, barcodeChoice: app.binIdForCode, options: optionsOf(app.sellableBins, app.binName)),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      const FieldSpec('reason', 'Reason', required: true),
      const FieldSpec('serials', 'Serial numbers', advanced: true),
    ],
    onSubmit: (v) async => app.mutate('/transfers', {
      'destinationBranchId': v['destinationBranchId'],
      'reason': v['reason'],
      'lines': [
        {'productId': v['productId'], 'binId': v['binId'], 'quantity': int.tryParse('${v['quantity']}') ?? 0, 'serials': splitList(v['serials'])},
      ],
    }, 'Stock sent.'),
  );
}

Future<void> receiveTransfer(BuildContext context, Json transfer) async {
  final app = context.appRead;
  final open = (transfer['lines'] as List).where((l) => l['quantity'] > l['received']).toList();
  await showFormDialog<void>(
    context,
    title: 'Receive transfer',
    submit: 'Receive',
    fields: [
      FieldSpec('lineId', 'Dispatch line',
          kind: FieldKind.select, required: true,
          value: open.length == 1 ? open.single['id'] : null,
          barcodeChoice: (code) {
            final id = app.uniqueProductIdForCode(code);
            final matches = open.where((l) => l['productId'] == id);
            return matches.length == 1 ? matches.single['id'] as String : null;
          },
          options: [for (final l in open) ('${l['id']}', '${app.productName('${l['productId']}')} · ${l['binId']} · ${l['quantity'] - l['received']} to receive')]),
      FieldSpec('binId', 'Into bin', kind: FieldKind.select, required: true, barcodeChoice: app.binIdForCode, options: optionsOf(app.sellableBins, app.binName)),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      const FieldSpec('serials', 'Serial numbers', advanced: true),
    ],
    onSubmit: (v) async => app.mutate('/transfers/${transfer['id']}/receive', {
      'lines': [
        {...v, 'quantity': int.tryParse('${v['quantity']}') ?? 0, 'serials': splitList(v['serials'])},
      ],
    }, 'Transfer received.'),
  );
}

class WarrantyScreen extends StatelessWidget {
  const WarrantyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final claimable = app.list('returns').where((r) =>
        r['condition'] == 'warranty' && !app.list('warrantyClaims').any((c) => c['returnId'] == r['id'])).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar([
        FilledButton.icon(
          onPressed: claimable.isEmpty
              ? null
              : () => showFormDialog<void>(
                    context,
                    title: 'Supplier warranty claim',
                    fields: [
                      FieldSpec('returnId', 'Warranty return', kind: FieldKind.select, required: true, options: optionsOf(claimable, (r) => '${r['number']}')),
                      FieldSpec('supplierId', 'Supplier', kind: FieldKind.select, required: true, options: optionsOf(app.list('suppliers'))),
                      const FieldSpec('reason', 'Fault', required: true),
                    ],
                    onSubmit: (v) async => app.mutate('/warranty-claims', {...v, 'status': 'open'}, 'Warranty claim created.'),
                  ),
          icon: const Icon(Icons.add),
          label: const Text('New claim'),
        ),
        if (app.isManager) OutlinedButton(onPressed: () => coreReturn(context), child: const Text('Core deposit refund')),
      ]),
      // QA #15: New claim needs a warranty return; link straight to it.
      if (claimable.isEmpty)
        Padding(
          key: const ValueKey('warranty-prerequisite'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('New claim needs a return recorded with the warranty condition.', style: Theme.of(context).textTheme.bodySmall),
            if (app.canSell)
              TextButton.icon(
                onPressed: () => ShellScope.of(context).open('sales-returns'),
                icon: const Icon(Icons.assignment_return_outlined, size: 18),
                label: const Text('Go to Returns & exchange'),
              ),
          ]),
        ),
      DataList(
        rows: app.list('warrantyClaims'),
        empty: claimable.isEmpty ? 'No claims. Record a return with the warranty condition first.' : 'No claims yet.',
        columns: [
          Col('Return', (c) => Text('${app.list('returns').where((r) => r['id'] == c['returnId']).firstOrNull?['number'] ?? c['returnId']}')),
          Col('Supplier', (c) => Text('${app.list('suppliers').where((s) => s['id'] == c['supplierId']).firstOrNull?['name'] ?? '—'}')),
          Col('Status', (c) => StatusChip(titleCase('${c['status']}'))),
          Col('Fault', (c) => Text('${c['reason']}'), flex: 2),
        ],
        actions: (c) => [
          OutlinedButton(
            onPressed: () => showFormDialog<void>(
              context,
              title: 'Update claim',
              fields: [
                FieldSpec('status', 'Status', kind: FieldKind.select, value: c['status'], options: [
                  for (final s in ['open', 'sent', 'approved', 'rejected', 'settled']) (s, titleCase(s)),
                ]),
                FieldSpec('reason', 'Note', value: c['reason'], required: true),
              ],
              onSubmit: (v) async => app.mutate('/warranty-claims', {...c, ...v}, 'Claim updated.'),
            ),
            child: const Text('Update'),
          ),
        ],
      ),
      SectionTitle('Core deposit refunds'),
      DataList(
        rows: app.list('coreReturns'),
        empty: 'No core refunds.',
        columns: [
          Col('Date', (r) => Text(formatDate(r['createdAt']))),
          Col('Part', (r) => Text(app.productName('${r['productId']}'))),
          Col('Qty', (r) => Text('${r['quantity']}'), numeric: true),
          Col('Refund', (r) => Text(app.money(r['total'] as num?)), numeric: true),
        ],
      ),
    ]);
  }
}

Future<void> coreReturn(BuildContext context) async {
  final app = context.appRead;
  final invoices = app.list('invoices').where((i) => (i['lines'] as List).any((l) => (l['coreCharge'] ?? 0) > 0)).toList();
  if (invoices.isEmpty) return app.toast('No invoices carry a core deposit.');
  await showFormDialog<void>(
    context,
    title: 'Core deposit refund',
    fields: [
      FieldSpec('invoiceId', 'Invoice', kind: FieldKind.select, required: true, options: optionsOf(invoices, (i) => '${i['number']}')),
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true, options: optionsOf(app.products.where((p) => (p['coreCharge'] ?? 0) > 0).toList())),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      FieldSpec('refundType', 'Refund by', kind: FieldKind.select, value: 'Cash', options: [for (final t in app.tenderTypes) (t, t)]),
      const FieldSpec('reason', 'Reason', required: true),
    ],
    onSubmit: (v) async => app.mutate('/core-returns', {...v, 'quantity': int.tryParse('${v['quantity']}') ?? 1}, 'Core refund recorded.'),
  );
}
