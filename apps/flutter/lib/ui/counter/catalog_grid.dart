import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../photos.dart';
import '../widgets.dart';
import '../shell.dart';
import 'counter_actions.dart';
import 'fitment_bar.dart';

/// The parts grid with its header and category chips. Rebuilds when the search
/// text, the catalog/shift data or the cart's pricing terms change; NOT when a
/// line is added to the cart.
class CounterCatalog extends StatelessWidget {
  const CounterCatalog({super.key, required this.category, required this.wide});
  final ValueNotifier<String> category;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final shell = ShellScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([shell.search, category, app.catalogState, app.shiftState, app.cartState.terms]),
      builder: (context, _) {
        final search = shell.search.value;
        final q = normalize(search.text);
        final exactIds = {for (final part in app.findByCode(search.text, forSale: true)) part['id']};
        final vehicle = app.cart['vehicle'] as Map?;
        final saleProducts = app.saleProducts.where((p) => p['type'] != 'service');
        final categories = {'All parts', ...saleProducts.map((p) => '${p['category']}')}.toList();
        final currentCategory = categories.contains(category.value) ? category.value : 'All parts';
        final parts = saleProducts.where((p) {
          if (exactIds.isNotEmpty) return exactIds.contains(p['id']);
          if (currentCategory != 'All parts' && p['category'] != currentCategory) return false;
          if (q.isNotEmpty &&
              ![p['name'], p['sku'], p['partNumber'], p['description'], ...(p['barcodes'] as List? ?? []), ...(p['oemReferences'] as List? ?? [])]
                  .any((v) => normalize(v).contains(q))) {
            return false;
          }
          if (vehicle != null && fitment(p, Map<String, dynamic>.from(vehicle)).needsOverride) return false;
          return true;
        }).toList();
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 20, wide ? 20 : 16, 4),
            sliver: SliverToBoxAdapter(
              child: FitmentBar(
                categories: categories,
                current: currentCategory,
                onCategory: (c) => category.value = c,
              ),
            ),
          ),
          if (parts.isEmpty)
            SliverToBoxAdapter(child: Column(children: [
              EmptyState(message: saleProducts.isEmpty ? 'No parts are available for sale.' : q.isEmpty ? 'No parts in this category.' : 'No part matches "${search.text}".'),
              if (saleProducts.isEmpty && app.canStock) TextButton(onPressed: () => shell.open('parts'), child: const Text('Go to parts')),
            ]))
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 0, wide ? 20 : 16, wide ? 28 : 96),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisExtent: 286,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: parts.length,
                itemBuilder: (context, i) => PartCard(product: parts[i]),
              ),
            ),
        ]);
      },
    );
  }
}

/// One part in the counter grid. Its parent [CounterCatalog] rebuilds it when
/// stock, price level or vehicle change, so it reads state without listening.
class PartCard extends StatelessWidget {
  const PartCard({super.key, required this.product});
  final Json product;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final service = product['type'] == 'service';
    final stock = app.available('${product['id']}');
    final low = !service && stock <= (product['reorderLevel'] ?? 0);
    final price = app.cart['priceLevel'] == 'wholesale' ? product['wholesalePrice'] : product['retailPrice'];
    final vehicle = app.cart['vehicle'] as Map?;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => addPart(context, product),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 128,
            child: Stack(fit: StackFit.expand, children: [
              Container(
                color: const Color(0xFFEFF3F0),
                child: PartPhoto(product: product),
              ),
              Positioned(
                left: 8,
                top: 8,
                child: !service && stock <= 0 && beyondStock(app, product)
                    ? const StockCaution('Out of stock')
                    : StatusChip(service ? 'Service' : stock > 0 ? '$stock in stock' : 'Out of stock'),
              ),
              if (low && stock > 0) const Positioned(right: 8, top: 8, child: StatusChip('Low')),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([product['brand'], product['sku']].where((v) => '${v ?? ''}'.trim().isNotEmpty).join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 3),
                Text('${product['name']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 3),
                Text(
                  [
                    if (vehicle != null) titleCase(fitment(product, Map<String, dynamic>.from(vehicle)).status),
                    if ('${product['partNumber'] ?? ''}'.isNotEmpty) '${product['partNumber']}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Row(children: [
                  Expanded(
                    child: Text(app.money(price as num?),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Add ${product['name']}',
                    onPressed: () => addPart(context, product, quick: true),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
