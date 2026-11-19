import 'package:cartunez_pos/core/label_layout.dart';
import 'package:cartunez_pos/core/zpl.dart';
import 'package:flutter_test/flutter_test.dart';

const part = LabelData(
  name: 'Engine Air Filter',
  code: '4006381333931',
  shop: 'Cartunez Auto',
  sku: 'ML-AIR-01',
  brand: 'Bosch',
  partNumber: 'F026400',
  bin: 'A / 1 / 01',
  price: 'Rs. 649.00',
  mrp: 'Rs. 765.82',
);

void main() {
  const layout = LabelLayout();

  test('label size is set in printer dots', () {
    final zpl = zplJob(const [part], layout);
    expect(zpl, startsWith('^XA'));
    expect(zpl, endsWith('^XZ'));
    expect(zpl, contains('^PW400^LL200'));
    expect(zplJob(const [part], layout, dpi: 300), contains('^PW591^LL295'));
  });

  test('EAN-13 sends 12 digits and lets the printer add the check digit', () {
    final zpl = zplJob(const [part], layout);
    expect(zpl, contains('^BEN,'));
    expect(zpl, contains('^FD400638133393^FS'));
  });

  test('UPC-A, EAN-8 and Code 128 use their own symbologies', () {
    expect(zplJob(const [LabelData(name: 'P', code: '036000291452')], layout), contains('^FD03600029145^FS'));
    expect(zplJob(const [LabelData(name: 'P', code: '96385074')], layout), contains('^B8N,'));
    final code128 = zplJob(const [LabelData(name: 'Oil', code: 'ML-OIL-01')], layout);
    expect(code128, contains(',N,N,A'));
    expect(code128, contains('^FDML-OIL-01^FS'));
  });

  test('digits under the bars can be switched off', () {
    expect(zplJob(const [part], layout), contains('^BEN,93,Y,N'.substring(0, 5)));
    expect(zplJob(const [part], layout.copyWith(digits: false)), matches(RegExp(r'\^BEN,\d+,N,N')));
  });

  test('only the chosen lines are printed', () {
    final plain = zplJob(const [part], layout);
    expect(plain, contains('Engine Air Filter'));
    expect(plain, contains('ML-AIR-01'));
    expect(plain, contains('Rs. 649.00'));
    expect(plain, isNot(contains('Bosch')));
    expect(plain, isNot(contains('Cartunez Auto')));

    final full = zplJob(const [part], layout.copyWith(shopName: true, brand: true, partNumber: true, bin: true, extra: 'Ph 98765'));
    for (final text in ['Cartunez Auto', 'Bosch · PN F026400', 'A / 1 / 01', 'Ph 98765']) {
      expect(full, contains(text));
    }
  });

  test('price options: price, MRP, both or none', () {
    expect(zplJob(const [part], layout.copyWith(price: 'mrp')), allOf(contains('MRP Rs. 765.82'), contains('Incl. of all taxes')));
    final both = zplJob(const [part], layout.copyWith(price: 'both'));
    expect(both, allOf(contains('Rs. 649.00'), contains('MRP Rs. 765.82 incl. of all taxes')));
    expect(zplJob(const [part], layout.copyWith(price: 'none')), isNot(contains('Rs.')));
  });

  test('two labels across the roll share one format per row', () {
    const twoUp = LabelLayout(widthMm: 38, heightMm: 25, columns: 2, gapMm: 2);
    final job = zplJob(const [part, LabelData(name: 'Oil', code: 'ML-OIL-01')], twoUp, copies: 3);
    // 2 parts × 3 copies = 6 labels = 3 rows.
    expect('^XA'.allMatches(job).length, 3);
    expect(job, contains('^PW623')); // (38 + 2 + 38) mm at 203 dpi
    final firstRow = job.split('\n').first;
    expect('Engine Air Filter'.allMatches(firstRow).length, 2);
  });

  test('special characters cannot break the label', () {
    final zpl = zplJob(const [LabelData(name: 'Bolt ^XZ ~JR_1', code: 'ML-1')], layout);
    expect(zpl, contains('Bolt _5EXZ _7EJR_5F1'));
    expect('^XZ'.allMatches(zpl).length, 1);
  });

  test('copies and darkness', () {
    final zpl = zplJob(const [part], layout, copies: 3, darkness: 18);
    expect(zpl, contains('^PQ3,0,1,Y'));
    expect(zpl, contains('~SD18'));
    expect(zplMoney('₹5,499.00'), 'Rs. 5,499.00');
  });

  test('a crowded design warns that the barcode may not scan', () {
    final crowded = layout.copyWith(shopName: true, brand: true, partNumber: true, price: 'both', sizes: {'name': 'large', 'price': 'large'}, extra: 'x');
    expect(planLabel(crowded, part).warning, contains('may not scan'));
    expect(planLabel(layout, part).warning, isNull);
    expect(planLabel(crowded.copyWith(heightMm: 50, widthMm: 75), part).warning, isNull);
  });

  test('layout survives saving and loading, with safe limits', () {
    final custom = layout.copyWith(widthMm: 38, columns: 2, brand: true, price: 'mrp', sizes: {'shop': 'xlarge'}, positions: {'price': (x: 10.0, y: 15.5)}, extra: 'Hi');
    final back = LabelLayout.fromJson(custom.toJson());
    expect(back.toJson(), custom.toJson());
    final wild = LabelLayout.fromJson({'widthMm': 999, 'columns': 9, 'price': 'free', 'nameSize': 'huge'});
    expect(wild.widthMm, 110);
    expect(wild.columns, 3);
    expect(wild.price, 'price');
    expect(wild.sizeOf('name'), 'medium');
  });

  test('designs saved before per-line sizes keep their name and price sizes', () {
    final old = LabelLayout.fromJson({'nameSize': 'large', 'priceSize': 'small'});
    expect(old.sizeOf('name'), 'large');
    expect(old.sizeOf('price'), 'small');
    expect(old.sizeOf('shop'), 'small');
  });

  test('the shop name can be made bigger', () {
    final shop = layout.copyWith(shopName: true);
    double height(LabelLayout l) => planLabel(l, part).elements.firstWhere((e) => e.part == 'shop').height;
    expect(height(shop.withSize('shop', 'xlarge')), greaterThan(height(shop)));
    expect(zplJob(const [part], shop.withSize('shop', 'xlarge')), contains('^A0N,35,35^FB'));
  });

  test('a moved line prints where it was dropped and leaves room for the barcode', () {
    final moved = layout.withPosition('price', (x: 2.0, y: 2.0));
    final plan = planLabel(moved, part);
    final price = plan.elements.firstWhere((e) => e.part == 'price');
    expect((price.x, price.y), (2.0, 2.0));
    expect(price.align, LabelAlign.left);
    expect(zplJob(const [part], moved), contains('^FO16,16^A0N,24,24^FB'));
    // Lines dropped outside the label are pulled back inside.
    final off = planLabel(layout.withPosition('name', (x: 49.0, y: 24.0)), part).elements.firstWhere((e) => e.part == 'name');
    expect(off.x + off.width, lessThanOrEqualTo(50));
    expect(off.y + off.height, lessThanOrEqualTo(25));
    expect(layout.withPosition('price', (x: 2.0, y: 2.0)).withPosition('price', null).positions, isEmpty);
  });

  test('overlapping lines are reported', () {
    final clash = layout.withPosition('price', (x: 1.2, y: 1.2));
    expect(planLabel(clash, part).warning, contains('overlap'));
  });

  test('the barcode can be made thinner, wider, shorter or taller', () {
    LabelElement bar(LabelLayout l, {int dpi = 203}) => planLabel(l, part, dpi: dpi).elements.firstWhere((e) => e.barcode);
    final big = layout.copyWith(widthMm: 75, heightMm: 50);
    expect(bar(big.copyWith(barcodeWidth: 'small')).module, 1);
    expect(bar(big.copyWith(barcodeWidth: 'xlarge')).module, 4);
    expect(bar(big.copyWith(barcodeWidth: 'small')).width, lessThan(bar(big.copyWith(barcodeWidth: 'large')).width));
    // The same printed size on a 300 dpi printer.
    expect(bar(big.copyWith(barcodeWidth: 'medium'), dpi: 300).module, 3);
    expect(bar(big.copyWith(barcodeHeight: 'small')).barHeight, 5);
    expect(bar(big.copyWith(barcodeHeight: 'large')).barHeight, 12);
    expect(zplJob(const [part], big.copyWith(barcodeWidth: 'small', barcodeHeight: 'small')), contains('^BY1,3,40^'));
  });

  test('a barcode too wide or too tall for the label is reported', () {
    final narrow = planLabel(layout.copyWith(barcodeWidth: 'xlarge'), part);
    expect(narrow.warning, contains('reduced'));
    expect(narrow.elements.firstWhere((e) => e.barcode).x + narrow.elements.firstWhere((e) => e.barcode).width, lessThanOrEqualTo(50));
    expect(planLabel(layout.copyWith(barcodeHeight: 'xlarge'), part).warning, contains('overlap'));
    final saved = LabelLayout.fromJson(layout.copyWith(barcodeWidth: 'large', barcodeHeight: 'small').toJson());
    expect((saved.barcodeWidth, saved.barcodeHeight), ('large', 'small'));
  });
}
