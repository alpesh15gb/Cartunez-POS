// WS-F: Owner command center (shown at /dashboard to owners and managers).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';

/// "1 bill", "3 bills".
String plural(Object? count, String one, [String? many]) {
  final n = count is num ? count : num.tryParse('${count ?? 0}') ?? 0;
  return '$n ${n == 1 ? one : many ?? '${one}s'}';
}

/// Live overview for the owner: tills, today's sales and margin by hour, stock
/// alerts, online orders, customer dues, shift variances and top items. Polls
/// the server every [refreshEvery] while the screen is visible and the app is
/// in the foreground. Every tile opens the workspace behind it.
class CommandCenter extends StatefulWidget {
  const CommandCenter({super.key, this.refreshEvery = const Duration(seconds: 45), this.onOpen});
  final Duration refreshEvery;

  /// Where a tile goes (defaults to the router). Tests pass their own.
  final ValueChanged<String>? onOpen;

  @override
  State<CommandCenter> createState() => CommandCenterState();
}

class CommandCenterState extends State<CommandCenter> with WidgetsBindingObserver {
  Json? data;
  String? problem;
  bool loading = false;
  int deadDays = 90;
  Timer? timer;
  bool foreground = true;
  DateTime? loadedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(widget.refreshEvery, (_) => _tick());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasAway = !foreground;
    foreground = state == AppLifecycleState.resumed;
    if (foreground && wasAway) load();
  }

  /// Only refresh while someone can see it.
  void _tick() {
    if (!mounted || !foreground || loading) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    load();
  }

  Future<void> load() async {
    final app = context.appRead;
    setState(() => loading = true);
    try {
      final result = await app.api('/dashboard?deadDays=$deadDays');
      if (!mounted) return;
      setState(() {
        data = Map<String, dynamic>.from(result as Map);
        problem = null;
        loadedAt = DateTime.now();
      });
    } catch (error) {
      if (mounted) setState(() => problem = errorText(error));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void open(String path) => widget.onOpen != null ? widget.onOpen!(path) : context.go(path);

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final d = data;
    final text = Theme.of(context).textTheme;
    final header = Row(children: [
      Expanded(child: Text(
        d == null
            ? (problem == null ? 'Loading today…' : 'Could not load the dashboard.')
            : 'Today ${formatDate(d['day'])} · updated ${loadedAt == null ? '' : TimeOfDay.fromDateTime(app.businessTime(loadedAt!)).format(context)} · '
                'refreshes every ${widget.refreshEvery.inSeconds} s',
        style: text.bodySmall)),
      if (loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      IconButton(tooltip: 'Refresh now', onPressed: loading ? null : load, icon: const Icon(Icons.refresh)),
    ]);
    if (d == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        if (problem != null) ...[
          Text(problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: load, child: const Text('Try again'))),
        ],
      ]);
    }
    List<Json> rows(Object? v) => [for (final r in (v as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    Json part(String key) => Map<String, dynamic>.from(d[key] as Map? ?? const {});
    final today = part('today');
    final tills = rows(d['tills']);
    final now = DateTime.now();
    bool overdue(Json till) {
      final openedAt = DateTime.tryParse('${till['openedAt'] ?? ''}');
      return openedAt != null && now.difference(openedAt) >= const Duration(days: 1);
    }
    final overdueCount = tills.where(overdue).length;
    final low = part('lowStock');
    final dead = part('deadStock');
    final online = part('onlineOrders');
    final dues = part('customerDues');
    final variances = rows(d['varianceShifts']);
    final top = rows(d['topItems']);
    num n(Object? v) => v is num ? v : 0;
    String time(Object? iso) {
      final t = DateTime.tryParse('${iso ?? ''}');
      if (t == null) return '—';
      final b = app.businessTime(t);
      return '${b.hour.toString().padLeft(2, '0')}:${b.minute.toString().padLeft(2, '0')}';
    }
    final marginPct = n(today['net']) > 0 ? ' (${(n(today['margin']) * 100 / n(today['net'])).toStringAsFixed(1)}%)' : '';

    final tiles = <_Tile>[
      _Tile(
        key: const ValueKey('tile-tills'),
        title: 'Till watch',
        value: tills.isEmpty ? 'No till open' : [
          '${tills.length} open',
          '${app.money(tills.fold<num>(0, (sum, till) => sum + n(till['cashOnHand'])))} in drawers',
          if (overdueCount > 0) '$overdueCount overdue',
        ].join(' · '),
        icon: Icons.point_of_sale_outlined,
        tone: overdueCount > 0 ? _Tone.warn : _Tone.ok,
        onTap: () => open('/shift'),
        children: [
          for (final t in tills)
            _Line('${t['counter']}${t['counter'] == t['userName'] ? '' : ' · ${t['userName']}'}', app.money(n(t['cashOnHand'])),
                sub: '${overdue(t) ? 'Overdue (24 h or more) · ' : ''}'
                    'Open since ${formatDate(t['openedAt'], inTimeZone: app.businessTime)}'
                    ' · ${plural(t['sales'], 'sale')} · last ${time(t['lastSaleAt'])}', maxSubLines: 3),
          if (tills.isEmpty) const _Line('Open a shift on the counter to start selling.', ''),
        ],
      ),
      _Tile(
        key: const ValueKey('tile-sales'),
        title: 'Sales and margin today',
        value: '${app.money(n(today['net']))} · ${plural(today['sales'], 'bill')}',
        icon: Icons.show_chart,
        wide: true,
        onTap: () => open('/reports/daily-sales'),
        children: [
          _Line('Margin', '${app.money(n(today['margin']))}$marginPct'),
          if (n(today['returns']) > 0) _Line('Refunds', app.money(n(today['returns']))),
          const SizedBox(height: 8),
          SizedBox(height: 150, child: HourlyChart(rows(d['hourly']), money: (v) => app.money(v))),
        ],
      ),
      _Tile(
        key: const ValueKey('tile-low'),
        title: 'Running low',
        value: plural(low['count'] ?? 0, 'part'),
        icon: Icons.trending_down,
        tone: n(low['count']) > 0 ? _Tone.warn : _Tone.ok,
        onTap: () => open('/reports/low-stock'),
        children: [
          for (final r in rows(low['rows']).take(5))
            _Line('${r['name']}', '${r['available']} left', sub: 'Reorder at ${r['reorderLevel']} · ${r['onOrder']} on order'),
        ],
      ),
      _Tile(
        key: const ValueKey('tile-dead'),
        title: 'Dead stock',
        value: '${plural(dead['count'] ?? 0, 'part')} · ${app.money(n(dead['value']))}',
        icon: Icons.inventory_outlined,
        tone: n(dead['count']) > 0 ? _Tone.warn : _Tone.ok,
        onTap: () => open('/reports/slow-moving'),
        trailing: DropdownButton<int>(
          value: deadDays,
          isDense: true,
          underline: const SizedBox(),
          items: [for (final days in const [30, 60, 90, 180, 365]) DropdownMenuItem(value: days, child: Text('$days days'))],
          onChanged: (v) {
            if (v == null) return;
            setState(() => deadDays = v);
            load();
          },
        ),
        children: [
          Text('No sale in ${dead['days'] ?? deadDays} days, and stock older than that.', style: text.bodySmall),
          for (final r in rows(dead['rows']).take(5)) _Line('${r['name']}', app.money(n(r['value'])), sub: '${r['quantity']} in stock'),
        ],
      ),
      if (app.feature('onlineStore'))
        _Tile(
          key: const ValueKey('tile-online'),
          title: 'Online orders waiting',
          value: '${online['pending'] ?? 0} · ${app.money(n(online['value']))}',
          icon: Icons.shopping_bag_outlined,
          tone: n(online['awaitingStock']) > 0 ? _Tone.warn : _Tone.ok,
          onTap: () => open('/orders/online'),
          children: [
            if (n(online['awaitingStock']) > 0) _Line('Waiting for stock', '${online['awaitingStock']}'),
            for (final r in rows(online['rows'])) _Line('#${r['number']} ${r['customer']}', app.money(n(r['total'])), sub: '${r['state']}'),
          ],
        ),
      _Tile(
        key: const ValueKey('tile-dues'),
        title: 'Customer dues',
        value: '${app.money(n(dues['total']))} · ${plural(dues['customers'] ?? 0, 'customer')}',
        icon: Icons.account_balance_wallet_outlined,
        onTap: () => open('/people/customers'),
        children: [for (final r in rows(dues['rows'])) _Line('${r['name']}', app.money(n(r['balance'])))],
      ),
      _Tile(
        key: const ValueKey('tile-variance'),
        title: 'Shift cash differences (7 days)',
        value: variances.isEmpty ? 'All balanced' : plural(variances.length, 'shift'),
        icon: Icons.rule,
        tone: variances.isEmpty ? _Tone.ok : _Tone.alert,
        onTap: () => open('/reports/shifts'),
        children: [
          for (final r in variances.take(5))
            _Line('${r['userName']}', '${n(r['variance']) > 0 ? 'Over' : 'Short'} ${app.money(n(r['variance']).abs())}',
                sub: 'Closed ${formatDate(r['closedAt'])}'),
        ],
      ),
      _Tile(
        key: const ValueKey('tile-top'),
        title: 'Top items today',
        value: top.isEmpty ? 'No sales yet' : '${top.first['name']}',
        icon: Icons.star_outline,
        onTap: () => open('/reports/fast-moving'),
        children: [for (final r in top) _Line('${r['name']}', app.money(n(r['revenue'])), sub: '${r['quantity']} sold')],
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      if (problem != null)
        Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text('Showing the last figures. $problem', style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (n(d['pendingConflicts']) > 0)
        Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text('${d['pendingConflicts']} offline sale conflict(s) need review and are not counted.')),
      LayoutBuilder(builder: (context, c) {
        final columns = c.maxWidth >= 1100 ? 3 : c.maxWidth >= 640 ? 2 : 1;
        const gap = 12.0;
        if (columns == 1) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, t) in tiles.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : gap), child: t),
          ]);
        }
        // Masonry: each tile goes under the shortest column so far (heights
        // estimated from content), which leaves no holes between tiles.
        final stacks = [for (var i = 0; i < columns; i++) <Widget>[]];
        final heights = List<double>.filled(columns, 0);
        for (final t in tiles) {
          var at = 0;
          for (var i = 1; i < columns; i++) {
            if (heights[i] < heights[at] - 1) at = i;
          }
          stacks[at].add(Padding(padding: EdgeInsets.only(bottom: gap), child: t));
          heights[at] += t.estimatedHeight + gap;
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < columns; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: stacks[i])),
          ],
        ]);
      }),
    ]);
  }
}

enum _Tone { ok, warn, alert }

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.title, required this.value, required this.icon, required this.onTap,
    this.children = const [], this.tone = _Tone.ok, this.wide = false, this.trailing});
  final String title, value;
  final IconData icon;
  final VoidCallback onTap;
  final List<Widget> children;
  final _Tone tone;
  final bool wide;
  final Widget? trailing;

  /// Rough height for the masonry layout: header and value, plus each line.
  double get estimatedHeight =>
      90 + children.fold<double>(0, (h, c) => h + (c is SizedBox ? (c.height ?? 0) : c is _Line ? (c.sub == null ? 24 : 40) : 22));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = switch (tone) { _Tone.ok => const Color(0xFF77AD91), _Tone.warn => Brand.warning, _Tone.alert => scheme.error };
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: accent, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: text.bodySmall, overflow: TextOverflow.ellipsis)),
              ?trailing,
              const Icon(Icons.chevron_right, size: 18),
            ]),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            if (children.isNotEmpty) const SizedBox(height: 8),
            ...children,
          ]),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.sub, this.maxSubLines = 1});
  final String label, value;
  final String? sub;
  final int maxSubLines;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
          if (sub != null) Text(sub!, maxLines: maxSubLines, overflow: TextOverflow.ellipsis, style: text.bodySmall),
        ])),
        if (value.isNotEmpty)
          Padding(padding: const EdgeInsets.only(left: 8), child: Text(value, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
      ]),
    );
  }
}

/// Today's net sales (bars) and margin (line) by hour, drawn with CustomPaint:
/// one small chart does not justify adding a charting package.
class HourlyChart extends StatelessWidget {
  const HourlyChart(this.hours, {super.key, required this.money});
  final List<Json> hours;
  final String Function(num) money;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    num v(Json h, String k) => h[k] is num ? h[k] as num : 0;
    final active = [for (final h in hours) if (v(h, 'sales') > 0 || v(h, 'net') != 0) v(h, 'hour').toInt()];
    // Shop hours: at least 09:00-21:00, wider when there were sales outside them.
    final first = math.min(9, active.isEmpty ? 9 : active.reduce(math.min));
    final last = math.max(21, active.isEmpty ? 21 : active.reduce(math.max));
    final shown = [for (final h in hours) if (v(h, 'hour') >= first && v(h, 'hour') <= last) h];
    final best = hours.fold<num>(0, (m, h) => math.max(m, v(h, 'net')));
    final label = Theme.of(context).textTheme.labelSmall;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final marginColor = dark ? const Color(0xFFFFC266) : Brand.warning;
    return Semantics(
      label: 'Sales by hour. Best hour ${money(best)}.',
      child: Column(children: [
        Expanded(child: CustomPaint(size: Size.infinite,
            painter: _HourlyPainter(shown, bar: scheme.primary, line: marginColor, grid: scheme.outlineVariant))),
        const SizedBox(height: 4),
        Row(children: [
          Text('${first.toString().padLeft(2, '0')}:00', style: label),
          Expanded(child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, color: scheme.primary),
            Text(' Sales  ', style: label),
            Container(width: 10, height: 2, color: marginColor),
            Text(' Margin', style: label),
          ])))),
          Text('${last.toString().padLeft(2, '0')}:00', style: label),
        ]),
      ]),
    );
  }
}

class _HourlyPainter extends CustomPainter {
  _HourlyPainter(this.hours, {required this.bar, required this.line, required this.grid});
  final List<Json> hours;
  final Color bar, line, grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (hours.isEmpty) return;
    num v(Json h, String k) => h[k] is num ? h[k] as num : 0;
    final top = hours.fold<num>(1, (m, h) => math.max(m, math.max(v(h, 'net'), v(h, 'margin'))));
    final bottom = hours.fold<num>(0, (m, h) => math.min(m, math.min(v(h, 'net'), v(h, 'margin'))));
    final span = (top - bottom).toDouble();
    double y(num value) => size.height - (value - bottom) / span * size.height;
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), Paint()..color = grid);
    final slot = size.width / hours.length;
    final barPaint = Paint()..color = bar;
    final path = Path();
    for (final (i, h) in hours.indexed) {
      final left = i * slot + slot * 0.15;
      canvas.drawRect(Rect.fromLTRB(left, math.min(y(v(h, 'net')), y(0)), left + slot * 0.7, math.max(y(v(h, 'net')), y(0))), barPaint);
      final point = Offset(i * slot + slot / 2, y(v(h, 'margin')));
      i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_HourlyPainter old) => old.hours != hours || old.line != line || old.bar != bar || old.grid != grid;
}
