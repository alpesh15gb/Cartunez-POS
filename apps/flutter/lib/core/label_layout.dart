// Shop label design: which lines appear on a barcode label and how big they
// are. planLabel() places everything in millimetres once; the Zebra (ZPL),
// PDF and on-screen preview renderers all draw from that same plan.
import 'billing.dart';

/// How a shop's labels look. Saved in the shop settings so every counter
/// prints the same label.
class LabelLayout {
  const LabelLayout({
    this.widthMm = 50,
    this.heightMm = 25,
    this.columns = 1,
    this.gapMm = 2,
    this.shopName = false,
    this.name = true,
    this.brand = false,
    this.partNumber = false,
    this.sku = true,
    this.bin = false,
    this.digits = true,
    this.price = 'price',
    this.nameSize = 'medium',
    this.priceSize = 'medium',
    this.extra = '',
  });

  final double widthMm, heightMm;

  /// Labels side by side on the roll (1-3) and the gap between them.
  final int columns;
  final double gapMm;
  final bool shopName, name, brand, partNumber, sku, bin, digits;

  /// 'price' (catalog price), 'mrp' (price including tax), 'both' or 'none'.
  final String price;

  /// 'small', 'medium' or 'large'.
  final String nameSize, priceSize;

  /// Free text printed along the bottom, e.g. a phone number.
  final String extra;

  double get rollWidthMm => columns * widthMm + (columns - 1) * gapMm;

  static const sizes = ['small', 'medium', 'large'];
  static const prices = ['price', 'mrp', 'both', 'none'];

  Map<String, dynamic> toJson() => {
        'widthMm': widthMm,
        'heightMm': heightMm,
        'columns': columns,
        'gapMm': gapMm,
        'shopName': shopName,
        'name': name,
        'brand': brand,
        'partNumber': partNumber,
        'sku': sku,
        'bin': bin,
        'digits': digits,
        'price': price,
        'nameSize': nameSize,
        'priceSize': priceSize,
        'extra': extra,
      };

  static LabelLayout fromJson(Map? j, {String? fallbackSize}) {
    double num0(Object? v, double d) => (v is num) ? v.toDouble() : d;
    bool flag(Object? v, bool d) => v is bool ? v : d;
    String pick(Object? v, List<String> allowed, String d) => allowed.contains(v) ? v as String : d;
    final size = (fallbackSize ?? '50x25').split('x');
    return LabelLayout(
      widthMm: num0(j?['widthMm'], double.tryParse(size.first) ?? 50).clamp(20, 110),
      heightMm: num0(j?['heightMm'], double.tryParse(size.last) ?? 25).clamp(10, 150),
      columns: ((j?['columns'] as num?)?.toInt() ?? 1).clamp(1, 3),
      gapMm: num0(j?['gapMm'], 2).clamp(0, 10),
      shopName: flag(j?['shopName'], false),
      name: flag(j?['name'], true),
      brand: flag(j?['brand'], false),
      partNumber: flag(j?['partNumber'], false),
      sku: flag(j?['sku'], true),
      bin: flag(j?['bin'], false),
      digits: flag(j?['digits'], true),
      price: pick(j?['price'], prices, 'price'),
      nameSize: pick(j?['nameSize'], sizes, 'medium'),
      priceSize: pick(j?['priceSize'], sizes, 'medium'),
      extra: '${j?['extra'] ?? ''}'.trim(),
    );
  }

  LabelLayout copyWith({
    double? widthMm,
    double? heightMm,
    int? columns,
    double? gapMm,
    bool? shopName,
    bool? name,
    bool? brand,
    bool? partNumber,
    bool? sku,
    bool? bin,
    bool? digits,
    String? price,
    String? nameSize,
    String? priceSize,
    String? extra,
  }) =>
      LabelLayout(
        widthMm: widthMm ?? this.widthMm,
        heightMm: heightMm ?? this.heightMm,
        columns: columns ?? this.columns,
        gapMm: gapMm ?? this.gapMm,
        shopName: shopName ?? this.shopName,
        name: name ?? this.name,
        brand: brand ?? this.brand,
        partNumber: partNumber ?? this.partNumber,
        sku: sku ?? this.sku,
        bin: bin ?? this.bin,
        digits: digits ?? this.digits,
        price: price ?? this.price,
        nameSize: nameSize ?? this.nameSize,
        priceSize: priceSize ?? this.priceSize,
        extra: extra ?? this.extra,
      );
}

/// The facts about one part (or bin) that a label may show. Prices arrive
/// already formatted for the target ("Rs. 649.00" for Zebra, "₹649.00" for PDF).
class LabelData {
  const LabelData({
    required this.name,
    required this.code,
    this.shop = '',
    this.sku = '',
    this.brand = '',
    this.partNumber = '',
    this.bin = '',
    this.price,
    this.mrp,
  });
  final String name, code, shop, sku, brand, partNumber, bin;
  final String? price, mrp;
}

enum LabelAlign { left, center, right }

/// One thing to draw, positioned in millimetres from the label's top-left.
class LabelElement {
  const LabelElement.text(this.text, this.x, this.y, this.width, this.height,
      {this.bold = false, this.align = LabelAlign.left})
      : barcode = false,
        format = '',
        module = 0,
        barHeight = 0,
        digits = false;

  const LabelElement.barcode(this.text, this.x, this.y, this.width, this.height,
      {required this.format, required this.module, required this.barHeight, required this.digits})
      : barcode = true,
        bold = false,
        align = LabelAlign.center;

  final bool barcode;
  final String text;
  final double x, y, width, height;
  final bool bold;
  final LabelAlign align;

  // Barcode only: symbology, narrow-bar width in printer dots, bar height (mm),
  // and whether the digits are printed under the bars.
  final String format;
  final int module;
  final double barHeight;
  final bool digits;
}

class LabelPlan {
  const LabelPlan(this.elements, {this.warning});
  final List<LabelElement> elements;

  /// Set when the design leaves too little room for a scannable barcode.
  final String? warning;
}

const _margin = 1.2, _rowGap = 0.4, _smallText = 2.0;
const _nameText = {'small': 2.0, 'medium': 2.6, 'large': 3.3};
const _priceText = {'small': 2.4, 'medium': 3.0, 'large': 3.8};

/// Bars plus quiet zones, in modules.
int barcodeModules(String format, String code) => switch (format) {
      'EAN13' || 'UPC' => 95 + 18,
      'EAN8' => 67 + 14,
      _ => 11 * (_code128Symbols(code) + 2) + 13 + 20,
    };

int _code128Symbols(String code) =>
    RegExp(r'^\d+$').hasMatch(code) && code.length >= 4 ? (code.length + 1) ~/ 2 + 1 : code.length;

/// Shortens text that would not fit [width] mm at [height] mm (about 0.55 em per character).
String fitText(String text, double width, double height) {
  final max = (width / (height * 0.55)).floor();
  return text.length <= max ? text : '${text.substring(0, (max - 1).clamp(1, text.length))}…';
}

/// Places every enabled line and the barcode on one label of [layout] for a
/// printer of [dpi] dots per inch.
LabelPlan planLabel(LabelLayout layout, LabelData data, {int dpi = 203}) {
  final w = layout.widthMm, h = layout.heightMm;
  final inner = w - 2 * _margin;
  final out = <LabelElement>[];
  var top = _margin;
  var bottom = h - _margin;

  void line(String text, double size, {bool bold = false, LabelAlign align = LabelAlign.left}) {
    if (text.trim().isEmpty) return;
    out.add(LabelElement.text(fitText(text.trim(), inner, size), _margin, top, inner, size, bold: bold, align: align));
    top += size + _rowGap;
  }

  // Top: shop, part name, brand / part number.
  if (layout.shopName) line(data.shop, _smallText, bold: true, align: LabelAlign.center);
  if (layout.name) line(data.name, _nameText[layout.nameSize]!, bold: true);
  final detail = [
    if (layout.brand) data.brand,
    if (layout.partNumber && data.partNumber.isNotEmpty) 'PN ${data.partNumber}',
  ].where((s) => s.trim().isNotEmpty).join(' · ');
  line(detail, _smallText);

  // Bottom, working upwards: extra text, then SKU/bin with the price, then the MRP note.
  if (layout.extra.isNotEmpty) {
    bottom -= _smallText;
    out.add(LabelElement.text(fitText(layout.extra, inner, _smallText), _margin, bottom, inner, _smallText, align: LabelAlign.center));
    bottom -= _rowGap;
  }
  final big = _priceText[layout.priceSize]!;
  final priceText = switch (layout.price) {
    'price' || 'both' => data.price,
    'mrp' => data.mrp == null ? null : 'MRP ${data.mrp}',
    _ => null,
  };
  final left = [if (layout.sku) data.sku, if (layout.bin) data.bin].where((s) => s.trim().isNotEmpty).join(' · ');
  if ((priceText ?? '').isNotEmpty || left.isNotEmpty) {
    final rowHeight = (priceText ?? '').isNotEmpty ? big : _smallText;
    bottom -= rowHeight;
    if ((priceText ?? '').isNotEmpty) {
      out.add(LabelElement.text(priceText!, _margin, bottom, inner, big, bold: true, align: LabelAlign.right));
    }
    if (left.isNotEmpty) {
      final priceWidth = (priceText ?? '').isEmpty ? 0.0 : priceText!.length * big * 0.55 + 1;
      final width = (inner - priceWidth).clamp(inner * 0.3, inner);
      out.add(LabelElement.text(fitText(left, width, _smallText), _margin, bottom + rowHeight - _smallText, width, _smallText));
    }
    bottom -= _rowGap;
  }
  final note = switch (layout.price) {
    'mrp' when data.mrp != null => 'Incl. of all taxes',
    'both' when data.mrp != null => 'MRP ${data.mrp} incl. of all taxes',
    _ => '',
  };
  if (note.isNotEmpty) {
    bottom -= _smallText;
    out.add(LabelElement.text(fitText(note, inner, _smallText), _margin, bottom, inner, _smallText, align: LabelAlign.right));
    bottom -= _rowGap;
  }

  // Middle: the barcode, as wide and tall as the remaining space allows.
  String? warning;
  if (data.code.isNotEmpty) {
    final format = barcodeFormat(data.code);
    final modules = barcodeModules(format, data.code);
    final dotsPerMm = dpi / 25.4;
    final innerDots = (inner * dotsPerMm).floor();
    final module = (innerDots ~/ modules).clamp(1, 4);
    final width = module * modules / dotsPerMm;
    // The printer scales the digits with the bar width; EAN/UPC digits are larger.
    final digitsHeight = !layout.digits ? 0.0 : (format == 'CODE128' ? module * 9 : module * 11) / dotsPerMm + 0.3;
    final space = bottom - top - 0.2;
    var bars = space - digitsHeight;
    if (innerDots < modules) {
      warning = 'This barcode is too long for a ${_mm(w)} mm label. Use a wider label or a shorter code.';
    } else if (bars < 4) {
      warning = 'Too much on this label: the barcode is only ${_mm(bars.clamp(0, 99))} mm tall and may not scan. '
          'Turn off a line, use smaller text or a taller label.';
    }
    bars = bars.clamp(2.5, 200);
    out.add(LabelElement.barcode(data.code, _margin + ((inner - width) / 2).clamp(0, inner), top, width.clamp(0, inner), bars + digitsHeight,
        format: format, module: module, barHeight: bars, digits: layout.digits));
  }
  return LabelPlan(out, warning: warning);
}

String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
