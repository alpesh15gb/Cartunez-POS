// WS-F: dense admin data grid.
//
// Sticky header, multi-column sort (click a header to sort by it; shift-click,
// or long-press on touch, to add it as a further sort key), client or server
// pagination, column visibility, search, row tap and keyboard use
// (Up/Down move, Enter opens, Page Up/Down change page, Home/End jump).
// Wide tables scroll sideways on phones instead of wrapping.
//
// Any list screen can adopt it: pass the rows and a list of [GridColumn]s.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';

class GridColumn {
  const GridColumn(this.key, this.label, {this.numeric = false, this.width, this.text, this.sortValue, this.cell, this.visible = true});

  /// Field in the row map (also the default sort and search value).
  final String key;
  final String label;
  final bool numeric;

  /// Fixed width in logical pixels; otherwise sized from the label and kind.
  final double? width;

  /// Display text for a row (defaults to the raw value).
  final String Function(Json row)? text;

  /// What to sort by (defaults to the raw value).
  final Comparable<Object?>? Function(Json row)? sortValue;

  /// Custom cell widget (defaults to [text]).
  final Widget Function(Json row)? cell;

  /// Shown until the user hides it.
  final bool visible;

  String display(Json row) => text?.call(row) ?? '${row[key] ?? ''}';
  double get preferredWidth => width ?? (numeric ? 120 : (label.length * 9.0 + 48).clamp(120, 260).toDouble());
}

class GridSort {
  const GridSort(this.key, this.ascending);
  final String key;
  final bool ascending;
}

/// Sorts [rows] by several columns, first key first. Nulls and blanks last.
List<Json> sortRows(List<Json> rows, List<GridSort> sorts, List<GridColumn> columns) {
  if (sorts.isEmpty) return rows;
  final byKey = {for (final c in columns) c.key: c};
  Object? valueOf(Json row, String key) => byKey[key]?.sortValue?.call(row) ?? row[key];
  int compare(Object? a, Object? b) {
    final aBlank = a == null || a == '', bBlank = b == null || b == '';
    if (aBlank || bBlank) return aBlank == bBlank ? 0 : (aBlank ? 1 : -1);
    if (a is num && b is num) return a.compareTo(b);
    if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
    if (a is Comparable && a.runtimeType == b.runtimeType) return a.compareTo(b);
    return '$a'.toLowerCase().compareTo('$b'.toLowerCase());
  }
  final indexed = rows.indexed.toList();
  indexed.sort((x, y) {
    for (final s in sorts) {
      final a = valueOf(x.$2, s.key), b = valueOf(y.$2, s.key);
      final blank = (a == null || a == '') != (b == null || b == '');
      final result = compare(a, b);
      // Blanks stay last whichever way the column is sorted.
      if (result != 0) return blank || s.ascending ? result : -result;
    }
    return x.$1.compareTo(y.$1); // stable
  });
  return [for (final e in indexed) e.$2];
}

class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.rows,
    required this.columns,
    this.onRowTap,
    this.pageSize = 25,
    this.searchable = true,
    this.searchHint = 'Search these rows',
    this.empty = 'Nothing to show.',
    this.height = 480,
    this.rowHeight = 38,
    this.totalRows,
    this.page = 0,
    this.onPage,
    this.toolbar = const [],
    this.storageKey,
  });

  /// Rows to show. In server mode ([onPage] set) these are the current page only.
  final List<Json> rows;
  final List<GridColumn> columns;
  final void Function(Json row)? onRowTap;
  final int pageSize;
  final bool searchable;
  final String searchHint;
  final String empty;

  /// Height of the scrolling body (the header stays above it).
  final double height;
  final double rowHeight;

  /// Server pagination: total rows on the server, the current page (0-based)
  /// and a callback to load another page. Sorting and search then apply to
  /// the loaded page.
  final int? totalRows;
  final int page;
  final ValueChanged<int>? onPage;

  /// Extra buttons at the end of the toolbar (exports, etc.).
  final List<Widget> toolbar;

  /// Remembers sort and hidden columns per key while the app runs.
  final String? storageKey;

  @override
  State<DataGrid> createState() => DataGridState();
}

final _remembered = <String, ({List<GridSort> sorts, Set<String> hidden})>{};

class DataGridState extends State<DataGrid> {
  List<GridSort> sorts = [];
  Set<String> hidden = {};
  String search = '';
  int localPage = 0;
  int? selected;
  final focus = FocusNode(debugLabel: 'data grid');
  final vertical = ScrollController();
  final horizontal = ScrollController();

  bool get serverPaged => widget.onPage != null;

  @override
  void initState() {
    super.initState();
    final saved = widget.storageKey == null ? null : _remembered[widget.storageKey];
    if (saved != null) {
      sorts = [...saved.sorts];
      hidden = {...saved.hidden};
    } else {
      hidden = {for (final c in widget.columns) if (!c.visible) c.key};
    }
  }

  @override
  void didUpdateWidget(DataGrid oldWidget) {
    final old = oldWidget;
    super.didUpdateWidget(old);
    if (old.storageKey != widget.storageKey) {
      final saved = widget.storageKey == null ? null : _remembered[widget.storageKey];
      sorts = [...?saved?.sorts];
      hidden = saved?.hidden ?? {for (final c in widget.columns) if (!c.visible) c.key};
      localPage = 0;
      selected = null;
    }
    // Parents often rebuild the row list; only a different set of rows clears the selection.
    if (old.rows.length != widget.rows.length || old.page != widget.page) {
      selected = null;
      if (!serverPaged && localPage * widget.pageSize >= widget.rows.length) localPage = 0;
    }
  }

  @override
  void dispose() {
    focus.dispose();
    vertical.dispose();
    horizontal.dispose();
    super.dispose();
  }

  void _remember() {
    if (widget.storageKey != null) _remembered[widget.storageKey!] = (sorts: [...sorts], hidden: {...hidden});
  }

  List<GridColumn> get visibleColumns => widget.columns.where((c) => !hidden.contains(c.key)).toList();

  /// Plain click: sort by this column only (asc, desc, off). Add: keep the others.
  void toggleSort(String key, {bool add = false}) => setState(() {
    final at = sorts.indexWhere((s) => s.key == key);
    final current = at < 0 ? null : sorts[at];
    final next = current == null ? GridSort(key, true) : current.ascending ? GridSort(key, false) : null;
    if (add) {
      if (at >= 0) sorts.removeAt(at);
      if (next != null) sorts.insert(at >= 0 ? at : sorts.length, next);
    } else {
      sorts = [?next];
    }
    localPage = 0;
    selected = null;
    _remember();
  });

  List<Json> get filtered {
    final q = search.trim().toLowerCase();
    final cols = visibleColumns;
    final rows = q.isEmpty
        ? widget.rows
        : widget.rows.where((r) => cols.any((c) => c.display(r).toLowerCase().contains(q))).toList();
    return sortRows(rows, sorts, widget.columns);
  }

  int get total => serverPaged ? (widget.totalRows ?? widget.rows.length) : filtered.length;
  int get page => serverPaged ? widget.page : localPage;
  int get pages => (total / widget.pageSize).ceil().clamp(1, 1 << 30);

  List<Json> get pageRows {
    final rows = filtered;
    if (serverPaged) return rows;
    return rows.skip(localPage * widget.pageSize).take(widget.pageSize).toList();
  }

  void goTo(int next) {
    if (next < 0 || next >= pages || next == page) return;
    if (serverPaged) {
      widget.onPage!(next);
    } else {
      setState(() => localPage = next);
    }
    setState(() => selected = null);
  }

  void _select(int index, int count) {
    if (count == 0) return;
    final i = index.clamp(0, count - 1);
    setState(() => selected = i);
    final top = i * widget.rowHeight;
    if (vertical.hasClients) {
      final view = vertical.position.viewportDimension;
      if (top < vertical.offset) {
        vertical.jumpTo(top);
      } else if (top + widget.rowHeight > vertical.offset + view) {
        vertical.jumpTo(top + widget.rowHeight - view);
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<Json> rows) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final at = selected ?? -1;
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(at + 1, rows.length);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _select(at < 0 ? 0 : at - 1, rows.length);
    } else if (key == LogicalKeyboardKey.home) {
      _select(0, rows.length);
    } else if (key == LogicalKeyboardKey.end) {
      _select(rows.length - 1, rows.length);
    } else if (key == LogicalKeyboardKey.pageDown) {
      goTo(page + 1);
    } else if (key == LogicalKeyboardKey.pageUp) {
      goTo(page - 1);
    } else if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) &&
        selected != null && selected! < rows.length) {
      widget.onRowTap?.call(rows[selected!]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _chooseColumns() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setInner) => AlertDialog(
        title: const Text('Columns'),
        content: SizedBox(
          width: 320,
          child: ListView(shrinkWrap: true, children: [
            for (final c in widget.columns)
              CheckboxListTile(
                dense: true,
                value: !hidden.contains(c.key),
                title: Text(c.label),
                // Keep at least one column.
                onChanged: !hidden.contains(c.key) && visibleColumns.length == 1 ? null : (v) {
                  setState(() => v == true ? hidden.remove(c.key) : hidden.add(c.key));
                  setInner(() {});
                  _remember();
                },
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final rows = pageRows;
    final cols = visibleColumns;
    final shiftHeld = HardwareKeyboard.instance.isShiftPressed;
    final toolbar = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (widget.searchable)
        SizedBox(
          width: 240,
          child: TextField(
            decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search, size: 18), hintText: widget.searchHint),
            onChanged: (v) => setState(() {
              search = v;
              localPage = 0;
              selected = null;
            }),
          ),
        ),
      OutlinedButton.icon(onPressed: _chooseColumns, icon: const Icon(Icons.view_column_outlined, size: 18),
          label: Text(hidden.isEmpty ? 'Columns' : 'Columns (${hidden.length} hidden)')),
      if (sorts.isNotEmpty)
        TextButton.icon(onPressed: () => setState(() { sorts = []; _remember(); }), icon: const Icon(Icons.sort, size: 18),
            label: Text('Clear sort (${sorts.length})')),
      ...widget.toolbar,
    ]);
    if (widget.rows.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        toolbar,
        Padding(padding: const EdgeInsets.symmetric(vertical: 32), child: Center(child: Text(widget.empty, style: text.bodySmall))),
      ]);
    }
    return LayoutBuilder(builder: (context, constraints) {
      final preferred = cols.fold<double>(0, (n, c) => n + c.preferredWidth);
      final available = constraints.maxWidth.isFinite ? constraints.maxWidth - 2 : preferred;
      final stretch = preferred < available ? available / preferred : 1.0;
      final widths = [for (final c in cols) c.preferredWidth * stretch];
      final tableWidth = widths.fold<double>(0, (n, w) => n + w);
      Widget header(int i) {
        final c = cols[i];
        final at = sorts.indexWhere((s) => s.key == c.key);
        final sort = at < 0 ? null : sorts[at];
        return Semantics(
          button: true,
          label: 'Sort by ${c.label}',
          child: InkWell(
            onTap: () => toggleSort(c.key, add: HardwareKeyboard.instance.isShiftPressed || shiftHeld),
            onLongPress: () => toggleSort(c.key, add: true),
            child: Container(
              width: widths[i],
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(c.label, overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700))),
                if (sort != null) ...[
                  Icon(sort.ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 14, key: ValueKey('sort-${c.key}')),
                  if (sorts.length > 1) Text('${at + 1}', style: text.labelSmall),
                ],
              ]),
            ),
          ),
        );
      }
      final bodyHeight = (rows.length * widget.rowHeight).clamp(widget.rowHeight, widget.height).toDouble();
      final grid = Scrollbar(
        controller: horizontal,
        child: SingleChildScrollView(
          controller: horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Sticky header: outside the vertical scroll.
              Container(
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest,
                    border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
                child: Row(children: [for (var i = 0; i < cols.length; i++) header(i)]),
              ),
              SizedBox(
                height: bodyHeight,
                child: ListView.builder(
                  controller: vertical,
                  itemExtent: widget.rowHeight,
                  itemCount: rows.length,
                  itemBuilder: (context, r) {
                    final row = rows[r];
                    final isSelected = selected == r;
                    return Material(
                      color: isSelected ? scheme.primaryContainer : (r.isOdd ? scheme.surfaceContainerLow : scheme.surface),
                      child: InkWell(
                        onTap: () {
                          setState(() => selected = r);
                          focus.requestFocus();
                          widget.onRowTap?.call(row);
                        },
                        child: Row(children: [
                          for (var i = 0; i < cols.length; i++)
                            Container(
                              width: widths[i],
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              alignment: cols[i].numeric ? Alignment.centerRight : Alignment.centerLeft,
                              child: cols[i].cell?.call(row) ??
                                  Text(cols[i].display(row), maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall?.copyWith(fontSize: 13,
                                          fontFeatures: cols[i].numeric ? const [FontFeature.tabularFigures()] : null)),
                            ),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );
      final start = total == 0 ? 0 : page * widget.pageSize + 1;
      final end = serverPaged ? page * widget.pageSize + widget.rows.length : (page * widget.pageSize + rows.length);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        toolbar,
        const SizedBox(height: 10),
        Focus(
          focusNode: focus,
          onKeyEvent: (node, event) => _onKey(node, event, rows),
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: grid),
          ),
        ),
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text('No rows match "$search".', style: text.bodySmall)),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Flexible(child: Text(
            total == 0 ? '0 rows' : '$start–$end of $total${search.isNotEmpty && serverPaged ? ' (search is on this page)' : ''}',
            key: const ValueKey('grid-range'), overflow: TextOverflow.ellipsis, style: text.bodySmall)),
          IconButton(tooltip: 'Previous page', onPressed: page == 0 ? null : () => goTo(page - 1), icon: const Icon(Icons.chevron_left)),
          IconButton(tooltip: 'Next page', onPressed: page + 1 >= pages ? null : () => goTo(page + 1), icon: const Icon(Icons.chevron_right)),
        ]),
      ]);
    });
  }
}
