import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../widgets.dart';

const _columns = 'sku,name,brand,category,unit,cost,retailPrice,taxPercent,barcodes,wholesalePrice,'
    'hsnSac,partNumber,reorderLevel,serialTracked,universal,type';
const _limit = 512 * 1024;

Future<void> importCatalog(BuildContext context) {
  final app = context.appRead;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AppScope(state: app, child: const _ImportDialog()),
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final input = TextEditingController();
  List<Json>? rows;
  String transactionId = uuid();
  String? error;
  bool busy = false;
  int page = 0;
  static const pageSize = 10;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void changed() => setState(() {
    rows = null;
    error = null;
    page = 0;
    transactionId = uuid();
  });

  Future<void> work(Future<void> Function() task) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(e);
          if (e is ApiError && e.status == 409) rows = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pick() => work(() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (!mounted || files.isEmpty) return;
    final file = files.single;
    if ((await file.length() ?? 0) > _limit) throw FormProblem('Choose a CSV up to 512 KiB.');
    final bytes = await file.readAsBytes();
    if (bytes.length > _limit) throw FormProblem('Choose a CSV up to 512 KiB.');
    final String csv;
    try {
      csv = utf8.decode(bytes);
    } on FormatException {
      throw FormProblem('Save the spreadsheet as UTF-8 CSV and choose it again.');
    }
    if (!mounted) return;
    input.text = csv;
    changed();
  });

  Future<void> preview() => work(() async {
    if (utf8.encode(input.text).length > _limit) throw FormProblem('Choose a CSV up to 512 KiB.');
    final result = await context.appRead.api('/products/import/preview', body: {'csv': input.text});
    if (!mounted) return;
    setState(() {
      rows = (result['rows'] as List).cast<Json>();
      page = 0;
    });
  });

  Future<void> submit() => work(() async {
    final app = context.appRead;
    final result = await app.mutate('/products/import', {'csv': input.text, 'transactionId': transactionId});
    if (!mounted) return;
    app.toast('Imported ${result['imported']} new ${result['imported'] == 1 ? 'part' : 'parts'}.');
    Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final previewRows = rows;
    final errors = previewRows?.where((row) => row['error'] != null).length ?? 0;
    final ready = previewRows != null && previewRows.isNotEmpty && errors == 0;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Import new parts'),
        content: SizedBox(width: 600, child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Use prices in ${app.settings['currency'] ?? 'INR'} and a tax percentage. Separate multiple barcodes with |. Keep codes as text to preserve leading zeros.'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: busy ? null : pick, child: const Text('Choose CSV')),
              TextButton(onPressed: busy ? null : () => work(() async {
                final result = await saveTextFile('catalog-template.csv', '\uFEFF$_columns\r\n');
                if (mounted) app.toast(result);
              }), child: const Text('Download template')),
            ]),
            const SizedBox(height: 8),
            TextField(controller: input, readOnly: busy, minLines: 3, maxLines: 5, keyboardType: TextInputType.multiline,
              onChanged: (_) => changed(), decoration: const InputDecoration(labelText: 'CSV contents', hintText: 'Choose a file or paste CSV here')),
            const SizedBox(height: 8),
            const Text('Include SKU, name, brand, category, unit, cost, retailPrice and taxPercent. Add opening stock in Inventory after importing.'),
            if (app.gst) const Text('HSN/SAC is required for this shop.'),
            if (app.noTax) const Text('This shop is not GST registered: every imported part gets tax 0.'),
            if (previewRows != null) ...[
              const Divider(),
              Text(errors == 0 ? '${previewRows.length} new ${previewRows.length == 1 ? 'part' : 'parts'} ready' : '$errors row(s) need correction',
                style: Theme.of(context).textTheme.titleSmall),
              for (final row in previewRows.skip(page * pageSize).take(pageSize))
                Padding(padding: const EdgeInsets.only(top: 5), child: Text(
                  "Row ${row['row']} · ${row['sku']} · ${row['name']} · ${row['error'] ?? app.money(row['retailPrice'] as num?)}",
                  style: row['error'] == null ? null : TextStyle(color: Theme.of(context).colorScheme.error))),
              if (previewRows.length > pageSize) Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                IconButton(tooltip: 'Previous rows', onPressed: page == 0 ? null : () => setState(() => page--), icon: const Icon(Icons.chevron_left)),
                Text('${page + 1} / ${(previewRows.length / pageSize).ceil()}'),
                IconButton(tooltip: 'Next rows', onPressed: (page + 1) * pageSize >= previewRows.length ? null : () => setState(() => page++), icon: const Icon(Icons.chevron_right)),
              ]),
            ],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        )),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          if (ready) FilledButton(onPressed: busy ? null : submit, child: Text('Import ${previewRows.length} ${previewRows.length == 1 ? 'part' : 'parts'}'))
          else FilledButton(onPressed: busy || input.text.trim().isEmpty ? null : preview, child: const Text('Preview')),
        ],
      ),
    );
  }
}
