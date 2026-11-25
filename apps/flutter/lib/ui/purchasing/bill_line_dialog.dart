
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart' show isOnlineOnly;
import '../theme.dart';
import '../widgets.dart';
import '../screens/inventory.dart';
import 'common.dart';

/// One bill line: an existing part (pick or scan) or a new item created on the spot.
Future<Json?> editBillLine(BuildContext context, {required bool gst, Json? original, required Set<String> taken}) async {
  final app = context.appRead;
  String? productId = original?['productId'] as String?;
  return showDialog<Json>(
    context: context,
    builder: (dialogContext) {
      final qty = TextEditingController(text: '${original?['quantity'] ?? 1}');
      final cost = TextEditingController(text: original == null ? '' : plainAmount(original['cost'] as int));
      final price = TextEditingController(text: original?['retailPrice'] == null ? '' : plainAmount(original!['retailPrice'] as int));
      final rate = TextEditingController(text: original == null ? '' : percentText((original['taxRate'] ?? 0) as int));
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
            if (cost.text.isEmpty && ((p['cost'] ?? 0) as int) > 0) cost.text = plainAmount(p['cost'] as int);
            if (rate.text.isEmpty) rate.text = percentText((p['taxRate'] ?? 0) as int);
            binId ??= defaultBin(app, id!);
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
              const SizedBox(height: 12),
              Row(children: [
                if (gst) ...[
                  Expanded(child: TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'GST %'))),
                  const SizedBox(width: 12),
                ],
                Expanded(child: TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'New selling price (optional)', helperText: 'Leave blank to keep the current price'))),
              ]),
              const SizedBox(height: 12),
              // Online only: the goods go straight out to the website customer (no bin, no shop stock).
              if (isOnlineOnly(part))
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Online only: goes straight to the website customer, not into shop stock.'),
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey(binId),
                  initialValue: app.sellableBins.any((b) => b['id'] == binId) ? binId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Put into bin'),
                  items: [for (final b in app.sellableBins) DropdownMenuItem(value: '${b['id']}', child: Text(app.binName(b)))],
                  onChanged: (v) => setLocal(() => binId = v),
                ),
              if (part?['serialTracked'] == true) ...[
                const SizedBox(height: 12),
                TextField(controller: serials, decoration: const InputDecoration(labelText: 'Serial numbers', helperText: 'One per unit, separated by commas')),
              ],
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
                } else if (binId == null && !isOnlineOnly(part)) {
                  err = 'Choose the bin.';
                } else if (price.text.trim().isNotEmpty && parsePaymentAmount(price.text.trim()) == null) {
                  err = 'Enter a valid selling price.';
                } else if (part?['serialTracked'] == true && (serialList.length != q || serialList.toSet().length != q)) {
                  err = 'Enter one serial number per unit.';
                }
                if (err != null) return setLocal(() => problem = err);
                Navigator.pop(dialogContext, {
                  'productId': productId, 'quantity': q, 'cost': c, 'taxRate': r.clamp(0, 4000), 'binId': isOnlineOnly(part) ? null : binId,
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
