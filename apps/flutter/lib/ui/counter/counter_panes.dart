import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../screens/people.dart';
import '../shell.dart';
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
List<Json> counterParts(AppState app, String search, String category, {bool services = false}) {
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
    if (vehicle != null && fitment(p, Map<String, dynamic>.from(vehicle)).needsOverride) return false;
    return true;
  }).toList();
}

/// Left pane of the counter: parts list / photo grid / service tiles.
class CounterLeftPane extends StatelessWidget {
  const CounterLeftPane({super.key, required this.category, required this.compact});
  final ValueNotifier<String> category;

  /// Phone: compact rows only, no pane switcher.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final counter = CounterScope.maybeOf(context) ?? CounterController();
    final pane = compact ? 'list' : counter.pane;
    final switcher = compact
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'list', icon: Icon(Icons.view_list, size: 18), label: Text('Parts')),
                  ButtonSegment(value: 'grid', icon: Icon(Icons.grid_view, size: 18), label: Text('Photos')),
                  ButtonSegment(value: 'services', icon: Icon(Icons.build_outlined, size: 18), label: Text('Services')),
                ],
                selected: {pane},
                onSelectionChanged: (v) => counter.setPane(v.first),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => showCounterKeys(context),
                icon: const Icon(Icons.keyboard_outlined, size: 18),
                label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Keys'), KeyCap('?')]),
              ),
            ]),
          );
    final body = switch (pane) {
      'grid' => CounterCatalog(category: category, wide: true),
      'services' => const ServiceTiles(),
      _ => PartsList(category: category, compact: compact),
    };
    if (switcher == null) return body;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [switcher, Expanded(child: body)]);
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
    return ListenableBuilder(
      listenable: Listenable.merge([shell.search, category, app.catalogState, app.shiftState, app.cartState.terms]),
      builder: (context, _) {
        final saleProducts = app.saleProducts.where((p) => p['type'] != 'service');
        final categories = {'All parts', ...saleProducts.map((p) => '${p['category']}')}.toList();
        final current = categories.contains(category.value) ? category.value : 'All parts';
        final parts = counterParts(app, shell.search.text, current);
        final pad = compact ? 12.0 : 20.0;
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, compact ? 10 : 14, pad, 0),
            sliver: SliverToBoxAdapter(child: FitmentBar(categories: categories, current: current, onCategory: (c) => category.value = c)),
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
            child: Text(stock > 0 ? '$stock' : 'Out', textAlign: TextAlign.right,
                style: TextStyle(fontFeatures: _figures, color: stock > 0 ? null : Theme.of(context).colorScheme.error)),
          ),
          SizedBox(
            width: 96,
            child: Text(app.money(price as num?), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
          ),
          IconButton(tooltip: 'Add ${product['name']}', onPressed: () => addPart(context, product), icon: const Icon(Icons.add_circle_outline)),
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
          return const EmptyState(message: 'No services yet. Add a product of type Service (for example "Seat cover fitting").', icon: Icons.build_outlined);
        }
        return GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 96, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemCount: services.length,
          itemBuilder: (context, i) {
            final s = services[i];
            final price = app.cart['priceLevel'] == 'wholesale' ? s['wholesalePrice'] : s['retailPrice'];
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => handleScan(context, shell, '${s['sku']}'),
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
        );
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

/// The cart as a table: #, item (with staff tag), qty, rate, amount.
/// Listens to the cart only.
class CartTable extends StatelessWidget {
  const CartTable({super.key, this.padding = const EdgeInsets.symmetric(horizontal: 16)});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final counter = CounterScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.cartState, ?counter]),
      builder: (context, _) {
        final lines = (app.cart['lines'] as List).cast<Map>();
        final bill = app.bill;
        if (lines.isEmpty) return const EmptyState(message: 'No items yet.\nScan a barcode or tap a part.', icon: Icons.qr_code_2);
        final head = Theme.of(context).textTheme.labelSmall;
        return Column(children: [
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
          Expanded(
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (context, i) => _TableLine(
                index: i,
                raw: Map<String, dynamic>.from(lines[i]),
                line: bill?.lines.elementAtOrNull(i),
                selected: counter?.selected == i,
                padding: padding,
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _TableLine extends StatelessWidget {
  const _TableLine({required this.index, required this.raw, required this.line, required this.selected, required this.padding});
  final int index;
  final Json raw;
  final QuoteLine? line;
  final bool selected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final product = app.productById('${raw['productId']}');
    final serial = product?['serialTracked'] == true;
    final qty = raw['qty'] as int;
    final scheme = Theme.of(context).colorScheme;
    final staff = '${raw['staffId'] ?? ''}';
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: () => CounterScope.read(context)?.select(index),
        child: Padding(
          padding: padding.add(const EdgeInsets.symmetric(vertical: 4)),
          child: Row(children: [
            SizedBox(width: 24, child: Text('${index + 1}', style: const TextStyle(fontFeatures: _figures))),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${product?['name'] ?? raw['productId']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                InkWell(
                  onTap: () => tagLineStaff(context, index),
                  child: Text(staff.isEmpty ? '+ staff' : app.userName(staff), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
                ),
              ]),
            ),
            SizedBox(
              width: 104,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
                  onPressed: serial || product?['salesStopped'] == true ? null : () => setLineQuantity(context, index, qty + 1),
                  icon: const Icon(Icons.add, size: 16),
                ),
              ]),
            ),
            SizedBox(width: 78, child: Text(app.money(line?.unitPrice ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontFeatures: _figures))),
            SizedBox(
              width: 88,
              child: Text(app.money(line?.total ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: _figures)),
            ),
            SizedBox(
              width: 32,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove',
                onPressed: () => setLineQuantity(context, index, 0),
                icon: const Icon(Icons.close, size: 16),
              ),
            ),
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
        final bill = app.bill;
        final blocker = lines.isEmpty ? null : checkoutBlocker(app);
        final can = lines.isNotEmpty && blocker == null && app.canSell;
        final scheme = Theme.of(context).colorScheme;
        final shell = shellOf(context);
        Future<void> run(Future<void> Function() action) async {
          final before = app.cart['transactionId'];
          await action();
          if (app.cart['transactionId'] != before) onDone?.call();
        }

        Widget pay(String label, String key, IconData icon, Future<void> Function() action, {bool primary = false}) {
          final child = Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(label, overflow: TextOverflow.ellipsis)), KeyCap(key, onDark: primary)]);
          const size = Size(0, 50);
          const inset = EdgeInsets.symmetric(horizontal: 10);
          return primary
              ? FilledButton.icon(style: FilledButton.styleFrom(minimumSize: size, padding: inset), onPressed: can ? () => run(action) : null, icon: Icon(icon, size: 18), label: child)
              : OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: size, padding: inset), onPressed: can ? () => run(action) : null, icon: Icon(icon, size: 18), label: child);
        }

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text(
                  'Subtotal ${app.money(bill?.subtotal ?? 0)} · ${app.settings['taxDisplayName'] ?? 'Tax'} ${app.money(bill?.tax ?? 0)}'
                  '${(bill?.rounding ?? 0) != 0 ? ' · Rounding ${app.money(bill!.rounding)}' : ''}',
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
              Text('${app.cartState.units} ${app.cartState.units == 1 ? 'item' : 'items'}', style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              Text(app.money(bill?.total ?? 0),
                  key: const ValueKey('dock-total'),
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8, fontFeatures: _figures)),
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
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                onPressed: lines.isEmpty || !app.online ? null : () => run(() => parkWithPrompt(context)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.pause, size: 18), SizedBox(width: 4), Text('Hold'), KeyCap('F4')]),
              ),
              const SizedBox(width: 8),
              Badge(
                isLabelVisible: app.list('holds').isNotEmpty,
                label: Text('${app.list('holds').length}'),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                  onPressed: shell == null ? null : () => showParked(context, shell),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.history, size: 18), SizedBox(width: 4), Text('Recall'), KeyCap('F5')]),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: pay('Pay & print', 'F12', Icons.print_outlined, () => startCheckout(context, print: true), primary: true)),
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
            builder: (context, _) => (app.cart['lines'] as List).isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear sale',
                    onPressed: () async {
                      if (await confirm(context, 'Clear this sale?', 'All items will be removed from the current bill.', action: 'Clear')) {
                        app.clearCart();
                      }
                    },
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
          ),
        ]),
      ),
      const Divider(height: 1),
      const Expanded(child: CartTable()),
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
        if ((app.cart['lines'] as List).isEmpty) return const SizedBox.shrink();
        final units = app.cartState.units;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: FilledButton(
              key: const ValueKey('cart-pill'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58), shape: const StadiumBorder()),
              onPressed: () => openPhoneCart(context),
              child: Row(children: [
                const Icon(Icons.shopping_bag_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('$units ${units == 1 ? 'item' : 'items'} • ${app.money(app.bill?.total ?? 0)}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontFeatures: _figures)),
                ),
                const Text('Pay', style: TextStyle(fontWeight: FontWeight.w800)),
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
                      IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
                    ]),
                    const Align(alignment: Alignment.centerLeft, child: CustomerVehicleChip()),
                    const SizedBox(height: 6),
                    if (lines.isEmpty) const EmptyState(message: 'No items yet.'),
                    for (var i = 0; i < lines.length; i++)
                      _PhoneLine(index: i, raw: Map<String, dynamic>.from(lines[i]), line: bill?.lines.elementAtOrNull(i)),
                  ]);
                },
              ),
            ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${product?['name'] ?? raw['productId']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${app.money(line?.unitPrice ?? 0)} each', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: _figures)),
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
          onPressed: serial ? null : () => setLineQuantity(context, index, qty + 1),
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
