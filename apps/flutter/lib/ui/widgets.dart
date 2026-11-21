import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/billing.dart';
import 'barcode_scan.dart';
import 'theme.dart';

String titleCase(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String humanize(String key) => key
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .replaceAll(RegExp(r'[-_]'), ' ')
    .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());

String formatDate(Object? value) {
  final date = DateTime.tryParse('${value ?? ''}');
  if (date == null) return '—';
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '${two(local.day)}/${two(local.month)}/${local.year}, $hour:${two(local.minute)} ${local.hour < 12 ? 'am' : 'pm'}';
}

List<String> splitList(Object? value) =>
    '${value ?? ''}'.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

String errorText(Object error) =>
    error is ApiError || error is OfflineError || error is BillingError || error is FormProblem
        ? error.toString()
        : 'Something went wrong: $error';

class FormProblem implements Exception {
  FormProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------- form dialog ----------------

enum FieldKind { text, number, signedNumber, money, multiline, select, checks, password, email, phone, date }

class FieldSpec {
  const FieldSpec(
    this.name,
    this.label, {
    this.kind = FieldKind.text,
    this.value,
    this.options = const [],
    this.required = false,
    this.advanced = false,
    this.help,
    this.suggestions = const [],
    this.barcodeInput = false,
    this.barcodeChoice,
  });
  final String name;
  final String label;
  final FieldKind kind;
  final Object? value;
  final List<(String, String)> options;
  final bool required;
  final bool advanced;
  final String? help;
  final List<String> suggestions;
  final bool barcodeInput;
  final String? Function(String code)? barcodeChoice;
}

/// Opens a form; [onSubmit] may throw to keep the dialog open with a message.
Future<T?> showFormDialog<T>(
  BuildContext context, {
  required String title,
  required List<FieldSpec> fields,
  required Future<T> Function(Json values) onSubmit,
  String submit = 'Save',
  Widget? header,
  bool expanded = false,
}) {
  return showDialog<T>(
    context: context,
    builder: (_) => _FormDialog<T>(
      title: title,
      fields: fields,
      onSubmit: onSubmit,
      submit: submit,
      header: header,
      expanded: expanded,
    ),
  );
}

class _FormDialog<T> extends StatefulWidget {
  const _FormDialog({
    required this.title,
    required this.fields,
    required this.onSubmit,
    required this.submit,
    this.header,
    this.expanded = false,
  });
  final String title;
  final List<FieldSpec> fields;
  final Future<T> Function(Json values) onSubmit;
  final String submit;
  final Widget? header;
  final bool expanded;
  @override
  State<_FormDialog<T>> createState() => _FormDialogState<T>();
}

class _FormDialogState<T> extends State<_FormDialog<T>> {
  final _form = GlobalKey<FormState>();
  final _text = <String, TextEditingController>{};
  final _values = <String, Object?>{};
  final _focus = <String, FocusNode>{};
  late bool _more = widget.expanded;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      switch (field.kind) {
        case FieldKind.select:
          final value = field.value == null ? null : '${field.value}';
          _values[field.name] = field.options.any((o) => o.$1 == value) ? value : null;
        case FieldKind.checks:
          _values[field.name] = {...(field.value as Iterable? ?? const []).map((e) => '$e')};
        default:
          final v = field.value;
          final text = v == null ? '' : v is double && v == v.roundToDouble() ? '${v.toInt()}' : '$v';
          _text[field.name] = TextEditingController(text: text);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) {
      if (widget.fields.any((f) => f.advanced && f.required)) setState(() => _more = true);
      return;
    }
    final values = <String, dynamic>{};
    for (final field in widget.fields) {
      values[field.name] = switch (field.kind) {
        FieldKind.select => _values[field.name] ?? '',
        FieldKind.checks => (_values[field.name] as Set<String>).toList(),
        _ => _text[field.name]!.text.trim(),
      };
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onSubmit(values);
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(FieldSpec field) {
    String? validate(String? value) {
      final text = (value ?? '').trim();
      if (field.required && text.isEmpty) return 'Required';
      if (text.isNotEmpty) {
        if (field.kind == FieldKind.signedNumber && int.tryParse(text) == null) return 'Enter a whole number';
        if (field.kind == FieldKind.number && (int.tryParse(text) ?? -1) < 0) return 'Enter a non-negative whole number';
        if (field.kind == FieldKind.money && parsePaymentAmount(text) == null) return 'Enter a valid amount';
      }
      return null;
    }

    final decoration = InputDecoration(labelText: field.label, helperText: field.help, helperMaxLines: 3);
    switch (field.kind) {
      case FieldKind.select:
        return DropdownButtonFormField<String>(
          key: field.barcodeChoice == null ? null : ValueKey((field.name, _values[field.name])),
          initialValue: _values[field.name] as String?,
          isExpanded: true,
          decoration: field.barcodeChoice == null ? decoration : decoration.copyWith(suffixIcon: IconButton(
            tooltip: 'Scan to select ${field.label.toLowerCase()}',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _busy ? null : () async {
              final scan = await requestBarcode(context);
              if (scan == null || !mounted) return;
              final choice = field.barcodeChoice!(scan);
              final valid = choice != null && field.options.any((option) => option.$1 == choice);
              setState(() {
                if (valid) _values[field.name] = choice;
                _error = valid ? null : 'That barcode does not uniquely match an available ${field.label.toLowerCase()}.';
              });
            },
          )),
          items: [for (final o in field.options) DropdownMenuItem(value: o.$1, child: Text(o.$2, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _values[field.name] = v),
          validator: (v) => field.required && (v == null || v.isEmpty) ? 'Required' : null,
        );
      case FieldKind.checks:
        final set = _values[field.name] as Set<String>;
        return InputDecorator(
          decoration: decoration.copyWith(filled: false, border: InputBorder.none),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final o in field.options)
              FilterChip(
                label: Text(o.$2),
                selected: set.contains(o.$1),
                onSelected: (on) => setState(() => on ? set.add(o.$1) : set.remove(o.$1)),
              ),
          ]),
        );
      default:
        final controller = _text[field.name]!;
        final input = TextFormField(
          controller: controller,
          decoration: field.barcodeInput ? decoration.copyWith(suffixIcon: IconButton(
            tooltip: 'Capture barcode',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () async {
              final scanned = await requestBarcode(context);
              if (scanned != null && mounted) {
                final code = scannedProductCode(scanned);
                final codes = splitList(controller.text);
                if (!codes.contains(code)) controller.text = [...codes, code].join(', ');
              }
            },
          )) : decoration,
          validator: validate,
          obscureText: field.kind == FieldKind.password,
          maxLines: field.kind == FieldKind.multiline ? 3 : 1,
          keyboardType: switch (field.kind) {
            FieldKind.number => TextInputType.number,
            FieldKind.signedNumber => const TextInputType.numberWithOptions(signed: true),
            FieldKind.money => const TextInputType.numberWithOptions(decimal: true),
            FieldKind.email => TextInputType.emailAddress,
            FieldKind.phone => TextInputType.phone,
            FieldKind.multiline => TextInputType.multiline,
            _ => TextInputType.text,
          },
          inputFormatters: field.kind == FieldKind.number
              ? [FilteringTextInputFormatter.digitsOnly]
              : field.kind == FieldKind.signedNumber
                  ? [TextInputFormatter.withFunction((old, next) => RegExp(r'^-?\d*$').hasMatch(next.text) ? next : old)]
              : field.kind == FieldKind.money
                  ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
                  : null,
          onFieldSubmitted: field.kind == FieldKind.multiline || field.barcodeInput ? null : (_) => _save(),
        );
        if (field.suggestions.isEmpty) return input;
        return RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: _focus.putIfAbsent(field.name, FocusNode.new),
          optionsBuilder: (value) => field.suggestions
              .where((s) => s.toLowerCase().contains(value.text.toLowerCase()) && s != value.text),
          fieldViewBuilder: (context, c, focus, submit) => TextFormField(
            controller: c,
            focusNode: focus,
            decoration: decoration,
            validator: validate,
          ),
          optionsViewBuilder: (context, select, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
                child: ListView(shrinkWrap: true, children: [
                  for (final o in options) ListTile(dense: true, title: Text(o), onTap: () => select(o)),
                ]),
              ),
            ),
          ),
        );
    }
  }

  static const _wideWidth = 720.0;

  Widget _grid(List<FieldSpec> fields, bool wide) {
    if (!wide || fields.length < 5) {
      return Column(children: [
        for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 14), child: _field(f)),
      ]);
    }
    // Dialogs size themselves from their content, so the width is fixed here
    // rather than measured (a LayoutBuilder cannot report intrinsic sizes).
    const half = (_wideWidth - 16) / 2;
    return Wrap(spacing: 16, runSpacing: 14, children: [
      for (final f in fields)
        SizedBox(width: f.kind == FieldKind.multiline || f.kind == FieldKind.checks ? _wideWidth : half, child: _field(f)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final basic = widget.fields.where((f) => !f.advanced).toList();
    final more = widget.fields.where((f) => f.advanced).toList();
    final screen = MediaQuery.sizeOf(context).width;
    final wide = basic.length > 6 && screen > 760;
    return PopScope(canPop: !_busy, child: AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: wide ? _wideWidth : 460,
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.header != null) ...[widget.header!, const SizedBox(height: 14)],
            if (basic.isNotEmpty) _grid(basic, wide),
            if (more.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _more = !_more),
                  icon: Icon(_more ? Icons.expand_less : Icons.expand_more),
                  label: Text(_more ? 'Fewer options' : 'More options (${more.length})'),
                ),
              ),
              Offstage(offstage: !_more, child: Padding(padding: const EdgeInsets.only(top: 6), child: _grid(more, wide))),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(widget.submit),
        ),
      ],
    ));
  }
}

// ---------------- data list ----------------

class Col {
  const Col(this.label, this.cell, {this.flex = 1, this.numeric = false});
  final String label;
  final Widget Function(Json row) cell;
  final int flex;
  final bool numeric;
}

/// A table on wide screens and stacked cards on phones.
class DataList extends StatelessWidget {
  const DataList({
    super.key,
    required this.rows,
    required this.columns,
    this.actions,
    this.empty = 'Nothing here yet.',
    this.onTap,
    this.actionWidth = 220,
    this.emptyAction, // UI polish: a way forward from an empty list
    this.dense = false, // UI polish: tighter table rows (wide layout)
  });
  final List<Json> rows;
  final List<Col> columns;
  final List<Widget> Function(Json row)? actions;
  final String empty;
  final void Function(Json row)? onTap;
  final double actionWidth;
  final Widget? emptyAction;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return EmptyState(message: empty, action: emptyAction);
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 700;
      if (narrow) {
        return Column(children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onTap == null ? null : () => onTap!(row),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        child: columns.first.cell(row),
                      ),
                      const SizedBox(height: 6),
                      for (final col in columns.skip(1))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(width: 110, child: Text(col.label, style: Theme.of(context).textTheme.bodySmall)),
                            Expanded(child: Align(alignment: Alignment.centerLeft, child: col.cell(row))),
                          ]),
                        ),
                      if (actions != null && actions!(row).isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: actions!(row)),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
        ]);
      }
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Container(
            color: const Color(0xFFF5F8F6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              for (final col in columns)
                Expanded(
                  flex: col.flex,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(col.label, textAlign: col.numeric ? TextAlign.right : TextAlign.left,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Brand.muted)),
                  ),
                ),
              if (actions != null) SizedBox(width: actionWidth),
            ]),
          ),
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) const Divider(),
            InkWell(
              onTap: onTap == null ? null : () => onTap!(row),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 6 : 12),
                child: Row(children: [
                  for (final col in columns)
                    Expanded(
                      flex: col.flex,
                      child: Align(
                        alignment: col.numeric ? Alignment.centerRight : Alignment.centerLeft,
                        child: Padding(padding: const EdgeInsets.only(right: 10), child: col.cell(row)),
                      ),
                    ),
                  if (actions != null)
                    SizedBox(
                    width: actionWidth,
                      child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: actions!(row)),
                    ),
                ]),
              ),
            ),
          ],
        ]),
      );
    });
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon = Icons.inbox_outlined, this.action});
  final String message;
  final IconData icon;

  /// UI polish: an optional button under the message (the next step).
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Column(children: [
            Icon(icon, size: 40, color: const Color(0xFF9CB1A5)),
            const SizedBox(height: 10),
            Text(message, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ]),
        ),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) {
    final key = label.toLowerCase();
    final (bg, fg) = switch (key) {
      'voided' || 'rejected' || 'returned' || 'disabled' || 'out of stock' => (const Color(0xFFFBEBE7), Brand.danger),
      'partially returned' || 'partial' || 'open' || 'sent' || 'dispatched' || 'low' || 'awaiting payment' =>
        (const Color(0xFFFDF3DF), Brand.warning),
      'closed' || 'settled' || 'received' => (const Color(0xFFEEF1EF), Brand.muted),
      _ => (Brand.mint, Brand.forest),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

class Metric extends StatelessWidget {
  const Metric(this.label, this.value, {super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF77AD91), width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            FittedBox(
              child: Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            ),
          ]),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?trailing,
        ]),
      );
}

class Toolbar extends StatelessWidget {
  const Toolbar(this.children, {super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 16), child: Wrap(spacing: 8, runSpacing: 8, children: children));
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Continue'}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return result == true;
}

List<(String, String)> optionsOf(List<Json> rows, [String Function(Json)? label]) =>
    [for (final r in rows) ('${r['id']}', label?.call(r) ?? '${r['name'] ?? r['number'] ?? r['id']}')];
