import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../widgets.dart';

Future<void> startPhysicalCount(BuildContext context) async {
  final app = context.appRead;
  final transactionId = uuid();
  final count = await showFormDialog<Json>(context, title: 'Start stock count', submit: 'Start counting',
    header: const Text('Choose the part and bin before counting. A stock movement during the count requires a recount.'),
    fields: [
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true, barcodeChoice: app.uniqueProductIdForCode,
        options: optionsOf(app.stockParts, (p) => "${p['sku']} · ${p['name']}")),
      FieldSpec('binId', 'Bin', kind: FieldKind.select, required: true, barcodeChoice: app.binIdForCode,
        options: optionsOf(app.bins, (bin) => "${app.binName(bin)} · ${bin['kind']}")),
    ],
    onSubmit: (v) async => Map<String, dynamic>.from(await app.mutate('/inventory/count/start',
      {...v, 'transactionId': transactionId})),
  );
  if (count != null && context.mounted) await enterPhysicalCount(context, count);
}

Future<void> enterPhysicalCount(BuildContext context, Json count) async {
  final app = context.appRead;
  final transactionId = uuid();
  final submitted = await showFormDialog<Json>(context, title: 'Enter physical count', submit: 'Submit for review',
    header: Text("${app.productName(count['productId'])} · ${app.locationName(count['binId'])}"),
    fields: [
      const FieldSpec('counted', 'Counted units', kind: FieldKind.number, required: true,
        help: 'Count every physical unit in this bin, including reserved stock. Enter 0 for an empty bin.'),
      if (count['serialTracked'] == true) const FieldSpec('serials', 'Observed serial numbers',
        kind: FieldKind.multiline, help: 'Enter one serial per line for every physical unit.'),
      const FieldSpec('reason', 'Count reason', required: true),
    ],
    onSubmit: (v) async {
      final counted = int.tryParse("${v['counted']}");
      if (counted == null || counted < 0) throw FormProblem('Enter a whole number of units, zero or more.');
      return Map<String, dynamic>.from(await app.mutate('/inventory/count/submit', {
        'transactionId': transactionId, 'countId': count['id'], 'counted': counted, 'reason': v['reason'],
        'serials': (v['serials'] as String? ?? '').split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      }, app.isManager ? null : 'Count submitted for manager review.'));
    },
  );
  if (submitted != null && app.isManager && context.mounted) await reviewPhysicalCount(context, submitted);
}

Future<void> reviewPhysicalCount(BuildContext context, Json count) async {
  final app = context.appRead;
  final transactionId = uuid();
  await showFormDialog<void>(context, title: 'Review stock count', submit: 'Confirm count', fields: const [],
    header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text("${app.productName(count['productId'])} · ${app.locationName(count['binId'])}"),
      Text("Counted by ${app.userName(count['startedBy'])} · ${formatDate(count['submittedAt'])}"),
      const Divider(),
      Text("Expected   ${count['expected']}"),
      Text("Counted   ${count['counted']}"),
      Text("Change   ${(count['delta'] as int) > 0 ? '+' : ''}${count['delta']}"),
      Text("Reason   ${count['reason']}"),
      if (count['serialTracked'] == true)
        SelectableText("Observed serials   ${(count['serials'] as List).join(', ')}"),
    ]),
    onSubmit: (_) async {
      await app.mutate('/inventory/count', {'countId': count['id'], 'transactionId': transactionId}, 'Count confirmed.');
    },
  );
}

Future<void> openPhysicalCounts(BuildContext context) async {
  final app = context.appRead;
  final rows = app.list('stockCounts');
  final action = await showDialog<(Json, String)>(context: context, builder: (dialog) => AlertDialog(
    title: const Text('Open stock counts'),
    content: SizedBox(width: 520, height: 360, child: ListView.builder(itemCount: rows.length,
      itemBuilder: (_, index) {
        final count = rows[index];
        final review = count['status'] == 'review';
        final canOpen = review ? app.isManager : count['startedBy'] == app.session?.userId;
        return ListTile(contentPadding: EdgeInsets.zero,
          title: Text("${app.productName(count['productId'])} · ${app.locationName(count['binId'])}"),
          subtitle: Text("${review ? 'Awaiting review' : 'Counting'} · ${app.userName(count['startedBy'])}"),
          onTap: canOpen ? () => Navigator.pop(dialog, (count, review ? 'review' : 'enter')) : null,
          trailing: IconButton(tooltip: 'Discard count', icon: const Icon(Icons.delete_outline),
            onPressed: () => Navigator.pop(dialog, (count, 'discard'))));
      })),
    actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close'))],
  ));
  if (action == null || !context.mounted) return;
  final (count, choice) = action;
  if (choice == 'review') return reviewPhysicalCount(context, count);
  if (choice == 'enter') return enterPhysicalCount(context, count);
  if (!await confirm(context, 'Discard stock count?', 'The observation will be closed without adjusting this bin.', action: 'Discard')) return;
  try {
    await app.mutate('/inventory/count/discard', {'countId': count['id']}, 'Count discarded.');
  } catch (e) {
    app.toast(errorText(e));
  }
}
