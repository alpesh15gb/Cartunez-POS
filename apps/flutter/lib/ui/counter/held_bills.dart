import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../widgets.dart';
import 'counter_keys.dart' show showKeyHints;

// WS-A: held (parked) bills drawer. Search by customer name, vehicle reg no,
// note or item; one click resumes the whole cart (lines, customer, vehicle,
// price level).

/// Held bills the counter may recall. Integration: job-card stock reservations
/// are holds carrying `jobId`; they are billed from the job card, never here.
List<Json> counterHolds(AppState app) =>
    app.list('holds').where((h) => '${h['jobId'] ?? ''}'.isEmpty).toList();

/// Whether [hold] matches the drawer's search text.
bool holdMatches(AppState app, Json hold, String query) {
  final q = normalize(query);
  if (q.isEmpty) return true;
  final cart = Map<String, dynamic>.from(hold['cart'] as Map? ?? {});
  final vehicle = cart['vehicle'] as Map?;
  final words = [
    hold['label'],
    hold['customerName'],
    hold['regNo'],
    cart['regNo'],
    app.customerById('${cart['customerId']}')?['name'],
    if (vehicle != null) '${vehicle['make']} ${vehicle['model']}',
    for (final l in cart['lines'] as List? ?? []) ...[
      app.productName('${l['productId']}'),
      app.productById('${l['productId']}')?['sku'],
    ],
  ];
  return words.any((w) => w != null && normalize(w).contains(q));
}

/// Puts a held bill back on the counter. Returns false when the counter is busy.
Future<bool> resumeHold(BuildContext context, Json hold) async {
  final app = context.appRead;
  if ('${hold['jobId'] ?? ''}'.isNotEmpty) {
    app.toast('These parts are reserved for a job card. Bill them from the job card.');
    return false;
  }
  if ((app.cart['lines'] as List).isNotEmpty && app.cart['holdId'] != hold['id']) {
    final park = await confirm(context, 'Hold the current bill?',
        'The bill on the counter is held first, so nothing is lost, then this one is resumed.',
        action: 'Hold and resume');
    if (!park || !context.mounted) return false;
    try {
      await app.parkCart();
    } catch (error) {
      app.toast(errorText(error));
      return false;
    }
  }
  final cart = Map<String, dynamic>.from(hold['cart'] as Map);
  app.replaceCart({
    ...cart,
    'holdId': hold['id'],
    if ('${hold['regNo'] ?? ''}'.isNotEmpty) 'regNo': hold['regNo'],
  });
  return true;
}

Future<void> showParked(BuildContext context, ShellController shell) async {
  final app = context.appRead;
  final wide = MediaQuery.sizeOf(context).width >= 600;
  Widget panel(BuildContext sheet) => AppScope(state: app, child: HeldBillsPanel(onResumed: () {
        Navigator.pop(sheet);
        shell.open('billing');
      }));
  if (wide) {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close held bills',
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (sheet, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 8,
          child: SizedBox(width: 440, height: double.infinity, child: SafeArea(child: panel(sheet))),
        ),
      ),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
        child: child,
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => FractionallySizedBox(heightFactor: 0.85, child: SafeArea(child: panel(sheet))),
  );
}

class HeldBillsPanel extends StatefulWidget {
  const HeldBillsPanel({super.key, required this.onResumed});
  final VoidCallback onResumed;
  @override
  State<HeldBillsPanel> createState() => _HeldBillsPanelState();
}

class _HeldBillsPanelState extends State<HeldBillsPanel> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _resume(Json hold) async {
    if (await resumeHold(context, hold) && mounted) widget.onResumed();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final all = counterHolds(app)
      ..sort((a, b) => '${b['updatedAt'] ?? b['createdAt']}'.compareTo('${a['updatedAt'] ?? a['createdAt']}'));
    final holds = all.where((h) => holdMatches(app, h, search.text)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Held bills (${all.length})', style: Theme.of(context).textTheme.titleLarge)),
          IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: search,
          autofocus: true,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name, reg no or item'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (holds.length == 1) _resume(holds.single);
          },
        ),
        const SizedBox(height: 8),
        Expanded(
          child: holds.isEmpty
              ? EmptyState(message: all.isEmpty
                  ? (showKeyHints(context)
                      ? 'No held bills. Press Hold (F4) to park a sale and reserve its stock.'
                      : 'No held bills. Tap Hold to park a sale and reserve its stock.')
                  : 'No held bill matches "${search.text}".')
              : ListView.builder(itemCount: holds.length, itemBuilder: (context, i) => _HoldTile(hold: holds[i], onResume: () => _resume(holds[i]))),
        ),
      ]),
    );
  }
}

class _HoldTile extends StatelessWidget {
  const _HoldTile({required this.hold, required this.onResume});
  final Json hold;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final cart = Map<String, dynamic>.from(hold['cart'] as Map? ?? {});
    final lines = (cart['lines'] as List? ?? []).cast<Map>();
    final name = '${hold['customerName'] ?? ''}'.isNotEmpty
        ? '${hold['customerName']}'
        : '${app.customerById('${cart['customerId']}')?['name'] ?? 'Walk-in customer'}';
    final reg = '${hold['regNo'] ?? ''}';
    Quote? bill;
    try {
      bill = app.currentQuote(cart);
    } catch (_) {}
    final expires = DateTime.tryParse('${hold['expiresAt'] ?? ''}');
    final expired = expires != null && expires.isBefore(DateTime.now());
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onResume,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (reg.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(border: Border.all(color: scheme.outline), borderRadius: BorderRadius.circular(4)),
                      child: Text(reg, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                    ),
                  if ('${hold['label'] ?? ''}'.isNotEmpty) Text('${hold['label']}', style: Theme.of(context).textTheme.bodySmall),
                  if (expired) const StatusChip('Expired'),
                ]),
                const SizedBox(height: 4),
                Text(
                  lines.map((l) => '${l['qty']} × ${app.productName('${l['productId']}')}').join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text('Held ${formatDate(hold['createdAt'])} by ${app.userName('${hold['userId']}')}'
                    '${expires != null && !expired ? ' · until ${formatDate(hold['expiresAt'])}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (bill != null)
                Text(app.money(bill.total), style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Discard',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await confirm(context, 'Discard this held bill?', 'Its reserved stock is released.', action: 'Discard')) return;
                    try {
                      await app.api('/holds/${hold['id']}', method: 'DELETE');
                      if (app.cart['holdId'] == hold['id']) app.updateCart({'holdId': null});
                      await app.sync();
                      app.toast('Held bill discarded. Stock released.');
                    } catch (error) {
                      app.toast(errorText(error));
                    }
                  },
                ),
                FilledButton(onPressed: onResume, child: const Text('Resume')),
              ]),
            ]),
          ]),
        ),
      ),
    );
  }
}
