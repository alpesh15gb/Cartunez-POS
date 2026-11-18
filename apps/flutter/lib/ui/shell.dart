import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../state/app_state.dart';
import 'barcode_scan.dart';
import 'login.dart';
import 'screens/billing.dart';
import 'screens/dashboard.dart';
import 'screens/inventory.dart';
import 'screens/people.dart';
import 'screens/purchasing.dart';
import 'screens/reports.dart';
import 'screens/sales.dart';
import 'screens/settings.dart';
import 'theme.dart';
import 'widgets.dart';

const _sellers = ['owner', 'manager', 'cashier'];
const _stock = ['owner', 'manager', 'inventory'];
const _everyone = ['owner', 'manager', 'cashier', 'inventory'];

class TabDef {
  const TabDef(this.id, this.label, this.roles, this.help, this.build, {this.feature});
  final String id;
  final String label;
  final List<String> roles;
  final String help;
  final Widget Function() build;
  final String? feature;
}

class Area {
  const Area(this.label, this.icon, this.tabs);
  final String label;
  final IconData icon;
  final List<TabDef> tabs;
}

final areas = <Area>[
  Area('Billing', Icons.point_of_sale_outlined, [
    TabDef('billing', 'Billing', _sellers, 'Scan or pick parts, then take payment.', () => const BillingScreen()),
  ]),
  Area('Sales', Icons.receipt_long_outlined, [
    TabDef('invoices', 'Invoices', _sellers, 'Reprint receipts, take returns and void invoices.', () => const InvoicesScreen()),
    TabDef('shifts', 'Shifts', _sellers, 'Open and close the cash drawer.', () => const ShiftsScreen()),
  ]),
  Area('Customers', Icons.people_outline, [
    TabDef('customers', 'Customers', _sellers, 'Saved customers for receipts and GST invoices.',
        () => const ContactsScreen(kind: 'customers')),
  ]),
  Area('Inventory', Icons.inventory_2_outlined, [
    TabDef('parts', 'Parts', _everyone, 'Parts, prices, stock and labels.', () => const PartsScreen()),
    TabDef('bins', 'Bins', _stock, 'Racks and bins where stock is kept.', () => const BinsScreen()),
    TabDef('fitment', 'Fitment', _stock, 'Which vehicles each part fits.', () => const FitmentScreen(), feature: 'fitment'),
    TabDef('transfers', 'Transfers', _stock, 'Stock sent between branches.', () => const TransfersScreen(),
        feature: 'transfers'),
    TabDef('warranty', 'Warranty & cores', _stock, 'Supplier warranty claims and core deposit refunds.',
        () => const WarrantyScreen(), feature: 'warranty'),
  ]),
  Area('Purchasing', Icons.local_shipping_outlined, [
    TabDef('orders', 'Orders', _stock, 'Order from suppliers and receive goods into bins.', () => const OrdersScreen()),
    TabDef('suppliers', 'Suppliers', _stock, 'Companies you buy parts from.', () => const ContactsScreen(kind: 'suppliers')),
  ]),
  Area('Dashboard', Icons.insights_outlined, [
    TabDef('dashboard', 'Dashboard', _everyone, 'Today at a glance.', () => const DashboardScreen()),
  ]),
  Area('Reports', Icons.bar_chart_outlined, [
    TabDef('reports', 'Reports', _stock, 'Sales, stock and tax reports with CSV export.', () => const ReportsScreen()),
  ]),
  Area('Settings', Icons.tune_outlined, [
    TabDef('settings', 'Settings', _everyone, 'Business details, staff and this counter.', () => const SettingsScreen()),
    TabDef('sync', 'Sync & audit', _sellers, 'Sales waiting to send and the audit trail.', () => const SyncScreen()),
  ]),
];

/// Navigation and the shared search box.
class ShellController extends ChangeNotifier {
  String section = '';
  final search = TextEditingController();
  final searchFocus = FocusNode();

  void open(String id) {
    if (section == id) return;
    section = id;
    search.clear();
    notifyListeners();
  }
}

class ShellScope extends InheritedNotifier<ShellController> {
  const ShellScope({super.key, required ShellController controller, required super.child}) : super(notifier: controller);
  static ShellController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()!.notifier!;
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final controller = ShellController();
  StreamSubscription<String>? _messages;
  final _buffer = StringBuffer();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _messages = context.appRead.messages.stream.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
    });
    HardwareKeyboard.instance.addHandler(_onKey);
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

  List<Area> _areasFor(AppState app) => [
        for (final area in areas)
          if (_tabsFor(area, app).isNotEmpty) area,
      ];

  List<TabDef> _tabsFor(Area area, AppState app) => [
        for (final tab in area.tabs)
          if (tab.roles.contains(app.role) && (tab.feature == null || app.feature(tab.feature!))) tab,
      ];

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final visible = _areasFor(app);
    final allTabs = [for (final a in visible) ..._tabsFor(a, app)];
    if (!allTabs.any((t) => t.id == controller.section)) {
      controller.section = allTabs.isEmpty ? 'settings' : allTabs.first.id;
    }
    return ShellScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final area = visible.firstWhere((a) => a.tabs.any((t) => t.id == controller.section), orElse: () => visible.first);
          final tabs = _tabsFor(area, app);
          final tab = tabs.firstWhere((t) => t.id == controller.section, orElse: () => tabs.first);
          final width = MediaQuery.sizeOf(context).width;
          final content = _Content(area: area, tabs: tabs, tab: tab, controller: controller);
          if (width >= 720) {
            return Scaffold(
              body: Row(children: [
                _Sidebar(areas: visible, active: area, compact: width < 1100, onOpen: (a) => controller.open(_tabsFor(a, app).first.id)),
                Expanded(child: content),
              ]),
            );
          }
          final primary = visible.take(4).toList();
          final selected = primary.indexOf(area);
          return Scaffold(
            body: SafeArea(bottom: false, child: content),
            bottomNavigationBar: NavigationBar(
              selectedIndex: selected < 0 ? primary.length : selected,
              onDestinationSelected: (index) {
                if (index < primary.length) {
                  controller.open(_tabsFor(primary[index], app).first.id);
                } else {
                  _moreSheet(context, visible.skip(4).toList(), app);
                }
              },
              destinations: [
                for (final a in primary) NavigationDestination(icon: Icon(a.icon), label: a.label),
                if (visible.length > 4) const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
              ],
            ),
          );
        },
      ),
    );
  }

  void _moreSheet(BuildContext context, List<Area> rest, AppState app) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final a in rest)
            ListTile(
              leading: Icon(a.icon),
              title: Text(a.label),
              onTap: () {
                Navigator.pop(sheet);
                controller.open(_tabsFor(a, app).first.id);
              },
            ),
        ]),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.areas, required this.active, required this.compact, required this.onOpen});
  final List<Area> areas;
  final Area active;
  final bool compact;
  final void Function(Area) onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final attention = app.pending.isNotEmpty || app.list('conflicts').any((c) => c['status'] == 'pending');
    return Container(
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
          for (final area in areas)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Tooltip(
                message: compact ? area.label : '',
                waitDuration: const Duration(milliseconds: 400),
                child: Material(
                  color: area == active ? const Color(0xFF2A3D32) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    hoverColor: const Color(0xFF23342E),
                    onTap: () => onOpen(area),
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                        children: [
                          if (!compact) const SizedBox(width: 12),
                          Badge(
                            isLabelVisible: area.label == 'Settings' && attention,
                            backgroundColor: const Color(0xFFF0A43A),
                            smallSize: 8,
                            child: Icon(area.icon,
                                size: 20, color: area == active ? Brand.lime : const Color(0xFFC6D0CA)),
                          ),
                          if (!compact) ...[
                            const SizedBox(width: 13),
                            Text(area.label,
                                style: TextStyle(
                                  color: area == active ? const Color(0xFFD8F6AE) : const Color(0xFFC6D0CA),
                                  fontWeight: area == active ? FontWeight.w700 : FontWeight.w500,
                                )),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          const Divider(color: Color(0xFF37463F)),
          Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: compact
                ? const Icon(Icons.storefront_outlined, color: Color(0xFFA7B6AC))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${app.snapshot['branch']?['name'] ?? app.session?.branchId}',
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

class _Content extends StatelessWidget {
  const _Content({required this.area, required this.tabs, required this.tab, required this.controller});
  final Area area;
  final List<TabDef> tabs;
  final TabDef tab;
  final ShellController controller;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final narrow = MediaQuery.sizeOf(context).width < 720;
    return Column(children: [
      _TopBar(controller: controller, narrow: narrow),
      if (app.sessionProblem != null)
        MaterialBanner(
          backgroundColor: const Color(0xFFFFF3EC),
          content: Text(app.sessionProblem!),
          actions: [TextButton(onPressed: app.logout, child: const Text('Sign in again'))],
        ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          child: KeyedSubtree(
            key: ValueKey(tab.id),
            child: tab.id == 'billing'
                ? tab.build()
                : ListView(
                    padding: EdgeInsets.fromLTRB(narrow ? 16 : 32, 24, narrow ? 16 : 32, 40),
                    children: [
                      Text(area.label, style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      Text(tab.help, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 14),
                      if (tabs.length > 1) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: [for (final t in tabs) ButtonSegment(value: t.id, label: Text(t.label))],
                            selected: {tab.id},
                            onSelectionChanged: (value) => controller.open(value.first),
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      tab.build(),
                    ],
                  ),
          ),
        ),
      ),
    ]);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.narrow});
  final ShellController controller;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final status = Tooltip(
      message: app.online ? 'Connected. Tap to refresh.' : 'Offline. Tap to retry.',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => app.sync(loud: true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            app.syncing
                ? const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6))
                : Icon(Icons.circle, size: 9, color: app.online ? Brand.forest : const Color(0xFFB46C15)),
            const SizedBox(width: 7),
            Text(
              narrow
                  ? (app.online ? 'Online' : 'Offline')
                  : '${app.online ? 'Online' : 'Offline'}${app.pending.isEmpty ? '' : ' · ${app.pending.length} waiting'}',
              style: const TextStyle(fontSize: 12, color: Brand.muted),
            ),
          ]),
        ),
      ),
    );
    return Container(
      height: 64,
      padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 28),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Brand.line))),
      child: Row(children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: TextField(
              controller: controller.search,
              focusNode: controller.searchFocus,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: controller.section == 'billing' ? (narrow ? 'Find a part' : 'Search or scan parts  (F2)') : 'Search this list',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: ValueListenableBuilder(
                  valueListenable: controller.search,
                  builder: (_, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: controller.search.clear),
                ),
              ),
              onSubmitted: (value) {
                if ({'billing', 'parts', 'bins'}.contains(controller.section) && value.trim().isNotEmpty) handleScan(context, controller, value);
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        if ({'billing', 'parts', 'bins'}.contains(controller.section))
          IconButton.filledTonal(
            tooltip: 'Scan barcode',
            onPressed: () async {
              final code = await requestBarcode(context);
              if (code != null && context.mounted) handleScan(context, controller, code);
            },
            icon: const Icon(Icons.qr_code_scanner),
          ),
        if (!narrow) const Spacer(),
        status,
        if (app.canSell) ...[
          const SizedBox(width: 6),
          Badge(
            isLabelVisible: app.list('holds').isNotEmpty,
            label: Text('${app.list('holds').length}'),
            child: IconButton(
              tooltip: 'Parked sales',
              onPressed: () => showParked(context, controller),
              icon: const Icon(Icons.pause_circle_outline),
            ),
          ),
        ],
      ]),
    );
  }
}
