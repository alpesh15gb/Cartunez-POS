// Billing rules shared with the web register (apps/web/app/storage.ts).
// Amounts are integers in minor units (paise); tax rates are basis points.
import 'dart:math';

typedef Json = Map<String, dynamic>;

String normalize(Object? value) =>
    (value ?? '').toString().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

String uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

int? parsePaymentAmount(String text) {
  final match = RegExp(r'^(\d{1,10})(?:\.(\d{0,2}))?$').firstMatch(text.trim());
  if (match == null) return null;
  final amount = int.parse(match[1]!) * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
  return amount <= 100000000000 ? amount : null;
}

class FitResult {
  const FitResult(this.status, [this.missing = const []]);
  final String status;
  final List<String> missing;
  bool get needsOverride => status == 'incompatible' || status == 'unverified';
}

/// Mirrors the server: no vehicle selected means there is nothing to check.
FitResult fitment(Json product, Json? vehicle) {
  if (product['universal'] == true) return const FitResult('universal');
  if (vehicle == null) return const FitResult('unchecked');
  final today = DateTime.now().toIso8601String().substring(0, 10);
  final fits = ((product['fitments'] as List?) ?? const [])
      .cast<Map>()
      .where((fit) =>
          (fit['effectiveFrom'] == null || '${fit['effectiveFrom']}'.compareTo(today) <= 0) &&
          (fit['effectiveTo'] == null || '${fit['effectiveTo']}'.compareTo(today) >= 0))
      .toList();
  if (fits.isEmpty) return const FitResult('unverified');
  final year = int.tryParse('${vehicle['year']}') ?? 0;
  final needed = <String>{};
  for (final fit in fits) {
    if (normalize(fit['make']) != normalize(vehicle['make']) ||
        normalize(fit['model']) != normalize(vehicle['model']) ||
        year < (fit['yearFrom'] ?? 0) ||
        year > (fit['yearTo'] ?? 9999)) {
      continue;
    }
    var valid = true;
    final missing = <String>{};
    for (final q in const ['engine', 'fuel', 'trim', 'drivetrain', 'market']) {
      final want = fit[q];
      if (want == null || '$want'.isEmpty) continue;
      final have = vehicle[q];
      if (have == null || '$have'.isEmpty) {
        missing.add(q);
        needed.add(q);
      } else if (normalize(want) != normalize(have)) {
        valid = false;
      }
    }
    final excluded = (fit['exclusions'] as List? ?? const []).whereType<Map>().any((rule) =>
        rule.entries.every((entry) => normalize(vehicle[entry.key]) == normalize(entry.value)));
    if (valid && missing.isEmpty && !excluded) return const FitResult('compatible');
  }
  return FitResult(needed.isEmpty ? 'incompatible' : 'unverified', needed.toList());
}

int _ratio(int value, int numerator, int denominator) {
  final result = (BigInt.from(value) * BigInt.from(numerator) + BigInt.from(denominator ~/ 2)) ~/
      BigInt.from(denominator);
  return result.toInt();
}

class QuoteLine {
  QuoteLine(this.input, this.product, this.unitPrice);
  final Json input;
  final Json product;
  final int unitPrice;
  int qty = 0, subtotal = 0, discount = 0, tax = 0, core = 0, total = 0;
}

class Quote {
  Quote(this.lines, this.subtotal, this.discount, this.tax, this.core, this.rounding, this.total,
      this.taxMode);
  final List<QuoteLine> lines;
  final int subtotal, discount, tax, core, rounding, total;
  final String taxMode;
}

class BillingError implements Exception {
  BillingError(this.message);
  final String message;
  @override
  String toString() => message;
}

Quote quote(Json cart, List<Json> products, {int roundingIncrement = 1, String taxMode = 'exclusive'}) {
  int amount(int value, String label, [int max = 100000000000]) {
    if (value < 0 || value > max) throw BillingError('$label exceeds the supported amount.');
    return value;
  }

  if (roundingIncrement < 1 || roundingIncrement > 10000) {
    throw BillingError('Invalid rounding increment. Refresh the register settings.');
  }
  final wholesale = cart['priceLevel'] == 'wholesale';
  final lines = <QuoteLine>[];
  for (final raw in (cart['lines'] as List? ?? const [])) {
    final line = Map<String, dynamic>.from(raw as Map);
    final product = products.firstWhere((p) => p['id'] == line['productId'],
        orElse: () => throw BillingError('A selected part is no longer in this branch catalog.'));
    if (product['salesStopped'] == true) throw BillingError('Sales are stopped for ${product['sku']}. Remove it before checkout.');
    final qty = line['qty'] as int? ?? 0;
    if (qty < 1 || qty > 9999) throw BillingError('Quantity must be a whole number between 1 and 9999.');
    amount((product['taxRate'] ?? 0) as int, 'Tax rate', 10000);
    final price = ((wholesale ? product['wholesalePrice'] : product['retailPrice']) ?? 0) as int;
    amount(price, 'Unit price');
    lines.add(QuoteLine(line, product, price)..qty = qty);
  }
  var subtotal = 0;
  for (final line in lines) {
    subtotal = amount(subtotal + amount(line.qty * line.unitPrice, 'Line amount'), 'Invoice subtotal');
  }
  final discount = min(max(0, (cart['discount'] ?? 0) as int), subtotal);
  var allocation = 0, running = 0;
  for (final line in lines) {
    final value = line.qty * line.unitPrice;
    running += value;
    final cumulative = subtotal == 0 ? 0 : _ratio(discount, running, subtotal);
    final allocated = cumulative - allocation;
    allocation = cumulative;
    final gross = value - allocated;
    final rate = (line.product['taxRate'] ?? 0) as int;
    line
      ..subtotal = value
      ..discount = allocated
      ..tax = taxMode == 'inclusive' ? gross - _ratio(gross, 10000, 10000 + rate) : _ratio(gross, rate, 10000)
      ..core = ((line.product['coreCharge'] ?? 0) as int) * line.qty;
    line.total = gross + (taxMode == 'inclusive' ? 0 : line.tax) + line.core;
  }
  final unrounded = lines.fold<int>(0, (sum, line) => sum + line.total);
  final total = _ratio(unrounded, 1, roundingIncrement) * roundingIncrement;
  amount(total, 'Invoice total');
  if (total < lines.fold<int>(0, (sum, line) => sum + line.core)) {
    throw BillingError('Invoice rounding would reduce the refundable core deposit. Use a smaller rounding increment.');
  }
  return Quote(
    lines,
    subtotal,
    discount,
    lines.fold(0, (sum, line) => sum + line.tax),
    lines.fold(0, (sum, line) => sum + line.core),
    total - unrounded,
    total,
    taxMode,
  );
}

/// True when the final digit is a valid GS1 (EAN/UPC) check digit.
bool gs1Valid(String code) {
  if (!RegExp(r'^\d+$').hasMatch(code)) return false;
  final digits = code.split('').map(int.parse).toList();
  final check = digits.removeLast();
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    sum += digits[digits.length - 1 - i] * (i.isEven ? 3 : 1);
  }
  return (10 - sum % 10) % 10 == check;
}

String? canonicalGtin(String code) =>
    const {8, 12, 13, 14}.contains(code.length) && gs1Valid(code) ? code.padLeft(14, '0') : null;

String barcodeKey(Object? value) {
  final code = '${value ?? ''}'.trim();
  return canonicalGtin(code) ?? code;
}

/// Extract just AI 01 from a recognized GS1 scan, preserving ordinary codes.
String scannedProductCode(String value) {
  final code = value.trim();
  final element = RegExp(r'^(?:\(01\)|\](?:d2|Q3|C1)01|\x1d01)(\d{14})').firstMatch(code)?.group(1);
  final uri = Uri.tryParse(code);
  final path = uri?.scheme == 'https' || uri?.scheme == 'http' ? uri!.pathSegments : const <String>[];
  final digitalLink = path.length >= 2 && path[0] == '01' ? path[1] : null;
  final gtin = element ?? digitalLink;
  if (gtin != null && gtin.length == 14 && gs1Valid(gtin)) return gtin;
  return code;
}

String barcodeFormat(String code) {
  if (code.length == 13 && gs1Valid(code)) return 'EAN13';
  if (code.length == 12 && gs1Valid(code)) return 'UPC';
  if (code.length == 8 && gs1Valid(code)) return 'EAN8';
  return 'CODE128';
}

/// Private Code 128 identifier with a distinct Cartunez prefix.
String inStoreBarcode(Set<String> taken) {
  final random = Random.secure();
  while (true) {
    final code = 'CTZ-${List.generate(12, (_) => random.nextInt(10)).join()}';
    if (!taken.contains(code)) return code;
  }
}
