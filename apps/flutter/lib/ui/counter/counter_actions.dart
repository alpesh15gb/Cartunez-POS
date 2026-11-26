import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';

// ---------------- actions ----------------

bool setLineQuantity(BuildContext context, int index, int qty, {bool quiet = false}) {
  final app = context.appRead;
  final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  if (index >= lines.length) return false;
  if (qty < 1) {
    lines.removeAt(index);
    app.updateCart({'lines': lines});
    return true;
  }
  if (qty > 9999) return false;
  final line = lines[index];
  final product = app.productById('${line['productId']}');
  if (product?['serialTracked'] == true && qty != line['qty']) {
    if (!quiet) app.toast('Add or remove serial-tracked units from the part form.');
    return false;
  }
  if (qty > (line['qty'] as int) && product != null) {
    if (product['salesStopped'] == true) {
      if (!quiet) app.toast('Sales are stopped for this part.');
      return false;
    }
    if (isOnlineOnly(product)) {
      if (!quiet) app.toast(onlineOnlyMessage(product));
      return false;
    }
  }
  if (line['binId'] != null && product?['type'] != 'service' && !beyondStock(app, product)) {
    final max = app.available('${line['productId']}', '${line['binId']}');
    if (qty > max) {
      if (!quiet) app.toast('Only $max available in ${app.locationName('${line['binId']}')}.');
      return false;
    }
  }
  lines[index] = {...line, 'qty': qty};
  app.updateCart({'lines': lines});
  return true;
}

Future<void> addPart(BuildContext context, Json product, {bool quick = false}) async {
  final app = context.appRead;
  if (!app.canSell) {
    app.toast('Your role cannot create sales.');
    return;
  }
  if (product['salesStopped'] == true) {
    app.toast('Sales are stopped for this part.');
    return;
  }
  if (isOnlineOnly(product)) {
    app.toast(onlineOnlyMessage(product));
    return;
  }
  final productId = '${product['id']}';
  final service = product['type'] == 'service';
  final beyond = beyondStock(app, product);
  final stocked = app.sellableBins.where((b) => app.available(productId, '${b['id']}') > 0).toList();
  final choices = stocked.isNotEmpty || !beyond ? stocked : usualBins(app, product);
  if (!service && choices.isEmpty) {
    app.toast(beyond ? 'Add a sellable bin first (Catalog & stock › Bins).' : '${product['name']} is out of stock.');
    return;
  }
  final vehicle = app.cart['vehicle'] as Map?;
  final fit = vehicle == null ? const FitResult('unchecked') : fitment(product, Map<String, dynamic>.from(vehicle));
  final binId = service ? null : '${choices.first['id']}';
  final lines = (app.cart['lines'] as List).cast<Json>();
  int remaining(Json bin) => app.available(productId, '${bin['id']}') - lines
      .where((line) => line['productId'] == product['id'] && line['binId'] == bin['id'])
      .fold<int>(0, (qty, line) => qty + (line['qty'] as int));
  if (quick && product['serialTracked'] != true && !fit.needsOverride && (service || stocked.length == 1)) {
    final index = lines.indexWhere((line) => line['productId'] == product['id'] && line['binId'] == binId);
    final qty = index < 0 ? 1 : (lines[index]['qty'] as int) + 1;
    if (qty <= 9999 && (service || qty <= app.available(productId, binId))) {
      if (index >= 0) {
        setLineQuantity(context, index, qty);
      } else {
        app.updateCart({'lines': [...lines, {'productId': product['id'], 'qty': 1, 'binId': binId, 'serials': <String>[]}]});
      }
      return;
    }
  }
  await showFormDialog<void>(
    context,
    title: 'Add ${product['name']}',
    submit: 'Add to sale',
    header: !service && beyond && !choices.any((bin) => remaining(bin) > 0)
        ? const StockCaution('No stock available. Adding this part can make stock negative.')
        : null,
    fields: [
      const FieldSpec('qty', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      if (!service)
        FieldSpec('binId', 'Picked from bin',
            kind: FieldKind.select,
            required: true,
            barcodeChoice: app.binIdForCode,
            value: binId,
            options: [for (final bin in choices) ('${bin['id']}', '${app.binName(bin)} · ${remaining(bin)} available')]),
      if (product['serialTracked'] == true)
        const FieldSpec('serials', 'Serial numbers', required: true, help: 'One per unit, separated by commas.'),
      if (fit.needsOverride)
        FieldSpec('overrideReason', '${titleCase(fit.status)} fitment — reason',
            required: true,
            help: fit.missing.isNotEmpty ? 'Add ${fit.missing.join(', ')} to the vehicle to verify the match.' : null),
      if (fit.needsOverride && !app.isManager)
        FieldSpec('approvalId', 'Manager approval ID',
            required: true, help: 'Ask a manager to approve fitment for ${app.cart['transactionId']}.'),
    ],
    onSubmit: (values) async {
      final currentProduct = app.productById('${product['id']}');
      if (currentProduct?['salesStopped'] == true) {
        throw FormProblem('Sales are stopped for this part.');
      }
      if (currentProduct != null && isOnlineOnly(currentProduct)) throw FormProblem(onlineOnlyMessage(currentProduct));
      final qty = int.tryParse('${values['qty']}') ?? 0;
      if (qty < 1 || qty > 9999) throw FormProblem('Enter a quantity from 1 to 9999.');
      final binId = '${values['binId'] ?? ''}'.isEmpty ? null : '${values['binId']}';
      final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final existing = lines.indexWhere((l) => l['productId'] == product['id'] && l['binId'] == binId);
      final already = existing >= 0 ? lines[existing]['qty'] as int : 0;
      if (qty + already > 9999) throw FormProblem('A sale line can contain at most 9999 units.');
      if (binId != null && !beyondStock(app, currentProduct ?? product) && qty + already > app.available(productId, binId)) {
        throw FormProblem('Only ${app.available(productId, binId)} available in that bin.');
      }
      final serials = splitList(values['serials']);
      final existingSerials = lines.where((l) => l['productId'] == product['id'])
          .expand((l) => l['serials'] as List? ?? const []).toSet();
      if (product['serialTracked'] == true &&
          (serials.length != qty || serials.toSet().length != qty || serials.any(existingSerials.contains))) {
        throw FormProblem('Enter one serial number for each unit.');
      }
      var approvalId = '${values['approvalId'] ?? ''}'.isNotEmpty ? values['approvalId'] : app.cart['approvalId'];
      if (fit.needsOverride && app.isManager) {
        final approval = await app.api('/approvals', body: {
          'action': 'fitment',
          'transactionId': app.cart['transactionId'],
          'reason': values['overrideReason'],
        }) as Map;
        approvalId = approval['id'];
      }
      final line = {
        if (existing >= 0) ...lines[existing],
        'productId': product['id'],
        'qty': qty + already,
        'binId': binId,
        'serials': [...(existing >= 0 ? lines[existing]['serials'] as List? ?? [] : []), ...serials],
        'overrideReason': '${values['overrideReason'] ?? ''}'.isNotEmpty
            ? values['overrideReason']
            : (existing >= 0 ? lines[existing]['overrideReason'] ?? '' : ''),
      };
      if (existing >= 0) {
        lines[existing] = line;
      } else {
        lines.add(line);
      }
      app.updateCart({'lines': lines, 'approvalId': approvalId});
    },
  );
}

void handleScan(BuildContext context, ShellController shell, String raw) {
  final app = context.appRead;
  final code = raw.trim();
  if (code.isEmpty) return;
  final matches = app.findByCode(code, forSale: shell.section == 'billing' && app.canSell);
  final bin = app.bins.where((b) => normalize(b['id']) == normalize(code)).firstOrNull;
  if (shell.section != 'billing' || !app.canSell) {
    shell.search.text = bin != null && matches.isEmpty ? app.binName(bin) : code;
    if (matches.isEmpty && bin == null) app.toast('No part or bin matches "$code".');
    return;
  }
  if (matches.isEmpty) {
    shell.search.text = code;
    final all = app.findByCode(code);
    final stopped = all.where((p) => p['salesStopped'] == true).firstOrNull;
    final websiteOnly = all.where(isOnlineOnly).firstOrNull;
    app.toast(websiteOnly != null && stopped == null ? onlineOnlyMessage(websiteOnly)
        : stopped != null ? 'Sales are stopped for ${stopped['sku']}.'
        : bin != null ? '${app.binName(bin)} is a bin label. Scan the part barcode.' : 'No part matches "$code".');
    return;
  }
  if (matches.length > 1) {
    shell.search.text = code;
    app.toast('${matches.length} parts share "$code". Choose the right one.');
    return;
  }
  final product = matches.first;
  shell.search.clear();
  HapticFeedback.selectionClick();
  addPart(context, product, quick: true);
}

Future<void> chooseVehicle(BuildContext context) async {
  final app = context.appRead;
  final current = Map<String, dynamic>.from(app.cart['vehicle'] as Map? ?? {});
  await showFormDialog<void>(
    context,
    title: 'Vehicle',
    submit: 'Use vehicle',
    expanded: ['engine', 'fuel', 'trim', 'drivetrain', 'market'].any((k) => '${current[k] ?? ''}'.isNotEmpty),
    fields: [
      FieldSpec('preset', 'Saved vehicle',
          kind: FieldKind.select,
          options: [for (final v in app.list('vehicles')) ('${v['id']}', '${v['year']} ${v['make']} ${v['model']} ${v['engine'] ?? ''}')]),
      FieldSpec('make', 'Make', value: current['make']),
      FieldSpec('model', 'Model', value: current['model']),
      FieldSpec('year', 'Year', kind: FieldKind.number, value: current['year']),
      for (final k in ['engine', 'fuel', 'trim', 'drivetrain', 'market'])
        FieldSpec(k, titleCase(k), value: current[k], advanced: true),
    ],
    onSubmit: (values) async {
      Json? vehicle;
      if ('${values['preset']}'.isNotEmpty) {
        vehicle = app.list('vehicles').firstWhere((v) => v['id'] == values['preset']);
      } else if ('${values['make']}'.isNotEmpty && '${values['model']}'.isNotEmpty) {
        vehicle = {...values..remove('preset'), 'year': int.tryParse('${values['year']}') ?? 0};
      }
      final lines = [
        for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': ''},
      ];
      app.updateCart({'vehicle': vehicle, 'approvalId': null, 'lines': lines});
    },
  );
}

Future<void> approveFitment(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'Approve fitment',
    submit: 'Record approval',
    fields: [
      const FieldSpec('reason', 'Reason', required: true),
      if (!app.isManager)
        FieldSpec('approvalId', 'Manager approval ID', required: true, help: 'Reference ${app.cart['transactionId']}'),
    ],
    onSubmit: (values) async {
      var id = values['approvalId'];
      if (app.isManager) {
        id = (await app.api('/approvals',
            body: {'action': 'fitment', 'transactionId': app.cart['transactionId'], 'reason': values['reason']}) as Map)['id'];
      }
      app.updateCart({
        'approvalId': id,
        'lines': [
          for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': values['reason']},
        ],
      });
    },
  );
}

Future<void> editDiscount(BuildContext context) async {
  final app = context.appRead;
  final bill = app.currentQuote();
  final limit = (app.settings['cashierDiscountLimit'] ?? 0) as int;
  await showFormDialog<void>(
    context,
    title: 'Discount',
    fields: [
      const FieldSpec('mode', 'Discount type', kind: FieldKind.select, value: 'amount',
          options: [('amount', 'Fixed amount'), ('percent', 'Percentage (%)')], required: true),
      FieldSpec('discount', 'Discount value', kind: FieldKind.money,
          value: ((app.cart['discount'] ?? 0) as int) / 100, required: true,
          help: 'Subtotal ${app.money(bill.subtotal)}. Enter an amount or percentage. Enter 0 to remove.'),
      FieldSpec('reason', 'Reason', value: app.cart['discountReason']),
      if (!app.isManager)
        FieldSpec('approvalId', 'Manager approval ID',
            help: 'Needed above ${app.money(limit)}. Reference ${app.cart['transactionId']}. '
                'The approval must cover at least this discount.'),
    ],
    onSubmit: (values) async {
      final value = parsePaymentAmount('${values['discount']}');
      if (value == null) throw FormProblem('Enter a valid discount with up to two decimal places.');
      final subtotal = app.currentQuote().subtotal;
      final percent = values['mode'] == 'percent';
      if (percent && value > 10000) throw FormProblem('Enter a percentage from 0 to 100.');
      final amount = percent
          ? ((BigInt.from(subtotal) * BigInt.from(value) + BigInt.from(5000)) ~/ BigInt.from(10000)).toInt()
          : value;
      if (amount > subtotal) throw FormProblem('Discount cannot be more than ${app.money(subtotal)}.');
      if (amount == 0) {
        app.updateCart({'discount': 0, 'discountReason': '', 'discountApprovalId': null});
        return;
      }
      if ('${values['reason']}'.isEmpty) throw FormProblem('Enter a reason for the discount.');
      if (!app.isManager && amount > limit && '${values['approvalId'] ?? ''}'.isEmpty) {
        throw FormProblem('A manager approval is needed above ${app.money(limit)}.');
      }
      var id = values['approvalId'];
      if (app.isManager) {
        // Security: approvals are bound to the amount (and customer) they approve.
        final customerId = '${app.cart['customerId'] ?? ''}';
        id = (await app.api('/approvals', body: {
          'action': 'discount',
          'transactionId': app.cart['transactionId'],
          'reason': values['reason'],
          'amount': amount,
          if (customerId.isNotEmpty) 'subjectId': customerId,
        }) as Map)['id'];
      }
      app.updateCart({'discount': amount, 'discountReason': values['reason'], 'discountApprovalId': id});
    },
  );
}

Future<void> holdSale(BuildContext context) async {
  final app = context.appRead;
  try {
    await app.parkCart();
  } catch (error) {
    app.toast(errorText(error));
  }
}

Future<void> clearCurrentSale(BuildContext context) async {
  final app = context.appRead;
  final draft = app.cart;
  final held = '${draft['holdId'] ?? ''}'.isNotEmpty;
  final clear = await confirm(
    context,
    'Clear this sale?',
    held
        ? 'The held bill will be discarded and its reserved stock released.'
        : 'All items and any exchange returns will be removed from the current bill.',
    action: 'Clear',
  );
  if (!clear || !context.mounted || !identical(app.cart, draft)) return;
  try {
    await app.discardCart();
  } catch (error) {
    app.toast(errorText(error));
  }
}

/// Whether this part may be sold with no stock showing (Settings › Modules; never for serial-tracked parts).
bool beyondStock(AppState app, Json? product) => app.feature('negativeStock') && product?['serialTracked'] != true;

/// Warn at the point of adding out-of-stock items or reviewing an overdrawn cart line.
class StockCaution extends StatelessWidget {
  const StockCaution(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFFDF3DF), borderRadius: BorderRadius.circular(6)),
        child: Text(message, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Brand.warning)),
      );
}

/// Bins for a sale with no stock showing: where the part is usually kept, then the other sellable bins.
List<Json> usualBins(AppState app, Json product) {
  final usual = app.list('stock').where((s) => s['productId'] == product['id']).map((s) => '${s['binId']}').toSet();
  return [
    ...app.sellableBins.where((b) => usual.contains(b['id'])),
    ...app.sellableBins.where((b) => !usual.contains(b['id'])),
  ];
}
