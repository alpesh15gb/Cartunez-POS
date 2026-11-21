import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../shell.dart';
import 'counter_actions.dart';
import 'counter_flow.dart';
import 'held_bills.dart';
import 'tender_sheet.dart';

// WS-A: keyboard-first counter. One map of keys, a help overlay listing them,
// small keycap badges on buttons, and a USB scanner guard.

/// The counter's key map, shown in the help overlay (?).
const counterKeyMap = <(String, String)>[
  ('F1', 'Search or scan a part'),
  ('F2', 'Customer and vehicle'),
  ('F4', 'Hold (park) this bill'),
  ('F5', 'Recall a held bill'),
  ('F6', 'Take payment'),
  ('F8', 'Discount'),
  ('F9', 'Exact cash: completes the sale'),
  ('F10', 'Split payment'),
  ('F12', 'Pay, save and print'),
  ('↑  ↓', 'Choose a cart line'),
  ('+  −', 'Change the chosen line\'s quantity'),
  ('Del', 'Remove the chosen line'),
  ('Esc', 'Clear the search, then the line choice'),
  ('?', 'Show these keys'),
];

/// Shared state of one counter screen: the cart line chosen with ↑/↓ and the
/// left pane (parts list, photo grid or service tiles).
class CounterController extends ChangeNotifier {
  int? selected;
  String pane = 'list';

  void select(int? index) {
    if (selected == index) return;
    selected = index;
    notifyListeners();
  }

  void setPane(String value) {
    if (pane == value) return;
    pane = value;
    notifyListeners();
  }
}

class CounterScope extends InheritedNotifier<CounterController> {
  const CounterScope({super.key, required CounterController controller, required super.child}) : super(notifier: controller);
  static CounterController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CounterScope>()?.notifier;
  static CounterController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CounterScope>()?.notifier;
}

/// Keyboard hints (F-keys, Ctrl shortcuts) are shown only at desktop widths;
/// phones and tablets are touch first.
bool showKeyHints(BuildContext context) => MediaQuery.sizeOf(context).width >= 1200;

/// A small keycap badge ("F9") for buttons. Shown on desktop only.
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key, this.onDark = false});
  final String label;
  final bool onDark;
  @override
  Widget build(BuildContext context) {
    if (!showKeyHints(context)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final fg = onDark ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: fg.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg, height: 1.2)),
    );
  }
}

/// Detects keyboard-wedge barcode scanners: characters arriving faster than a
/// person types, ending in Enter. A slow typist never produces a burst.
class ScanBurst {
  ScanBurst({this.maxGap = const Duration(milliseconds: 45), this.minLength = 4});
  final Duration maxGap;
  final int minLength;
  final _chars = StringBuffer();
  Duration? _last;

  void reset() {
    _chars.clear();
    _last = null;
  }

  void add(String char, Duration at) {
    if (_last != null && at - _last! > maxGap) _chars.clear();
    if (_chars.length < 512) _chars.write(char);
    _last = at;
  }

  /// Enter pressed: the scanned code, or null when this was ordinary typing.
  String? enter(Duration at) {
    final code = _chars.toString();
    final burst = code.length >= minLength && _last != null && at - _last! <= maxGap;
    reset();
    return burst ? code : null;
  }
}

final _clock = Stopwatch()..start();

/// Wraps the counter: global F-keys, line navigation and the scanner guard.
/// Registered as a [HardwareKeyboard] handler so it works while the cursor is
/// in the top search box (outside the counter's own focus tree).
class CounterKeyboard extends StatefulWidget {
  const CounterKeyboard({super.key, required this.controller, required this.child});
  final CounterController controller;
  final Widget child;

  /// Counter screens on screen; the shell leaves keys to them while > 0.
  static int active = 0;

  /// Time source for the scanner guard (tests replace it).
  static Duration Function() clock = () => _clock.elapsed;

  @override
  State<CounterKeyboard> createState() => _CounterKeyboardState();
}

class _CounterKeyboardState extends State<CounterKeyboard> {
  final _burst = ScanBurst();

  @override
  void initState() {
    super.initState();
    CounterKeyboard.active++;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    CounterKeyboard.active--;
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  ShellController? get _shell => context.getInheritedWidgetOfExactType<ShellScope>()?.notifier;

  /// Something (dialog, sheet, menu) is open above the counter.
  bool get _covered {
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return true;
    // Dialogs open on the root navigator, above a nested (router shell) one.
    final root = Navigator.maybeOf(context, rootNavigator: true);
    return root != null && route?.navigator != root && root.canPop();
  }

  EditableTextState? _field() {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return null;
    if (focus.widget is EditableText) return (focus as StatefulElement).state as EditableTextState;
    return focus.findAncestorStateOfType<EditableTextState>();
  }

  bool get _inSearch => _shell != null && _shell!.searchFocus.hasPrimaryFocus;

  /// True when a key like + or Del belongs to the cart, not to a text field.
  bool get _cartKeysFree {
    final field = _field();
    if (field == null) return true;
    return _inSearch && _shell!.search.text.isEmpty;
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent || !mounted) return false;
    final keyboard = HardwareKeyboard.instance;
    if (_covered || keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) {
      _burst.reset();
      return false;
    }
    final key = event.logicalKey;
    final now = CounterKeyboard.clock();
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final code = _burst.enter(now);
      if (code == null) return false;
      _routeScan(code);
      return true;
    }
    final char = event.character;
    if (char != null && char.length == 1 && (char.codeUnitAt(0) >= 32 || char == '\x1d')) _burst.add(char, now);
    final repeat = event is KeyRepeatEvent;
    final command = repeat ? null : _commands[key];
    if (command != null) {
      command();
      return true;
    }
    final lines = (context.appRead.cart['lines'] as List).length;
    final c = widget.controller;
    if ((key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) && lines > 0 && (_field() == null || _inSearch)) {
      final down = key == LogicalKeyboardKey.arrowDown;
      final current = c.selected;
      c.select(current == null ? (down ? 0 : lines - 1) : (current + (down ? 1 : -1)).clamp(0, lines - 1));
      return true;
    }
    if (repeat) return false;
    if (char == '?' && _field() == null) {
      showCounterKeys(context);
      return true;
    }
    final index = c.selected;
    if (index != null && index < lines && _cartKeysFree) {
      final qty = ((context.appRead.cart['lines'] as List)[index]['qty'] as int);
      if (key == LogicalKeyboardKey.numpadAdd || char == '+') {
        setLineQuantity(context, index, qty + 1);
        return true;
      }
      if (key == LogicalKeyboardKey.numpadSubtract || char == '-') {
        if (qty > 1) setLineQuantity(context, index, qty - 1);
        return true;
      }
      if (key == LogicalKeyboardKey.delete) {
        setLineQuantity(context, index, 0);
        c.select(lines - 1 == 0 ? null : index.clamp(0, lines - 2));
        return true;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_shell != null && _shell!.search.text.isNotEmpty) {
        _shell!.search.clear();
        return true;
      }
      if (c.selected != null) {
        c.select(null);
        return true;
      }
    }
    return false;
  }

  /// A scanner burst landed while the cursor was somewhere else: take the code
  /// back out of that field and add the part to the sale.
  void _routeScan(String code) {
    final field = _field();
    if (field != null) {
      final controller = field.widget.controller;
      final text = controller.text;
      final at = text.lastIndexOf(code);
      if (at >= 0) {
        controller.value = TextEditingValue(
          text: text.replaceRange(at, at + code.length, ''),
          selection: TextSelection.collapsed(offset: at),
        );
      }
    }
    final shell = _shell;
    if (shell == null) return;
    handleScan(context, shell, code);
  }

  late final Map<LogicalKeyboardKey, VoidCallback> _commands = {
    LogicalKeyboardKey.f1: () => focusScan(context),
    LogicalKeyboardKey.f2: () => editCustomerVehicle(context),
    LogicalKeyboardKey.f4: () => parkWithPrompt(context),
    LogicalKeyboardKey.f5: () {
      final shell = _shell;
      if (shell != null) showParked(context, shell);
    },
    LogicalKeyboardKey.f6: () => startCheckout(context),
    LogicalKeyboardKey.f8: () {
      if ((context.appRead.cart['lines'] as List).isNotEmpty) editDiscount(context);
    },
    LogicalKeyboardKey.f9: () => expressCash(context),
    LogicalKeyboardKey.f10: () => startCheckout(context, split: true),
    LogicalKeyboardKey.f12: () => startCheckout(context, print: true),
  };

  @override
  Widget build(BuildContext context) => CounterScope(controller: widget.controller, child: widget.child);
}

/// Puts the cursor in the search / scan box.
void focusScan(BuildContext context) {
  final shell = context.getInheritedWidgetOfExactType<ShellScope>()?.notifier;
  shell?.searchFocus.requestFocus();
}

/// The help overlay: every counter key on one card.
Future<void> showCounterKeys(BuildContext context) => showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Counter keys'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (key, label) in counterKeyMap)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                    width: 64,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(dialog).colorScheme.outline),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(key, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                    ),
                  ),
                  Expanded(child: Text(label)),
                ]),
              ),
            const SizedBox(height: 8),
            Text('A barcode scanner works wherever the cursor is.', style: Theme.of(dialog).textTheme.bodySmall),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close'))],
      ),
    );
