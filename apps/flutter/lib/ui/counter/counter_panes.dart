import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../orders/exchange.dart' show ExchangeReturnsPanel, exchangeCredit, exchangeReturns; // WS-B
import '../people/account_actions.dart' show availableAdvance; // WS-B
import '../screens/inventory.dart' show editProduct;
import '../screens/people.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'catalog_grid.dart';
import 'counter_actions.dart';
import 'counter_flow.dart';
import 'counter_keys.dart';
import 'fitment_bar.dart';
import 'held_bills.dart';
import 'tender_sheet.dart';

// WS-A: counter layouts. Desktop (>= 1200): 60/40, left pane toggles between a
// dense parts list, the photo grid and quick-tap service tiles; right pane is
// the cart table with a sticky payment dock. Phone: compact rows and a sticky
// cart pill that opens a draggable sheet.

const _figures = [FontFeature.tabularFigures()];

/// Parts for sale matching the search box, category and vehicle (fitment).
List<Json> counterParts(AppState app, String search, String category, {bool services = false, bool showAllFitment = false}) {
  final q = normalize(search);
  final exactIds = {for (final part in app.findByCode(search, forSale: true)) part['id']};
  final vehicle = app.cart['vehicle'] as Map?;
  return app.saleProducts.where((p) {
    if (services != (p['type'] == 'service')) return false;
    if (exactIds.isNotEmpty) return exactIds.contains(p['id']);
    if (category != 'All parts' && p['category'] != category) return false;
    if (q.isNotEmpty &&
        ![p['name'], p['sku'], p['partNumber'], p['description'], ...(p['barcodes'] as List? ?? []), ...(p['oemReferences'] as List? ?? [])]
            .any((v) => normalize(v).contains(q))) {
      return false;
    }
    if (!services && !showAllFitment && vehicle != null && fitment(p, Map<String, dynamic>.from(vehicle)).needsOverride) return false;
    return true;
  }).toList();
}

/// Left pane of the counter: parts list / photo grid / service tiles.
class CounterLeftPane extends StatelessWidget {
  const CounterLeftPane({super.key, required this.category, required this.compact});
  final ValueNotifier<String> category;

  /// Use phone spacing when the counter has a cart sheet.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final counter = CounterScope.maybeOf(context)!;
    final inset = compact ? 12.0 : 20.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(inset, compact ? 6 : 12, inset, 0),
        child: Row(children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Parts')),
              ButtonSegment(value: true, label: Text('Services')),
            ],
            selected: {counter.services},
            onSelectionChanged: (v) => counter.showServices(v.first),
          ),
          if (!counter.services) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: counter.photos ? 'Show parts list' : 'Show parts photos',
              onPressed: counter.togglePhotos,
              icon: Icon(counter.photos ? Icons.view_list_outlined : Icons.grid_view_outlined),
            ),
          ],
          const Spacer(),
          if (showKeyHints(context))
            TextButton.icon(
              onPressed: () => showCounterKeys(context),
              icon: const Icon(Icons.keyboard_outlined, size: 18),
              label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Keys'), KeyCap('?')]),
            ),
        ]),
      ),
      Expanded(
        child: counter.services ? const ServiceTiles()
            : counter.photos ? CounterCatalog(category: category, wide: !compact)
            : PartsList(category: category, compact: compact),
      ),
    ]);
  }
}

/// Dense parts list with the fitment bar (vehicle chip + categories).
class PartsList extends StatelessWidget {
  const PartsList({super.key, required this.category, this.compact = false});
  final ValueNotifier<String> category;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final shell = ShellScope.of(context);
    final counter = CounterScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([shell.search, category, app.catalogState, app.shiftState, app.cartState.terms]),
      builder: (context, _) {
        final saleProducts = app.saleProducts.where((p) => p['type'] != 'service');
        final categories = {'All parts', ...saleProducts.map((p) => '${p['category']}')}.toList();
        final current = categories.contains(category.value) ? category.value : 'All parts';
        final vehicle = app.cart['vehicle'] as Map?;
        final showAll = counter?.showAllFitment == true;
        final allMatches = counterParts(app, shell.search.text, current, showAllFitment: true);
        final parts = showAll || vehicle == null
            ? allMatches
            : allMatches.where((p) => !fitment(p, Map<String, dynamic>.from(vehicle)).needsOverride).toList();
        final hiddenByFitment = vehicle == null || showAll ? 0 : allMatches.length - parts.length;
        final pad = compact ? 12.0 : 20.0;
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, compact ? 10 : 14, pad, 0),
            sliver: SliverToBoxAdapter(
              child: FitmentBar(
                categories: categories,
                current: current,
                onCategory: (c) => category.value = c,
                hiddenByFitment: hiddenByFitment,
                showAllFitment: showAll && vehicle != null,
                onToggleFitment: counter == null || vehicle == null ? null : counter.toggleShowAllFitment,
              ),
            ),
          ),
          if (parts.isEmpty)
            SliverToBoxAdapter(
              child: EmptyState(message: shell.search.text.isEmpty ? 'No parts in this category.' : 'No part matches "${shell.search.text}".'),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, compact ? 110 : 20),
              sliver: SliverList.separated(
                itemCount: parts.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => PartRow(product: parts[i]),
              ),
            ),
        ]);
      },
    );
  }
}

/// One compact part row: name, SKU / part no., stock, price, add.
class PartRow extends StatelessWidget {
  const PartRow({super.key, required this.product});
  final Json product;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final stock = app.available('${product['id']}');
    final price = app.cart['priceLevel'] == 'wholesale' ? product['wholesalePrice'] : product['retailPrice'];
    final muted = Theme.of(context).textTheme.bodySmall;
    return InkWell(
      onTap: () => addPart(context, product),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${product['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                [product['brand'], product['sku'], product['partNumber']].where((v) => '${v ?? ''}'.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ]),
          ),
          SizedBox(
            width: 64,
            child: stock <= 0 && beyondStock(app, product)
                ? const Align(alignment: Alignment.centerRight, child: Tooltip(message: 'Out of stock', child: StockCaution('Out')))
                : Text(stock > 0 ? '$stock' : 'Out', textAlign: TextAlign.right,
                    style: TextStyle(fontFeatures: _figures, color: stock > 0 ? null : Theme.of(context).colorScheme.error)),
          ),
          SizedBox(
            width: 96,
            child: Text(app.money(price as num?), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
          ),
          IconButton(tooltip: 'Add ${product['name']}', onPressed: () => addPart(context, product, quick: true), icon: const Icon(Icons.add_circle_outline)),
        ]),
      ),
    );
  }
}

/// Quick-tap tiles for services (fitting, wiring, polishing…): one tap adds one.
class ServiceTiles extends StatelessWidget {
  const ServiceTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final shell = ShellScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([shell.search, app.catalogState, app.cartState.terms]),
      builder: (context, _) {
        final services = counterParts(app, shell.search.text, 'All parts', services: true);
        if (services.isEmpty) {
          final empty = !app.saleProducts.any((p) => p['type'] == 'service');
          return EmptyState(
          message: empty ? 'No services yet.' : 'No service matches "${shell.search.text}".',
          icon: Icons.build_outlined,
          action: empty && app.canStock
              ? FilledButton.icon(
                  onPressed: () => editProduct(context, const {'type': 'service', 'universal': true}),
                  icon: const Icon(Icons.add),
                  label: const Text('Create service'),
                )
              : null,
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (app.canStock)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => editProduct(context, const {'type': 'service', 'universal': true}),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create service'),
              ),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 96, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: services.length,
            itemBuilder: (context, i) {
              final s = services[i];
              final price = app.cart['priceLevel'] == 'wholesale' ? s['wholesalePrice'] : s['retailPrice'];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => addPart(context, s, quick: true),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${s['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text(app.money(price as num?), style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: _figures)),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]);
      },
    );
  }
}

/// Customer / vehicle chip for the cart header (F2).
class CustomerVehicleChip extends StatelessWidget {
  const CustomerVehicleChip({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: app.cartState.terms,
      builder: (context, _) {
        final customer = app.customerById('${app.cart['customerId']}');
        final vehicle = app.cart['vehicle'] as Map?;
        final reg = '${app.cart['regNo'] ?? ''}';
        final text = [
          customer?['name'] ?? 'Walk-in',
          if (reg.isNotEmpty) reg,
          if (vehicle != null) '${vehicle['make']} ${vehicle['model']}',
        ].join(' · ');
        return ActionChip(
          avatar: const Icon(Icons.person_outline, size: 18),
          label: Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(text, overflow: TextOverflow.ellipsis)), const KeyCap('F2')]),
          onPressed: () => editCustomerVehicle(context),
        );
      },
    );
  }
}

/// Compact balance / advance badge for the selected customer on the counter.
class _CustomerAccountHint extends StatelessWidget {
  const _CustomerAccountHint({this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 6)});
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: Listenable.merge([app.cartState.terms, app]),
      builder: (context, _) {
        final customer = app.customerById('${app.cart['customerId']}');
        if (customer == null) return const SizedBox.shrink();
        final id = '${customer['id']}';
        final balance = app.partyBalance('customers', id);
        final advance = availableAdvance(app, id);
        final phone = '${customer['phone'] ?? ''}'.trim();
        if (balance == 0 && advance == 0 && phone.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (phone.isNotEmpty)
              Text(phone, style: Theme.of(context).textTheme.bodySmall),
            if (balance > 0)
              Text('Owes ${app.money(balance)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Brand.danger)),
            if (advance > 0)
              Text('Advance ${app.money(advance)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Brand.forest)),
          ]),
        );
      },
    );
  }
}

/// A wide table or a stacked list, depending on the cart's own available width.
class CartTable extends StatelessWidget {
  const CartTable({super.key, this.padding = const EdgeInsets.symmetric(horizontal: 16)});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final counter = CounterScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.cartState, app.catalogState, ?counter]),
      builder: (context, _) {
        final lines = (app.cart['lines'] as List).cast<Map>();
        final hasExchange = exchangeReturns(app.cart).isNotEmpty;
        final bill = app.bill;
        if (lines.isEmpty) {
          return EmptyState(
            message: hasExchange
                ? 'Exchange credit on this bill.\nScan a barcode or tap a replacement part.'
                : 'No items yet.\nScan a barcode or tap a part.',
            icon: hasExchange ? Icons.swap_horiz : Icons.qr_code_2,
          );
        }
        final head = Theme.of(context).textTheme.labelSmall;
        return LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 540;
          return Column(children: [
            if (!compact) ...[
              Padding(
                padding: padding.add(const EdgeInsets.symmetric(vertical: 6)),
                child: Row(children: [
                  SizedBox(width: 24, child: Text('#', style: head)),
                  Expanded(child: Text('Item', style: head)),
                  SizedBox(width: 104, child: Text('Qty', textAlign: TextAlign.center, style: head)),
                  SizedBox(width: 78, child: Text('Rate', textAlign: TextAlign.right, style: head)),
                  SizedBox(width: 88, child: Text('Amount', textAlign: TextAlign.right, style: head)),
                  const SizedBox(width: 32),
                ]),
              ),
              const Divider(height: 1),
            ],
            Expanded(
              child: ListView.separated(
                itemCount: lines.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _TableLine(
                  index: i,
                  raw: Map<String, dynamic>.from(lines[i]),
                  line: bill?.lines.elementAtOrNull(i),
                  selected: counter?.selected == i,
                  padding: padding,
                  compact: compact,
                ),
              ),
            ),
          ]);
        });
      },
    );
  }
}

class _TableLine extends StatelessWidget {
  const _TableLine({required this.index, required this.raw, required this.line, required this.selected, required this.padding, required this.compact});
  final int index;
  final Json raw;
  final QuoteLine? line;
  final bool selected;
  final EdgeInsets padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final product = app.productById('${raw['productId']}');
    final serial = product?['serialTracked'] == true;
    final qty = raw['qty'] as int;
    final scheme = Theme.of(context).colorScheme;
    final staff = '${raw['staffId'] ?? ''}';
    final title = Text('${product?['name'] ?? raw['productId']}', style: const TextStyle(fontWeight: FontWeight.w700));
    final staffAction = InkWell(
      onTap: () => tagLineStaff(context, index),
      child: Text(staff.isEmpty ? '+ staff' : app.userName(staff), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
    );
    final amounts = Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Decrease quantity',
        onPressed: serial || qty <= 1 ? null : () => setLineQuantity(context, index, qty - 1),
        icon: const Icon(Icons.remove, size: 16),
      ),
      Text('$qty', style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Increase quantity',
        onPressed: serial || product?['salesStopped'] == true || (product != null && isOnlineOnly(product))
            ? null : () => setLineQuantity(context, index, qty + 1),
        icon: const Icon(Icons.add, size: 16),
      ),
    ]);
    final remove = IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Remove',
      onPressed: () => setLineQuantity(context, index, 0),
      icon: const Icon(Icons.close, size: 16),
    );
    final total = Text(app.money(line?.total ?? 0), textAlign: TextAlign.right,
        style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures));
    final stockWarning = raw['binId'] != null && beyondStock(app, product) &&
        qty > app.available('${raw['productId']}', '${raw['binId']}');
    final serialList = (raw['serials'] as List? ?? const []).map((e) => '$e').where((e) => e.isNotEmpty).toList();
    final overrideReason = '${raw['overrideReason'] ?? ''}'.trim();
    final meta = Theme.of(context).textTheme.bodySmall;
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: () => CounterScope.read(context)?.select(index),
        child: Padding(
          padding: padding.add(const EdgeInsets.symmetric(vertical: 4)),
          child: compact
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [Expanded(child: title), remove]),
                  Text('$qty × ${app.money(line?.unitPrice ?? 0)}', style: meta),
                  if (serialList.isNotEmpty) Text('Serials: ${serialList.join(', ')}', style: meta),
                  if (overrideReason.isNotEmpty) Text('Fitment override: $overrideReason', style: meta),
                  if (stockWarning) const StockCaution('This sale exceeds available stock.'),
                  Row(children: [
                    Expanded(child: staffAction),
                    amounts,
                    Flexible(child: Align(alignment: Alignment.centerRight, child: total)),
                  ]),
                ])
              : Row(children: [
            SizedBox(width: 24, child: Text('${index + 1}', style: const TextStyle(fontFeatures: _figures))),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                title,
                staffAction,
                if (serialList.isNotEmpty) Text('Serials: ${serialList.join(', ')}', style: meta),
                if (overrideReason.isNotEmpty) Text('Fitment override: $overrideReason', style: meta),
                if (stockWarning) const StockCaution('Exceeds available stock'),
              ]),
            ),
            SizedBox(width: 104, child: amounts),
            SizedBox(width: 78, child: Text(app.money(line?.unitPrice ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontFeatures: _figures))),
            SizedBox(width: 88, child: total),
            SizedBox(width: 32, child: remove),
          ]),
        ),
      ),
    );
  }
}

/// Sticky payment dock: totals, discount, big total and the Pay buttons.
class PaymentDock extends StatelessWidget {
  const PaymentDock({super.key, this.onDone});

  /// Called after a completed or parked sale (the phone sheet closes itself).
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: Listenable.merge([app.cartState, app]),
      builder: (context, _) {
        final lines = app.cart['lines'] as List;
        final exchange = exchangeReturns(app.cart).isNotEmpty;
        final hasSale = lines.isNotEmpty || exchange;
        final exCredit = exchange ? exchangeCredit(app.cart) : 0;
        final bill = app.bill;
        final blocker = hasSale ? checkoutBlocker(app) : null;
        final can = hasSale && blocker == null && app.canSell;
        final scheme = Theme.of(context).colorScheme;
        final shell = shellOf(context);
        Future<void> run(Future<void> Function() action) async {
          final before = app.cart['transactionId'];
          await action();
          if (app.cart['transactionId'] != before) onDone?.call();
        }

        Widget pay(String label, String key, IconData icon, Future<void> Function() action, {bool primary = false}) =>
            LayoutBuilder(builder: (context, constraints) {
              final stackHint = primary && key.length > 4;
              final hasHint = showKeyHints(context) && constraints.maxWidth >= (stackHint ? 90 : 118);
              final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
              final child = hasHint && stackHint
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      text,
                      const SizedBox(height: 2),
                      FittedBox(child: KeyCap(key, onDark: true)),
                    ])
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (constraints.maxWidth >= 150) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
                      Flexible(child: text),
                      if (hasHint) KeyCap(key, onDark: primary),
                    ]);
              const size = Size(0, 50);
              const inset = EdgeInsets.symmetric(horizontal: 10);
              final onPressed = can ? () => run(action) : null;
              final button = primary
                  ? FilledButton(style: FilledButton.styleFrom(minimumSize: size, padding: inset), onPressed: onPressed, child: child)
                  : OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: size, padding: inset), onPressed: onPressed, child: child);
              return primary && !hasHint ? Tooltip(message: 'Pay & print ($key)', child: button) : button;
            });

        final netTotal = (bill?.total ?? 0) - exCredit;
        final summaryParts = [
          'Subtotal ${app.money(bill?.subtotal ?? 0)}',
          if (!app.noTax) '${app.settings['taxDisplayName'] ?? 'Tax'} ${app.money(bill?.tax ?? 0)}',
          if ((bill?.core ?? 0) != 0) 'Core ${app.money(bill!.core)}',
          if ((bill?.rounding ?? 0) != 0) 'Rounding ${app.money(bill!.rounding)}',
          if (exchange) 'Exchange −${app.money(exCredit)}',
        ];

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text(
                  summaryParts.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: _figures),
                ),
              ),
              TextButton(
                onPressed: lines.isEmpty ? null : () => editDiscount(context),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text((bill?.discount ?? 0) > 0 ? 'Discount −${app.money(bill!.discount)}' : 'Discount'),
                  const KeyCap('F8'),
                ]),
              ),
            ]),
            if (blocker != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: blocker.startsWith('Record the fitment')
                    ? OutlinedButton.icon(onPressed: () => approveFitment(context), icon: const Icon(Icons.verified_user_outlined), label: Text(blocker))
                    : Text(blocker, style: TextStyle(color: scheme.error)),
              ),
            Row(children: [
              Expanded(
                child: Text(
                  exchange
                      ? (netTotal >= 0 ? 'Customer pays' : 'Refund due')
                      : '${app.cartState.units} ${app.cartState.units == 1 ? 'item' : 'items'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: exchange && netTotal < 0 ? Brand.forest : null,
                        fontWeight: exchange ? FontWeight.w700 : null,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(app.money(exchange ? netTotal.abs() : (bill?.total ?? 0)),
                      key: const ValueKey('dock-total'),
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        fontFeatures: _figures,
                        color: exchange && netTotal < 0 ? Brand.forest : null,
                      )),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: pay('Exact cash', 'F9', Icons.payments_outlined, () => expressCash(context))),
              const SizedBox(width: 8),
              if (app.tenderTypes.contains('UPI')) ...[
                Expanded(child: pay('UPI', 'F6', Icons.qr_code_2, () => startCheckout(context, tender: 'UPI'))),
                const SizedBox(width: 8),
              ],
              Expanded(child: pay('Split', 'F10', Icons.call_split, () => startCheckout(context, split: true))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Tooltip(
                message: exchange ? 'Complete or remove the exchange instead of holding' : 'Hold this bill',
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                  onPressed: lines.isEmpty || exchange || !app.online ? null : () => run(() => parkWithPrompt(context)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.pause, size: 18), SizedBox(width: 4), Text('Hold'), KeyCap('F4')]),
                ),
              ),
              const SizedBox(width: 8),
              Badge(
                isLabelVisible: counterHolds(app).isNotEmpty,
                label: Text('${counterHolds(app).length}'),
                child: Tooltip(
                  message: 'Recall a held bill',
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                    onPressed: shell == null ? null : () => showParked(context, shell),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.history, size: 18), SizedBox(width: 4), Text('Recall'), KeyCap('F5')]),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: pay('Pay & print', payPrintShortcut, Icons.print_outlined, () => startCheckout(context, print: true), primary: true)),
            ]),
          ]),
        );
      },
    );
  }
}

/// Desktop right pane: header, cart table, sticky payment dock.
class DeskCartPane extends StatelessWidget {
  const DeskCartPane({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
        child: Row(children: [
          const Expanded(child: Align(alignment: Alignment.centerLeft, child: CustomerVehicleChip())),
          IconButton(
            tooltip: 'New customer',
            onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) => app.updateCart({'customerId': saved['id']})),
            icon: const Icon(Icons.person_add_alt),
          ),
          ListenableBuilder(
            listenable: app.cartState.terms,
            builder: (context, _) => SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [ButtonSegment(value: 'retail', label: Text('Retail')), ButtonSegment(value: 'wholesale', label: Text('Wholesale'))],
              selected: {'${app.cart['priceLevel'] ?? 'retail'}'},
              onSelectionChanged: (v) => app.updateCart({'priceLevel': v.first}),
            ),
          ),
          ListenableBuilder(
            listenable: app.cartState,
            builder: (context, _) => (app.cart['lines'] as List).isEmpty && exchangeReturns(app.cart).isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear sale',
                    onPressed: () => clearCurrentSale(context),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
          ),
        ]),
      ),
      const _CustomerAccountHint(),
      const Divider(height: 1),
      const Expanded(child: CartTable()),
      const ExchangeReturnsPanel(),
      const PaymentDock(),
    ]);
  }
}

/// UI polish: tablet (840–1199) right pane: customer / price level, touch
/// friendly cart lines (staff tag, +/−) and the same payment dock as desktop,
/// so the cart stays on screen instead of in a bottom sheet.
class TabletCartPane extends StatelessWidget {
  const TabletCartPane({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 4),
        child: Row(children: [
          const Expanded(child: Align(alignment: Alignment.centerLeft, child: CustomerVehicleChip())),
          IconButton(
            tooltip: 'New customer',
            onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) => app.updateCart({'customerId': saved['id']})),
            icon: const Icon(Icons.person_add_alt),
          ),
          ListenableBuilder(
            listenable: app.cartState,
            builder: (context, _) => (app.cart['lines'] as List).isEmpty && exchangeReturns(app.cart).isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear sale',
                    onPressed: () => clearCurrentSale(context),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
          ),
        ]),
      ),
      const _CustomerAccountHint(padding: EdgeInsets.fromLTRB(14, 0, 14, 6)),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: ListenableBuilder(
          listenable: app.cartState.terms,
          builder: (context, _) => SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [ButtonSegment(value: 'retail', label: Text('Retail')), ButtonSegment(value: 'wholesale', label: Text('Wholesale'))],
            selected: {'${app.cart['priceLevel'] ?? 'retail'}'},
            onSelectionChanged: (v) => app.updateCart({'priceLevel': v.first}),
          ),
        ),
      ),
      const Divider(height: 1),
      const Expanded(child: CartTable(padding: EdgeInsets.symmetric(horizontal: 14))),
      const ExchangeReturnsPanel(),
      const PaymentDock(),
    ]);
  }
}

/// Phone / narrow: "3 items • ₹1,250 → Pay" pinned to the bottom.
class CartPill extends StatelessWidget {
  const CartPill({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: app.cartState,
      builder: (context, _) {
        final lines = app.cart['lines'] as List;
        final exchange = exchangeReturns(app.cart).isNotEmpty;
        if (lines.isEmpty && !exchange) return const SizedBox.shrink();
        final units = app.cartState.units;
        final net = (app.bill?.total ?? 0) - (exchange ? exchangeCredit(app.cart) : 0);
        final summary = lines.isEmpty
            ? 'Exchange credit • ${app.money(exchangeCredit(app.cart))}'
            : '$units ${units == 1 ? 'item' : 'items'} • ${app.money(exchange ? net.abs() : (app.bill?.total ?? 0))}';
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: FilledButton(
              key: const ValueKey('cart-pill'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58), shape: const StadiumBorder()),
              onPressed: () => openPhoneCart(context),
              child: Row(children: [
                Icon(exchange ? Icons.swap_horiz : Icons.shopping_bag_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(summary, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontFeatures: _figures)),
                ),
                Text(exchange && lines.isEmpty ? 'View' : 'Pay', style: const TextStyle(fontWeight: FontWeight.w800)),
                const Icon(Icons.arrow_forward),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// The phone cart: a draggable sheet with lines (staff tag), customer,
/// discount and payment (split tender and UPI QR live in checkout).
Future<void> openPhoneCart(BuildContext context) {
  final app = context.appRead;
  final shell = shellOf(context);
  final counter = CounterScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheet) {
      Widget scoped(Widget child) {
        Widget w = AppScope(state: app, child: child);
        if (shell != null) w = ShellScope(controller: shell, child: w);
        if (counter != null) w = CounterScope(controller: counter, child: w);
        return w;
      }

      return scoped(DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scroll) => Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            Expanded(
              child: ListenableBuilder(
                listenable: app.cartState,
                builder: (context, _) {
                  final lines = (app.cart['lines'] as List).cast<Map>();
                  final hasExchange = exchangeReturns(app.cart).isNotEmpty;
                  final bill = app.bill;
                  return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), children: [
                    Center(
                      child: Container(
                        width: 40, height: 4, margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    Row(children: [
                      Expanded(child: Text('Current sale', style: Theme.of(context).textTheme.titleLarge)),
                      if (lines.isNotEmpty || hasExchange)
                        IconButton(
                          tooltip: 'Clear sale',
                          onPressed: () => clearCurrentSale(context),
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                      IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
                    ]),
                    Row(children: [
                      const Expanded(child: Align(alignment: Alignment.centerLeft, child: CustomerVehicleChip())),
                      IconButton(
                        tooltip: 'New customer',
                        onPressed: () => editContact(context, 'customers', const {}, onSaved: (saved) => app.updateCart({'customerId': saved['id']})),
                        icon: const Icon(Icons.person_add_alt),
                      ),
                    ]),
                    const _CustomerAccountHint(padding: EdgeInsets.only(top: 2, bottom: 4)),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 6),
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        segments: const [ButtonSegment(value: 'retail', label: Text('Retail')), ButtonSegment(value: 'wholesale', label: Text('Wholesale'))],
                        selected: {'${app.cart['priceLevel'] ?? 'retail'}'},
                        onSelectionChanged: (v) => app.updateCart({'priceLevel': v.first}),
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (lines.isEmpty)
                      EmptyState(
                        message: hasExchange
                            ? 'Add a replacement part to complete the exchange.\nFor a refund without replacement, use Orders › Returns.'
                            : 'No items yet.',
                        icon: hasExchange ? Icons.swap_horiz : Icons.inbox_outlined,
                      ),
                    for (var i = 0; i < lines.length; i++)
                      _PhoneLine(index: i, raw: Map<String, dynamic>.from(lines[i]), line: bill?.lines.elementAtOrNull(i)),
                  ]);
                },
              ),
            ),
            const ExchangeReturnsPanel(),
            PaymentDock(onDone: () {
              if (Navigator.of(sheet).canPop()) Navigator.pop(sheet);
            }),
          ]),
        ),
      ));
    },
  );
}

class _PhoneLine extends StatelessWidget {
  const _PhoneLine({required this.index, required this.raw, required this.line});
  final int index;
  final Json raw;
  final QuoteLine? line;
  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final product = app.productById('${raw['productId']}');
    final qty = raw['qty'] as int;
    final serial = product?['serialTracked'] == true;
    final staff = '${raw['staffId'] ?? ''}';
    final stockWarning = raw['binId'] != null && beyondStock(app, product) &&
        qty > app.available('${raw['productId']}', '${raw['binId']}');
    final serialList = (raw['serials'] as List? ?? const []).map((e) => '$e').where((e) => e.isNotEmpty).toList();
    final overrideReason = '${raw['overrideReason'] ?? ''}'.trim();
    final meta = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${product?['name'] ?? raw['productId']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${app.money(line?.unitPrice ?? 0)} each', style: meta?.copyWith(fontFeatures: _figures)),
            if (serialList.isNotEmpty) Text('Serials: ${serialList.join(', ')}', style: meta),
            if (overrideReason.isNotEmpty) Text('Fitment override: $overrideReason', style: meta),
            if (stockWarning) const StockCaution('Exceeds available stock'),
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.badge_outlined, size: 16),
              label: Text(staff.isEmpty ? 'Staff' : app.userName(staff)),
              onPressed: () => tagLineStaff(context, index),
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Decrease quantity',
          onPressed: serial ? null : () => setLineQuantity(context, index, qty - 1),
          icon: Icon(qty <= 1 ? Icons.delete_outline : Icons.remove),
        ),
        Text('$qty', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, fontFeatures: _figures)),
        IconButton(
          tooltip: 'Increase quantity',
          onPressed: serial || product?['salesStopped'] == true || (product != null && isOnlineOnly(product))
              ? null : () => setLineQuantity(context, index, qty + 1),
          icon: const Icon(Icons.add),
        ),
        SizedBox(
          width: 84,
          child: Text(app.money(line?.total ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
        ),
      ]),
    );
  }
}
