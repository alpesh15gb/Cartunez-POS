import 'package:cartunez_pos/core/billing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final products = <Json>[
    {'id': 'part', 'retailPrice': 10000, 'wholesalePrice': 9000, 'taxRate': 1800, 'coreCharge': 0},
    {'id': 'battery', 'retailPrice': 549900, 'wholesalePrice': 494900, 'taxRate': 1800, 'coreCharge': 50000},
  ];

  test('tax is added on top of exclusive prices', () {
    final bill = quote({'lines': [{'productId': 'part', 'qty': 2}], 'priceLevel': 'retail', 'discount': 0}, products);
    expect(bill.subtotal, 20000);
    expect(bill.tax, 3600);
    expect(bill.total, 23600);
  });

  test('inclusive prices carve tax out of the price', () {
    final bill = quote({'lines': [{'productId': 'part', 'qty': 1}], 'discount': 0}, products, taxMode: 'inclusive');
    expect(bill.total, 10000);
    expect(bill.tax, 1525);
  });

  test('discount is spread across lines and core deposits are untaxed', () {
    final bill = quote({
      'lines': [{'productId': 'part', 'qty': 1}, {'productId': 'battery', 'qty': 1}],
      'discount': 1000,
    }, products);
    expect(bill.discount, 1000);
    expect(bill.lines.fold<int>(0, (n, l) => n + l.discount), 1000);
    expect(bill.core, 50000);
    expect(bill.total, 559900 - 1000 + bill.tax + 50000);
  });

  test('rounding to the nearest rupee', () {
    final bill = quote({'lines': [{'productId': 'part', 'qty': 1}], 'discount': 7}, products, roundingIncrement: 100);
    expect(bill.total % 100, 0);
    expect(bill.rounding.abs(), lessThan(100));
  });

  test('no vehicle means no fitment check', () {
    expect(fitment({'universal': false, 'fitments': []}, null).status, 'unchecked');
    expect(fitment({'universal': false, 'fitments': []}, null).needsOverride, isFalse);
    expect(fitment({'universal': false, 'fitments': []}, {'make': 'A', 'model': 'B', 'year': 2020}).needsOverride, isTrue);
  });

  test('barcodes', () {
    expect(gs1Valid('4006381333931'), isTrue);
    expect(gs1Valid('4006381333932'), isFalse);
    expect(barcodeFormat('036000291452'), 'UPC');
    expect(barcodeFormat('ML-OIL-01'), 'CODE128');
    expect(barcodeKey('036000291452'), barcodeKey('0036000291452'));
    expect(barcodeKey('036000291453'), '036000291453');
    expect(barcodeKey('ML-OIL-01'), isNot(barcodeKey('MLOIL01')));
    expect(scannedProductCode(']d2010003600029145210LOT-A'), '00036000291452');
    expect(scannedProductCode('https://id.example/01/00036000291452/10/LOT-A'), '00036000291452');
    expect(scannedProductCode('https://example.com/ordinary-qr'), 'https://example.com/ordinary-qr');
    final taken = <String>{};
    for (var i = 0; i < 300; i++) {
      final code = inStoreBarcode(taken);
      expect(code, matches(RegExp(r'^CTZ-\d{12}$')));
      expect(barcodeFormat(code), 'CODE128');
      expect(taken.add(code), isTrue);
    }
  });
}
