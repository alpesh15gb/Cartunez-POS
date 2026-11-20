import 'package:flutter/material.dart';

import '../../main.dart';
import 'catalog_import.dart';
import 'labels.dart';
import 'physical_count.dart';
import 'tender_comparison.dart';

// Workspace pages for tools that run as dialogs (catalog import, stock counts,
// labels, tender comparison), so each one has its own address and nav entry.

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.icon, required this.title, required this.body, required this.actions});
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              ]),
              const SizedBox(height: 8),
              Text(body, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ]),
          ),
        ),
      ),
    );
  }
}

class CatalogImportPage extends StatelessWidget {
  const CatalogImportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return _ToolCard(
      icon: Icons.upload_file,
      title: 'Import parts from a CSV file',
      body: app.online
          ? 'Add or update many parts at once from a spreadsheet saved as CSV. You can check every row before it is saved.'
          : 'Importing needs a connection to the shop server. Reconnect, then try again.',
      actions: [
        FilledButton.icon(
          onPressed: app.online ? () => importCatalog(context) : null,
          icon: const Icon(Icons.upload_file),
          label: const Text('Choose CSV file'),
        ),
      ],
    );
  }
}

class StockCountsPage extends StatelessWidget {
  const StockCountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final open = app.list('stockCounts').length;
    return _ToolCard(
      icon: Icons.fact_check_outlined,
      title: 'Physical stock counts',
      body: 'Count one part in one bin; a manager reviews the difference before stock is adjusted.'
          '${open == 0 ? '' : ' $open count${open == 1 ? '' : 's'} open.'}',
      actions: [
        FilledButton.icon(
          onPressed: app.online ? () => startPhysicalCount(context) : null,
          icon: const Icon(Icons.add),
          label: const Text('Start a count'),
        ),
        OutlinedButton(
          onPressed: app.online && open > 0 ? () => openPhysicalCounts(context) : null,
          child: const Text('Open counts'),
        ),
      ],
    );
  }
}

class LabelsPage extends StatelessWidget {
  const LabelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final parts = app.products.where((p) => p['type'] != 'service').toList();
    return _ToolCard(
      icon: Icons.qr_code_2,
      title: labelPrinterSummary(app),
      body: 'Labels show ${labelDesignSummary(app)}. Print one part from Parts, or every part here.',
      actions: [
        FilledButton.icon(
          onPressed: parts.isEmpty ? null : () => printLabels(context, [for (final p in parts) productLabel(app, p)]),
          icon: const Icon(Icons.print_outlined),
          label: Text('Print labels for all parts (${parts.length})'),
        ),
        OutlinedButton(onPressed: () => editLabelDesign(context), child: Text(app.isOwner ? 'Design label' : 'View design')),
        OutlinedButton(onPressed: () => editLabelPrinter(context), child: const Text('Printer')),
        OutlinedButton(onPressed: () => printTestLabel(context), child: const Text('Print test label')),
      ],
    );
  }
}

class TenderComparisonPage extends StatelessWidget {
  const TenderComparisonPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _ToolCard(
      icon: Icons.compare_arrows,
      title: 'Compare a bank or UPI statement',
      body: 'Match card and UPI payments taken at the counter against the statement from your bank or payment app.',
      actions: [
        FilledButton.icon(
          onPressed: () => compareTenderStatement(context),
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare statement'),
        ),
      ],
    );
  }
}
