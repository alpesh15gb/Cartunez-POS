import 'package:cartunez_pos/ui/screens/reports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export labels money and tax units and preserves signed credits', () {
    final csv = reportCsv([
      {'day': '2026-11-20', 'sales': 1, 'gross': 50000, 'taxRate': 1800, 'net': -125, 'sku': '=part'},
    ], currency: 'INR');
    final lines = csv.split('\r\n');
    expect(lines.first, '"day","sales","gross (INR)","taxRate (%)","net (INR)","sku"');
    expect(lines.last, '''"2026-11-20","1","500.00","18.00","-1.25","'=part"''');
  });
}
