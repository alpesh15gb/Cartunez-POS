import 'package:flutter/material.dart';

import '../../main.dart';
import '../counter/cart_table.dart';
import '../counter/catalog_grid.dart';
import '../theme.dart';

export '../counter/cart_table.dart' show CartPanel;
export '../counter/counter_actions.dart';
export '../counter/held_bills.dart' show showParked;
export '../counter/tender_sheet.dart' show startCheckout, openShiftDialog, CheckoutDialog;

final billingKey = GlobalKey();

/// The sales counter: catalog on the left, the current sale on the right
/// (or in a bottom sheet on narrow screens).
///
/// Rebuild scopes: the catalog listens to the search box, catalog/shift data and
/// the cart's pricing terms; the cart pane listens to the cart. This widget
/// itself does not depend on [AppState], so a scan only rebuilds the cart pane.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});
  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  final category = ValueNotifier('All parts');

  @override
  void dispose() {
    category.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final catalog = CounterCatalog(category: category, wide: wide);
    if (wide) {
      return Row(key: billingKey, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: catalog),
        Container(
          width: 380,
          decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: Brand.line))),
          child: const CartPanel(),
        ),
      ]);
    }
    return Stack(key: billingKey, children: [
      catalog,
      const _ViewSaleButton(),
    ]);
  }
}

/// Narrow screens: "View sale · 3 items  ₹1,250" pinned to the bottom.
class _ViewSaleButton extends StatelessWidget {
  const _ViewSaleButton();

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    return ListenableBuilder(
      listenable: app.cartState,
      builder: (context, _) {
        if ((app.cart['lines'] as List).isEmpty) return const SizedBox.shrink();
        final units = app.cartState.units;
        return Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: AppScope(state: app, child: const CartPanel(inSheet: true))),
            ),
            child: Row(children: [
              const Icon(Icons.shopping_bag_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text('View sale · $units ${units == 1 ? 'item' : 'items'}', overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(app.money(app.bill?.total ?? 0), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        );
      },
    );
  }
}
