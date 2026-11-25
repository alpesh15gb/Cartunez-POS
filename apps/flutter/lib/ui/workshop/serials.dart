// WS-C (workshop): serial / IMEI warranty lookup (Catalog & stock › Warranty).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../barcode_scan.dart';
import '../widgets.dart';

class SerialLookupScreen extends StatefulWidget {
  const SerialLookupScreen({super.key});
  @override
  State<SerialLookupScreen> createState() => _SerialLookupScreenState();
}

class _SerialLookupScreenState extends State<SerialLookupScreen> {
  final code = TextEditingController();
  List<Json>? rows;
  String? problem;
  bool busy = false;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> _lookup([String? value]) async {
    final serial = (value ?? code.text).trim();
    if (serial.isEmpty) {
      setState(() => problem = 'Scan or type a serial number.');
      return;
    }
    code.text = serial;
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      final result = await context.appRead.api('/serials/lookup?code=${Uri.encodeQueryComponent(serial)}') as Map;
      if (!mounted) return;
      setState(() => rows = [for (final r in result['rows'] as List) Map<String, dynamic>.from(r as Map)]);
    } catch (e) {
      if (mounted) setState(() => problem = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (app.canStock && app.feature('warranty'))
        Toolbar([OutlinedButton.icon(
          onPressed: () => context.go('/catalog/warranty'),
          icon: const Icon(Icons.assignment_return_outlined),
          label: const Text('Claims & core refunds'),
        )]),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('serial-code'),
            controller: code,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Serial number or IMEI',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: ValueListenableBuilder(
                valueListenable: code,
                builder: (_, v, _) => v.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear serial number',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          code.clear();
                          problem = null;
                        }),
                      ),
              ),
            ),
            onSubmitted: _lookup,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'Scan',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () async {
            final scanned = await requestBarcode(context);
            if (scanned != null) await _lookup(scanned);
          },
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: busy ? null : _lookup, child: const Text('Look up')),
      ]),
      if (problem != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      if (rows != null && rows!.isEmpty)
        const EmptyState(message: 'No part with that serial number. Check the number on the label.'),
      for (final r in rows ?? const <Json>[])
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${r['product']?['name'] ?? 'Unknown part'} · ${r['serial']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                StatusChip(titleCase('${r['warranty']}')),
              ]),
              const SizedBox(height: 6),
              Text('Stock status: ${titleCase('${r['status']}')}'),
              if (r['soldAt'] != null) Text('Sold ${formatDate(r['soldAt'])}${r['invoice'] == null ? '' : ' on ${r['invoice']['number']}'}'),
              if (r['warrantyUntil'] != null) Text('Warranty until ${formatDate(r['warrantyUntil'])} (${r['product']?['warrantyMonths'] ?? 0} months)'),
              if (r['customer'] != null) Text('Customer: ${r['customer']['name']} ${r['customer']['phone'] ?? ''}'),
              if (r['vehicle'] != null) Text('Vehicle: ${r['vehicle']['regNo']} ${r['vehicle']['make'] ?? ''} ${r['vehicle']['model'] ?? ''}'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (r['invoice']?['id'] != null)
                  OutlinedButton.icon(
                    onPressed: () => context.go('/orders/invoices/${r['invoice']['id']}'),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: Text(r['canReturn'] == true && app.canSell ? 'Open invoice to return / RMA' : 'Open invoice'),
                  ),
                if (r['vehicle'] != null)
                  TextButton(onPressed: () => context.go('/people/vehicles/${r['vehicle']['id']}'), child: const Text('Open vehicle')),
              ]),
            ]),
          ),
        ),
    ]);
  }
}
