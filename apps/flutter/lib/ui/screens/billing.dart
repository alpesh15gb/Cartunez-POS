import 'package:flutter/material.dart';

import '../counter/cart_table.dart';
import '../counter/catalog_grid.dart';
import '../counter/counter_keys.dart';
import '../counter/counter_panes.dart';
import '../theme.dart';

export '../counter/cart_table.dart' show CartPanel;
export '../counter/counter_actions.dart';
export '../counter/counter_flow.dart' show expressCash, afterSale, parkWithPrompt, editCustomerVehicle;
export '../counter/counter_keys.dart' show CounterKeyboard, counterKeyMap, showCounterKeys;
export '../counter/held_bills.dart' show showParked;
export '../counter/tender_sheet.dart' show startCheckout, openShiftDialog, CheckoutDialog;

final billingKey = GlobalKey();

/// The sales counter.
///
/// * Desktop (>= 1200): 60/40. Left: dense parts list, photo grid or service
///   tiles; right: cart table, customer / vehicle chip and the payment dock.
///   Keyboard first (F-keys, ↑/↓, +/−, Del, ? for help) with a scanner guard.
/// * 1000–1199: photo grid with the classic cart panel.
/// * Narrower: compact rows (phone) or the grid, with a sticky cart pill.
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
  final counter = CounterController();

  @override
  void dispose() {
    category.dispose();
    counter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final Widget body;
    if (width >= 1200) {
      final scheme = Theme.of(context).colorScheme;
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 6,
          child: ListenableBuilder(listenable: counter, builder: (_, _) => CounterLeftPane(category: category, compact: false)),
        ),
        Expanded(
          flex: 4,
          child: DecoratedBox(
            decoration: BoxDecoration(color: scheme.surface, border: Border(left: BorderSide(color: Theme.of(context).dividerColor))),
            child: const DeskCartPane(),
          ),
        ),
      ]);
    } else if (width >= 1000) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: CounterCatalog(category: category, wide: true)),
        Container(
          width: 380,
          decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: Brand.line))),
          child: const CartPanel(),
        ),
      ]);
    } else {
      body = Stack(children: [
        if (width < 600) CounterLeftPane(category: category, compact: true) else CounterCatalog(category: category, wide: false),
        const Positioned(left: 0, right: 0, bottom: 0, child: CartPill()),
      ]);
    }
    return CounterKeyboard(controller: counter, child: KeyedSubtree(key: billingKey, child: body));
  }
}
