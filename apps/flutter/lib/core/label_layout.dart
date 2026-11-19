// Shop label design: which lines appear on a barcode label, how big they are
// and where they sit. planLabel() places everything in millimetres once; the
// Zebra (ZPL), PDF and on-screen preview renderers all draw from that plan.
import 'billing.dart';

/// The parts of a label that can be sized and moved.
const labelParts = ['shop', 'name', 'detail', 'barcode', 'info', 'price', 'note', 'extra'];

/// What each part is called in the designer.
const labelPartNames = {
  'shop': 'Shop name',
  'name': 'Part name',
  'detail': 'Brand / part number',
  'barcode': 'Barcode',
  'info': 'SKU / bin',
  'price': 'Price',
  'note': 'MRP note',
  'extra': 'Extra line',
};

const labelSizes4 = ['small', 'medium', 'large', 'xlarge'];

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
    this.sizes = const {},
    this.positions = const {},
    this.extra = '',
  });

  final double widthMm, heightMm;

  /// Labels side by side on the roll (1-3) and the gap between them.
  final int columns;
  final double gapMm;
  final bool shopName, name, brand, partNumber, sku, bin, digits;

  /// 'price' (catalog price), 'mrp' (price including tax), 'both' or 'none'.
  final String price;

  /// Text size per part ('small', 'medium', 'large', 'xlarge'); missing parts use [defaultSize].
  final Map<String, String> sizes;

  /// Parts the owner dragged somewhere else: top-left corner in mm.
  final Map<String, ({double x, double y})> positions;

  /// Free text printed along the bottom, e.g. a phone number.
  final String extra;

  double get rollWidthMm => columns * widthMm + (columns - 1) * gapMm;

  static String defaultSize(String part) => part == 'name' || part == 'price' ? 'medium' : 'small';
  String sizeOf(String part) => sizes[part] ?? defaultSize(part);

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
        'sizes': {for (final e in sizes.entries) e.key: e.value},
        'positions': {for (final e in positions.entries) e.key: {'x': _round(e.value.x), 'y': _round(e.value.y)}},
        'extra': extra,
      };

  static LabelLayout fromJson(Map? j, {String? fallbackSize}) {
    double num0(Object? v, double d) => (v is num) ? v.toDouble() : d;
    bool flag(Object? v, bool d) => v is bool ? v : d;
    final size = (fallbackSize ?? '50x25').split('x');
    final sizes = <String, String>{};
    // Designs saved before per-line sizes kept only the name and price sizes.
    for (final (old, part) in [('nameSize', 'name'), ('priceSize', 'price')]) {
      if (labelSizes4.contains(j?[old])) sizes[part] = j![old] as String;
    }
    final savedSizes = j?['sizes'];
    if (savedSizes is Map) {
      for (final e in savedSizes.entries) {
        if (labelParts.contains(e.key) && labelSizes4.contains(e.value)) sizes[e.key as String] = e.value as String;
      }
    }
    final positions = <String, ({double x, double y})>{};
    final savedPositions = j?['positions'];
    if (savedPositions is Map) {
      for (final e in savedPositions.entries) {
        final v = e.value;
        if (labelParts.contains(e.key) && v is Map && v['x'] is num && v['y'] is num) {
          positions[e.key as String] = (x: (v['x'] as num).toDouble().clamp(0, 110), y: (v['y'] as num).toDouble().clamp(0, 150));
        }
      }
    }
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
      price: prices.contains(j?['price']) ? j!['price'] as String : 'price',
      sizes: sizes,
      positions: positions,
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
    Map<String, String>? sizes,
    Map<String, ({double x, double y})>? positions,
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
        sizes: sizes ?? this.sizes,
        positions: positions ?? this.positions,
        extra: extra ?? this.extra,
      );

  /// A copy with one part's size changed.
  LabelLayout withSize(String part, String size) => copyWith(sizes: {...sizes, part: size});

  /// A copy with one part moved (or put back in its automatic place when [at] is null).
  LabelLayout withPosition(String part, ({double x, double y})? at) {
    final next = {...positions};
    at == null ? next.remove(part) : next[part] = at;
    return copyWith(positions: next);
  }
}

double _round(double v) => (v * 10).round() / 10;

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
  const LabelElement.text(this.part, this.text, this.x, this.y, this.width, this.height,
      {this.bold = false, this.align = LabelAlign.left})
      : barcode = false,
        format = '',
        module = 0,
        barHeight = 0,
        digits = false;

  const LabelElement.barcode(this.text, this.x, this.y, this.width, this.height,
      {required this.format, required this.module, required this.barHeight, required this.digits})
      : part = 'barcode',
        barcode = true,
        bold = false,
        align = LabelAlign.center;

  /// Which part of the label this is (see [labelParts]).
  final String part;
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

  LabelElement moved(double nx, double ny, double nwidth) => barcode
      ? LabelElement.barcode(text, nx, ny, width, height, format: format, module: module, barHeight: barHeight, digits: digits)
      : LabelElement.text(part, text, nx, ny, nwidth, height, bold: bold, align: LabelAlign.left);
}

class LabelPlan {
  const LabelPlan(this.elements, {this.warning});
  final List<LabelElement> elements;

  /// Set when the design leaves too little room for a scannable barcode, or lines overlap.
  final String? warning;
}

const _margin = 1.2, _rowGap = 0.4;
const _textMm = {'small': 2.0, 'medium': 2.6, 'large': 3.4, 'xlarge': 4.4};
const _priceMm = {'small': 2.4, 'medium': 3.0, 'large': 3.8, 'xlarge': 4.8};

/// Text height in mm for [part] at its chosen size.
double textHeight(LabelLayout layout, String part) => (part == 'price' ? _priceMm : _textMm)[layout.sizeOf(part)]!;

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

/// Estimated printed width of [text] at [height] mm.
double textWidth(String text, double height) => text.length * height * 0.55 + 0.4;

/// Places every enabled line and the barcode on one label of [layout] for a
/// printer of [dpi] dots per inch. Parts the owner moved keep their position.
LabelPlan planLabel(LabelLayout layout, LabelData data, {int dpi = 203}) {
  final w = layout.widthMm, h = layout.heightMm;
  final inner = w - 2 * _margin;
  final out = <LabelElement>[];
  final moved = layout.positions;
  var top = _margin;
  var bottom = h - _margin;

  // Moved parts are placed later and do not take space in the automatic flow.
  void line(String part, String text, {bool bold = false, LabelAlign align = LabelAlign.left}) {
    if (text.trim().isEmpty) return;
    final size = textHeight(layout, part);
    out.add(LabelElement.text(part, fitText(text.trim(), inner, size), _margin, top, inner, size, bold: bold, align: align));
    if (!moved.containsKey(part)) top += size + _rowGap;
  }

  // Top: shop, part name, brand / part number.
  if (layout.shopName) line('shop', data.shop, bold: true, align: LabelAlign.center);
  if (layout.name) line('name', data.name, bold: true);
  final detail = [
    if (layout.brand) data.brand,
    if (layout.partNumber && data.partNumber.isNotEmpty) 'PN ${data.partNumber}',
  ].where((s) => s.trim().isNotEmpty).join(' · ');
  line('detail', detail);

  // Bottom, working upwards: extra text, then SKU/bin with the price, then the MRP note.
  if (layout.extra.isNotEmpty) {
    final size = textHeight(layout, 'extra');
    final y = bottom - size;
    out.add(LabelElement.text('extra', fitText(layout.extra, inner, size), _margin, y, inner, size, align: LabelAlign.center));
    if (!moved.containsKey('extra')) bottom = y - _rowGap;
  }
  final big = textHeight(layout, 'price');
  final small = textHeight(layout, 'info');
  final priceText = switch (layout.price) {
    'price' || 'both' => data.price,
    'mrp' => data.mrp == null ? null : 'MRP ${data.mrp}',
    _ => null,
  };
  final hasPrice = (priceText ?? '').isNotEmpty;
  final left = [if (layout.sku) data.sku, if (layout.bin) data.bin].where((s) => s.trim().isNotEmpty).join(' · ');
  if (hasPrice || left.isNotEmpty) {
    final priceFlows = hasPrice && !moved.containsKey('price');
    final infoFlows = left.isNotEmpty && !moved.containsKey('info');
    final rowHeight = priceFlows ? (big > small ? big : small) : small;
    final y = bottom - rowHeight;
    if (hasPrice) {
      out.add(LabelElement.text('price', priceText!, _margin, priceFlows ? y : bottom - big, inner, big, bold: true, align: LabelAlign.right));
    }
    if (left.isNotEmpty) {
      final priceWidth = priceFlows ? textWidth(priceText!, big) + 0.6 : 0.0;
      final width = (inner - priceWidth).clamp(inner * 0.3, inner);
      out.add(LabelElement.text('info', fitText(left, width, small), _margin, y + rowHeight - small, width, small));
    }
    if (priceFlows || infoFlows) bottom = y - _rowGap;
  }
  final note = switch (layout.price) {
    'mrp' when data.mrp != null => 'Incl. of all taxes',
    'both' when data.mrp != null => 'MRP ${data.mrp} incl. of all taxes',
    _ => '',
  };
  if (note.isNotEmpty) {
    final size = textHeight(layout, 'note');
    final y = bottom - size;
    out.add(LabelElement.text('note', fitText(note, inner, size), _margin, y, inner, size, align: LabelAlign.right));
    if (!moved.containsKey('note')) bottom = y - _rowGap;
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
    // A moved barcode keeps the height it would have had in the automatic layout.
    var bars = bottom - top - 0.2 - digitsHeight;
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

  // Parts the owner dragged: put them where they were dropped, kept inside the label.
  final placed = [
    for (final e in out)
      if (moved[e.part] case final at?)
        () {
          final width = e.barcode ? e.width : textWidth(e.text, e.height).clamp(1.0, w - 2 * _margin);
          final x = at.x.clamp(0.0, (w - width).clamp(0.0, w));
          final y = at.y.clamp(0.0, (h - e.height).clamp(0.0, h));
          return e.moved(x, y, width);
        }()
      else
        e,
  ];
  if (warning == null && moved.isNotEmpty && _overlaps(placed)) {
    warning = 'Some lines overlap on the label. Drag them apart or use smaller text.';
  }
  return LabelPlan(placed, warning: warning);
}

/// The area a part actually covers, in mm (text is measured by its characters,
/// not its full-width box).
({double l, double t, double r, double b}) labelBox(LabelElement e) {
  if (e.barcode) return (l: e.x, t: e.y, r: e.x + e.width, b: e.y + e.height);
  final tw = textWidth(e.text, e.height).clamp(0.0, e.width);
  final l = switch (e.align) { LabelAlign.left => e.x, LabelAlign.center => e.x + (e.width - tw) / 2, LabelAlign.right => e.x + e.width - tw };
  return (l: l, t: e.y, r: l + tw, b: e.y + e.height);
}

/// Whether any two parts cover the same area.
bool _overlaps(List<LabelElement> elements) {
  final boxes = elements.map(labelBox).toList();
  for (var i = 0; i < boxes.length; i++) {
    for (var j = i + 1; j < boxes.length; j++) {
      final a = boxes[i], b = boxes[j];
      if (a.l < b.r - 0.3 && b.l < a.r - 0.3 && a.t < b.b - 0.3 && b.t < a.b - 0.3) return true;
    }
  }
  return false;
}

String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
