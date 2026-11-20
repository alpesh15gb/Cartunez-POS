import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../photos.dart';
import '../theme.dart';
import '../widgets.dart';
import '../screens/people.dart';
import 'common.dart';
import 'bill_line_dialog.dart';
import 'file_thumbs.dart';

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
  final billDate = TextEditingController(text: billToday());
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
        'taxRate': part?['taxRate'] ?? 0, 'binId': defaultBin(app, '${l['productId']}'), 'retailPrice': null, 'serials': <String>[],
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
    return (subtotal: subtotal, tax: tax, total: subtotal + tax + amountMinor(freight.text) - amountMinor(discount.text));
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
    final line = await editBillLine(context, gst: gst, original: index == null ? null : lines[index],
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
    final paid = amountMinor(paidNow.text);
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
        'otherCharges': amountMinor(freight.text),
        'discount': amountMinor(discount.text),
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
                  if (gst) 'GST ${percentText((l['taxRate'] ?? 0) as int)}%',
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
                sumRow('Items', app.money(t.subtotal)),
                if (gst) sumRow(interState ? 'IGST' : 'GST (CGST + SGST)', app.money(t.tax)),
                if (amountMinor(freight.text) > 0) sumRow('Freight / other', app.money(amountMinor(freight.text))),
                if (amountMinor(discount.text) > 0) sumRow('Discount', '− ${app.money(amountMinor(discount.text))}'),
                sumRow('Bill total', app.money(t.total), bold: true),
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
              TextButton(onPressed: () => setState(() => paidNow.text = plainAmount(t.total < 0 ? 0 : t.total)), child: const Text('Paid in full')),
              Text('Left on the supplier\'s account: ${app.money((t.total - amountMinor(paidNow.text)).clamp(0, 1 << 40))}'),
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
