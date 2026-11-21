import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/billing.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'barcode_scan.dart';
import 'counter/counter_keys.dart' show showKeyHints;
import 'login.dart';
// WS-B: returns desk, customer 360 and collections.
import 'orders/returns.dart';
import 'people/collections.dart';
import 'people/customer_360.dart';
import 'prefs.dart';
import 'purchasing/cost_changes.dart'; // WS-E
import 'purchasing/reorder.dart'; // WS-E
import 'screens/billing.dart';
import 'screens/bills.dart';
import 'screens/dashboard.dart';
import 'screens/inventory.dart';
import 'screens/online.dart';
import 'screens/online_orders.dart';
import 'screens/people.dart';
import 'screens/purchasing.dart';
import 'screens/receipt.dart';
import 'screens/reports.dart';
import 'screens/sales.dart';
import 'screens/settings.dart';
import 'screens/tools.dart';
import 'shift/pin_counter.dart' show isLockShortcut, lockCounter; // WS-D
import 'theme.dart';
import 'widgets.dart';
// WS-C (workshop)
import 'workshop/estimates.dart';
import 'workshop/jobs.dart';
import 'workshop/serials.dart';
import 'workshop/vehicles.dart';

const _sellers = ['owner', 'manager', 'cashier'];
const _stock = ['owner', 'manager', 'inventory'];
const _everyone = ['owner', 'manager', 'cashier', 'inventory'];
const _managers = ['owner', 'manager'];

/// Opens the record named in a detail link (for example an invoice receipt).
/// Returns null when the record is not on this device (yet).
typedef DetailOpener = Future<void>? Function(BuildContext context, String id);

/// One sub-tab of a workspace, with its own address.
class TabDef {
  const TabDef(this.id, this.label, this.roles, this.help, this.build,
      {required this.path, this.feature, this.detail, this.takesArg = false, this.search = true, this.argIsRecord = true});

  /// Stable id used by [ShellController.open] (kept from the old navigation).
  final String id;
  final String label;
  final List<String> roles;
  final String help;

  /// Builds the screen. [arg] is the trailing path segment for tabs that
  /// [takesArg] (for example /reports/:name); null otherwise.
  final Widget Function(BuildContext context, String? arg) build;

  /// Address of this tab, for example /orders/invoices.
  final String path;
  final String? feature;

  /// When set, `path/:id` opens that record over the list.
  final DetailOpener? detail;
  final bool takesArg;

  /// UI polish: false hides the top bar's "Search this list" box on tabs whose
  /// screen does not read it (dashboards, settings, forms with their own box).
  final bool search;

  /// UI polish: for [takesArg] tabs, whether `path/:arg` is a record page (a
  /// customer, a job card) that gets the compact back-arrow header on phones.
  /// False for arguments that only pick a view (for example /reports/:name).
  final bool argIsRecord;

  /// [arg] opens a record page (not a list or a view of one).
  bool isRecordPage(String? arg) => arg != null && takesArg && argIsRecord;

  bool get hasArg => takesArg || detail != null;
  bool visibleTo(AppState app) => roles.contains(app.role) && (feature == null || app.feature(feature!));
}

/// A top-level workspace: a nav destination holding one or more sub-tabs.
class Workspace {
  const Workspace(this.root, this.label, this.short, this.icon, this.tabs);

  /// Address of the workspace itself; opens its first tab you may use.
  final String root;
  final String label;

  /// Label for the phone bottom bar and the narrow rail.
  final String short;
  final IconData icon;
  final List<TabDef> tabs;

  List<TabDef> visibleTabs(AppState app) => [for (final t in tabs) if (t.visibleTo(app)) t];
}

Json? _find(List<Json> rows, String id, [List<String> alsoBy = const []]) {
  for (final row in rows) {
    if ('${row['id']}' == id) return row;
  }
  for (final key in alsoBy) {
    for (final row in rows) {
      if ('${row[key]}' == id) return row;
    }
  }
  return null;
}

Future<void>? _openInvoice(BuildContext context, String id) {
  final app = context.appRead;
  final doc = _find([...app.list('invoices'), ...app.list('returns')], id, ['number']);
  return doc == null ? null : showReceipt(context, doc);
}

Future<void>? _openOnlineOrder(BuildContext context, String id) {
  final order = _find(context.appRead.list('onlineOrders'), id, ['incrementId', 'number']);
  return order == null ? null : showOnlineOrder(context, order);
}

Future<void>? _openBill(BuildContext context, String id) {
  final bill = _find(context.appRead.list('purchaseBills'), id, ['billNumber']);
  return bill == null ? null : showBill(context, bill);
}

DetailOpener _openLedger(String kind) => (context, id) {
      final party = _find(context.appRead.list(kind), id);
      return party == null ? null : showLedger(context, kind, party);
    };

final workspaces = <Workspace>[
  Workspace('/counter', 'Counter', 'Counter', Icons.point_of_sale_outlined, [
    TabDef('billing', 'Billing', _sellers, 'Scan or pick parts, then take payment.', (_, _) => const BillingScreen(),
        path: '/counter'),
  ]),
  Workspace('/orders', 'Orders & bills', 'Orders', Icons.receipt_long_outlined, [
    TabDef('invoices', 'Invoices & returns', _sellers, 'Reprint receipts, take returns, void invoices and see credit notes.',
        (_, _) => const InvoicesScreen(),
        path: '/orders/invoices', detail: _openInvoice),
    // WS-B
    TabDef('sales-returns', 'Returns & exchange', _sellers,
        'Find a bill by number, receipt barcode, phone or serial; refund, exchange or give store credit.',
        (_, _) => const ReturnsPage(),
        path: '/orders/returns', search: false),
    TabDef('online-orders', 'Online orders', _managers, 'Orders from your Magento store: reserved, sold, waiting for stock or cancelled.',
        (_, _) => const OnlineOrdersScreen(),
        path: '/orders/online', feature: 'onlineStore', detail: _openOnlineOrder),
    // WS-C (workshop)
    TabDef('estimates', 'Estimates', _sellers, 'Quotes for parts, labour and kits; share on WhatsApp, then open a job card.',
        (_, id) => EstimatesScreen(id: id),
        path: '/orders/estimates', search: false, takesArg: true),
    TabDef('jobs', 'Job cards', _sellers, 'Vehicles in the workshop: check-in, work, parts, photos, then one-click GST invoice.',
        (_, id) => JobsScreen(id: id),
        path: '/orders/jobs', search: false, takesArg: true),
  ]),
  Workspace('/catalog', 'Catalog & stock', 'Stock', Icons.inventory_2_outlined, [
    TabDef('parts', 'Parts', _everyone, 'Parts, prices, stock and labels.', (_, _) => const PartsScreen(), path: '/catalog/parts'),
    TabDef('bins', 'Bins', _stock, 'Racks and bins where stock is kept.', (_, _) => const BinsScreen(), path: '/catalog/bins'),
    TabDef('fitment', 'Fitment', _stock, 'Which vehicles each part fits.', (_, _) => const FitmentScreen(),
        path: '/catalog/fitment', search: false, feature: 'fitment'),
    TabDef('transfers', 'Transfers', _stock, 'Stock sent between branches.', (_, _) => const TransfersScreen(),
        path: '/catalog/transfers', search: false, feature: 'transfers'),
    TabDef('warranty', 'Warranty & cores', _stock, 'Supplier warranty claims and core deposit refunds.',
        (_, _) => const WarrantyScreen(),
        path: '/catalog/warranty', search: false, feature: 'warranty'),
    TabDef('counts', 'Stock counts', _stock, 'Count a bin and review the difference before stock changes.',
        (_, _) => const StockCountsPage(),
        path: '/catalog/counts', search: false),
    TabDef('import', 'Import', _stock, 'Add or update many parts from a CSV file.', (_, _) => const CatalogImportPage(),
        path: '/catalog/import', search: false),
    TabDef('labels', 'Labels', _everyone, 'Barcode labels for parts and bins.', (_, _) => const LabelsPage(), path: '/catalog/labels', search: false),
    TabDef('online', 'Online products', _managers, 'Publish parts to your Magento store and set online prices and availability.',
        (_, _) => const OnlineStoreScreen(),
        path: '/catalog/online', feature: 'onlineStore'),
    // WS-C (workshop)
    TabDef('serials', 'Serial & warranty', _everyone, 'Look up a serial or IMEI: who bought it, which vehicle, warranty until when.',
        (_, _) => const SerialLookupScreen(),
        path: '/catalog/serials', search: false),
  ]),
  Workspace('/purchasing', 'Purchasing', 'Purchasing', Icons.local_shipping_outlined, [
    TabDef('bills', 'Supplier bills', _stock,
        'Enter what suppliers deliver: items, cost, photo of their note. Adds stock and the supplier balance.',
        (_, _) => const BillsScreen(),
        path: '/purchasing/bills', detail: _openBill),
    TabDef('orders', 'Purchase orders', _stock, 'Order from suppliers; enter the bill when the goods arrive.',
        (_, _) => const OrdersScreen(),
        path: '/purchasing/orders', search: false),
    // WS-E: reorder alerts → draft POs; supplier cost rises found while receiving.
    TabDef('reorder', 'Reorder alerts', _stock, 'Parts at or below their reorder level. Make draft purchase orders per supplier in one click.',
        (_, _) => const ReorderScreen(),
        path: '/purchasing/reorder', search: false),
    TabDef('cost-changes', 'Cost changes', _stock, 'Supplier costs that rose since the last purchase, and their effect on your margin.',
        (_, _) => const CostChangesScreen(),
        path: '/purchasing/cost-changes', search: false),
    TabDef('suppliers', 'Suppliers', _stock, 'Suppliers, what you owe each one, payments and returns.',
        (_, _) => const ContactsScreen(kind: 'suppliers'),
        path: '/purchasing/suppliers', detail: _openLedger('suppliers')),
  ]),
  Workspace('/people', 'People & vehicles', 'People', Icons.people_outline, [
    // WS-B: /people/customers/:id opens the customer 360 page.
    TabDef('customers', 'Customers', _sellers, 'Customers, credit (udhaar) balances and payments received.',
        (_, id) => id == null ? const ContactsScreen(kind: 'customers') : Customer360Page(id: id),
        path: '/people/customers', takesArg: true),
    TabDef('collections', 'Collections', _sellers, 'Customers who owe you: collect payments and send WhatsApp reminders.',
        (_, _) => const CollectionsPage(),
        path: '/people/collections'),
    TabDef('people-suppliers', 'Suppliers', _stock, 'Suppliers, what you owe each one, payments and returns.',
        (_, _) => const ContactsScreen(kind: 'suppliers'),
        path: '/people/suppliers', detail: _openLedger('suppliers')),
    TabDef('staff', 'Staff', _managers /* WS-D: managers set counter PINs */, 'Staff accounts, roles, PINs and who can sign in.', (_, _) => const StaffScreen(),
        path: '/people/staff', search: false),
    // WS-C (workshop)
    TabDef('vehicles', 'Vehicles', _everyone, 'Customer vehicles by registration number, with their jobs and invoices.',
        (_, id) => VehiclesScreen(id: id),
        path: '/people/vehicles', search: false, takesArg: true),
  ]),
  Workspace('/shift', 'Shift, reports & settings', 'Shift', Icons.insights_outlined, [
    TabDef('shifts', 'Shifts', _sellers, 'Open and close the cash drawer.', (_, _) => const ShiftsScreen(), path: '/shift', search: false),
    TabDef('tender', 'Tender check', _managers, 'Compare card and UPI takings with your statement.',
        (_, _) => const TenderComparisonPage(),
        path: '/shift/tender', search: false),
    TabDef('dashboard', 'Dashboard', _everyone, 'Today at a glance.', (_, _) => const DashboardScreen(), path: '/dashboard', search: false),
    TabDef('reports', 'Reports', _stock, 'Sales, stock and tax reports with CSV export.',
        (context, name) => ReportsScreen(initial: name, onNameChanged: (next) => context.go('/reports/$next')),
        path: '/reports', argIsRecord: false, search: false, takesArg: true),
    TabDef('settings', 'Settings', _everyone, 'Business details, branches, labels and this counter.',
        (_, _) => const SettingsScreen(),
        path: '/settings', search: false),
    TabDef('sync', 'Sync & audit', _sellers, 'Sales waiting to send and the audit trail.', (_, _) => const SyncScreen(),
        path: '/settings/sync', search: false),
  ]),
];

/// Old section ids that are not a tab id any more.
const _aliases = {'credit-notes': 'invoices', 'returns': 'invoices', 'products': 'parts', 'tender-comparison': 'tender'};

TabDef? tabById(String id) {
  final key = _aliases[id] ?? id;
  for (final ws in workspaces) {
    for (final tab in ws.tabs) {
      if (tab.id == key) return tab;
    }
  }
  return null;
}

/// The address for a tab id such as 'suppliers' (null when unknown).
String? pathForId(String id) => tabById(id)?.path;

Workspace workspaceOf(TabDef tab) => workspaces.firstWhere((ws) => ws.tabs.contains(tab));

/// The tab (and trailing argument) shown at [path], or null.
({TabDef tab, String? arg})? matchPath(String path) {
  final clean = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  for (final ws in workspaces) {
    for (final tab in ws.tabs) {
      if (clean == tab.path) return (tab: tab, arg: null);
    }
  }
  for (final ws in workspaces) {
    for (final tab in ws.tabs) {
      if (!tab.hasArg || !clean.startsWith('${tab.path}/')) continue;
      final rest = clean.substring(tab.path.length + 1);
      if (rest.isNotEmpty && !rest.contains('/')) return (tab: tab, arg: Uri.decodeComponent(rest));
    }
  }
  return null;
}

List<Workspace> visibleWorkspaces(AppState app) => [for (final ws in workspaces) if (ws.visibleTabs(app).isNotEmpty) ws];

/// Where a signed-in user lands: the first tab their role may use.
String homePath(AppState app) {
  for (final ws in workspaces) {
    final tabs = ws.visibleTabs(app);
    if (tabs.isNotEmpty) return tabs.first.path;
  }
  return '/settings';
}

/// Navigation and the shared search box.
class ShellController extends ChangeNotifier {
  ShellController({this.navigate});

  /// Id of the tab on screen (for example 'billing' or 'parts').
  String section = '';
  final search = TextEditingController();
  final searchFocus = FocusNode();

  /// Set by the app shell: moves the router to an address. Without it (single
  /// screen widget tests) [open] only switches [section].
  void Function(String path)? navigate;

  /// Opens a tab by id ('suppliers', 'bins', ...) or by address ('/orders/invoices/42').
  void open(String id) {
    final path = id.startsWith('/') ? id : pathForId(id);
    if (navigate != null && path != null) {
      navigate!(path);
      return;
    }
    if (section == id) return;
    section = id;
    search.clear();
    notifyListeners();
  }

  /// The router moved to another tab (link, back button or [open]).
  void arrived(String id) {
    if (section == id) return;
    section = id;
    // Clear after this frame: the search box listeners are being built now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      search.clear();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }
}

class ShellScope extends InheritedNotifier<ShellController> {
  const ShellScope({super.key, required ShellController controller, required super.child}) : super(notifier: controller);
  static ShellController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()!.notifier!;
}

/// Layout classes. Desktop: full rail and dense content. Tablet / small web:
/// collapsible rail. Phone: bottom navigation bar with a More sheet.
enum DeviceLayout {
  phone,
  tablet,
  desktop;

  static DeviceLayout of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return desktop;
    if (width >= 600) return tablet;
    return phone;
  }
}

/// The frame around every workspace: navigation, the top bar and the routed page.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.location, required this.child});

  /// Current address path, for example /orders/invoices.
  final String location;

  /// The routed workspace page.
  final Widget child;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final controller = ShellController(navigate: (path) {
    if (mounted) GoRouter.of(context).go(path);
  });
  StreamSubscription<String>? _messages;
  final _buffer = StringBuffer();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    controller.section = matchPath(widget.location)?.tab.id ?? '';
    _messages = context.appRead.messages.stream.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
    });
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(Shell old) {
    super.didUpdateWidget(old);
    final id = matchPath(widget.location)?.tab.id;
    if (id != null) controller.arrived(id);
  }

  @override
  void dispose() {
    _messages?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    controller.dispose();
    super.dispose();
  }

  bool _typingInField() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    return context.widget is EditableText || context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Keyboard-wedge barcode scanners type fast and end with Enter. Capture them
  /// wherever the cursor is, unless the user is typing into a field.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // WS-D: Ctrl+L / F11 locks the counter for the next person (the cart is kept).
    // Checked first, so it also works on the counter.
    if (isLockShortcut(event)) {
      _buffer.clear();
      unawaited(lockCounter(context.appRead));
      return true;
    }
    // WS-A: on the counter, CounterKeyboard owns the keys (F1 search, F2
    // customer/vehicle, F6 pay, ...) and the scanner guard. Elsewhere F2 still
    // focuses the search box.
    if (controller.section == 'billing' && CounterKeyboard.active > 0) {
      _buffer.clear();
      return false;
    }
    if (event.synthesized || Navigator.of(context).canPop() ||
        HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      _buffer.clear();
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.f2) {
      controller.searchFocus.requestFocus();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.f6 && controller.section == 'billing') {
      final context = billingKey.currentContext;
      if (context != null && ModalRoute.of(context)?.isCurrent == true) startCheckout(context);
      return true;
    }
    if (_typingInField() || !{'billing', 'parts', 'bins'}.contains(controller.section)) {
      _buffer.clear();
      return false;
    }
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds > 100) _buffer.clear();
    _last = now;
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString();
      _buffer.clear();
      if (code.isNotEmpty) {
        handleScan(context, controller, code);
        return true;
      }
      return false;
    }
    final char = event.character;
    if (char != null && char.length == 1 && _buffer.length < 512 &&
        (char.codeUnitAt(0) >= 32 || char == '\x1d')) {
      _buffer.write(char);
    }
    return false;
  }

  void _go(String path) => GoRouter.of(context).go(path);

  void _openWorkspace(Workspace ws, AppState app) {
    final tabs = ws.visibleTabs(app);
    if (tabs.isNotEmpty) _go(tabs.first.path);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final visible = visibleWorkspaces(app);
    final match = matchPath(widget.location);
    final tab = match?.tab;
    final active = tab == null ? null : workspaceOf(tab);
    // UI polish: the search box only where the screen reads it, never on record pages.
    final searchable = tab == null || (tab.search && !tab.isRecordPage(match?.arg));
    if (tab != null && controller.section.isEmpty) controller.section = tab.id;
    final layout = DeviceLayout.of(context);
    final prefs = UiPrefsScope.maybeOf(context);
    final theme = Theme.of(context);

    if (layout == DeviceLayout.phone) {
      return ShellScope(
        controller: controller,
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              _TopBar(controller: controller, layout: layout, searchable: searchable),
              Expanded(child: widget.child),
            ]),
          ),
          bottomNavigationBar: _PhoneNav(
            visible: visible,
            active: active,
            onOpen: (ws) => _openWorkspace(ws, app),
            onScan: () async {
              final code = await requestBarcode(context);
              if (code != null && context.mounted) handleScan(context, controller, code);
            },
            onMore: () => _moreSheet(context, visible, app),
          ),
        ),
      );
    }

    final desktop = layout == DeviceLayout.desktop;
    final expanded = desktop || (prefs?.railExpanded ?? false);
    final content = desktop
        ? Theme(data: theme.copyWith(visualDensity: VisualDensity.compact), child: widget.child)
        : widget.child;
    return ShellScope(
      controller: controller,
      child: Scaffold(
        body: Row(children: [
          _Rail(
            workspaces: visible,
            active: active,
            expanded: expanded,
            onToggle: desktop || prefs == null ? null : prefs.toggleRail,
            onOpen: (ws) => _openWorkspace(ws, app),
          ),
          Expanded(
            child: Column(children: [
              _TopBar(controller: controller, layout: layout, searchable: searchable),
              Expanded(child: content),
            ]),
          ),
        ]),
      ),
    );
  }

  void _moreSheet(BuildContext context, List<Workspace> visible, AppState app) {
    final prefs = UiPrefsScope.maybeOf(context);
    final entries = <(IconData, String, String)>[
      for (final ws in visible)
        if (!_phoneRoots.contains(ws.root)) (ws.icon, ws.label, ws.visibleTabs(app).first.path),
      for (final id in const ['import', 'labels', 'counts', 'reports', 'dashboard', 'settings', 'sync'])
        if (tabById(id)!.visibleTo(app)) (_moreIcons[id]!, tabById(id)!.label, tabById(id)!.path),
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            for (final (icon, label, path) in entries)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                selected: widget.location == path,
                onTap: () {
                  Navigator.pop(sheet);
                  _go(path);
                },
              ),
            if (prefs != null) ...[
              const Divider(),
              ListTile(
                leading: Icon(prefs.appearance.icon),
                title: const Text('Appearance'),
                trailing: Text(prefs.appearance.label),
                onTap: () => prefs.setAppearance(prefs.appearance.next),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Workspaces on the phone bottom bar; the rest live under More.
const _phoneRoots = ['/counter', '/orders', '/catalog', '/shift'];

const _moreIcons = {
  'import': Icons.upload_file,
  'labels': Icons.qr_code_2,
  'counts': Icons.fact_check_outlined,
  'reports': Icons.bar_chart_outlined,
  'dashboard': Icons.insights_outlined,
  'settings': Icons.tune_outlined,
  'sync': Icons.sync,
};

class _PhoneNav extends StatelessWidget {
  const _PhoneNav({required this.visible, required this.active, required this.onOpen, required this.onScan, required this.onMore});
  final List<Workspace> visible;
  final Workspace? active;
  final void Function(Workspace) onOpen;
  final VoidCallback onScan;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final primary = [for (final root in _phoneRoots) ...visible.where((ws) => ws.root == root)];
    final index = active == null ? -1 : primary.indexOf(active!);
    return NavigationBar(
      selectedIndex: index < 0 ? primary.length : index,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: (i) {
        if (i >= primary.length) return onMore();
        // Tapping Stock again opens the camera scanner.
        if (i == index && primary[i].root == '/catalog' && supportsBarcodeCamera) return onScan();
        onOpen(primary[i]);
      },
      destinations: [
        for (final ws in primary)
          NavigationDestination(
            icon: Icon(ws.root == '/catalog' ? Icons.qr_code_scanner : ws.icon),
            label: ws.short,
            tooltip: ws.root == '/catalog' ? 'Stock (tap again to scan)' : ws.label,
          ),
        const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
      ],
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.workspaces, required this.active, required this.expanded, required this.onToggle, required this.onOpen});
  final List<Workspace> workspaces;
  final Workspace? active;
  final bool expanded;
  final VoidCallback? onToggle;
  final void Function(Workspace) onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final attention = app.pending.isNotEmpty || app.list('conflicts').any((c) => c['status'] == 'pending');
    final compact = !expanded;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: compact ? 76 : 228,
      color: Brand.sidebar,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 18 : 20, 22, 16, 26),
            child: Row(children: [
              const BrandMark(size: 38),
              if (!compact) ...[
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Cartunez',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                    Text(
                      '${app.business['tradingName'] ?? app.business['legalName'] ?? 'Automotive POS'}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFADBBB2), fontSize: 11),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
              for (final ws in workspaces)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: Tooltip(
                    message: compact ? ws.label : '',
                    waitDuration: const Duration(milliseconds: 400),
                    child: Material(
                      color: ws == active ? const Color(0xFF2A3D32) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        hoverColor: const Color(0xFF23342E),
                        onTap: () => onOpen(ws),
                        child: SizedBox(
                          height: 44,
                          child: Row(
                            mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                            children: [
                              if (!compact) const SizedBox(width: 12),
                              Badge(
                                isLabelVisible: ws.root == '/shift' && attention,
                                backgroundColor: const Color(0xFFF0A43A),
                                smallSize: 8,
                                child: Icon(ws.icon, size: 20, color: ws == active ? Brand.lime : const Color(0xFFC6D0CA)),
                              ),
                              if (!compact) ...[
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Text(ws.label,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: ws == active ? const Color(0xFFD8F6AE) : const Color(0xFFC6D0CA),
                                        fontWeight: ws == active ? FontWeight.w700 : FontWeight.w500,
                                      )),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          if (onToggle != null)
            IconButton(
              tooltip: compact ? 'Show labels' : 'Hide labels',
              onPressed: onToggle,
              icon: Icon(compact ? Icons.chevron_right : Icons.chevron_left, color: const Color(0xFFC6D0CA)),
            ),
          const Divider(color: Color(0xFF37463F)),
          Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: compact
                ? const Icon(Icons.storefront_outlined, color: Color(0xFFA7B6AC))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${app.snapshot['branch']?['name'] ?? app.session?.branchId ?? ''}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${app.session?.user['name'] ?? ''} · ${titleCase(app.role)}',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFA7B6AC), fontSize: 11)),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// A routed workspace page: heading, sub-tabs and the tab's screen. Detail
/// links (path/:id) open the record over the list, then return to the list.
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, required this.tab, this.arg});
  final TabDef tab;
  final String? arg;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  String? _opening;

  /// UI polish: the sub-tab strip scrolls so the selected tab is on screen.
  final _strip = ScrollController();
  final _stripBox = GlobalKey();
  final _selectedTab = GlobalKey();
  String? _revealed;

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  /// Scrolls the tab strip (only it, not the page) so the selected tab shows.
  void _revealSelectedTab() {
    if (_revealed == widget.tab.path) return;
    _revealed = widget.tab.path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_strip.hasClients) return;
      final tab = _selectedTab.currentContext?.findRenderObject() as RenderBox?;
      final view = _stripBox.currentContext?.findRenderObject() as RenderBox?;
      if (tab == null || view == null || !tab.attached || !view.attached) return;
      final left = tab.localToGlobal(Offset.zero, ancestor: view).dx;
      final right = left + tab.size.width;
      const margin = 24.0;
      if (left >= margin && right <= view.size.width - margin) return;
      final target = _strip.offset + left - (view.size.width - tab.size.width) / 2;
      _strip.jumpTo(target.clamp(0.0, _strip.position.maxScrollExtent));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeOpenDetail();
  }

  @override
  void didUpdateWidget(WorkspacePage old) {
    super.didUpdateWidget(old);
    if (old.arg != widget.arg) _opening = null;
    _maybeOpenDetail();
  }

  void _maybeOpenDetail() {
    final id = widget.arg;
    final opener = widget.tab.detail;
    if (id == null || opener == null || _opening == id) return;
    _opening = id;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.arg != id) return;
      final app = context.appRead;
      final shown = opener(context, id);
      if (shown == null) {
        // Not on this device yet: wait for the first sync before giving up.
        if (app.lastSync == null) {
          _opening = null;
          return;
        }
        app.toast('${widget.tab.label}: "$id" was not found on this register.');
        if (mounted && widget.arg == id) context.go(widget.tab.path);
        return;
      }
      await shown;
      if (mounted && widget.arg == id) context.go(widget.tab.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (widget.arg != null && _opening == null) _maybeOpenDetail();
    final tab = widget.tab;
    final body = tab.build(context, tab.takesArg ? widget.arg : null);
    if (tab.id == 'billing') return body;
    final ws = workspaceOf(tab);
    final tabs = ws.visibleTabs(app);
    final layout = DeviceLayout.of(context);
    final pad = switch (layout) { DeviceLayout.phone => 16.0, DeviceLayout.tablet => 28.0, DeviceLayout.desktop => 24.0 };
    final textTheme = Theme.of(context).textTheme;
    // UI polish: on phones a record page (a customer, a job card) gets a
    // compact back-arrow header instead of the workspace heading and tabs.
    if (layout == DeviceLayout.phone && tab.isRecordPage(widget.arg)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Material(
          key: const ValueKey('record-app-bar'),
          color: Theme.of(context).colorScheme.surface,
          child: SizedBox(
            height: 48,
            child: Row(children: [
              IconButton(
                tooltip: 'Back to ${tab.label.toLowerCase()}',
                onPressed: () => context.go(tab.path),
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(child: Text(tab.label, overflow: TextOverflow.ellipsis, style: textTheme.titleMedium)),
            ]),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [body]),
        ),
      ]);
    }
    if (tabs.length > 1) _revealSelectedTab();
    return ListView(
      padding: EdgeInsets.fromLTRB(pad, layout == DeviceLayout.desktop ? 18 : 24, pad, 40),
      children: [
        Text(ws.label, style: layout == DeviceLayout.desktop ? textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800) : textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(tab.help, style: textTheme.bodySmall),
        const SizedBox(height: 14),
        if (tabs.length > 1) ...[
          SingleChildScrollView(
            key: _stripBox,
            controller: _strip,
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final t in tabs)
                  ButtonSegment(
                    value: t.path,
                    label: t == tab ? KeyedSubtree(key: _selectedTab, child: Text(t.label)) : Text(t.label),
                  ),
              ],
              selected: {tab.path},
              onSelectionChanged: (value) => context.go(value.first),
            ),
          ),
          SizedBox(height: layout == DeviceLayout.desktop ? 14 : 18),
        ],
        body,
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.layout, this.searchable = true});
  final ShellController controller;
  final DeviceLayout layout;

  /// False hides the search box (the tab's screen does not read it).
  final bool searchable;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final narrow = layout == DeviceLayout.phone;
    // UI polish: below ~420 px the connection status is a dot only, so the
    // search box keeps room for its placeholder.
    final tiny = MediaQuery.sizeOf(context).width < 420;
    final scheme = Theme.of(context).colorScheme;
    final prefs = UiPrefsScope.maybeOf(context);
    final status = Tooltip(
      message: app.online ? 'Connected. Tap to refresh.' : 'Offline. Tap to retry.',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => app.sync(loud: true),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tiny ? 8 : 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            app.syncing
                ? const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6))
                : Icon(Icons.circle, size: tiny ? 11 : 9, color: app.online ? Brand.forest : const Color(0xFFB46C15),
                    semanticLabel: app.online ? 'Online' : 'Offline'),
            if (!tiny) ...[
            const SizedBox(width: 7),
            Text(
              narrow
                  ? (app.online ? 'Online' : 'Offline')
                  : '${app.online ? 'Online' : 'Offline'}${app.pending.isEmpty ? '' : ' · ${app.pending.length} waiting'}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            ],
          ]),
        ),
      ),
    );
    final scans = {'billing', 'parts', 'bins'}.contains(controller.section);
    return Container(
      height: layout == DeviceLayout.desktop ? 56 : 64,
      padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 24),
      decoration: BoxDecoration(color: scheme.surface, border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        if (!searchable) const Spacer() else Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: TextField(
              controller: controller.search,
              focusNode: controller.searchFocus,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: controller.section == 'billing'
                    ? (narrow ? 'Find a part' : showKeyHints(context) ? 'Search or scan parts  (F1)' /* WS-A: F1 on the counter */ : 'Search or scan parts')
                    : (tiny ? 'Search' : 'Search this list'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: ValueListenableBuilder(
                  valueListenable: controller.search,
                  builder: (_, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: controller.search.clear),
                ),
              ),
              onSubmitted: (value) {
                if (scans && value.trim().isNotEmpty) handleScan(context, controller, value);
              },
            ),
          ),
        ),
        if (searchable) SizedBox(width: tiny ? 4 : 8),
        if (scans)
          IconButton.filledTonal(
            tooltip: 'Scan barcode',
            visualDensity: tiny ? VisualDensity.compact : null,
            onPressed: () async {
              final code = await requestBarcode(context);
              if (code != null && context.mounted) handleScan(context, controller, code);
            },
            icon: const Icon(Icons.qr_code_scanner),
          ),
        if (!narrow && searchable) const Spacer(),
        status,
        if (!narrow && prefs != null)
          IconButton(
            tooltip: 'Appearance: ${prefs.appearance.label} (switch to ${prefs.appearance.next.label})',
            onPressed: () => prefs.setAppearance(prefs.appearance.next),
            icon: Icon(prefs.appearance.icon),
          ),
        // WS-D: switch user / lock the counter.
        IconButton(
          tooltip: 'Switch user (Ctrl+L)',
          visualDensity: tiny ? VisualDensity.compact : null,
          onPressed: () => lockCounter(app),
          icon: const Icon(Icons.switch_account_outlined),
        ),
        if (app.canSell) ...[
          SizedBox(width: tiny ? 0 : 6),
          Badge(
            isLabelVisible: counterHolds(app).isNotEmpty, // Integration: job reservations are not counter bills
            label: Text('${counterHolds(app).length}'),
            child: IconButton(
              tooltip: 'Parked sales',
              visualDensity: tiny ? VisualDensity.compact : null,
              onPressed: () => showParked(context, controller),
              icon: const Icon(Icons.pause_circle_outline),
            ),
          ),
        ],
      ]),
    );
  }
}
