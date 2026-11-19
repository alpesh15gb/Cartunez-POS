// Draws a planned label (see core/label_layout.dart) as a PDF page or as an
// on-screen preview. Both follow the same millimetre plan as the Zebra output.
import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/billing.dart';
import '../core/label_layout.dart';

Barcode symbology(String format) => switch (format) {
      'EAN13' => Barcode.ean13(),
      'UPC' => Barcode.upcA(),
      'EAN8' => Barcode.ean8(),
      _ => Barcode.code128(),
    };

/// Whether [code] can be drawn as a barcode at all.
bool printableCode(String code) => code.isNotEmpty && symbology(barcodeFormat(code)).isValid(code);

/// The bars' share of the barcode element (the rest is quiet zone).
double _barShare(String format, String code) => switch (format) {
      'EAN13' || 'UPC' => 95 / barcodeModules(format, code),
      'EAN8' => 67 / barcodeModules(format, code),
      _ => (barcodeModules(format, code) - 20) / barcodeModules(format, code),
    };

// ---------- PDF ----------

/// One PDF page per row of labels on the roll.
List<pw.Page> pdfLabelPages(LabelLayout layout, List<LabelPlan> plans) {
  const mm = PdfPageFormat.mm;
  final format = PdfPageFormat(layout.rollWidthMm * mm, layout.heightMm * mm);
  final pages = <pw.Page>[];
  for (var start = 0; start < plans.length; start += layout.columns) {
    final row = plans.sublist(start, (start + layout.columns).clamp(0, plans.length));
    pages.add(pw.Page(
      pageFormat: format,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [
        for (final (c, plan) in row.indexed)
          for (final e in plan.elements) _pdfElement(e, c * (layout.widthMm + layout.gapMm)),
      ]),
    ));
  }
  return pages;
}

pw.Widget _pdfElement(LabelElement e, double offset) {
  const mm = PdfPageFormat.mm;
  if (!e.barcode) {
    return pw.Positioned(
      left: (offset + e.x) * mm,
      top: e.y * mm,
      child: pw.SizedBox(
        width: e.width * mm,
        height: e.height * mm,
        child: pw.Text(
          e.text,
          maxLines: 1,
          textAlign: switch (e.align) { LabelAlign.left => pw.TextAlign.left, LabelAlign.center => pw.TextAlign.center, LabelAlign.right => pw.TextAlign.right },
          style: pw.TextStyle(fontSize: e.height * mm * 0.95, lineSpacing: 0, fontWeight: e.bold ? pw.FontWeight.bold : null),
        ),
      ),
    );
  }
  final share = _barShare(e.format, e.text);
  final width = e.width * (e.format == 'CODE128' ? share : 1);
  return pw.Positioned(
    left: (offset + e.x + (e.width - width) / 2) * mm,
    top: e.y * mm,
    child: pw.BarcodeWidget(
      barcode: symbology(e.format),
      data: e.text,
      width: width * mm,
      height: e.height * mm,
      drawText: e.digits,
      textStyle: pw.TextStyle(fontSize: ((e.height - e.barHeight) * 0.8).clamp(1.5, 6) * mm),
    ),
  );
}

// ---------- On-screen preview ----------

/// Draws the label (or a row of labels) to scale.
class LabelPreview extends StatelessWidget {
  const LabelPreview({super.key, required this.layout, required this.plans, this.maxWidth = 420});
  final LabelLayout layout;
  final List<LabelPlan> plans;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // Fixed width (no LayoutBuilder) so the preview can sit inside dialogs.
    final scale = maxWidth / layout.rollWidthMm;
    return SizedBox(
      width: maxWidth,
      height: layout.heightMm * scale,
      child: CustomPaint(painter: _LabelPainter(layout, plans, scale)),
    );
  }
}

class _LabelPainter extends CustomPainter {
  _LabelPainter(this.layout, this.plans, this.scale);
  final LabelLayout layout;
  final List<LabelPlan> plans;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()..color = const Color(0xFF111111);
    for (var c = 0; c < layout.columns; c++) {
      final offset = c * (layout.widthMm + layout.gapMm);
      final rect = Rect.fromLTWH(offset * scale, 0, layout.widthMm * scale, layout.heightMm * scale);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(1.2 * scale)), Paint()..color = Colors.white);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(1.2 * scale)),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFFCBD5CF));
      if (plans.isEmpty) continue;
      final plan = plans[c % plans.length];
      for (final e in plan.elements) {
        e.barcode ? _barcode(canvas, e, offset, ink) : _text(canvas, e, offset);
      }
    }
  }

  void _text(Canvas canvas, LabelElement e, double offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: e.text,
        style: TextStyle(
          color: const Color(0xFF111111),
          fontFamily: 'CartunezSans',
          fontSize: e.height * scale * 0.95,
          height: 1,
          fontWeight: e.bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textAlign: switch (e.align) { LabelAlign.left => TextAlign.left, LabelAlign.center => TextAlign.center, LabelAlign.right => TextAlign.right },
      textDirection: TextDirection.ltr,
    )..layout(minWidth: e.width * scale, maxWidth: e.width * scale);
    painter.paint(canvas, Offset((offset + e.x) * scale, e.y * scale));
  }

  void _barcode(Canvas canvas, LabelElement e, double offset, Paint ink) {
    final share = _barShare(e.format, e.text);
    final width = e.width * (e.format == 'CODE128' ? share : 1);
    final left = (offset + e.x + (e.width - width) / 2) * scale;
    final top = e.y * scale;
    final digits = (e.height - e.barHeight) * scale;
    try {
      for (final part in symbology(e.format).make(e.text,
          width: width * scale, height: e.height * scale, drawText: e.digits, fontHeight: (digits * 0.8).clamp(4, 40))) {
        if (part is BarcodeBar && part.black) {
          canvas.drawRect(Rect.fromLTWH(left + part.left, top + part.top, part.width, part.height), ink);
        } else if (part is BarcodeText) {
          final tp = TextPainter(
            text: TextSpan(text: part.text, style: TextStyle(color: const Color(0xFF111111), fontFamily: 'CartunezSans', fontSize: part.height, height: 1)),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
          )..layout(minWidth: part.width, maxWidth: part.width.clamp(part.width, 9999));
          tp.paint(canvas, Offset(left + part.left, top + part.top));
        }
      }
    } catch (_) {
      // Invalid code: leave the space empty; the design screen shows a warning.
    }
  }

  @override
  bool shouldRepaint(_LabelPainter old) => true;
}
