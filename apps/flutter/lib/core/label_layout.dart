// Shop label design: which lines appear on a barcode label, how big they are
// and where they sit. planLabel() places everything in millimetres once; the
// Zebra (ZPL), PDF and on-screen preview renderers all draw from that plan.
import 'package:barcode/barcode.dart';
import 'package:characters/characters.dart';

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

/// Barcode width and height choices; 'auto' fits the barcode to the free space.
const barcodeSizes = ['auto', 'small', 'medium', 'large', 'xlarge'];

/// Narrow-bar width in mm for each barcode width (about 1-4 dots on a 203 dpi printer).
const _barMm = {'small': 0.13, 'medium': 0.25, 'large': 0.375, 'xlarge': 0.5};

/// Bar height in mm for each barcode height.
const _barHeightMm = {'small': 5.0, 'medium': 8.0, 'large': 12.0, 'xlarge': 16.0};

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
    this.barcodeWidth = 'auto',
    this.barcodeHeight = 'auto',
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

  /// Barcode bar thickness and bar height (see [barcodeSizes]).
  final String barcodeWidth, barcodeHeight;

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
        'barcodeWidth': barcodeWidth,
        'barcodeHeight': barcodeHeight,
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
      barcodeWidth: barcodeSizes.contains(j?['barcodeWidth']) ? j!['barcodeWidth'] as String : 'auto',
      barcodeHeight: barcodeSizes.contains(j?['barcodeHeight']) ? j!['barcodeHeight'] as String : 'auto',
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
    String? barcodeWidth,
    String? barcodeHeight,
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
        barcodeWidth: barcodeWidth ?? this.barcodeWidth,
        barcodeHeight: barcodeHeight ?? this.barcodeHeight,
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
  const LabelPlan(this.elements, {this.warning, this.printProblem});
  final List<LabelElement> elements;

  /// Set when the design leaves too little room for a scannable barcode, or lines overlap.
  final String? warning;

  /// A barcode that cannot fit or intersects another field must not be sent.
  final String? printProblem;
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
      _ => _code128Modules(code),
    };

int _code128Modules(String code) {
  // Each encoded symbol has six runs across eleven modules. The final stop
  // pattern has seven runs across thirteen. Count the encoder's actual runs
  // because a mixed SKU can switch to paired digits partway through the code.
  try {
    final runs = Barcode.code128().make(code, width: 1, height: 1).whereType<BarcodeBar>().length;
    return ((runs - 7) ~/ 6) * 11 + 13 + 20;
  } on BarcodeException {
    // The designer still needs to lay out and explain an unprintable code.
    return 11 * (code.length + 2) + 13 + 20;
  }
}

// Printable ASCII advances in hundredths of an em. Each is the maximum of the
// bundled Roboto Regular/Medium/Bold and Helvetica Bold advances, rounded up.
// Preview and PDF text is drawn at 95% of the nominal height.
const _asciiAdvance = [
  28, 34, 48, 62, 58, 89, 73, 24, 36, 36, 46, 59, 28, 39, 30, 42,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 34, 34, 59, 59, 59, 62,
  98, 73, 73, 73, 73, 67, 62, 78, 73, 30, 56, 73, 62, 88, 73, 78,
  67, 78, 73, 67, 62, 73, 67, 95, 67, 67, 62, 34, 43, 34, 59, 56,
  34, 56, 62, 56, 62, 56, 36, 62, 62, 28, 28, 56, 28, 89, 62, 62,
  62, 62, 39, 56, 34, 62, 56, 78, 56, 56, 51, 39, 29, 39, 69,
];

double _advance(String grapheme) {
  final code = grapheme.codeUnitAt(0);
  if (grapheme.length == 1 && code >= 32 && code <= 126) return _asciiAdvance[code - 32] / 100;
  return 1.1 * grapheme.runes.length;
}

double textWidth(String text, double height) =>
    0.4 + text.characters.fold(0.0, (width, char) => width + _advance(char) * height);

String _fittingPrefix(String text, double width, double height) {
  final out = StringBuffer();
  var used = 0.4;
  for (final char in text.characters) {
    used += _advance(char) * height;
    if (used > width) break;
    out.write(char);
  }
  return out.toString();
}

String fitText(String text, double width, double height) {
  if (textWidth(text, height) <= width) return text;
  if (textWidth('…', height) > width) return '';
  return '${_fittingPrefix(text, width - _advance('…') * height, height).trimRight()}…';
}

/// Splits [text] into at most [maxLines] lines of [width] mm at [height] mm,
/// breaking between words; the last line ends with "…" if text is left over.
List<String> wrapText(String text, double width, double height, {int maxLines = 2}) {
  if (maxLines < 1) return [];
  var rest = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  final lines = <String>[];
  while (lines.length < maxLines - 1 && rest.isNotEmpty) {
    final prefix = _fittingPrefix(rest, width, height);
    if (prefix.isEmpty || prefix == rest) break;
    final space = prefix.lastIndexOf(' ');
    final cut = space > 0 && !rest.startsWith(' ', prefix.length) ? space : prefix.length;
    lines.add(rest.substring(0, cut).trimRight());
    rest = rest.substring(cut).trimLeft();
  }
  if (rest.isNotEmpty) lines.add(fitText(rest, width, height));
  return lines;
}

/// Places every enabled line and the barcode on one label of [layout] for a
/// printer of [dpi] dots per inch. Parts the owner moved keep their position.
LabelPlan planLabel(LabelLayout layout, LabelData data, {int dpi = 203}) =>
    _planLabel(layout, data, dpi, wrapName: true);

LabelPlan _planLabel(LabelLayout layout, LabelData data, int dpi, {required bool wrapName}) {
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
    // A long part name continues on a second line instead of being cut short
    // (only in the automatic flow; a name the owner moved stays one line).
    if (wrapName && part == 'name' && !moved.containsKey(part) && textWidth(text.trim(), size) > inner) {
      for (final piece in wrapText(text, inner, size)) {
        out.add(LabelElement.text(part, piece, _margin, top, inner, size, bold: bold, align: align));
        top += size + _rowGap;
      }
      return;
    }
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
  String? printProblem;
  if (data.code.isNotEmpty) {
    final format = barcodeFormat(data.code);
    final modules = barcodeModules(format, data.code);
    final dotsPerMm = dpi / 25.4;
    final innerDots = (inner * dotsPerMm).floor();
    final widest = (innerDots ~/ modules).clamp(1, 6);
    final wanted = _barMm[layout.barcodeWidth];
    // Auto: the widest bars that fit (up to 4 dots). A chosen width keeps its
    // printed size on any printer resolution, but never runs off the label.
    final module = wanted == null ? widest.clamp(1, 4) : (wanted * dotsPerMm).round().clamp(1, widest);
    final narrowed = wanted != null && (wanted * dotsPerMm).round() > widest;
    final width = module * modules / dotsPerMm;
    // The printer scales the digits with the bar width; EAN/UPC digits are larger.
    final digitsHeight = !layout.digits ? 0.0 : (format == 'CODE128' ? module * 9 : module * 11) / dotsPerMm + 0.3;
    // Auto height fills the free space (a moved barcode keeps the height it would
    // have had there); a chosen height is fixed.
    final fixed = _barHeightMm[layout.barcodeHeight];
    var bars = fixed ?? bottom - top - 0.2 - digitsHeight;
    if (innerDots < modules) {
      printProblem = 'This barcode is too long for a ${_mm(w)} mm label. Use a wider label or a shorter code.';
    } else if (fixed == null && bars < 4) {
      printProblem = 'Too much on this label: the barcode is only ${_mm(bars.clamp(0, 99))} mm tall and may not scan. '
          'Turn off a line, use smaller text or a taller label.';
    } else if (narrowed) {
      warning = 'The barcode width was reduced so it fits on a ${_mm(w)} mm label.';
    }
    bars = bars.clamp(2.5, 200);
    // A barcode shorter than the free space sits in the middle of it.
    final spare = bottom - top - 0.2 - bars - digitsHeight;
    final barTop = top + (spare > 0 ? spare / 2 : 0);
    out.add(LabelElement.barcode(data.code, _margin + ((inner - width) / 2).clamp(0, inner), barTop, width.clamp(0, inner), bars + digitsHeight,
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
  final bar = placed.where((e) => e.barcode).firstOrNull;
  if (bar != null) {
    if (bar.y + bar.height > h || placed.any((e) => !e.barcode && _intersects(bar, e))) {
      printProblem ??= 'The barcode extends past the label or overlaps text. Move the fields or use a taller label.';
    }
    if (printProblem != null && wrapName && placed.where((e) => e.part == 'name').length > 1) {
      return _planLabel(layout, data, dpi, wrapName: false);
    }
  }
  if (moved.isNotEmpty && _overlaps(placed)) {
    warning ??= 'Some lines overlap on the label. Drag them apart or use smaller text.';
  }
  return LabelPlan(placed, warning: printProblem ?? warning, printProblem: printProblem);
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
  for (var i = 0; i < elements.length; i++) {
    for (var j = i + 1; j < elements.length; j++) {
      if (_intersects(elements[i], elements[j])) return true;
    }
  }
  return false;
}

bool _intersects(LabelElement first, LabelElement second) {
  final a = labelBox(first), b = labelBox(second);
  return a.l < b.r - 0.05 && b.l < a.r - 0.05 && a.t < b.b - 0.05 && b.t < a.b - 0.05;
}

String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
