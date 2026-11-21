// WS-F: barcode labels as PDF for the browser (and any printer without ZPL).
//
// Browsers cannot send raw ZPL to a printer, so the web prints the same label
// plan (core/label_layout.dart) as a PDF of exactly the right size:
//  * roll: one page per row of labels, page = roll width × label height, for
//    a label printer with its driver set to that paper size;
//  * sheet: A4 (or any page) with a grid of labels, for adhesive label sheets
//    on an ordinary printer, with configurable columns, rows, margins and gaps.
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../ui/label_render.dart';
import 'label_layout.dart';

/// A sheet of labels: page size and the grid the labels sit on (all mm).
class SheetGrid {
  const SheetGrid({
    this.columns = 3,
    this.rows = 8,
    this.marginTopMm = 10,
    this.marginLeftMm = 7,
    this.gapXMm = 2.5,
    this.gapYMm = 0,
    this.pageWidthMm = 210,
    this.pageHeightMm = 297,
  });

  final int columns, rows;
  final double marginTopMm, marginLeftMm, gapXMm, gapYMm, pageWidthMm, pageHeightMm;

  int get perPage => columns * rows;

  Map<String, dynamic> toJson() => {
        'columns': columns, 'rows': rows, 'marginTopMm': marginTopMm, 'marginLeftMm': marginLeftMm,
        'gapXMm': gapXMm, 'gapYMm': gapYMm, 'pageWidthMm': pageWidthMm, 'pageHeightMm': pageHeightMm,
      };

  static SheetGrid fromJson(Map? j) {
    double d(String k, double fallback, double min, double max) => ((j?[k] as num?)?.toDouble() ?? fallback).clamp(min, max);
    int i(String k, int fallback) => ((j?[k] as num?)?.toInt() ?? fallback).clamp(1, 20);
    return SheetGrid(
      columns: i('columns', 3),
      rows: i('rows', 8),
      marginTopMm: d('marginTopMm', 10, 0, 100),
      marginLeftMm: d('marginLeftMm', 7, 0, 100),
      gapXMm: d('gapXMm', 2.5, 0, 50),
      gapYMm: d('gapYMm', 0, 0, 50),
      pageWidthMm: d('pageWidthMm', 210, 50, 500),
      pageHeightMm: d('pageHeightMm', 297, 50, 500),
    );
  }

  /// Plain-English problem when [layout]'s labels do not fit this sheet.
  String? problem(LabelLayout layout) {
    final width = marginLeftMm + columns * layout.widthMm + (columns - 1) * gapXMm;
    final height = marginTopMm + rows * layout.heightMm + (rows - 1) * gapYMm;
    if (width > pageWidthMm + 0.01) {
      return '$columns labels of ${_mm(layout.widthMm)} mm do not fit across a ${_mm(pageWidthMm)} mm page '
          '(needs ${_mm(width)} mm). Use fewer columns or smaller margins.';
    }
    if (height > pageHeightMm + 0.01) {
      return '$rows rows of ${_mm(layout.heightMm)} mm do not fit down a ${_mm(pageHeightMm)} mm page '
          '(needs ${_mm(height)} mm). Use fewer rows or smaller margins.';
    }
    return null;
  }
}

String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Page size of a roll print: the whole roll width by one label's height.
PdfPageFormat labelRollFormat(LabelLayout layout) =>
    PdfPageFormat(layout.rollWidthMm * PdfPageFormat.mm, layout.heightMm * PdfPageFormat.mm);

PdfPageFormat sheetFormat(SheetGrid grid) =>
    PdfPageFormat(grid.pageWidthMm * PdfPageFormat.mm, grid.pageHeightMm * PdfPageFormat.mm);

/// Labels laid out on sheets. [skip] leaves the first positions empty so a
/// part-used sheet can be fed again.
List<pw.Page> labelSheetPages(LabelLayout layout, List<LabelPlan> plans, SheetGrid grid, {int skip = 0}) {
  final problem = grid.problem(layout);
  if (problem != null) throw ArgumentError(problem);
  final slots = [...List<LabelPlan?>.filled(skip.clamp(0, grid.perPage - 1), null), ...plans];
  final pages = <pw.Page>[];
  for (var start = 0; start < slots.length; start += grid.perPage) {
    final page = slots.sublist(start, (start + grid.perPage).clamp(0, slots.length));
    pages.add(pw.Page(
      pageFormat: sheetFormat(grid),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [
        for (final (i, plan) in page.indexed)
          if (plan != null)
            for (final e in plan.elements)
              pdfLabelElement(
                e,
                grid.marginLeftMm + (i % grid.columns) * (layout.widthMm + grid.gapXMm),
                grid.marginTopMm + (i ~/ grid.columns) * (layout.heightMm + grid.gapYMm),
              ),
      ]),
    ));
  }
  return pages;
}

/// The finished PDF: roll pages when [sheet] is null, otherwise sheets.
Future<Uint8List> labelPdf(LabelLayout layout, List<LabelPlan> plans, {SheetGrid? sheet, int skip = 0, pw.ThemeData? theme}) {
  final doc = pw.Document(theme: theme);
  final pages = sheet == null ? pdfLabelPages(layout, plans) : labelSheetPages(layout, plans, sheet, skip: skip);
  for (final page in pages) {
    doc.addPage(page);
  }
  return doc.save();
}
