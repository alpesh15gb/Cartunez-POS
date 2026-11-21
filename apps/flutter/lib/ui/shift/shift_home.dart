// WS-D: the Shift home at /shift — current shift with big buttons, then history.
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shift_dialogs.dart';
import 'shift_summary.dart';

class ShiftsScreen extends StatelessWidget {
  const ShiftsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final mine = app.openShift;
    final theme = Theme.of(context);
    Widget big(String label, IconData icon, VoidCallback? onTap, {bool primary = false, String? hint}) => SizedBox(
          width: 168,
          height: 92,
          child: Tooltip(
            message: hint ?? '',
            child: (primary ? FilledButton.new : OutlinedButton.new)(
              key: ValueKey('shift-$label'),
              onPressed: onTap,
              style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 28),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        );
    final offline = app.online ? null : 'Reconnect to record this.';
    final current = Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StatusChip(mine == null ? 'Closed' : 'Open'),
            const SizedBox(width: 10),
            Expanded(
              child: Text(mine == null ? 'No shift open' : 'Your shift since ${formatDate(mine['openedAt'])}',
                  style: theme.textTheme.titleMedium),
            ),
          ]),
          const SizedBox(height: 8),
          if (mine == null)
            Text(app.canSell ? 'Open a shift with the cash in the drawer to start selling.' : 'Only sales staff open shifts.',
                style: theme.textTheme.bodySmall)
          else
            Wrap(spacing: 24, runSpacing: 6, children: [
              _Figure('Opening cash', app.money(mine['openingCash'] as num?)),
              _Figure('Expected in drawer', app.money(app.expectedCash(mine)), key: const ValueKey('expected-cash')),
              _Figure('Bills', '${app.list('invoices').where((i) => i['shiftId'] == mine['id']).length}'),
            ]),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, children: [
            if (mine == null)
              big('Open shift', Icons.lock_open, app.canSell && app.online ? () => showOpenShiftDialog(context) : null,
                  primary: true, hint: offline)
            else ...[
              big('Cash in', Icons.add_circle_outline, app.online ? () => recordDrawerMovement(context, mine, 'in') : null, hint: offline),
              big('Cash out', Icons.remove_circle_outline, app.online ? () => recordDrawerMovement(context, mine, 'out') : null, hint: offline),
              big('Shift summary', Icons.receipt_long_outlined, app.online ? () => showShiftSummary(context, mine) : null, hint: offline),
              big('Close shift', Icons.lock_outline, app.online ? () => closeShift(context, mine) : null, primary: true, hint: offline),
            ],
          ]),
        ]),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      current,
      SectionTitle('Shift history'),
      DataList(
        onTap: (shift) => app.online ? showShiftSummary(context, shift) : showDrawerActivity(context, shift),
        rows: app.list('shifts').reversed.toList(),
        empty: 'No shifts yet.',
        columns: [
          Col('Cashier', (s) => Text(app.userName('${s['userId']}'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Col('Opened', (s) => Text(formatDate(s['openedAt'])), flex: 2),
          Col('Closed', (s) => Text(s['closedAt'] == null ? '—' : formatDate(s['closedAt'])), flex: 2),
          Col('Expected', (s) => Text(app.money((s['closedAt'] != null ? s['expectedCash'] : app.expectedCash(s)) as num?)), numeric: true),
          Col('Counted', (s) => Text(s['closedAt'] == null ? '—' : app.money(s['countedCash'] as num?)), numeric: true),
          Col('Difference', (s) => s['closedAt'] == null
              ? const Text('—')
              : Text(app.money(s['variance'] as num?),
                  style: TextStyle(color: (s['variance'] ?? 0) == 0 ? Brand.forest : Brand.danger, fontWeight: FontWeight.w700)),
              numeric: true),
          Col('Status', (s) => StatusChip(s['closedAt'] == null ? 'Open' : 'Closed')),
        ],
        actionWidth: 90,
        actions: !app.isManager
            ? null
            : (Json s) => [
                  if (s['closedAt'] == null && s['userId'] != app.session?.userId)
                    OutlinedButton(onPressed: () => closeShift(context, s), child: const Text('Close')),
                ],
      ),
    ]);
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ]);
}
