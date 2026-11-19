import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/billing.dart';
import '../../core/label_layout.dart';
import '../../core/label_printer.dart';
import '../../core/zpl.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../label_render.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receipt.dart' show pdfTheme;

/// One label to print. Prices are in paise; [mrp] is the price including tax.
class LabelItem {
  const LabelItem(this.name, this.code, {this.sku, this.price, this.mrp, this.brand, this.partNumber, this.bin});
  final String name;
  final String code;
  final String? sku, brand, partNumber, bin;
  final int? price, mrp;
}

/// A part's label, with its brand, part number, main bin, price and MRP.
LabelItem productLabel(AppState app, Json p) {
  final price = p['type'] == 'service' ? null : p['retailPrice'] as int?;
  final taxRate = (p['taxRate'] as num?)?.toInt() ?? 0;
  final mrp = price == null ? null : (app.settings['taxMode'] == 'inclusive' ? price : (price + price * taxRate / 10000).round());
  Json? bin;
  var most = 0;
  for (final b in app.bins) {
    final n = app.available('${p['id']}', '${b['id']}');
    if (n > most) {
      most = n;
      bin = b;
    }
  }
  return LabelItem(
    '${p['name']}',
    '${(p['barcodes'] as List? ?? []).firstOrNull ?? p['sku']}',
    sku: '${p['sku'] ?? ''}',
    brand: '${p['brand'] ?? ''}',
    partNumber: '${p['partNumber'] ?? ''}',
    bin: bin == null ? '' : app.binName(bin),
    price: price,
    mrp: mrp,
  );
}

/// Common thermal label sizes (width × height in mm).
const labelSizes = [
  ('50x25', '50 × 25 mm (2 × 1 in)'),
  ('38x25', '38 × 25 mm (1.5 × 1 in)'),
  ('50x30', '50 × 30 mm'),
  ('75x50', '75 × 50 mm (3 × 2 in)'),
  ('100x50', '100 × 50 mm (4 × 2 in)'),
];

const _modeZebraUsb = 'zebra-installed', _modeZebraNetwork = 'zebra-network', _modeDialog = 'dialog';

/// The shop's label design (shared by all counters).
LabelLayout shopLabelLayout(AppState app) =>
    LabelLayout.fromJson(app.settings['labelLayout'] as Map?, fallbackSize: app.labelPrinter['size'] as String?);

String _mode(Json printer) {
  final mode = '${printer['mode'] ?? _modeDialog}';
  if (mode == _modeZebraUsb && !canPrintToInstalledPrinter) return _modeDialog;
  if (mode == _modeZebraNetwork && !canPrintToNetworkPrinter) return _modeDialog;
  return mode;
}

bool _zebra(AppState app) => _mode(app.labelPrinter) != _modeDialog;
int _dpi(AppState app) => int.tryParse('${app.labelPrinter['dpi'] ?? 203}') ?? 203;

String _size(LabelLayout l) => '${_num(l.widthMm)} × ${_num(l.heightMm)} mm${l.columns > 1 ? ', ${l.columns} across' : ''}';
String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// One line describing where labels go, for Settings and the print dialog.
String labelPrinterSummary(AppState app) {
  final p = app.labelPrinter;
  final size = _size(shopLabelLayout(app));
  return switch (_mode(p)) {
    _modeZebraUsb => '${p['printer']} · $size',
    _modeZebraNetwork => 'Zebra at ${p['host']} · $size',
    _ => kIsWeb ? 'Browser print dialog · $size' : 'Print dialog · $size',
  };
}

/// What the shop's label shows, in a few words.
String labelDesignSummary(AppState app) {
  final l = shopLabelLayout(app);
  final parts = [
    if (l.shopName) 'shop name',
    if (l.name) 'part name',
    if (l.brand) 'brand',
    if (l.partNumber) 'part number',
    'barcode',
    if (l.sku) 'SKU',
    if (l.bin) 'bin',
    switch (l.price) { 'mrp' => 'MRP', 'both' => 'price and MRP', 'none' => '', _ => 'price' },
    if (l.extra.isNotEmpty) '"${l.extra}"',
  ].where((s) => s.isNotEmpty);
  return parts.join(', ');
}

LabelData _data(AppState app, LabelItem i, {required bool zebra}) {
  String? money(int? v) => v == null ? null : (zebra ? zplMoney(app.money(v)) : app.money(v));
  return LabelData(
    name: i.name,
    code: i.code,
    shop: '${app.business['tradingName'] ?? app.business['legalName'] ?? ''}',
    sku: i.sku ?? '',
    brand: i.brand ?? '',
    partNumber: i.partNumber ?? '',
    bin: i.bin ?? '',
    price: money(i.price),
    mrp: money(i.mrp),
  );
}

/// First label print on Windows with a Zebra driver installed: use it straight away.
Future<void> _autoDetect(AppState app) async {
  if (app.labelPrinter.isNotEmpty || !canPrintToInstalledPrinter) return;
  final zebra = (await installedPrinters()).where((n) => RegExp('zebra|zdesigner', caseSensitive: false).hasMatch(n)).firstOrNull;
  if (zebra != null) {
    await app.saveLabelPrinter({'mode': _modeZebraUsb, 'printer': zebra, 'dpi': RegExp('300').hasMatch(zebra) ? 300 : 203});
  }
}

/// Prints barcode labels with the shop's design on this device's label printer
/// (Zebra ZPL), or through the print dialog as a PDF sized to the label.
Future<void> printLabels(BuildContext context, List<LabelItem> items) async {
  final app = context.appRead;
  if (items.isEmpty) return app.toast('Nothing to print.');
  for (final item in items) {
    if (!printableCode(item.code)) {
      return app.toast('The barcode on ${item.name} cannot be printed. Use a printable barcode or SKU.');
    }
  }
  await _autoDetect(app);
  if (!context.mounted) return;
  final copies = await showFormDialog<int>(
    context,
    title: items.length == 1 ? 'Label · ${items.first.name}' : '${items.length} labels',
    submit: 'Print labels',
    header: _PrintHeader(item: items.first),
    fields: const [FieldSpec('copies', 'Copies of each label', kind: FieldKind.number, value: 1, required: true)],
    onSubmit: (v) async {
      final n = int.tryParse('${v['copies']}') ?? 0;
      if (n < 1 || n > 100) throw FormProblem('Print between 1 and 100 copies.');
      return n;
    },
  );
  if (copies == null) return;
  await _print(app, items, copies, shopLabelLayout(app));
}

Future<void> _print(AppState app, List<LabelItem> items, int copies, LabelLayout layout) async {
  final printer = app.labelPrinter;
  final mode = _mode(printer);
  final zebra = mode != _modeDialog;
  final data = [for (final i in items) _data(app, i, zebra: zebra)];
  if (!zebra) {
    final doc = pw.Document(theme: await pdfTheme());
    final plans = [for (final d in data) for (var c = 0; c < copies; c++) planLabel(layout, d, dpi: 300)];
    for (final page in pdfLabelPages(layout, plans)) {
      doc.addPage(page);
    }
    await Printing.layoutPdf(name: 'labels', onLayout: (_) => doc.save());
    return;
  }
  final zpl = zplJob(data, layout, dpi: _dpi(app), darkness: int.tryParse('${printer['darkness'] ?? ''}'), copies: copies);
  try {
    if (mode == _modeZebraUsb) {
      await printRawToInstalled('${printer['printer']}', zpl);
    } else {
      await printRawToNetwork('${printer['host']}', int.tryParse('${printer['port'] ?? 9100}') ?? 9100, zpl);
    }
    final count = items.length * copies;
    app.toast('Sent $count label${count == 1 ? '' : 's'} to ${mode == _modeZebraUsb ? printer['printer'] : 'the Zebra printer'}.');
  } catch (e) {
    app.toast('Labels not printed: ${errorText(e)}');
  }
}

const _sampleItem = LabelItem('Engine Air Filter', '4006381333931',
    sku: 'ML-AIR-01', brand: 'Bosch', partNumber: 'F026400', bin: 'A / 1 / 01', price: 64900, mrp: 76582);

/// A real part from the catalog for the preview, or a sample one.
LabelItem _previewItem(AppState app) {
  final part = app.products.where((p) => p['type'] != 'service' && (p['barcodes'] as List? ?? []).isNotEmpty).firstOrNull;
  return part == null ? _sampleItem : productLabel(app, part);
}

/// Prints one label with the shop's design so the size, position and darkness can be checked.
Future<void> printTestLabel(BuildContext context, {LabelLayout? layout}) async {
  final app = context.appRead;
  await _autoDetect(app);
  await _print(app, [_previewItem(app)], 1, layout ?? shopLabelLayout(app));
}

// ---------- Label design ----------

/// Design the shop's label: size, which lines print, price style and text size.
Future<void> editLabelDesign(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _LabelDesigner());

class _LabelDesigner extends StatefulWidget {
  const _LabelDesigner();
  @override
  State<_LabelDesigner> createState() => _LabelDesignerState();
}

class _LabelDesignerState extends State<_LabelDesigner> {
  late LabelLayout layout;
  late final TextEditingController extra, width, height, gap;
  bool saving = false;
  String? problem;

  @override
  void initState() {
    super.initState();
    layout = shopLabelLayout(context.appRead);
    extra = TextEditingController(text: layout.extra);
    width = TextEditingController(text: _num(layout.widthMm));
    height = TextEditingController(text: _num(layout.heightMm));
    gap = TextEditingController(text: _num(layout.gapMm));
  }

  @override
  void dispose() {
    for (final c in [extra, width, height, gap]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _sizeKey {
    final key = '${_num(layout.widthMm)}x${_num(layout.heightMm)}';
    return labelSizes.any((s) => s.$1 == key) ? key : 'custom';
  }

  void _set(LabelLayout next) => setState(() => layout = next);

  void _customSize() {
    final w = double.tryParse(width.text), h = double.tryParse(height.text), g = double.tryParse(gap.text);
    _set(layout.copyWith(
      widthMm: w?.clamp(20, 110).toDouble(),
      heightMm: h?.clamp(10, 150).toDouble(),
      gapMm: g?.clamp(0, 10).toDouble(),
    ));
  }

  Future<void> _save() async {
    final app = context.appRead;
    setState(() {
      saving = true;
      problem = null;
    });
    try {
      await app.mutate('/settings', {'labelLayout': layout.copyWith(extra: extra.text.trim()).toJson()});
      if (mounted) Navigator.of(context).pop();
      app.toast('Label design saved for every counter.');
    } catch (e) {
      setState(() => problem = errorText(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final owner = app.isOwner;
    final zebra = _zebra(app);
    final sample = _data(app, _previewItem(app), zebra: zebra);
    final plan = planLabel(layout, sample, dpi: _dpi(app));
    final wide = MediaQuery.sizeOf(context).width > 900;
    final theme = Theme.of(context);

    Widget chip(String label, bool on, LabelLayout Function(bool) change) => FilterChip(
          label: Text(label),
          selected: on,
          onSelected: owner ? (v) => _set(change(v)) : null,
        );
    Widget segments(String label, String value, List<(String, String)> options, LabelLayout Function(String) change) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [for (final (v, l) in options) ButtonSegment(value: v, label: Text(l))],
              selected: {value},
              onSelectionChanged: owner ? (s) => _set(change(s.first)) : null,
            ),
          ]),
        );

    final controls = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _sizeKey,
            decoration: const InputDecoration(labelText: 'Label size'),
            items: [
              for (final (k, l) in labelSizes) DropdownMenuItem(value: k, child: Text(l)),
              const DropdownMenuItem(value: 'custom', child: Text('Custom size')),
            ],
            onChanged: !owner
                ? null
                : (v) {
                    if (v == null) return;
                    if (v == 'custom') {
                      _set(layout.copyWith(widthMm: layout.widthMm + 0.5));
                    } else {
                      final p = v.split('x');
                      _set(layout.copyWith(widthMm: double.parse(p[0]), heightMm: double.parse(p[1])));
                    }
                    width.text = _num(layout.widthMm);
                    height.text = _num(layout.heightMm);
                  },
          ),
        ),
      ]),
      if (_sizeKey == 'custom')
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Expanded(child: TextField(controller: width, enabled: owner, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width (mm)'), onChanged: (_) => _customSize())),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: height, enabled: owner, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height (mm)'), onChanged: (_) => _customSize())),
          ]),
        ),
      segments('Labels across the roll', '${layout.columns}', const [('1', '1'), ('2', '2'), ('3', '3')],
          (v) => layout.copyWith(columns: int.parse(v))),
      if (layout.columns > 1)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TextField(controller: gap, enabled: owner, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Gap between labels (mm)'), onChanged: (_) => _customSize()),
        ),
      Padding(padding: const EdgeInsets.only(top: 16, bottom: 6), child: Text('Print on the label', style: theme.textTheme.labelLarge)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        chip('Shop name', layout.shopName, (v) => layout.copyWith(shopName: v)),
        chip('Part name', layout.name, (v) => layout.copyWith(name: v)),
        chip('Brand', layout.brand, (v) => layout.copyWith(brand: v)),
        chip('Part number', layout.partNumber, (v) => layout.copyWith(partNumber: v)),
        chip('SKU', layout.sku, (v) => layout.copyWith(sku: v)),
        chip('Bin location', layout.bin, (v) => layout.copyWith(bin: v)),
        chip('Digits under barcode', layout.digits, (v) => layout.copyWith(digits: v)),
      ]),
      segments('Price', layout.price, const [('price', 'Price'), ('mrp', 'MRP'), ('both', 'Both'), ('none', 'None')],
          (v) => layout.copyWith(price: v)),
      segments('Part name size', layout.nameSize, const [('small', 'Small'), ('medium', 'Medium'), ('large', 'Large')],
          (v) => layout.copyWith(nameSize: v)),
      segments('Price size', layout.priceSize, const [('small', 'Small'), ('medium', 'Medium'), ('large', 'Large')],
          (v) => layout.copyWith(priceSize: v)),
      const SizedBox(height: 14),
      TextField(
        controller: extra,
        enabled: owner,
        maxLength: 60,
        decoration: const InputDecoration(labelText: 'Extra line (optional)', hintText: 'e.g. phone number or "No return without label"'),
        onChanged: (v) => _set(layout.copyWith(extra: v.trim())),
      ),
    ]);

    final preview = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Preview', style: theme.textTheme.labelLarge),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFFEFF3F0), borderRadius: BorderRadius.circular(12)),
        child: Center(child: LabelPreview(layout: layout, plans: [plan], maxWidth: wide ? 380 : 340)),
      ),
      const SizedBox(height: 8),
      Text(
        '${_size(layout)} · ${zebra ? 'prices print as "Rs." on the Zebra' : 'printed through the print dialog'}',
        style: theme.textTheme.bodySmall,
      ),
      if (plan.warning != null)
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309), size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(plan.warning!, style: const TextStyle(color: Color(0xFF7C2D12)))),
          ]),
        ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => printTestLabel(context, layout: layout.copyWith(extra: extra.text.trim())),
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: const Text('Print test label'),
        ),
      ),
      if (!owner)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Only the owner can change the shop\'s label design.', style: theme.textTheme.bodySmall),
        ),
    ]);

    return AlertDialog(
      title: const Text('Label design'),
      content: SizedBox(
        width: wide ? 860 : 520,
        child: SingleChildScrollView(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: controls),
                  const SizedBox(width: 24),
                  Expanded(child: preview),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [preview, const SizedBox(height: 16), controls]),
        ),
      ),
      actions: [
        if (problem != null) Text(problem!, style: const TextStyle(color: Brand.danger)),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(owner ? 'Cancel' : 'Close')),
        if (owner)
          FilledButton(onPressed: saving ? null : _save, child: Text(saving ? 'Saving…' : 'Save design')),
      ],
    );
  }
}

// ---------- Printer (this device) ----------

/// Where this device sends barcode labels.
Future<void> editLabelPrinter(BuildContext context) async {
  final app = context.appRead;
  final printers = await installedPrinters();
  if (!context.mounted) return;
  final p = app.labelPrinter;
  final zebra = printers.where((n) => RegExp('zebra|zdesigner', caseSensitive: false).hasMatch(n)).firstOrNull;
  final modes = [
    if (canPrintToInstalledPrinter) (_modeZebraUsb, 'Zebra printer installed on this PC (USB)'),
    if (canPrintToNetworkPrinter) (_modeZebraNetwork, 'Zebra printer on the network (IP address)'),
    (_modeDialog, kIsWeb ? 'Browser print dialog (PDF)' : 'Print dialog, any printer (PDF)'),
  ];
  final current = modes.any((m) => m.$1 == p['mode']) ? p['mode'] : (zebra != null ? _modeZebraUsb : modes.first.$1);
  await showFormDialog<void>(
    context,
    title: 'Label printer on this device',
    header: kIsWeb
        ? const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('Browsers can only print through the print dialog. For one-click Zebra printing, use the Windows app.'),
          )
        : null,
    fields: [
      FieldSpec('mode', 'Print labels on', kind: FieldKind.select, value: current, options: modes),
      if (printers.isNotEmpty)
        FieldSpec('printer', 'Installed printer', kind: FieldKind.select,
            value: printers.contains(p['printer']) ? p['printer'] : (zebra ?? printers.first),
            options: [for (final n in printers) (n, n)],
            help: 'Pick the Zebra (usually named "ZDesigner …"). Install the Zebra driver if it is not listed.'),
      if (canPrintToNetworkPrinter)
        FieldSpec('host', 'Zebra IP address', value: p['host'] ?? '', help: 'For a network Zebra: printed on its configuration label.'),
      FieldSpec('dpi', 'Printer resolution', kind: FieldKind.select, value: '${p['dpi'] ?? 203}', advanced: true,
          options: const [('203', '203 dpi (most Zebra desktop printers)'), ('300', '300 dpi')]),
      FieldSpec('darkness', 'Print darkness (0-30)', kind: FieldKind.number, value: p['darkness'], advanced: true,
          help: 'Leave empty to keep the printer\'s own setting. Raise it if bars look faint.'),
      FieldSpec('port', 'Network port', kind: FieldKind.number, value: p['port'] ?? 9100, advanced: true),
    ],
    onSubmit: (v) async {
      final mode = '${v['mode']}';
      if (mode == _modeZebraUsb && '${v['printer'] ?? ''}'.isEmpty) throw FormProblem('Choose the installed Zebra printer.');
      if (mode == _modeZebraNetwork && '${v['host']}'.trim().isEmpty) throw FormProblem('Enter the Zebra printer\'s IP address.');
      final darkness = int.tryParse('${v['darkness'] ?? ''}');
      if (darkness != null && (darkness < 0 || darkness > 30)) throw FormProblem('Darkness is from 0 to 30.');
      await app.saveLabelPrinter({
        'mode': mode,
        'printer': ?v['printer'],
        'host': '${v['host'] ?? ''}'.trim(),
        'port': int.tryParse('${v['port']}') ?? 9100,
        'dpi': int.tryParse('${v['dpi']}') ?? 203,
        'darkness': ?darkness,
        // Earlier versions kept the label size per device; keep it as a fallback.
        'size': ?p['size'],
      });
      app.toast('Label printer saved. Print a test label to check it.');
    },
  );
}

/// Preview and printer line at the top of the print dialog.
class _PrintHeader extends StatelessWidget {
  const _PrintHeader({required this.item});
  final LabelItem item;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final layout = shopLabelLayout(app);
    final plan = planLabel(layout, _data(app, item, zebra: _zebra(app)), dpi: _dpi(app));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFEFF3F0), borderRadius: BorderRadius.circular(10)),
          child: Center(child: LabelPreview(layout: layout, plans: [plan], maxWidth: 300)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.print_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(labelPrinterSummary(app), style: Theme.of(context).textTheme.bodyMedium)),
          TextButton(onPressed: () => editLabelPrinter(context), child: const Text('Printer')),
          if (app.isOwner) TextButton(onPressed: () => editLabelDesign(context), child: const Text('Design')),
        ]),
      ]),
    );
  }
}
