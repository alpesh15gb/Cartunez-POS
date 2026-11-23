// Draws a planned label (see core/label_layout.dart) as a PDF page or as an
// on-screen preview. Both follow the same millimetre plan as the Zebra output.
import 'package:barcode/barcode.dart';
import 'package:flutter/gestures.dart';
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

/// One planned element as a PDF widget, [offsetX]/[offsetY] mm from the page's
/// top-left (WS-F: used by the A4 label sheets in core/label_sheet_pdf.dart).
pw.Widget pdfLabelElement(LabelElement e, double offsetX, double offsetY) {
  if (offsetY == 0) return _pdfElement(e, offsetX);
  final moved = e.barcode
      ? LabelElement.barcode(e.text, e.x, e.y + offsetY, e.width, e.height,
          format: e.format, module: e.module, barHeight: e.barHeight, digits: e.digits)
      : LabelElement.text(e.part, e.text, e.x, e.y + offsetY, e.width, e.height, bold: e.bold, align: e.align);
  return _pdfElement(moved, offsetX);
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
      textStyle: pw.TextStyle(fontSize: ((e.height - e.barHeight) * 0.8).clamp(1.5, 6) * mm, fontWeight: pw.FontWeight.bold),
    ),
  );
}

// ---------- On-screen preview ----------

/// Draws the label (or a row of labels) to scale. With [onDrag], parts can be
/// tapped to select and dragged to move (in the first label of the row).
class LabelPreview extends StatefulWidget {
  const LabelPreview({
    super.key,
    required this.layout,
    required this.plans,
    this.maxWidth = 420,
    this.selected,
    this.onSelect,
    this.onDragStart,
    this.onDrag,
  });
  final LabelLayout layout;
  final List<LabelPlan> plans;
  final double maxWidth;
  final String? selected;
  final ValueChanged<String?>? onSelect;

  /// Called when a part starts being dragged.
  final ValueChanged<String>? onDragStart;

  /// Called while a part is dragged, with the total movement since the drag started, in mm.
  final void Function(String part, double dxMm, double dyMm)? onDrag;

  @override
  State<LabelPreview> createState() => _LabelPreviewState();
}

class _LabelPreviewState extends State<LabelPreview> {
  String? dragging;
  Offset dragFrom = Offset.zero;

  double get scale => widget.maxWidth / widget.layout.rollWidthMm;

  /// The part under [local] (pixels), text before the barcode.
  String? _hit(Offset local) {
    if (widget.plans.isEmpty) return null;
    final l = widget.layout;
    final pitch = l.widthMm + l.gapMm;
    final column = (local.dx / scale / pitch).floor();
    final x = local.dx / scale - column * pitch, y = local.dy / scale;
    final elements = [...widget.plans.first.elements]..sort((a, b) => (a.barcode ? 1 : 0) - (b.barcode ? 1 : 0));
    for (final e in elements) {
      final box = labelBox(e);
      const pad = 0.6;
      if (x >= box.l - pad && x <= box.r + pad && y >= box.t - pad && y <= box.b + pad) return e.part;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Fixed width (no LayoutBuilder) so the preview can sit inside dialogs.
    final paint = SizedBox(
      width: widget.maxWidth,
      height: widget.layout.heightMm * scale,
      child: CustomPaint(painter: _LabelPainter(widget.layout, widget.plans, scale, widget.selected)),
    );
    if (widget.onDrag == null && widget.onSelect == null) return paint;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Pick the part under the finger where it first touched, not after the drag slop.
        dragStartBehavior: DragStartBehavior.down,
        onTapUp: (d) => widget.onSelect?.call(_hit(d.localPosition)),
        onPanStart: (d) {
          dragging = _hit(d.localPosition);
          dragFrom = d.localPosition;
          if (dragging != null) {
            widget.onSelect?.call(dragging);
            widget.onDragStart?.call(dragging!);
          }
        },
        // Measured from where the finger first touched, so no movement is lost
        // while the gesture is being recognised.
        onPanUpdate: (d) {
          final total = d.localPosition - dragFrom;
          if (dragging != null) widget.onDrag?.call(dragging!, total.dx / scale, total.dy / scale);
        },
        onPanEnd: (_) => dragging = null,
        child: paint,
      ),
    );
  }
}

class _LabelPainter extends CustomPainter {
  _LabelPainter(this.layout, this.plans, this.scale, this.selected);
  final LabelLayout layout;
  final List<LabelPlan> plans;
  final double scale;
  final String? selected;

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
      // Outline the selected part on the first label.
      if (c == 0 && selected != null) {
        for (final e in plan.elements.where((e) => e.part == selected)) {
          final box = labelBox(e);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTRB((box.l - 0.4) * scale, (box.t - 0.3) * scale, (box.r + 0.4) * scale, (box.b + 0.3) * scale),
                Radius.circular(0.6 * scale)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = const Color(0xFF117755),
          );
        }
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
            text: TextSpan(text: part.text, style: TextStyle(color: const Color(0xFF111111), fontFamily: 'CartunezSans', fontSize: part.height, height: 1, fontWeight: FontWeight.w800)),
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
