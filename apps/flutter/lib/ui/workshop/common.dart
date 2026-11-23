// WS-C (workshop): shared pieces for estimates, job cards and vehicles.
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../barcode_scan.dart';
import '../screens/receipt.dart' show pdfTheme;
import '../widgets.dart';
import 'kits.dart';
import '../../core/receipt_print.dart' show openWhatsApp, whatsappUri;

/// QA #10/#14: "GST invoice" only for a GST-registered shop, otherwise "Invoice".
String invoiceTerm(AppState app, {bool lower = false}) {
  final term = app.gst ? 'GST invoice' : 'Invoice';
  return lower ? (app.gst ? 'GST invoice' : 'invoice') : term;
}

/// Job card statuses, in board order.
const jobStatuses = ['checked-in', 'in-progress', 'waiting-parts', 'ready', 'delivered'];
const jobStatusLabels = {
  'checked-in': 'Checked in',
  'in-progress': 'In progress',
  'waiting-parts': 'Waiting parts',
  'ready': 'Ready',
  'delivered': 'Delivered',
  'cancelled': 'Cancelled',
};
String jobStatusLabel(Object? status) => jobStatusLabels['$status'] ?? titleCase('$status');

const estimateStatusLabels = {
  'draft': 'Draft',
  'sent': 'Sent',
  'approved': 'Approved',
  'rejected': 'Rejected',
  'converted': 'Job card made',
};

Json? vehicleById(AppState app, Object? id) =>
    id == null ? null : app.list('customerVehicles').where((v) => v['id'] == id).firstOrNull;

/// "MH 12 AB 1234 · Maruti Suzuki Swift 2022"
String vehicleTitle(Json? vehicle) {
  if (vehicle == null) return 'No vehicle';
  final what = [vehicle['make'], vehicle['model'], vehicle['variant'], vehicle['year']]
      .where((e) => e != null && '$e'.isNotEmpty)
      .join(' ');
  return what.isEmpty ? '${vehicle['regNo']}' : '${vehicle['regNo']} · $what';
}

String customerLabel(AppState app, Object? id) =>
    id == null || '$id'.isEmpty ? 'Walk-in customer' : '${app.customerById('$id')?['name'] ?? 'Customer'}';

String lineKindLabel(Object? kind) => switch ('$kind') {
      'labour' => 'Labour',
      'service' => 'Service',
      'kit' => 'Kit',
      _ => 'Part',
    };

/// Line amount before tax (unit price × quantity).
int lineAmount(Json line) => ((line['unitPrice'] ?? 0) as num).toInt() * ((line['qty'] ?? 0) as num).toInt();

/// A short text for WhatsApp: number, vehicle, lines and total.
String documentSummary(AppState app, Json doc, {required String title}) {
  final shop = '${app.business['legalName'] ?? app.business['tradeName'] ?? ''}'.trim();
  final vehicle = vehicleById(app, doc['vehicleId']);
  final buffer = StringBuffer()
    ..writeln('$title ${doc['number']}${shop.isEmpty ? '' : ' from $shop'}')
    ..writeln(vehicle == null ? '' : 'Vehicle: ${vehicleTitle(vehicle)}');
  for (final line in (doc['lines'] as List? ?? const [])) {
    final l = Map<String, dynamic>.from(line as Map);
    buffer.writeln('• ${l['qty']} × ${l['name'] ?? app.productName('${l['productId']}')}'
        '${'${l['description'] ?? ''}'.isEmpty ? '' : ' (${l['description']})'} — ${app.money(lineAmount(l))}');
  }
  buffer
    ..writeln('Tax: ${app.money(doc['tax'] as num?)}')
    ..writeln('Total: ${app.money(doc['total'] as num?)}');
  if (doc['validUntil'] != null) buffer.writeln('Valid until ${doc['validUntil']}');
  return buffer.toString().replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}

/// wa.me link to the customer's phone (Indian numbers get +91), or the share chooser without a number.
String whatsappLink(String? phone, String text) => whatsappUri(phone, text).toString();

/// Opens WhatsApp with the summary (shared launcher); if that fails the link is copied.
Future<void> shareOnWhatsApp(BuildContext context, Json doc, {required String title}) async {
  final app = context.appRead;
  final phone = app.customerById('${doc['customerId']}')?['phone'] as String?;
  await openWhatsApp(whatsappUri(phone, documentSummary(app, doc, title: title)), app.toast,
      copied: 'Could not open WhatsApp, so the link was copied. Paste it in a browser or chat, or use Share PDF.');
}

/// A paginated estimate or job card, handed to the system share sheet.
Future<void> shareDocumentPdf(BuildContext context, Json doc, {required String title}) async {
  final app = context.appRead;
  try {
    final pdf = pw.Document(theme: await pdfTheme());
    final vehicle = vehicleById(app, doc['vehicleId']);
    final business = app.business;
    final lines = [for (final l in (doc['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
    String money(num? v) => app.money(v);
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: lines.length + 30,
      footer: (page) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text(
          '${doc['number']} · ${page.pageNumber} / ${page.pagesCount}', style: const pw.TextStyle(fontSize: 9))),
      build: (_) => [
        pw.Text('${business['legalName'] ?? ''}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        if ('${business['address'] ?? ''}'.isNotEmpty) pw.Text('${business['address']}'),
        pw.SizedBox(height: 12),
        pw.Text('$title ${doc['number']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('Date: ${formatDate(doc['createdAt'])}'),
        pw.Text('Customer: ${customerLabel(app, doc['customerId'])}'),
        if (vehicle != null) pw.Text('Vehicle: ${vehicleTitle(vehicle)}'),
        if (doc['validUntil'] != null) pw.Text('Valid until: ${doc['validUntil']}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: ['Item', 'Type', 'Qty', 'Rate', 'Amount'],
          columnWidths: const {
            0: pw.FlexColumnWidth(3.5), 1: pw.FlexColumnWidth(1), 2: pw.FlexColumnWidth(0.6),
            3: pw.FlexColumnWidth(1.2), 4: pw.FlexColumnWidth(1.3),
          },
          data: [
            for (final l in lines)
              [
                '${l['name']}${'${l['description'] ?? ''}'.isEmpty ? '' : '\n${l['description']}'}',
                lineKindLabel(l['kind']),
                '${l['qty']}',
                money(l['unitPrice'] as num?),
                money(lineAmount(l)),
              ],
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Subtotal: ${money(doc['subtotal'] as num?)}'),
            pw.Text('Tax: ${money(doc['tax'] as num?)}'),
            if ((doc['core'] ?? 0) != 0) pw.Text('Core deposits: ${money(doc['core'] as num?)}'),
            if ((doc['rounding'] ?? 0) != 0) pw.Text('Rounding: ${money(doc['rounding'] as num?)}'),
            pw.Text('Total: ${money(doc['total'] as num?)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ]),
        ),
        if ('${doc['notes'] ?? doc['complaint'] ?? ''}'.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text('Notes: ${doc['notes'] ?? doc['complaint']}'),
        ],
        pw.SizedBox(height: 16),
        pw.Text('This is not a tax invoice.', style: const pw.TextStyle(fontSize: 9)),
      ],
    ));
    await Printing.sharePdf(bytes: await pdf.save(), filename: '${doc['number']}.pdf');
  } catch (e) {
    app.toast('Could not make the PDF. ${errorText(e)}');
  }
}

/// Picks a part, labour item or kit: search by name/SKU or scan a barcode.
Future<Json?> pickProduct(BuildContext context, {String title = 'Add part, labour or kit'}) =>
    showDialog<Json>(context: context, builder: (_) => _ProductPicker(title: title));

class _ProductPicker extends StatefulWidget {
  const _ProductPicker({required this.title});
  final String title;
  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  final query = TextEditingController();
  String? problem;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await requestBarcode(context);
    if (code == null || !mounted) return;
    final app = context.appRead;
    final found = app.findByCode(scannedProductCode(code), forSale: true);
    if (found.length == 1) {
      Navigator.pop(context, found.first);
    } else {
      setState(() {
        query.text = code;
        problem = found.isEmpty ? 'No part has the code $code.' : 'Several parts share that code. Pick one below.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final q = normalize(query.text);
    final rows = app.saleProducts
        .where((p) => q.isEmpty || normalize('${p['name']} ${p['sku']} ${p['brand']} ${p['partNumber']} ${(p['barcodes'] as List? ?? []).join(' ')}').contains(q))
        .take(60)
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(children: [
          TextField(
            controller: query,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Search name, SKU or barcode',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(tooltip: 'Scan barcode', icon: const Icon(Icons.qr_code_scanner), onPressed: _scan),
            ),
            onChanged: (_) => setState(() => problem = null),
            onSubmitted: (_) {
              if (rows.length == 1) Navigator.pop(context, rows.first);
            },
          ),
          if (problem != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? const EmptyState(message: 'Nothing matches. Check the spelling or add the part in Catalog.')
                : ListView(children: [
                    for (final p in rows)
                      ListTile(
                        dense: true,
                        title: Text('${p['name']}'),
                        subtitle: Text('${p['sku']} · ${isKit(p) ? 'Kit' : p['type'] == 'service' ? 'Labour / service' : 'In stock ${app.available('${p['id']}')}'}'),
                        trailing: Text(app.money(p['retailPrice'] as num?)),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// A new document line for [product] (the server fills prices and bins).
Json newLine(Json product) => {
      'productId': product['id'],
      'name': product['name'],
      'sku': product['sku'],
      'qty': 1,
      'unitPrice': product['retailPrice'] ?? 0,
      'kind': isKit(product) ? 'kit' : product['type'] == 'service' ? 'labour' : 'part',
    };

/// Edits one line: quantity, price (managers), note, staff, serials (job parts).
Future<Json?> editLine(BuildContext context, Json line, {bool job = false}) {
  final app = context.appRead;
  final product = app.productById('${line['productId']}');
  final serial = job && product?['serialTracked'] == true;
  return showFormDialog<Json>(
    context,
    title: '${line['name'] ?? app.productName('${line['productId']}')}',
    fields: [
      FieldSpec('qty', 'Quantity', kind: FieldKind.number, value: line['qty'], required: true),
      if (app.isManager)
        FieldSpec('unitPrice', 'Price per unit', kind: FieldKind.money, value: (((line['unitPrice'] ?? 0) as num) / 100).toStringAsFixed(2),
            help: 'Quoted price. The catalog price is ${app.money(product?['retailPrice'] as num?)}.'),
      FieldSpec('description', 'Note on this line', value: line['description']),
      FieldSpec('staffId', 'Done by', kind: FieldKind.select, value: line['staffId'],
          options: [('', 'Job technician'), ...staffOptions(app)]),
      if (serial)
        FieldSpec('serials', 'Serial numbers', value: (line['serials'] as List? ?? const []).join(', '),
            help: 'One per unit, separated by commas. Needed before billing.'),
    ],
    onSubmit: (v) async {
      final qty = int.tryParse('${v['qty']}') ?? 0;
      if (qty < 1 || qty > 9999) throw FormProblem('Enter a quantity from 1 to 9999.');
      final price = v['unitPrice'] == null ? line['unitPrice'] : parsePaymentAmount('${v['unitPrice']}');
      if (price == null) throw FormProblem('Enter the price, for example 450 or 450.50.');
      return {
        ...line,
        'qty': qty,
        'unitPrice': price,
        'description': v['description'],
        'staffId': '${v['staffId']}'.isEmpty ? null : v['staffId'],
        if (serial) 'serials': splitList(v['serials']),
      };
    },
  );
}

/// Staff who can be named on a job or line (owners see all users; others see themselves).
List<(String, String)> staffOptions(AppState app) {
  final users = app.list('users');
  final me = app.session;
  return [
    for (final u in users)
      if (u['active'] != false) ('${u['id']}', '${u['name'] ?? u['email']}'),
    if (users.isEmpty && me != null) (me.userId, '${me.user['name'] ?? 'Me'}'),
  ];
}

/// The lines of an estimate or job, with edit and remove (phone: cards; wide: table).
class DocumentLines extends StatelessWidget {
  const DocumentLines({super.key, required this.lines, this.onChanged, this.job = false});
  final List<Json> lines;
  final ValueChanged<List<Json>>? onChanged;
  final bool job;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (lines.isEmpty) return const EmptyState(message: 'No parts or labour yet. Add or scan them.');
    return Column(children: [
      for (final (index, line) in lines.indexed)
        Card(
          child: ListTile(
            title: Text('${line['qty']} × ${line['name'] ?? app.productName('${line['productId']}')}'),
            subtitle: Text([
              lineKindLabel(line['kind']),
              if ('${line['description'] ?? ''}'.isNotEmpty) '${line['description']}',
              if (line['binId'] != null) 'Bin ${app.binName(app.binById('${line['binId']}'))}',
              if ((line['serials'] as List? ?? const []).isNotEmpty) 'Serials ${(line['serials'] as List).join(', ')}',
              if (line['staffId'] != null) 'By ${app.userName('${line['staffId']}')}',
            ].join(' · ')),
            trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
              Text(app.money(lineAmount(line)), style: const TextStyle(fontWeight: FontWeight.w700)),
              if (onChanged != null)
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onChanged!([...lines]..removeAt(index)),
                ),
            ]),
            onTap: onChanged == null
                ? null
                : () async {
                    final edited = await editLine(context, line, job: job);
                    if (edited != null) onChanged!([...lines]..[index] = edited);
                  },
          ),
        ),
    ]);
  }
}

/// Subtotal / tax / total block.
class DocumentTotals extends StatelessWidget {
  const DocumentTotals(this.doc, {super.key});
  final Json doc;
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    Widget row(String label, Object? value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label)),
            Text(app.money(value as num?), style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          row('Subtotal', doc['subtotal']),
          row('Tax', doc['tax']),
          if ((doc['core'] ?? 0) != 0) row('Core deposits', doc['core']),
          if ((doc['rounding'] ?? 0) != 0) row('Rounding', doc['rounding']),
          row('Total', doc['total'], bold: true),
        ]),
      ),
    );
  }
}
