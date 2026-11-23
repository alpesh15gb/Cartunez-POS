// ZPL (Zebra Programming Language) labels for thermal barcode printers.
// The printer draws the barcode itself, so bars land exactly on its print-head
// dots and scan reliably even on small labels. Positions come from planLabel().
import 'label_layout.dart';

/// Built-in Zebra fonts have no rupee sign, so prices print as "Rs.".
String zplMoney(String formatted) => formatted.replaceAll('₹', 'Rs. ').replaceAll('  ', ' ').trim();

/// Escapes field data with ^FH so ^, ~ and _ in names cannot break the label.
String _field(String text) {
  final clean = text.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
  final out = StringBuffer();
  for (final rune in clean.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '^' || ch == '~' || ch == '_') {
      out.write('_${rune.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      out.write(ch);
    }
  }
  return '^FH_^FD$out^FS';
}

/// The barcode number in bold under the bars: the scalable font printed twice,
/// one dot apart, centred across the barcode's width.
String _boldDigits(String text, int x, int top, int width, int space, int dpi) {
  final gap = (dpi / 203 * 2).round();
  final h = (space - gap).clamp(10, 200);
  final w = (h * 0.9).round();
  final shift = (dpi / 203).round().clamp(1, 3);
  final field = _field(text);
  return '^FO$x,${top + gap}^A0N,$h,$w^FB$width,1,0,C$field'
      '^FO${x + shift},${top + gap}^A0N,$h,$w^FB$width,1,0,C$field';
}

String _elements(LabelPlan plan, double offsetMm, int dpi) {
  int d(double mm) => (mm * dpi / 25.4).round();
  final b = StringBuffer();
  for (final e in plan.elements) {
    final x = d(offsetMm + e.x), y = d(e.y);
    if (!e.barcode) {
      final h = d(e.height);
      final align = switch (e.align) { LabelAlign.left => 'L', LabelAlign.center => 'C', LabelAlign.right => 'R' };
      b.write('^FO$x,$y^A0N,$h,$h^FB${d(e.width)},1,0,$align${_field(e.text)}');
      continue;
    }
    final bars = d(e.barHeight);
    // The printer's own number line uses a fixed thin font, so it is switched off
    // ('N') and the number is printed below the bars in bold instead.
    const hr = 'N';
    // EAN/UPC: the printer adds the check digit, so send the digits without it.
    final (command, data) = switch (e.format) {
      'EAN13' => ('^BEN,$bars,$hr,N', e.text.substring(0, 12)),
      'UPC' => ('^BUN,$bars,$hr,N,Y', e.text.substring(0, 11)),
      'EAN8' => ('^B8N,$bars,$hr,N', e.text.substring(0, 7)),
      _ => ('^BCN,$bars,$hr,N,N,A', e.text),
    };
    final quiet = e.module * (e.format == 'CODE128' ? 10 : 9);
    b.write('^BY${e.module},3,$bars^FO${x + quiet},$y$command${_field(data)}');
    if (e.digits) b.write(_boldDigits(e.text, x, y + bars, d(e.width), d(e.height) - bars, dpi));
  }
  return b.toString();
}

/// Labels for [labels], each printed [copies] times. With several labels
/// across the roll, each row of the roll is one label format.
String zplJob(List<LabelData> labels, LabelLayout layout, {int dpi = 203, int? darkness, int copies = 1, List<int>? quantities}) {
  int d(double mm) => (mm * dpi / 25.4).round();
  final header = StringBuffer()
    ..write('^XA^CI28^PW${d(layout.rollWidthMm)}^LL${d(layout.heightMm)}^LH0,0')
    ..write(darkness == null ? '' : '~SD${darkness.clamp(0, 30).toString().padLeft(2, '0')}');
  final formats = <String>[];
  var row = StringBuffer(header);
  var column = 0;
  for (final (index, label) in labels.indexed) {
    var count = quantities?[index] ?? copies;
    if (count <= 0) continue;
    final plan = planLabel(layout, label, dpi: dpi);
    if (layout.columns == 1) {
      final elements = _elements(plan, 0, dpi);
      while (count > 0) {
        final batch = count.clamp(1, 999);
        formats.add('$header$elements^PQ$batch,0,1,Y^XZ');
        count -= batch;
      }
    } else {
      for (var i = 0; i < count; i++) {
        row.write(_elements(plan, column * (layout.widthMm + layout.gapMm), dpi));
        if (++column == layout.columns) {
          formats.add('$row^PQ1,0,1,Y^XZ');
          row = StringBuffer(header);
          column = 0;
        }
      }
    }
  }
  if (column > 0) formats.add('$row^PQ1,0,1,Y^XZ');
  return formats.join('\n');
}
