import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../photos.dart';
import '../widgets.dart';

// ---------- Prices (same rules as the server) ----------

/// MRP (price including tax) and the online selling price, in paise.
({int mrp, int selling}) onlinePrices(AppState app, Json product, Json? listing) {
  final retail = (product['retailPrice'] as num?)?.toInt() ?? 0;
  final tax = (product['taxRate'] as num?)?.toInt() ?? 0;
  final mrp = app.settings['taxMode'] == 'inclusive' ? retail : (retail + retail * tax / 10000).round();
  final pricing = (listing?['pricing'] as Map?) ?? const {'mode': 'mrp'};
  final selling = switch (pricing['mode']) {
    'percent' => (mrp * (10000 - ((pricing['percent'] as num?)?.toInt() ?? 0)) / 10000).round(),
    'fixed' => (pricing['price'] as num?)?.toInt() ?? mrp,
    _ => mrp,
  };
  return (mrp: mrp, selling: selling);
}

Json get _magento => {};

extension OnlineStore on AppState {
  Json get magento => Map<String, dynamic>.from(((settings['integrations'] as Map?)?['magento'] as Map?) ?? _magento);
  bool get magentoConnected => magento['enabled'] == true && magento['tokenSet'] == true && '${magento['baseUrl'] ?? ''}'.isNotEmpty;
  Map<String, Json> get onlineListings => {for (final l in list('onlineListings')) '${l['productId']}': l};
}

/// Website status of one part, for the chip and filters.
String websiteStatus(Json? listing) {
  if (listing == null) return 'Not on website';
  final state = (listing['sync'] as Map?)?['state'];
  final published = listing['published'] == true;
  return switch (state) {
    'error' => 'Error',
    'pending' => published ? 'Sending…' : 'Removing…',
    'synced' => published ? 'On website' : 'Not on website',
    'unpublished' => 'Unpublished',
    _ => published ? 'Sending…' : 'Not on website',
  };
}

/// Today's date in India (YYYY-MM-DD), as the server compares sale end dates.
String indiaToday([DateTime? now]) =>
    (now ?? DateTime.now()).toUtc().add(const Duration(hours: 5, minutes: 30)).toIso8601String().substring(0, 10);

/// Sale state of one part: 'on' (shown in the shop's Sale section), 'ended', or null (not on sale).
String? saleState(Json? listing, [DateTime? now]) {
  if (listing == null || listing['onSale'] != true) return null;
  final until = '${listing['saleUntil'] ?? ''}';
  if (until.isNotEmpty && indiaToday(now).compareTo(until) > 0) return 'ended';
  return 'on';
}

const _availabilityNames = {'stock': 'In stock', 'order': 'On order', 'hidden': 'Hidden when out'};

// ---------- Screen ----------

class OnlineStoreScreen extends StatefulWidget {
  const OnlineStoreScreen({super.key});
  @override
  State<OnlineStoreScreen> createState() => _OnlineStoreScreenState();
}

class _OnlineStoreScreenState extends State<OnlineStoreScreen> {
  final selected = <String>{};
  String filter = 'all';

  static const filters = [
    ('all', 'All parts'),
    ('on', 'On website'),
    ('off', 'Not on website'),
    ('order', 'On order'),
    ('sale', 'On sale'),
    ('error', 'Errors'),
    ('low', 'Low stock'),
  ];

  bool _matches(AppState app, Json p, Json? l) => switch (filter) {
        'on' => l?['published'] == true,
        'off' => l?['published'] != true,
        'order' => l?['availability'] == 'order',
        'sale' => l?['onSale'] == true,
        'error' => (l?['sync'] as Map?)?['state'] == 'error',
        'low' => app.available('${p['id']}') <= ((p['reorderLevel'] as num?) ?? 0),
        _ => true,
      };

  Future<void> _bulk(Json changes, String done) async {
    final app = context.appRead;
    try {
      await app.mutate('/online-listings', {'productIds': selected.toList(), 'changes': changes}, done);
    } catch (e) {
      app.toast(errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final listings = app.onlineListings;
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final parts = app.saleProducts.where((p) => p['type'] != 'service').toList();
        final rows = parts
            .where((p) => q.isEmpty || [p['name'], p['sku'], p['brand'], p['partNumber'], ...(p['barcodes'] as List? ?? [])].any((v) => normalize(v).contains(q)))
            .where((p) => _matches(app, p, listings['${p['id']}']))
            .toList();
        selected.removeWhere((id) => !parts.any((p) => p['id'] == id));
        final allSelected = rows.isNotEmpty && rows.every((p) => selected.contains(p['id']));
        final errors = listings.values.where((l) => (l['sync'] as Map?)?['state'] == 'error').length;
        final waiting = listings.values.where((l) => (l['sync'] as Map?)?['state'] == 'pending').length;
        final published = listings.values.where((l) => l['published'] == true).length;

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _ConnectionBanner(published: published, waiting: waiting, errors: errors),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, label) in filters)
              ChoiceChip(label: Text(label), selected: filter == key, onSelected: (_) => setState(() => filter = key)),
          ]),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: selected.isEmpty
                ? const SizedBox.shrink()
                : _BulkBar(
                    count: selected.length,
                    onPublish: () => _bulk({'published': true}, 'Publishing ${selected.length} part(s) to Magento.'),
                    onUnpublish: () => _bulk({'published': false}, 'Removing ${selected.length} part(s) from the website.'),
                    onPrice: () => _priceDialog(context, selected.length, (pricing) => _bulk({'pricing': pricing}, 'Online prices updated.')),
                    onAvailability: () => _availabilityDialog(context, (c) => _bulk(c, 'Availability updated.')),
                    onBuffer: () => _bufferDialog(context, (c) => _bulk(c, 'Safety buffer updated.')),
                    onSale: () => _saleDialog(
                      context,
                      [for (final p in parts) if (selected.contains(p['id'])) p],
                      listings,
                      (c) => _bulk(c, 'Putting ${selected.length} part(s) on sale.'),
                    ),
                    onEndSale: () => _bulk({'onSale': false}, 'Removing ${selected.length} part(s) from the sale.'),
                    onClear: () => setState(selected.clear),
                  ),
          ),
          _ListingTable(
            rows: rows,
            listings: listings,
            selected: selected,
            allSelected: allSelected,
            onToggle: (id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id)),
            onToggleAll: () => setState(() => allSelected ? selected.removeAll(rows.map((p) => p['id'])) : selected.addAll(rows.map((p) => '${p['id']}'))),
            onOpen: (p) => editListing(context, p),
            empty: parts.isEmpty ? 'No parts yet. Add parts in Inventory first.' : 'No part matches.',
          ),
        ]);
      },
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.published, required this.waiting, required this.errors});
  final int published, waiting, errors;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final m = app.magento;
    if (!app.magentoConnected) {
      return Card(
        color: const Color(0xFFFFF7E8),
        child: ListTile(
          leading: const Icon(Icons.link_off, color: Brand.warning),
          title: const Text('Magento is not connected'),
          subtitle: Text(app.isOwner
              ? 'Connect your store to publish parts. Changes you make here are kept and sent once connected.'
              : 'Ask the owner to connect the Magento store in Settings. Changes you make here are kept.'),
          trailing: app.isOwner ? FilledButton(onPressed: () => editMagento(context), child: const Text('Connect')) : null,
        ),
      );
    }
    final branch = app.list('branches').where((b) => b['id'] == m['branchId']).firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Icon(Icons.storefront_outlined, color: Brand.forest),
          Text('${m['baseUrl']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('Stock from ${branch?['name'] ?? m['branchId']} · buffer ${m['defaultBuffer'] ?? 0}', style: Theme.of(context).textTheme.bodySmall),
          Text('$published on website', style: Theme.of(context).textTheme.bodySmall),
          if (waiting > 0) Text('$waiting sending…', style: Theme.of(context).textTheme.bodySmall),
          if (errors > 0) Text('$errors with errors', style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
          if (errors > 0)
            OutlinedButton(
              onPressed: () => app.mutate('/integrations/magento/retry', {}, 'Retrying parts with errors.').catchError((e) => app.toast(errorText(e))),
              child: const Text('Retry errors'),
            ),
          TextButton(onPressed: () => app.sync(loud: true), child: const Text('Refresh')),
          // Sends every website part again, e.g. after brands were added or the shop changed.
          Tooltip(
            message: 'Send every website part to the shop again (brands, categories, prices, stock)',
            child: TextButton(
              onPressed: () => app.mutate('/integrations/magento/retry', {'all': true}, 'Sending all website parts again.').catchError((e) => app.toast(errorText(e))),
              child: const Text('Send all again'),
            ),
          ),
          const _ComparisonLine(),
        ]),
      ),
    );
  }
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.count,
    required this.onPublish,
    required this.onUnpublish,
    required this.onPrice,
    required this.onAvailability,
    required this.onBuffer,
    required this.onSale,
    required this.onEndSale,
    required this.onClear,
  });
  final int count;
  final VoidCallback onPublish, onUnpublish, onPrice, onAvailability, onBuffer, onSale, onEndSale, onClear;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Brand.ink, borderRadius: BorderRadius.circular(12)),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('$count selected', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.lime, foregroundColor: Brand.ink),
            onPressed: onPublish,
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Publish'),
          ),
          for (final (label, action) in [
            ('Unpublish', onUnpublish),
            ('Set price', onPrice),
            ('Availability', onAvailability),
            ('Buffer', onBuffer),
            ('Put on sale…', onSale),
            ('Remove from sale', onEndSale),
          ])
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              onPressed: action,
              child: Text(label),
            ),
          TextButton(style: TextButton.styleFrom(foregroundColor: Colors.white70), onPressed: onClear, child: const Text('Clear')),
        ]),
      );
}

class _ListingTable extends StatelessWidget {
  const _ListingTable({
    required this.rows,
    required this.listings,
    required this.selected,
    required this.allSelected,
    required this.onToggle,
    required this.onToggleAll,
    required this.onOpen,
    required this.empty,
  });
  final List<Json> rows;
  final Map<String, Json> listings;
  final Set<String> selected;
  final bool allSelected;
  final ValueChanged<String> onToggle;
  final VoidCallback onToggleAll;
  final ValueChanged<Json> onOpen;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return EmptyState(message: empty);
    final app = context.app;
    final small = Theme.of(context).textTheme.bodySmall;
    final onlineBranch = app.magento['branchId'] == app.session?.branchId;
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 760;
      Widget statusChip(Json? l) {
        final status = websiteStatus(l);
        final (bg, fg) = switch (status) {
          'On website' => (Brand.mint, Brand.forest),
          'Error' => (const Color(0xFFFBEBE7), Brand.danger),
          'Sending…' || 'Removing…' => (const Color(0xFFFDF3DF), Brand.warning),
          _ => (const Color(0xFFEEF1EF), Brand.muted),
        };
        final chip = Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
          child: Text(status, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
        );
        final error = (l?['sync'] as Map?)?['error'];
        return error == null ? chip : Tooltip(message: '$error', child: chip);
      }

      Widget saleChip(Json? l) {
        final state = saleState(l);
        if (state == null) return const SizedBox.shrink();
        final until = '${l?['saleUntil'] ?? ''}';
        final label = state == 'ended' ? 'Sale ended' : until.isEmpty ? 'On sale' : 'On sale to ${until.substring(8)}/${until.substring(5, 7)}/${until.substring(0, 4)}';
        return Container(
          key: ValueKey('sale-chip-${l?['productId']}'),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: state == 'ended' ? const Color(0xFFEEF1EF) : const Color(0xFFFBEBE7),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(label, style: TextStyle(color: state == 'ended' ? Brand.muted : Brand.danger, fontSize: 11.5, fontWeight: FontWeight.w700)),
        );
      }

      Widget price(Json p, Json? l) {
        final pr = onlinePrices(app, p, l);
        final off = pr.mrp > 0 && pr.selling < pr.mrp ? ((pr.mrp - pr.selling) * 100 / pr.mrp).round() : 0;
        return Column(crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: [
          Text(app.money(pr.selling), style: const TextStyle(fontWeight: FontWeight.w700)),
          if (off > 0)
            Text.rich(TextSpan(children: [
              TextSpan(text: app.money(pr.mrp), style: const TextStyle(decoration: TextDecoration.lineThrough)),
              TextSpan(text: '  $off% off', style: const TextStyle(color: Brand.forest, fontWeight: FontWeight.w700)),
            ]), style: small),
        ]);
      }

      String stock(Json p, Json? l) {
        final pos = app.available('${p['id']}');
        final buffer = (l?['buffer'] as num?)?.toInt() ?? (app.magento['defaultBuffer'] as num?)?.toInt() ?? 0;
        final online = onlineBranch ? (pos - buffer).clamp(0, 1 << 30) : (l?['sync'] as Map?)?['qty'];
        return onlineBranch ? '$pos in shop · ${online ?? '—'} online' : '${online ?? '—'} online';
      }

      String availability(Json? l) {
        final a = '${l?['availability'] ?? 'stock'}';
        return a == 'order' ? 'On order · ${l?['leadDays'] ?? 7} days' : _availabilityNames[a]!;
      }

      if (narrow) {
        return Column(children: [
          CheckboxListTile(value: allSelected, onChanged: (_) => onToggleAll(), title: Text('Select all ${rows.length}'), controlAffinity: ListTileControlAffinity.leading),
          for (final p in rows)
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onOpen(p),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Checkbox(value: selected.contains(p['id']), onChanged: (_) => onToggle('${p['id']}')),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${p['sku']} · ${stock(p, listings['${p['id']}'])}', style: small),
                        const SizedBox(height: 6),
                        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          statusChip(listings['${p['id']}']),
                          if (saleState(listings['${p['id']}']) != null) saleChip(listings['${p['id']}']),
                          Text(availability(listings['${p['id']}']), style: small),
                        ]),
                      ]),
                    ),
                    price(p, listings['${p['id']}']),
                  ]),
                ),
              ),
            ),
        ]);
      }

      Widget header(String t, {int flex = 1, bool end = false}) => Expanded(
            flex: flex,
            child: Text(t, textAlign: end ? TextAlign.right : TextAlign.left, style: small?.copyWith(fontWeight: FontWeight.w700)),
          );
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Container(
            color: const Color(0xFFF2F5F3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              Checkbox(value: allSelected, onChanged: (_) => onToggleAll()),
              const SizedBox(width: 54),
              header('Part', flex: 4),
              header('Website', flex: 2),
              header('Availability', flex: 2),
              header('Stock', flex: 2),
              header('Online price', flex: 2, end: true),
              const SizedBox(width: 16),
            ]),
          ),
          for (final p in rows)
            InkWell(
              onTap: () => onOpen(p),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: selected.contains(p['id']) ? const Color(0xFFF2F9EA) : null,
                  border: const Border(top: BorderSide(color: Brand.line)),
                ),
                child: Row(children: [
                  Checkbox(value: selected.contains(p['id']), onChanged: (_) => onToggle('${p['id']}')),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(width: 44, height: 44, color: const Color(0xFFEFF3F0), child: PartPhoto(product: p, iconSize: 20)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 4,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${p['sku']}${'${p['brand'] ?? ''}'.isNotEmpty ? ' · ${p['brand']}' : ''}'
                          '${app.photosOf('${p['id']}').isEmpty ? ' · no photo' : ''}', style: small),
                    ]),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(spacing: 6, runSpacing: 4, children: [
                        statusChip(listings['${p['id']}']),
                        if (saleState(listings['${p['id']}']) != null) saleChip(listings['${p['id']}']),
                      ]),
                    ),
                  ),
                  Expanded(flex: 2, child: Text(availability(listings['${p['id']}']))),
                  Expanded(flex: 2, child: Text(stock(p, listings['${p['id']}']), style: small)),
                  Expanded(flex: 2, child: price(p, listings['${p['id']}'])),
                  const SizedBox(width: 16),
                ]),
              ),
            ),
        ]),
      );
    });
  }
}

// ---------- Dialogs ----------

Json _pricing(Json v) => switch ('${v['mode']}') {
      'percent' => {'mode': 'percent', 'percent': ((double.tryParse('${v['percent']}') ?? 0) * 100).round()},
      'fixed' => {'mode': 'fixed', 'price': ((double.tryParse('${v['price']}') ?? 0) * 100).round()},
      _ => {'mode': 'mrp'},
    };

const _priceModes = [('mrp', 'Same as MRP (no discount)'), ('percent', '% off MRP'), ('fixed', 'Fixed selling price')];

Future<void> _priceDialog(BuildContext context, int count, Future<void> Function(Json pricing) apply) => showFormDialog<void>(
      context,
      title: 'Online price for $count part(s)',
      submit: 'Apply',
      fields: const [
        FieldSpec('mode', 'Selling price', kind: FieldKind.select, value: 'percent', options: _priceModes),
        FieldSpec('percent', 'Discount off MRP (%)', kind: FieldKind.number, value: 10, help: 'Used with "% off MRP". The website shows MRP struck through.'),
        FieldSpec('price', 'Fixed selling price', kind: FieldKind.money, help: 'Used with "Fixed selling price". Cannot be above MRP.'),
      ],
      onSubmit: (v) async {
        final p = _pricing(v);
        if (p['mode'] == 'percent' && ((p['percent'] as int) < 0 || (p['percent'] as int) > 9000)) throw FormProblem('Enter a discount from 0 to 90%.');
        if (p['mode'] == 'fixed' && (p['price'] as int) < 1) throw FormProblem('Enter the selling price.');
        await apply(p);
      },
    );

Future<void> _availabilityDialog(BuildContext context, Future<void> Function(Json changes) apply) => showFormDialog<void>(
      context,
      title: 'Availability on the website',
      submit: 'Apply',
      fields: const [
        FieldSpec('availability', 'When stock runs out', kind: FieldKind.select, value: 'stock', options: [
          ('stock', 'In stock: show "Out of stock" at 0'),
          ('order', 'On order: customers can still buy (backorder)'),
          ('hidden', 'Hide the part at 0 stock'),
        ]),
        FieldSpec('leadDays', 'On order: ships in (days)', kind: FieldKind.number, value: 7),
      ],
      onSubmit: (v) async {
        final days = int.tryParse('${v['leadDays']}') ?? 7;
        if (days < 0 || days > 365) throw FormProblem('Lead time is 0 to 365 days.');
        await apply({'availability': v['availability'], 'leadDays': days});
      },
    );

Future<void> _bufferDialog(BuildContext context, Future<void> Function(Json changes) apply) => showFormDialog<void>(
      context,
      title: 'Safety buffer',
      submit: 'Apply',
      fields: const [
        FieldSpec('buffer', 'Units held back from the website', kind: FieldKind.number,
            help: 'Leave empty to use the shop default. Protects the last units from selling twice.'),
      ],
      onSubmit: (v) async {
        final raw = '${v['buffer'] ?? ''}'.trim();
        final n = raw.isEmpty ? null : int.tryParse(raw);
        if (raw.isNotEmpty && (n == null || n < 0)) throw FormProblem('Enter 0 or more units, or leave empty.');
        await apply({'buffer': n});
      },
    );

/// Puts the selected parts on sale: they join the shop's Sale category and home page section.
Future<void> _saleDialog(BuildContext context, List<Json> parts, Map<String, Json> listings, Future<void> Function(Json changes) apply) {
  final app = context.appRead;
  final noDiscount = parts.where((p) {
    final pr = onlinePrices(app, p, listings['${p['id']}']);
    return pr.selling >= pr.mrp;
  }).toList();
  final unpublished = parts.where((p) => listings['${p['id']}']?['published'] != true).length;
  return showFormDialog<void>(
    context,
    title: 'Put ${parts.length} part(s) on sale',
    submit: 'Put on sale',
    header: Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('The parts are shown in the Sale section of the shop\'s home page. The sale price is the selling '
            'price set with Set price (MRP is shown struck through).'),
        if (noDiscount.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            key: const ValueKey('sale-no-discount'),
            '${noDiscount.length == 1 ? '${noDiscount.first['sku']} sells' : '${noDiscount.length} parts sell'} at MRP, '
            'so no discount will show. Set a lower price first.',
            style: const TextStyle(color: Brand.warning, fontWeight: FontWeight.w600),
          ),
        ],
        if (unpublished > 0) ...[
          const SizedBox(height: 8),
          Text('$unpublished part(s) are not published; they appear in the sale once published.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ]),
    ),
    fields: const [
      FieldSpec('saleUntil', 'Sale ends on (YYYY-MM-DD)', kind: FieldKind.date,
          help: 'Optional. The last day of the sale; leave empty to keep the parts on sale until removed.'),
    ],
    onSubmit: (v) async {
      final until = '${v['saleUntil'] ?? ''}'.trim();
      if (until.isNotEmpty) {
        final parsed = DateTime.tryParse(until);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(until) || parsed == null || parsed.toIso8601String().substring(0, 10) != until) {
          throw FormProblem('Enter the end date as YYYY-MM-DD.');
        }
        if (until.compareTo(indiaToday()) < 0) throw FormProblem('The end date cannot be in the past.');
      }
      await apply({'onSale': true, 'saleUntil': until.isEmpty ? null : until});
    },
  );
}

/// Everything about one part on the website.
Future<void> editListing(BuildContext context, Json product) async {
  final app = context.appRead;
  final l = app.onlineListings['${product['id']}'] ?? const {};
  final pricing = (l['pricing'] as Map?) ?? const {'mode': 'mrp'};
  final pr = onlinePrices(app, product, l);
  final sync = (l['sync'] as Map?) ?? const {};
  await showFormDialog<void>(
    context,
    title: '${product['name']}',
    header: Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(
            'MRP ${app.money(pr.mrp)} · ${websiteStatus(l.isEmpty ? null : l)}'
            '${sync['error'] != null ? '\n${sync['error']}' : ''}',
            style: TextStyle(color: sync['error'] != null ? Brand.danger : null),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => editPhotos(context, product),
          icon: const Icon(Icons.photo_library_outlined, size: 18),
          label: Text('Photos (${app.photosOf('${product['id']}').length})'),
        ),
      ]),
    ),
    fields: [
      FieldSpec('published', 'Show on the website', kind: FieldKind.select, value: l['published'] == true ? 'yes' : 'no',
          options: const [('yes', 'Yes, published'), ('no', 'No')]),
      FieldSpec('mode', 'Selling price', kind: FieldKind.select, value: '${pricing['mode'] ?? 'mrp'}', options: _priceModes),
      FieldSpec('percent', 'Discount off MRP (%)', kind: FieldKind.number, value: ((pricing['percent'] as num?) ?? 0) / 100),
      FieldSpec('price', 'Fixed selling price', kind: FieldKind.money, value: ((pricing['price'] as num?) ?? pr.mrp) / 100),
      FieldSpec('availability', 'When stock runs out', kind: FieldKind.select, value: '${l['availability'] ?? 'stock'}', options: const [
        ('stock', 'In stock: show "Out of stock" at 0'),
        ('order', 'On order: customers can still buy'),
        ('hidden', 'Hide the part at 0 stock'),
      ]),
      FieldSpec('leadDays', 'On order: ships in (days)', kind: FieldKind.number, value: l['leadDays'] ?? 7),
      // On sale: shown in the shop's Sale menu and the home page "On sale" section
      // at the selling price above (owners and managers only).
      if (app.isManager) ...[
        FieldSpec('onSale', 'On sale (home page & Sale menu)', kind: FieldKind.select,
            value: l['onSale'] == true ? 'yes' : 'no',
            options: const [('no', 'No'), ('yes', 'Yes, show in the sale')],
            help: 'The sale price is the selling price above.'),
        FieldSpec('saleUntil', 'Sale ends on (YYYY-MM-DD)', kind: FieldKind.date, value: l['saleUntil'],
            help: 'Optional. Leave empty to keep it on sale until you remove it.'),
      ],
      FieldSpec('buffer', 'Safety buffer (units)', kind: FieldKind.number, value: l['buffer'], help: 'Empty = shop default.'),
      FieldSpec('description', 'Website description', kind: FieldKind.multiline, value: l['description'] ?? '', advanced: true),
    ],
    onSubmit: (v) async {
      final buffer = '${v['buffer'] ?? ''}'.trim();
      final onSale = v['onSale'] == 'yes';
      final until = '${v['saleUntil'] ?? ''}'.trim();
      if (app.isManager && onSale && until.isNotEmpty) {
        final parsed = DateTime.tryParse(until);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(until) || parsed == null || parsed.toIso8601String().substring(0, 10) != until) {
          throw FormProblem('Enter the sale end date as YYYY-MM-DD.');
        }
        if (until.compareTo(indiaToday()) < 0) throw FormProblem('The sale end date cannot be in the past.');
      }
      await app.mutate('/online-listings', {
        'productIds': [product['id']],
        'changes': {
          'published': v['published'] == 'yes',
          'pricing': _pricing(v),
          'availability': v['availability'],
          'leadDays': int.tryParse('${v['leadDays']}') ?? 7,
          'buffer': buffer.isEmpty ? null : int.tryParse(buffer),
          'description': '${v['description'] ?? ''}',
          if (app.isManager) ...{
            'onSale': onSale,
            if (onSale) 'saleUntil': until.isEmpty ? null : until,
          },
        },
      }, 'Saved. Magento is being updated.');
    },
  );
}

/// Owner: connect the Magento store.
Future<void> editMagento(BuildContext context) async {
  final app = context.appRead;
  final m = app.magento;
  final branches = app.list('branches');
  await showFormDialog<void>(
    context,
    title: 'Magento store',
    header: const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Text('In the Magento admin: System › Integrations › Add New Integration. Allow Catalog, Stores and '
          'Sales › Orders (view), save, Activate, then copy the Access Token here. The token stays on the server.'),
    ),
    fields: [
      FieldSpec('baseUrl', 'Store address', value: m['baseUrl'] ?? 'https://shop.cartunez.in', required: true),
      FieldSpec('token', m['tokenSet'] == true ? 'Access token (saved; leave empty to keep)' : 'Access token', kind: FieldKind.password,
          required: m['tokenSet'] != true),
      FieldSpec('branchId', 'Branch that sells online', kind: FieldKind.select, value: m['branchId'] ?? app.session?.branchId,
          options: [for (final b in branches) ('${b['id']}', '${b['name']}')], required: true),
      FieldSpec('defaultBuffer', 'Safety buffer (units held back)', kind: FieldKind.number, value: m['defaultBuffer'] ?? 1),
      // A paused store shows as "not connected", so opening this dialog means connecting: default to on.
      FieldSpec('enabled', 'Sync', kind: FieldKind.select, value: 'on',
          options: const [('on', 'On: keep Magento up to date'), ('off', 'Paused')]),
      FieldSpec('attributeSetId', 'Magento attribute set ID', kind: FieldKind.number, value: m['attributeSetId'] ?? 4, advanced: true),
      FieldSpec('websiteId', 'Magento website ID', kind: FieldKind.number, value: m['websiteId'] ?? 1, advanced: true),
      FieldSpec('rootCategoryId', 'Magento root category ID', kind: FieldKind.number, value: m['rootCategoryId'] ?? 2, advanced: true,
          help: 'Part categories are created under this one (2 = Default Category).'),
      // WS-E: MSI source shipments come from, and the payment methods a gateway collects.
      FieldSpec('sourceCode', 'MSI source code', value: m['sourceCode'] ?? '', advanced: true,
          help: 'The Magento inventory source orders ship from (Stores › Sources). Leave empty for the default source.'),
      FieldSpec('prepaidMethods', 'Prepaid payment method codes', value: ((m['prepaidMethods'] as List?) ?? []).join(', '), advanced: true,
          help: 'Magento payment codes a gateway has already collected, for example razorpay. Others (bank transfer / UPI, '
              'cash on delivery) stay on the customer\'s account until the money is recorded.'),
    ],
    onSubmit: (v) async {
      final token = '${v['token'] ?? ''}'.trim();
      if (token.isNotEmpty || '${v['baseUrl']}' != '${m['baseUrl'] ?? ''}') {
        try {
          await app.api('/integrations/magento/test', body: {'baseUrl': v['baseUrl'], if (token.isNotEmpty) 'token': token});
        } catch (e) {
          throw FormProblem('Could not connect: ${errorText(e)}');
        }
      }
      await app.mutate('/integrations/magento', {
        'baseUrl': v['baseUrl'],
        if (token.isNotEmpty) 'token': token,
        'branchId': v['branchId'],
        'defaultBuffer': int.tryParse('${v['defaultBuffer']}') ?? 0,
        'attributeSetId': int.tryParse('${v['attributeSetId']}') ?? 4,
        'websiteId': int.tryParse('${v['websiteId']}') ?? 1,
        'rootCategoryId': int.tryParse('${v['rootCategoryId']}') ?? 2,
        'sourceCode': '${v['sourceCode'] ?? ''}'.trim(),
        'prepaidMethods': '${v['prepaidMethods'] ?? ''}',
        'enabled': v['enabled'] == 'on',
      }, v['enabled'] == 'on' ? 'Magento connected. Published parts are being sent.' : 'Magento settings saved. Sync is paused.');
    },
  );
}

/// Checks the saved connection and says what Magento answered.
Future<void> testMagento(BuildContext context) async {
  final app = context.appRead;
  try {
    final r = await app.api('/integrations/magento/test', body: {});
    app.toast('Connected to ${r['baseUrl']} (${r['currency'] ?? 'currency unknown'}).');
  } catch (e) {
    app.toast('Magento: ${errorText(e)}');
  }
}

/// The daily comparison of Magento with the POS, with "Compare now".
class _ComparisonLine extends StatefulWidget {
  const _ComparisonLine();
  @override
  State<_ComparisonLine> createState() => _ComparisonLineState();
}

class _ComparisonLineState extends State<_ComparisonLine> {
  bool running = false;

  Future<void> _run() async {
    final app = context.appRead;
    setState(() => running = true);
    try {
      final r = await app.api('/integrations/magento/compare', body: {});
      await app.sync();
      app.toast((r['differences'] ?? 0) == 0 ? 'Magento matches the POS.' : '${r['differences']} difference(s) found and being corrected.');
    } catch (e) {
      await app.sync();
      app.toast('Magento: ${errorText(e)}');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final check = app.snapshot['magentoCheck'] as Map?;
    final small = Theme.of(context).textTheme.bodySmall;
    final text = check == null
        ? 'Not compared yet'
        : check['error'] != null
            ? 'Last comparison failed: ${check['error']}'
            : 'Compared ${formatDate(check['at'] as String?)}: ${check['checked']} parts, '
                '${(check['differenceCount'] ?? 0) == 0 ? 'all match' : '${check['partsFixed']} corrected'}';
    final details = ((check?['differences'] as List?) ?? const [])
        .take(10)
        .map((d) => '${(d as Map)['sku']}: ${d['field']} POS ${d['pos']} · Magento ${d['magento']}')
        .join('\n');
    return Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Tooltip(
        message: details.isEmpty ? text : details,
        child: Text(text, style: small?.copyWith(color: check?['error'] != null ? Brand.danger : null)),
      ),
      TextButton(onPressed: running ? null : _run, child: Text(running ? 'Comparing…' : 'Compare now')),
    ]);
  }
}
