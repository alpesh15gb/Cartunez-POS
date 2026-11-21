// WS-D: the simple shift loop — open with a float, cash in/out, close with a
// note-by-note count (expected vs counted and the difference shown).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shift_summary.dart';

/// Indian notes in paise, largest first. Coins are entered as one amount.
const cashNotes = [200000, 50000, 20000, 10000, 5000, 2000, 1000];

/// Total counted cash in paise: notes × counts plus the coins amount.
int denominationTotal(Map<int, int> counts, {int coins = 0}) {
  var total = coins;
  counts.forEach((note, count) => total += note * count);
  return total;
}

/// Quick opening floats (paise).
const openingFloats = [0, 50000, 100000, 200000, 500000];

/// Opens the cashier's shift with an opening float. Returns true when opened.
Future<bool> showOpenShiftDialog(BuildContext context, {bool forCheckout = false}) async {
  final app = context.appRead;
  final opened = await showDialog<bool>(
    context: context,
    builder: (_) => AppScope(state: app, child: OpenShiftDialog(forCheckout: forCheckout)),
  );
  return opened == true;
}

class OpenShiftDialog extends StatefulWidget {
  const OpenShiftDialog({super.key, this.forCheckout = false});
  final bool forCheckout;
  @override
  State<OpenShiftDialog> createState() => _OpenShiftDialogState();
}

class _OpenShiftDialogState extends State<OpenShiftDialog> {
  final amount = TextEditingController(text: '0');
  bool busy = false;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  /// What the last closed shift in this branch counted, a common opening float.
  int? get _lastCounted {
    final closed = context.appRead.list('shifts').where((s) => s['closedAt'] != null && s['countedCash'] is int).toList();
    return closed.isEmpty ? null : closed.last['countedCash'] as int;
  }

  Future<void> _submit() async {
    final app = context.appRead;
    final value = parsePaymentAmount(amount.text.trim().isEmpty ? '0' : amount.text);
    if (value == null) {
      setState(() => error = 'Enter the cash in the drawer, for example 2000 or 2000.50.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await app.mutate('/shifts/open', {'openingCash': value}, 'Shift opened with ${app.money(value)} in the drawer.');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final last = _lastCounted;
    final quick = {...openingFloats, ?last};
    return AlertDialog(
      title: const Text('Open shift'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.forCheckout ? 'A shift is needed before taking payment. Count the cash in the drawer.' : 'Count the cash in the drawer to start.'),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('opening-cash'),
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Opening cash (float)', prefixText: '₹ '),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final value in quick)
              ActionChip(
                label: Text(value == last && !openingFloats.contains(value) ? 'Last close ${app.money(value)}' : app.money(value)),
                onPressed: () => setState(() => amount.text = (value / 100).toStringAsFixed(value % 100 == 0 ? 0 : 2)),
              ),
          ]),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: busy ? null : _submit, child: const Text('Open shift')),
      ],
    );
  }
}

const cashInReasons = ['Change float', 'Owner added cash'];
const cashOutReasons = ['Safe drop', 'Petty expense', 'Paid to owner'];

Future<void> recordDrawerMovement(BuildContext context, Json shift, String direction) async {
  final app = context.appRead;
  final transactionId = uuid();
  await showFormDialog<void>(context,
    title: direction == 'in' ? 'Cash in' : 'Cash out',
    submit: 'Record movement',
    fields: [
      const FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true),
      FieldSpec('reason', 'Reason', required: true, suggestions: direction == 'in' ? cashInReasons : cashOutReasons),
    ],
    onSubmit: (values) async {
      final amount = parsePaymentAmount('${values['amount']}');
      if (amount == null || amount < 1) throw FormProblem('Enter an amount above zero with up to two decimal places.');
      await app.mutate('/shifts/${shift['id']}/cash-movements', {
        'transactionId': transactionId, 'direction': direction, 'amount': amount, 'reason': values['reason'],
      }, 'Drawer movement recorded.');
    },
  );
}

Future<void> showDrawerActivity(BuildContext context, Json shift) async {
  final app = context.appRead;
  final entries = app.list('cashMovements').where((m) => m['shiftId'] == shift['id']).toList().reversed;
  final staff = app.userName(shift['userId']);
  await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
    title: const Text('Shift cash activity'),
    content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$staff · ${formatDate(shift['openedAt'])}'),
        Text('Opening cash   ${app.money(shift['openingCash'])}'),
        Text('Expected cash   ${app.money(shift['expectedCash'] ?? app.expectedCash(shift))}'),
        if (shift['closedAt'] != null) Text('Counted cash   ${app.money(shift['countedCash'])}'),
        const Divider(),
        if (entries.isEmpty) const Text('No cash-in or cash-out entries.'),
        for (final entry in entries) ListTile(contentPadding: EdgeInsets.zero,
          title: Text('${entry['direction'] == 'in' ? 'Cash in' : 'Cash out'} · ${app.money(entry['amount'])}'),
          subtitle: Text('${formatDate(entry['createdAt'])} · ${app.userName(entry['userId'])}\n${entry['reason']}'),
        ),
      ],
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')),
      FilledButton.tonal(onPressed: () {
        Navigator.pop(dialog);
        showShiftSummary(context, shift);
      }, child: const Text('Shift summary')),
    ],
  ));
}

/// Close a shift: count the drawer (by notes or as one total), see expected,
/// counted and the difference, then close. Shows the summary afterwards.
Future<void> closeShift(BuildContext context, Json shift) async {
  final app = context.appRead;
  if (app.pending.any((e) => e['transaction']['shiftId'] == shift['id'])) {
    app.toast('Resolve waiting payments in Settings › Sync & audit before closing this shift.');
    return;
  }
  final closed = await showDialog<Json>(
    context: context,
    builder: (_) => AppScope(state: app, child: CloseShiftDialog(shift: shift)),
  );
  if (closed != null && context.mounted) await showShiftSummary(context, closed);
}

class CloseShiftDialog extends StatefulWidget {
  const CloseShiftDialog({super.key, required this.shift, this.expected});
  final Json shift;

  /// Expected drawer cash; defaults to the register's calculation.
  final int? expected;
  @override
  State<CloseShiftDialog> createState() => CloseShiftDialogState();
}

class CloseShiftDialogState extends State<CloseShiftDialog> {
  final notes = {for (final n in cashNotes) n: TextEditingController()};
  final coins = TextEditingController();
  final total = TextEditingController();
  final note = TextEditingController(text: 'Shift close');
  bool byNotes = true;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final c in [...notes.values, coins, total, note]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<int, int> get counts => {for (final e in notes.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0};
  int get coinsPaise => parsePaymentAmount(coins.text.trim().isEmpty ? '0' : coins.text) ?? 0;

  /// The counted cash in paise, or null when the direct total is not a valid amount.
  int? get counted => byNotes ? denominationTotal(counts, coins: coinsPaise) : parsePaymentAmount(total.text.trim());

  Future<void> _submit() async {
    final app = context.appRead;
    final cash = counted;
    if (cash == null) {
      setState(() => error = 'Enter the cash counted in the drawer.');
      return;
    }
    if (byNotes && coins.text.trim().isNotEmpty && parsePaymentAmount(coins.text) == null) {
      setState(() => error = 'Enter coins as an amount, for example 45 or 45.50.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await app.mutate('/shifts/${widget.shift['id']}/close', {
        'countedCash': cash,
        if (byNotes) 'denominations': {
          for (final e in counts.entries)
            if (e.value > 0) '${e.key}': e.value,
          if (coinsPaise > 0) 'coins': coinsPaise,
        },
        'reason': note.text.trim().isEmpty ? 'Shift close' : note.text.trim(),
      }) as Map;
      final variance = (result['variance'] ?? 0) as int;
      app.toast(variance == 0 ? 'Shift closed. The drawer balances.' : 'Shift closed with a difference of ${app.money(variance)}.');
      if (mounted) Navigator.pop(context, Map<String, dynamic>.from(result));
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final expected = widget.expected ?? app.expectedCash(widget.shift);
    final cash = counted;
    final variance = cash == null ? null : cash - expected;
    void changed(String _) => setState(() {});
    final numberField = [FilteringTextInputFormatter.digitsOnly];
    Widget noteRow(int value) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SizedBox(width: 70, child: Text(app.money(value).replaceAll('.00', ''), style: const TextStyle(fontWeight: FontWeight.w700))),
            const Text('×  '),
            SizedBox(
              width: 90,
              child: TextField(
                key: ValueKey('note-$value'),
                controller: notes[value],
                keyboardType: TextInputType.number,
                inputFormatters: numberField,
                textAlign: TextAlign.end,
                decoration: const InputDecoration(isDense: true, hintText: '0'),
                onChanged: changed,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.money(value * (int.tryParse(notes[value]!.text) ?? 0)),
                  textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
            ),
          ]),
        );
    return AlertDialog(
      title: const Text('Close shift'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Count notes')),
                ButtonSegment(value: false, label: Text('Enter total')),
              ],
              selected: {byNotes},
              onSelectionChanged: (v) => setState(() => byNotes = v.first),
            ),
            const SizedBox(height: 14),
            if (byNotes) ...[
              for (final n in cashNotes) noteRow(n),
              Row(children: [
                const SizedBox(width: 70, child: Text('Coins', style: TextStyle(fontWeight: FontWeight.w700))),
                const Text('   '),
                SizedBox(
                  width: 90,
                  child: TextField(
                    key: const ValueKey('note-coins'),
                    controller: coins,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(isDense: true, hintText: '0', prefixText: '₹ '),
                    onChanged: changed,
                  ),
                ),
              ]),
            ] else
              TextField(
                key: const ValueKey('counted-total'),
                controller: total,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: 'Cash counted in drawer', prefixText: '₹ '),
                onChanged: changed,
              ),
            const Divider(height: 28),
            _Line('Expected in drawer', app.money(expected)),
            _Line('Counted', cash == null ? '—' : app.money(cash), key: const ValueKey('counted-cash')),
            _Line(
              'Difference',
              variance == null ? '—' : '${variance > 0 ? '+' : ''}${app.money(variance)}${variance == 0 ? '' : variance > 0 ? ' over' : ' short'}',
              color: variance == null || variance == 0 ? Brand.forest : Brand.danger,
              strong: true,
              key: const ValueKey('variance'),
            ),
            const SizedBox(height: 10),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
            if (error != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: busy ? null : _submit, child: const Text('Close shift')),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {super.key, this.color, this.strong = false});
  final String label;
  final String value;
  final Color? color;
  final bool strong;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(color: color, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, fontSize: strong ? 16 : null)),
        ]),
      );
}
