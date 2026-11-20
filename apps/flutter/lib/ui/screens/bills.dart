import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../photos.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'inventory.dart';
import 'labels.dart';
import 'people.dart';

// Purchasing: supplier bills (with a photo of the supplier's note), returns to
// suppliers, payments, and the running balance (ledger) of every supplier and
// customer.

const paymentModes = ['Cash', 'UPI', 'Bank transfer', 'Cheque', 'Card'];

String _today() => DateTime.now().toIso8601String().substring(0, 10);
int _minor(Object? text) => parsePaymentAmount('${text ?? ''}'.trim().isEmpty ? '0' : '$text') ?? 0;
String _plain(int minor) => (minor / 100).toStringAsFixed(2);
String _percent(int basis) => basis % 100 == 0 ? '${basis ~/ 100}' : (basis / 100).toStringAsFixed(2);

/// "We owe ₹4,300" / "Advance ₹200" for suppliers; "Owes us" / "Advance" for customers.
String balanceText(AppState app, String kind, int balance) {
  if (balance == 0) return 'Settled';
  if (kind == 'suppliers') return balance > 0 ? 'You owe ${app.money(balance)}' : 'Advance ${app.money(-balance)}';
  return balance > 0 ? 'Owes ${app.money(balance)}' : 'Advance ${app.money(-balance)}';
}

Color balanceColor(int balance) => balance > 0 ? Brand.danger : balance < 0 ? Brand.forest : Brand.muted;

// ---------------------------------------------------------------- bills list

class BillsScreen extends StatelessWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final shell = ShellScope.of(context);
    final owed = app.list('suppliers').fold<int>(0, (n, s) => n + app.partyBalance('suppliers', '${s['id']}'));
    return ValueListenableBuilder(
      valueListenable: shell.search,
      builder: (context, search, _) {
        final q = normalize(search.text);
        final rows = app.list('purchaseBills').reversed.where((b) => q.isEmpty ||
            normalize('${b['billNumber']} ${b['supplierName']} ${(b['lines'] as List).map((l) => '${l['name']} ${l['sku']}').join(' ')}').contains(q)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar([
            FilledButton.icon(onPressed: () => enterBill(context), icon: const Icon(Icons.add), label: const Text('Enter supplier bill')),
            OutlinedButton.icon(onPressed: () => shell.open('suppliers'), icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(owed > 0 ? 'Supplier balances · you owe ${app.money(owed)}' : 'Supplier balances')),
            if (app.sellableBins.isEmpty) TextButton(onPressed: () => shell.open('bins'), child: const Text('Add a sellable bin first')),
          ]),
          DataList(
            rows: rows,
            empty: 'No supplier bills yet. When goods arrive, press "Enter supplier bill" and photograph the supplier\'s note.',
            onTap: (b) => showBill(context, b),
            actionWidth: 60,
            columns: [
              Col('Date', (b) => Text('${b['billDate']}')),
              Col('Supplier', (b) => Text('${b['supplierName'] ?? app.supplierById(b['supplierId'])?['name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w700)), flex: 2),
              Col('Bill no.', (b) => Text('${(b['billNumber'] ?? '').toString().isEmpty ? '—' : b['billNumber']}')),
              Col('Items', (b) => Text((b['lines'] as List).map((l) => '${l['name']} × ${l['quantity']}').join(', '), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 3),
              Col('Total', (b) => Text(app.money(b['total']), style: TextStyle(decoration: b['voided'] == true ? TextDecoration.lineThrough : null)), numeric: true),
              Col('', (b) => Wrap(spacing: 6, children: [
                    if (b['voided'] == true) const StatusChip('Cancelled'),
                    if (b['gst'] == true) const StatusChip('GST'),
                  ])),
            ],
            actions: (b) => [
              if ((b['photoIds'] as List? ?? []).isNotEmpty)
                const Tooltip(message: 'Has a photo of the supplier note', child: Icon(Icons.photo_outlined, color: Brand.muted)),
            ],
          ),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------- bill entry

/// Enter what a supplier delivered. [order] pre-fills the outstanding parts of a purchase order.
Future<void> enterBill(BuildContext context, {Json? order, String? supplierId}) async {
  final app = context.appRead;
  if (app.sellableBins.isEmpty) return app.toast('Add a sellable bin first (Inventory › Bins).');
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _BillDialog(order: order, supplierId: supplierId));
}

class _BillDialog extends StatefulWidget {
  const _BillDialog({this.order, this.supplierId});
  final Json? order;
  final String? supplierId;
  @override
  State<_BillDialog> createState() => _BillDialogState();
}

class _BillDialogState extends State<_BillDialog> {
  final transactionId = uuid();
  String? supplierId;
  final billNumber = TextEditingController();
  final billDate = TextEditingController(text: _today());
  final freight = TextEditingController(text: '0.00');
  final discount = TextEditingController(text: '0.00');
  final paidNow = TextEditingController(text: '0.00');
  final notes = TextEditingController();
  String paidMode = 'Cash';
  bool gst = false;
  bool interState = false;
  final lines = <Json>[];
  final photos = <Json>[]; // {id, contentType, name}
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    supplierId = widget.order?['supplierId'] ?? widget.supplierId;
    for (final l in widget.order?['lines'] as List? ?? []) {
      final outstanding = (l['quantity'] as int) - ((l['received'] ?? 0) as int);
      if (outstanding <= 0) continue;
      final part = app.productById('${l['productId']}');
      lines.add({
        'productId': l['productId'], 'quantity': outstanding, 'cost': l['cost'],
        'taxRate': part?['taxRate'] ?? 0, 'binId': _defaultBin(app, '${l['productId']}'), 'retailPrice': null, 'serials': <String>[],
      });
    }
  }

  @override
  void dispose() {
    for (final c in [billNumber, billDate, freight, discount, paidNow, notes]) {
      c.dispose();
    }
    super.dispose();
  }

  ({int subtotal, int tax, int total}) get totals {
    var subtotal = 0, tax = 0;
    for (final l in lines) {
      final amount = (l['quantity'] as int) * (l['cost'] as int);
      subtotal += amount;
      if (gst) tax += (amount * ((l['taxRate'] ?? 0) as int) / 10000).round();
    }
    return (subtotal: subtotal, tax: tax, total: subtotal + tax + _minor(freight.text) - _minor(discount.text));
  }

  Future<void> _addPhoto() async {
    final app = context.appRead;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf']);
    if (picked.isEmpty) return;
    setState(() => busy = true);
    try {
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final isPdf = file.name.toLowerCase().endsWith('.pdf');
        Json body;
        if (isPdf) {
          body = {'contentType': 'application/pdf', 'data': base64Encode(bytes), 'name': file.name};
        } else {
          final photo = await preparePhoto(bytes);
          if (photo == null) {
            app.toast('${file.name} is not a photo the app can read.');
            continue;
          }
          body = {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'name': file.name};
        }
        final saved = await app.api('/attachments', body: body);
        photos.add(Map<String, dynamic>.from(saved as Map));
      }
    } catch (e) {
      app.toast(errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Photograph the supplier's note with the camera (Android).
  Future<void> _capture() async {
    final app = context.appRead;
    setState(() => busy = true);
    try {
      final photo = await capturePhoto();
      if (photo == null) return;
      final saved = await app.api('/attachments', body: {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'name': 'supplier-note.jpg'});
      photos.add(Map<String, dynamic>.from(saved as Map));
    } catch (e) {
      app.toast('The photo could not be taken. ${errorText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _newSupplier() async {
    await editContact(context, 'suppliers', const {}, onSaved: (saved) => setState(() => supplierId = '${saved['id']}'));
  }

  Future<void> _editLine([int? index]) async {
    final line = await _billLine(context, gst: gst, original: index == null ? null : lines[index],
        taken: {for (final (i, l) in lines.indexed) if (i != index) '${l['productId']}'});
    if (line == null || !mounted) return;
    setState(() => index == null ? lines.add(line) : lines[index] = line);
  }

  Future<void> _save() async {
    final app = context.appRead;
    setState(() => error = null);
    if (supplierId == null) return setState(() => error = 'Choose the supplier.');
    if (lines.isEmpty) return setState(() => error = 'Add the items on the bill.');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(billDate.text.trim())) return setState(() => error = 'Enter the bill date as YYYY-MM-DD.');
    final t = totals;
    if (t.total < 0) return setState(() => error = 'The discount is larger than the bill.');
    for (final (label, field) in [('Freight / other charges', freight), ('Discount', discount), ('Paid now', paidNow)]) {
      final text = field.text.trim();
      if (text.isNotEmpty && parsePaymentAmount(text) == null) {
        return setState(() => error = '$label is not a valid amount (use up to two decimals, for example 250.50).');
      }
    }
    final paid = _minor(paidNow.text);
    if (paid > t.total) return setState(() => error = 'Paid now is more than the bill total.');
    setState(() => busy = true);
    try {
      await app.mutate('/purchase-bills', {
        'transactionId': transactionId,
        'supplierId': supplierId,
        'billNumber': billNumber.text.trim(),
        'billDate': billDate.text.trim(),
        'gst': gst,
        'interState': gst && interState,
        if (widget.order != null) 'purchaseOrderId': widget.order!['id'],
        'lines': [
          for (final l in lines)
            {...l, if (!gst) 'taxRate': 0},
        ],
        'otherCharges': _minor(freight.text),
        'discount': _minor(discount.text),
        'photoIds': [for (final p in photos) p['id']],
        'notes': notes.text.trim(),
        if (paid > 0) 'paidNow': {'amount': paid, 'mode': paidMode},
      }, 'Bill saved. Stock and the supplier balance are updated.');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final t = totals;
    final suppliers = app.list('suppliers');
    final balance = app.partyBalance('suppliers', supplierId);
    Widget money(String label, TextEditingController c) => SizedBox(
          width: 150,
          child: TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: label),
            onChanged: (_) => setState(() {}),
          ),
        );
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        insetPadding: MediaQuery.sizeOf(context).width < 600 ? const EdgeInsets.all(12) : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        title: Text(widget.order == null ? 'Supplier bill' : 'Supplier bill for purchase order'),
        scrollable: true,
        content: SizedBox(
          width: 860,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(supplierId),
                  initialValue: suppliers.any((s) => s['id'] == supplierId) ? supplierId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Supplier'),
                  items: [for (final s in suppliers) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}', overflow: TextOverflow.ellipsis))],
                  onChanged: widget.order != null ? null : (v) => setState(() => supplierId = v),
                ),
              ),
              if (widget.order == null) TextButton.icon(onPressed: _newSupplier, icon: const Icon(Icons.person_add_alt), label: const Text('New supplier')),
              SizedBox(width: 160, child: TextField(controller: billNumber, decoration: const InputDecoration(labelText: 'Bill / note no.'))),
              SizedBox(width: 150, child: TextField(controller: billDate, decoration: const InputDecoration(labelText: 'Bill date', hintText: 'YYYY-MM-DD'))),
            ]),
            if (supplierId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Balance before this bill: ${balanceText(app, 'suppliers', balance)}',
                    style: TextStyle(color: balanceColor(balance), fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 12),
            // Photo of the handwritten note.
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final (i, p) in photos.indexed)
                Stack(children: [
                  FileThumb(file: p, size: 84),
                  Positioned(right: 0, top: 0, child: InkWell(onTap: () => setState(() => photos.removeAt(i)),
                      child: const CircleAvatar(radius: 11, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)))),
                ]),
              if (canUseCamera)
                FilledButton.tonalIcon(
                  onPressed: busy || photos.length >= 6 ? null : _capture,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(photos.isEmpty ? 'Take photo of supplier note' : 'Take another photo'),
                ),
              OutlinedButton.icon(
                onPressed: busy || photos.length >= 6 ? null : _addPhoto,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(canUseCamera ? 'From gallery / PDF' : photos.isEmpty ? 'Attach photo of supplier note / bill' : 'Add another photo'),
              ),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: gst,
              onChanged: (v) => setState(() => gst = v),
              title: const Text('GST bill'),
              subtitle: Text(gst ? 'GST is added per item. Turn off for a plain note without GST.' : 'Most supplier notes have no GST. Turn on only for a GST tax invoice.'),
            ),
            if (gst)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: interState,
                onChanged: (v) => setState(() => interState = v ?? false),
                title: const Text('Supplier is in another state (IGST)'),
              ),
            const Divider(),
            Text('Items', style: Theme.of(context).textTheme.titleMedium),
            for (final (i, l) in lines.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(app.productName('${l['productId']}')),
                subtitle: Text([
                  '${l['quantity']} × ${app.money(l['cost'])}',
                  if (gst) 'GST ${_percent((l['taxRate'] ?? 0) as int)}%',
                  'into ${app.locationName(l['binId'])}',
                  if (l['retailPrice'] != null) 'new price ${app.money(l['retailPrice'])}',
                ].join(' · ')),
                onTap: () => _editLine(i),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(app.money((l['quantity'] as int) * (l['cost'] as int)), style: const TextStyle(fontWeight: FontWeight.w700)),
                  IconButton(tooltip: 'Remove', icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() => lines.removeAt(i))),
                ]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(onPressed: busy ? null : () => _editLine(), icon: const Icon(Icons.add), label: const Text('Add item')),
            ),
            const Divider(),
            Wrap(spacing: 12, runSpacing: 12, children: [
              money('Freight / other charges', freight),
              money('Discount on bill', discount),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Brand.mint, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _sumRow('Items', app.money(t.subtotal)),
                if (gst) _sumRow(interState ? 'IGST' : 'GST (CGST + SGST)', app.money(t.tax)),
                if (_minor(freight.text) > 0) _sumRow('Freight / other', app.money(_minor(freight.text))),
                if (_minor(discount.text) > 0) _sumRow('Discount', '− ${app.money(_minor(discount.text))}'),
                _sumRow('Bill total', app.money(t.total), bold: true),
              ]),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              money('Paid now', paidNow),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  initialValue: paidMode,
                  decoration: const InputDecoration(labelText: 'Paid by'),
                  items: [for (final m in paymentModes) DropdownMenuItem(value: m, child: Text(m))],
                  onChanged: (v) => setState(() => paidMode = v ?? paidMode),
                ),
              ),
              TextButton(onPressed: () => setState(() => paidNow.text = _plain(t.total < 0 ? 0 : t.total)), child: const Text('Paid in full')),
              Text('Left on the supplier\'s account: ${app.money((t.total - _minor(paidNow.text)).clamp(0, 1 << 40))}'),
            ]),
            const SizedBox(height: 8),
            TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600))),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: busy ? null : _save, child: Text(busy ? 'Saving…' : 'Save bill · add to stock')),
        ],
      ),
    );
  }
}

Widget _sumRow(String label, String value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
        Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 17 : null)),
      ]),
    );

String? _defaultBin(AppState app, String productId) {
  final stocked = app.list('stock').where((s) => s['productId'] == productId && ((s['quantity'] ?? 0) as num) > 0)
      .map((s) => '${s['binId']}').where((id) => app.sellableBins.any((b) => b['id'] == id));
  return stocked.firstOrNull ?? app.sellableBins.firstOrNull?['id'] as String?;
}

/// One bill line: an existing part (pick or scan) or a new item created on the spot.
Future<Json?> _billLine(BuildContext context, {required bool gst, Json? original, required Set<String> taken}) async {
  final app = context.appRead;
  String? productId = original?['productId'] as String?;
  return showDialog<Json>(
    context: context,
    builder: (dialogContext) {
      final qty = TextEditingController(text: '${original?['quantity'] ?? 1}');
      final cost = TextEditingController(text: original == null ? '' : _plain(original['cost'] as int));
      final price = TextEditingController(text: original?['retailPrice'] == null ? '' : _plain(original!['retailPrice'] as int));
      final rate = TextEditingController(text: original == null ? '' : _percent((original['taxRate'] ?? 0) as int));
      final serials = TextEditingController(text: (original?['serials'] as List? ?? []).join(', '));
      String? binId = original?['binId'] as String?;
      String? problem;
      var pick = 0; // changes when an item is chosen by scan or "New item", to refresh the field
      return StatefulBuilder(builder: (context, setLocal) {
        final part = productId == null ? null : app.productById(productId!);
        void choose(String? id) {
          productId = id;
          final p = id == null ? null : app.productById(id);
          if (p != null) {
            if (cost.text.isEmpty && ((p['cost'] ?? 0) as int) > 0) cost.text = _plain(p['cost'] as int);
            if (rate.text.isEmpty) rate.text = _percent((p['taxRate'] ?? 0) as int);
            binId ??= _defaultBin(app, id!);
          }
        }

        final parts = app.products.where((p) => p['type'] != 'service' && (!taken.contains(p['id']) || p['id'] == productId)).toList()
          ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
        return AlertDialog(
          title: Text(original == null ? 'Add item' : 'Edit item'),
          scrollable: true,
          content: SizedBox(
            width: 520,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Autocomplete<Json>(
                key: ValueKey(pick),
                initialValue: TextEditingValue(text: part == null ? '' : '${part['name']}'),
                displayStringForOption: (p) => '${p['name']}',
                optionsBuilder: (v) {
                  final q = normalize(v.text);
                  if (q.isEmpty) return parts.take(30);
                  final byCode = app.uniqueProductIdForCode(v.text.trim());
                  return parts.where((p) => p['id'] == byCode ||
                      normalize('${p['name']} ${p['sku']} ${p['brand']} ${p['partNumber']} ${(p['barcodes'] as List? ?? []).join(' ')}').contains(q)).take(30);
                },
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280, maxWidth: 520),
                      child: ListView(shrinkWrap: true, children: [
                        for (final p in options)
                          ListTile(dense: true, title: Text('${p['name']}'), subtitle: Text('${p['sku']} · ${p['brand'] ?? ''} · cost ${app.money(p['cost'])}'),
                              onTap: () => onSelected(p)),
                      ]),
                    ),
                  ),
                ),
                onSelected: (p) => setLocal(() => choose('${p['id']}')),
                fieldViewBuilder: (context, controller, focus, submit) => TextField(
                  controller: controller,
                  focusNode: focus,
                  autofocus: original == null,
                  decoration: const InputDecoration(labelText: 'Item', hintText: 'Type a name, SKU or scan a barcode', prefixIcon: Icon(Icons.search)),
                  onChanged: (text) {
                    if (productId != null && text != app.productName(productId!)) setLocal(() => productId = null);
                  },
                  onSubmitted: (text) {
                    final id = app.uniqueProductIdForCode(text.trim());
                    if (id == null) return;
                    if (taken.contains(id)) return setLocal(() => problem = '${app.productName(id)} is already on this bill. Edit that line instead.');
                    setLocal(() { choose(id); problem = null; controller.text = app.productName(id); });
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add_box_outlined),
                  label: const Text('New item (not in the system yet)'),
                  onPressed: () => editProduct(dialogContext, const {}, onSaved: (saved) => setLocal(() { choose('${saved['id']}'); pick++; })),
                ),
              ),
              if (part != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('${part['sku']} · selling price ${app.money(part['retailPrice'])} · last cost ${app.money(part['cost'])}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              Row(children: [
                Expanded(child: TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: gst ? 'Unit cost before GST' : 'Unit cost'))),
              ]),
              Row(children: [
                if (gst) ...[
                  Expanded(child: TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'GST %'))),
                  const SizedBox(width: 12),
                ],
                Expanded(child: TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'New selling price (optional)', helperText: 'Leave blank to keep the current price'))),
              ]),
              DropdownButtonFormField<String>(
                key: ValueKey(binId),
                initialValue: app.sellableBins.any((b) => b['id'] == binId) ? binId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Put into bin'),
                items: [for (final b in app.sellableBins) DropdownMenuItem(value: '${b['id']}', child: Text(app.binName(b)))],
                onChanged: (v) => setLocal(() => binId = v),
              ),
              if (part?['serialTracked'] == true)
                TextField(controller: serials, decoration: const InputDecoration(labelText: 'Serial numbers', helperText: 'One per unit, separated by commas')),
              if (problem != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(problem!, style: const TextStyle(color: Brand.danger))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final q = int.tryParse(qty.text.trim()) ?? 0;
                final c = parsePaymentAmount(cost.text.trim());
                final r = ((double.tryParse(rate.text.trim().isEmpty ? '0' : rate.text.trim()) ?? -1) * 100).round();
                final serialList = splitList(serials.text);
                String? err;
                if (productId == null) {
                  err = 'Choose the item, or create a new one.';
                } else if (q < 1) {
                  err = 'Enter the quantity.';
                } else if (c == null) {
                  err = 'Enter the unit cost.';
                } else if (gst && (r < 0 || r > 4000)) {
                  err = 'Enter the GST % (for example 18).';
                } else if (binId == null) {
                  err = 'Choose the bin.';
                } else if (price.text.trim().isNotEmpty && parsePaymentAmount(price.text.trim()) == null) {
                  err = 'Enter a valid selling price.';
                } else if (part?['serialTracked'] == true && (serialList.length != q || serialList.toSet().length != q)) {
                  err = 'Enter one serial number per unit.';
                }
                if (err != null) return setLocal(() => problem = err);
                Navigator.pop(dialogContext, {
                  'productId': productId, 'quantity': q, 'cost': c, 'taxRate': r.clamp(0, 4000), 'binId': binId,
                  'retailPrice': price.text.trim().isEmpty ? null : parsePaymentAmount(price.text.trim()),
                  'serials': serialList,
                });
              },
              child: Text(original == null ? 'Add to bill' : 'Update'),
            ),
          ],
        );
      });
    },
  );
}

// ---------------------------------------------------------------- photos

/// A small preview of a bill photo (or a PDF icon); tap to open it large.
class FileThumb extends StatelessWidget {
  const FileThumb({super.key, required this.file, this.size = 72});
  final Json file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final isPdf = file['contentType'] == 'application/pdf';
    return InkWell(
      onTap: () => viewFile(context, file),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: size,
          height: size,
          color: const Color(0xFFEFF3F0),
          child: isPdf
              ? const Icon(Icons.picture_as_pdf_outlined, size: 36, color: Brand.muted)
              : FutureBuilder<Uint8List>(
                  future: app.fileBytes('${file['id']}'),
                  builder: (context, snap) => snap.hasData
                      ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
                      : const Icon(Icons.image_outlined, color: Brand.muted),
                ),
        ),
      ),
    );
  }
}

Future<void> viewFile(BuildContext context, Json file) async {
  final app = context.appRead;
  if (file['contentType'] == 'application/pdf') {
    try {
      final bytes = await app.fileBytes('${file['id']}');
      final name = '${file['name'] ?? ''}'.toLowerCase().endsWith('.pdf') ? '${file['name']}' : 'supplier-bill-${file['id']}.pdf';
      app.toast(await saveBytesFile(name, bytes, mimeType: 'application/pdf'));
    } catch (e) {
      app.toast(errorText(e));
    }
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: Stack(children: [
        InteractiveViewer(
          maxScale: 6,
          child: FutureBuilder<Uint8List>(
            future: app.fileBytes('${file['id']}'),
            builder: (context, snap) => snap.hasData
                ? Image.memory(snap.data!, fit: BoxFit.contain)
                : const SizedBox(width: 300, height: 300, child: Center(child: CircularProgressIndicator())),
          ),
        ),
        Positioned(right: 4, top: 4, child: IconButton.filledTonal(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
      ]),
    ),
  );
}

// ---------------------------------------------------------------- one bill

Future<void> showBill(BuildContext context, Json bill) async {
  final app = context.appRead;
  final photos = (bill['photos'] as List? ?? [for (final id in bill['photoIds'] as List? ?? []) {'id': id, 'contentType': 'image/jpeg'}])
      .map((e) => Map<String, dynamic>.from(e as Map)).toList();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Bill ${(bill['billNumber'] ?? '').toString().isEmpty ? '' : '${bill['billNumber']} '}· ${bill['supplierName'] ?? ''}'),
      scrollable: true,
      content: SizedBox(
        width: 720,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, children: [
            Text('Date ${bill['billDate']}'),
            if (bill['gst'] == true) StatusChip(bill['interState'] == true ? 'GST · IGST' : 'GST'),
            if (bill['voided'] == true) const StatusChip('Cancelled'),
          ]),
          if (bill['voided'] == true) Text('Cancelled: ${bill['voidReason'] ?? ''}', style: const TextStyle(color: Brand.danger)),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final p in photos) FileThumb(file: p, size: 110),
            ]),
          ],
          const SizedBox(height: 12),
          for (final l in bill['lines'] as List)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${l['name']}'),
              subtitle: Text('${l['sku']} · ${l['quantity']} × ${app.money(l['cost'])}${bill['gst'] == true ? ' · GST ${_percent((l['taxRate'] ?? 0) as int)}%' : ''} · ${app.locationName(l['binId'])}'),
              trailing: Text(app.money((l['amount'] ?? (l['quantity'] as int) * (l['cost'] as int)) as int)),
            ),
          const Divider(),
          _sumRow('Items', app.money(bill['subtotal'])),
          if (bill['gst'] == true) _sumRow('GST', app.money(bill['tax'])),
          if (((bill['otherCharges'] ?? 0) as int) > 0) _sumRow('Freight / other', app.money(bill['otherCharges'])),
          if (((bill['discount'] ?? 0) as int) > 0) _sumRow('Discount', '− ${app.money(bill['discount'])}'),
          _sumRow('Bill total', app.money(bill['total']), bold: true),
          if ('${bill['notes'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Notes: ${bill['notes']}')),
        ]),
      ),
      actions: [
        if (bill['voided'] != true)
          TextButton.icon(
            icon: const Icon(Icons.print_outlined),
            label: const Text('Print labels'),
            onPressed: () async {
              final labels = <({LabelItem item, int quantity})>[];
              for (final l in bill['lines'] as List) {
                final part = app.productById('${l['productId']}');
                if (part == null) continue;
                labels.add((item: productLabel(app, part, binId: '${l['binId']}'), quantity: l['quantity'] as int));
              }
              try {
                await printReceiptLineLabels(context, labels);
              } catch (e) {
                app.toast('Labels could not be printed. ${errorText(e)}');
              }
            },
          ),
        if (bill['voided'] != true && app.canStock)
          TextButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Return items to supplier'),
            onPressed: () {
              Navigator.pop(dialogContext);
              supplierReturn(context, app.supplierById('${bill['supplierId']}') ?? {'id': bill['supplierId'], 'name': bill['supplierName']}, bill: bill);
            },
          ),
        if (bill['voided'] != true && app.isManager)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Brand.danger),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await showFormDialog<void>(
                context,
                title: 'Cancel this bill?',
                submit: 'Cancel bill',
                fields: const [FieldSpec('reason', 'Reason', required: true, help: 'Its stock is taken back out. Payments stay; cancel them separately if needed.')],
                onSubmit: (v) async => app.mutate('/purchase-bills/${bill['id']}/void', {'reason': v['reason']}, 'Bill cancelled.'),
              );
            },
            child: const Text('Cancel bill'),
          ),
        FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
      ],
    ),
  );
}

// ---------------------------------------------------------------- returns to supplier

Future<void> supplierReturn(BuildContext context, Json supplier, {Json? bill}) async {
  final app = context.appRead;
  final returned = <String, int>{};
  if (bill != null) {
    for (final r in app.list('purchaseReturns').where((r) => r['billId'] == bill['id'])) {
      for (final l in r['lines'] as List) {
        returned.update('${l['productId']}', (n) => n + (l['quantity'] as int), ifAbsent: () => l['quantity'] as int);
      }
    }
  }
  final candidates = bill == null
      ? app.products.where((p) => p['type'] != 'service').map((p) => {'productId': p['id'], 'cost': p['cost'], 'max': null}).toList()
      : [
          for (final l in bill['lines'] as List)
            if ((l['quantity'] as int) - (returned['${l['productId']}'] ?? 0) > 0)
              {'productId': l['productId'], 'cost': l['cost'], 'binId': l['binId'], 'max': (l['quantity'] as int) - (returned['${l['productId']}'] ?? 0)},
        ];
  if (candidates.isEmpty) return app.toast('Everything on this bill has already been returned.');
  await showFormDialog<void>(
    context,
    title: 'Return to ${supplier['name']}',
    submit: 'Return and adjust balance',
    fields: [
      FieldSpec('productId', 'Part', kind: FieldKind.select, required: true,
          value: candidates.length == 1 ? candidates.single['productId'] : null,
          barcodeChoice: app.uniqueProductIdForCode,
          options: [
            for (final c in candidates)
              ('${c['productId']}', '${app.productName('${c['productId']}')}${c['max'] == null ? '' : ' · up to ${c['max']}'} · ${app.money(c['cost'])} each'),
          ]),
      const FieldSpec('quantity', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      FieldSpec('binId', 'Take from bin', kind: FieldKind.select, required: true,
          value: bill == null ? (app.sellableBins.firstOrNull?['id']) : ((bill['lines'] as List).firstOrNull?['binId']),
          barcodeChoice: app.binIdForCode,
          options: [for (final b in app.list('locations')) ('${b['id']}', app.binName(b))]),
      const FieldSpec('cost', 'Credit per unit (blank = bill cost)', kind: FieldKind.money),
      const FieldSpec('reason', 'Reason', required: true, help: 'For example: damaged, wrong part, excess.'),
    ],
    onSubmit: (v) async {
      final c = candidates.firstWhere((c) => c['productId'] == v['productId']);
      final q = int.tryParse('${v['quantity']}') ?? 0;
      if (q < 1) throw FormProblem('Enter the quantity.');
      if (c['max'] != null && q > (c['max'] as int)) throw FormProblem('Only ${c['max']} can be returned against this bill.');
      await app.mutate('/purchase-returns', {
        'supplierId': supplier['id'],
        if (bill != null) 'billId': bill['id'],
        'reason': v['reason'],
        'lines': [
          {'productId': v['productId'], 'quantity': q, 'binId': v['binId'], 'cost': '${v['cost'] ?? ''}'.isEmpty ? c['cost'] : _minor(v['cost'])},
        ],
      }, 'Returned. Stock and the supplier balance are updated.');
    },
  );
}

// ---------------------------------------------------------------- payments and ledgers

/// Pay a supplier, or receive money from a customer. [refund] goes the other way.
Future<void> recordPayment(BuildContext context, String kind, Json party, {bool refund = false}) async {
  final app = context.appRead;
  final balance = app.partyBalance(kind, '${party['id']}');
  final supplier = kind == 'suppliers';
  final title = supplier
      ? (refund ? 'Money received back from ${party['name']}' : 'Pay ${party['name']}')
      : (refund ? 'Give money back to ${party['name']}' : 'Receive payment from ${party['name']}');
  await showFormDialog<void>(
    context,
    title: title,
    submit: 'Save',
    fields: [
      FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true,
          value: !refund && balance > 0 ? _plain(balance) : null, help: balanceText(app, kind, balance)),
      FieldSpec('mode', 'Paid by', kind: FieldKind.select, required: true, value: 'Cash', options: [for (final m in paymentModes) (m, m)]),
      const FieldSpec('reference', 'UPI / cheque / transaction reference'),
      FieldSpec('date', 'Date', value: _today(), help: 'YYYY-MM-DD'),
      const FieldSpec('notes', 'Notes'),
    ],
    onSubmit: (v) async {
      final amount = _minor(v['amount']);
      if (amount <= 0) throw FormProblem('Enter the amount.');
      await app.mutate('/party-payments', {
        'partyKind': supplier ? 'supplier' : 'customer',
        'partyId': party['id'],
        'amount': amount,
        'mode': v['mode'],
        'reference': v['reference'] ?? '',
        'date': '${v['date'] ?? ''}'.trim().isEmpty ? _today() : '${v['date']}'.trim(),
        'notes': v['notes'] ?? '',
        if (refund) 'refund': true,
      }, 'Payment saved.');
    },
  );
}

/// Everything with one supplier or customer, with the running balance.
Future<void> showLedger(BuildContext context, String kind, Json party) =>
    showDialog<void>(context: context, builder: (_) => _LedgerDialog(kind: kind, party: party));

class _LedgerDialog extends StatefulWidget {
  const _LedgerDialog({required this.kind, required this.party});
  final String kind;
  final Json party;
  @override
  State<_LedgerDialog> createState() => _LedgerDialogState();
}

class _LedgerDialogState extends State<_LedgerDialog> {
  late Future<dynamic> ledger = _load();
  Future<dynamic> _load() => context.appRead.api('/parties/${widget.kind}/${widget.party['id']}/ledger');
  void _reload() => setState(() => ledger = _load());

  Future<void> _then(Future<void> action) async {
    await action;
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final supplier = widget.kind == 'suppliers';
    final party = app.list(widget.kind).where((p) => p['id'] == widget.party['id']).firstOrNull ?? widget.party;
    return AlertDialog(
      insetPadding: MediaQuery.sizeOf(context).width < 600 ? const EdgeInsets.all(12) : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: Row(children: [
        Expanded(child: Text('${party['name']}')),
        IconButton(tooltip: 'Edit details', icon: const Icon(Icons.edit_outlined), onPressed: () async {
          await editContact(context, widget.kind, party);
          if (mounted) _reload();
        }),
      ]),
      content: SizedBox(
        width: 820,
        height: 520,
        child: FutureBuilder<dynamic>(
          future: ledger,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text(errorText(snap.error!)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final balance = (snap.data['balance'] as num).toInt();
            final entries = (snap.data['entries'] as List).cast<Map>().reversed.toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Brand.mint, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text('${party['phone'] ?? ''}')),
                  Text(balanceText(app, widget.kind, balance), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: balanceColor(balance))),
                ]),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(supplier ? 'Pay supplier' : 'Receive payment'),
                  onPressed: () => _then(recordPayment(context, widget.kind, party)),
                ),
                if (supplier && app.canStock) ...[
                  OutlinedButton.icon(icon: const Icon(Icons.receipt_long_outlined), label: const Text('Enter bill'),
                      onPressed: () => _then(enterBill(context, supplierId: '${party['id']}'))),
                  OutlinedButton.icon(icon: const Icon(Icons.undo), label: const Text('Return parts'),
                      onPressed: () => _then(supplierReturn(context, party))),
                ],
                TextButton(
                  onPressed: () => _then(recordPayment(context, widget.kind, party, refund: true)),
                  child: Text(supplier ? 'Refund received' : 'Give money back'),
                ),
              ]),
              const SizedBox(height: 10),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('Nothing yet.'))
                    : ListView.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final debit = (e['debit'] as num).toInt();
                          final credit = (e['credit'] as num).toInt();
                          final payment = e['type'] == 'payment' || e['type'] == 'refund';
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${e['reference']}'),
                            subtitle: Text('${e['date'] == '0000-00-00' ? 'Before the POS' : e['date']}${'${e['note']}'.isEmpty ? '' : ' · ${e['note']}'}'),
                            onTap: e['type'] == 'bill'
                                ? () {
                                    final bill = app.list('purchaseBills').where((b) => b['id'] == e['id']).firstOrNull;
                                    if (bill != null) showBill(context, bill);
                                  }
                                : null,
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(debit > 0 ? '+ ${app.money(debit)}' : '− ${app.money(credit)}',
                                    style: TextStyle(color: debit > 0 ? Brand.danger : Brand.forest, fontWeight: FontWeight.w600)),
                                Text('Bal. ${app.money(e['balance'])}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ]),
                              if (payment && app.isManager)
                                IconButton(
                                  tooltip: 'Cancel this payment',
                                  icon: const Icon(Icons.block, size: 18),
                                  onPressed: () => _then(showFormDialog<void>(
                                    context,
                                    title: 'Cancel this payment?',
                                    submit: 'Cancel payment',
                                    fields: const [FieldSpec('reason', 'Reason', required: true)],
                                    onSubmit: (v) async => app.mutate('/party-payments/${e['id']}/void', {'reason': v['reason']}, 'Payment cancelled.'),
                                  )),
                                )
                              else
                                const SizedBox(width: 8),
                            ]),
                          );
                        },
                      ),
              ),
            ]);
          },
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
