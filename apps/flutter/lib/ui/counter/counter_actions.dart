import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../shell.dart';
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
  if (product?['salesStopped'] == true && qty > (line['qty'] as int)) {
    if (!quiet) app.toast('Sales are stopped for this part.');
    return false;
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

Future<void> addPart(BuildContext context, Json product) async {
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
  final service = product['type'] == 'service';
  final beyond = beyondStock(app, product);
  final stocked = app.sellableBins.where((b) => app.available('${product['id']}', '${b['id']}') > 0).toList();
  // No stock showing: still sellable (stock goes negative until the purchase is entered).
  final choices = stocked.isNotEmpty || !beyond ? stocked : usualBins(app, product);
  if (!service && choices.isEmpty) {
    app.toast(beyond ? 'Add a sellable bin first (Inventory › Bins).' : '${product['name']} is out of stock.');
    return;
  }
  final vehicle = app.cart['vehicle'] as Map?;
  final fit = vehicle == null ? const FitResult('unchecked') : fitment(product, Map<String, dynamic>.from(vehicle));
  await showFormDialog<void>(
    context,
    title: 'Add ${product['name']}',
    submit: 'Add to sale',
    fields: [
      const FieldSpec('qty', 'Quantity', kind: FieldKind.number, value: 1, required: true),
      if (!service)
        FieldSpec('binId', 'Picked from bin',
            kind: FieldKind.select,
            required: true,
            barcodeChoice: app.binIdForCode,
            value: choices.first['id'],
            options: [for (final b in choices) ('${b['id']}', '${app.binName(b)} · ${app.available('${product['id']}', '${b['id']}')} available')]),
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
      if (app.productById('${product['id']}')?['salesStopped'] == true) {
        throw FormProblem('Sales are stopped for this part.');
      }
      final qty = int.tryParse('${values['qty']}') ?? 0;
      if (qty < 1 || qty > 9999) throw FormProblem('Enter a quantity from 1 to 9999.');
      final binId = '${values['binId'] ?? ''}'.isEmpty ? null : '${values['binId']}';
      final lines = (app.cart['lines'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final existing = lines.indexWhere((l) => l['productId'] == product['id'] && l['binId'] == binId);
      final already = existing >= 0 ? lines[existing]['qty'] as int : 0;
      if (qty + already > 9999) throw FormProblem('A sale line can contain at most 9999 units.');
      if (binId != null && !beyond && qty + already > app.available('${product['id']}', binId)) {
        throw FormProblem('Only ${app.available('${product['id']}', binId)} available in that bin.');
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
  if (product['serialTracked'] != true) {
    final lines = (app.cart['lines'] as List).cast<Json>();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i]['productId'] != product['id']) continue;
      if (setLineQuantity(context, i, (lines[i]['qty'] as int) + 1, quiet: true)) {
        return;
      }
    }
    final vehicle = app.cart['vehicle'] as Map?;
    final needsOverride = vehicle != null && fitment(product, Map<String, dynamic>.from(vehicle)).needsOverride;
    final service = product['type'] == 'service';
    var binChoices = app.sellableBins.where((bin) =>
        app.available('${product['id']}', '${bin['id']}') > 0 &&
        !lines.any((line) => line['productId'] == product['id'] && line['binId'] == bin['id'])).toList();
    if (binChoices.isEmpty && !service && beyondStock(app, product) &&
        !lines.any((line) => line['productId'] == product['id'])) {
      binChoices = usualBins(app, product).take(1).toList();
    }
    if (!needsOverride && (service || binChoices.length == 1)) {
      if (service && lines.any((line) => line['productId'] == product['id'])) {
        app.toast('A sale line can contain at most 9999 units.');
        return;
      }
      app.updateCart({'lines': [...lines, {
        'productId': product['id'], 'qty': 1, 'binId': service ? null : binChoices.single['id'], 'serials': <String>[],
      }]});
      return;
    }
  }
  addPart(context, product);
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
      FieldSpec('discount', 'Amount off (subtotal ${app.money(bill.subtotal)})',
          kind: FieldKind.money, value: ((app.cart['discount'] ?? 0) as int) / 100, required: true, help: 'Enter 0 to remove.'),
      FieldSpec('reason', 'Reason', value: app.cart['discountReason']),
      if (!app.isManager)
        FieldSpec('approvalId', 'Manager approval ID',
            help: 'Needed above ${app.money(limit)}. Reference ${app.cart['transactionId']}. '
                'The approval must cover at least this discount.'),
    ],
    onSubmit: (values) async {
      final amount = ((double.tryParse('${values['discount']}') ?? -1) * 100).round();
      if (amount < 0) throw FormProblem('Enter a valid amount.');
      if (amount > bill.subtotal) throw FormProblem('Discount cannot be more than ${app.money(bill.subtotal)}.');
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

/// Whether this part may be sold with no stock showing (Settings › Modules; never for serial-tracked parts).
bool beyondStock(AppState app, Json? product) => app.feature('negativeStock') && product?['serialTracked'] != true;

/// Bins for a sale with no stock showing: where the part is usually kept, then the other sellable bins.
List<Json> usualBins(AppState app, Json product) {
  final usual = app.list('stock').where((s) => s['productId'] == product['id']).map((s) => '${s['binId']}').toSet();
  return [
    ...app.sellableBins.where((b) => usual.contains(b['id'])),
    ...app.sellableBins.where((b) => !usual.contains(b['id'])),
  ];
}
