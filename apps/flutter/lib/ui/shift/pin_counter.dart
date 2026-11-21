// WS-D: PIN sign-in on an enrolled counter, and the quick "Switch user" lock.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/billing.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// This counter's PIN sign-in set-up (server, organization, branch, device and
/// its secret key), kept on the device only.
class PinCounter {
  PinCounter._();
  static const storeKey = 'pin-counter';

  /// Tests replace these to avoid real storage.
  static Future<Json?> Function() load = () async {
    final value = await (await LocalStore.open()).read(storeKey);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  };
  static Future<void> Function(Json? value) save = (value) async => (await LocalStore.open()).write(storeKey, value);

  /// Staff tiles for the sign-in screen.
  static Future<Json> staff(Json counter) async => Map<String, dynamic>.from(await request(
        '${counter['api']}', '', '/auth/pin-staff',
        body: {'organizationId': counter['organizationId'], 'deviceId': counter['deviceId'], 'deviceKey': counter['key']},
      ) as Map);

  /// Signs [userId] in with [pin] and opens their workspace (their own saved cart).
  static Future<void> signIn(AppState app, Json counter, String userId, String pin) async {
    final api = '${counter['api']}';
    final auth = await request(api, '', '/auth/pin-login', body: {
      'organizationId': counter['organizationId'],
      'deviceId': counter['deviceId'],
      'deviceKey': counter['key'],
      'userId': userId,
      'pin': pin,
    }) as Map;
    await app.syncState.adoptSession(api, '${auth['organizationId']}', '${auth['branchId']}', auth);
  }
}

/// True for the lock shortcut: Ctrl+L or F11.
bool isLockShortcut(KeyEvent event) =>
    event is KeyDownEvent &&
    (event.logicalKey == LogicalKeyboardKey.f11 ||
        (event.logicalKey == LogicalKeyboardKey.keyL && HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isAltPressed));

/// Locks the counter for the next person. The cart on the counter is saved
/// with the person who built it and comes back when they sign in again;
/// sales waiting to send stay on this device.
Future<void> lockCounter(AppState app) async {
  if (app.session == null) return;
  final lines = (app.cart['lines'] as List? ?? const []).length;
  final waiting = app.pending.length;
  await app.logout();
  if (lines > 0 || waiting > 0) {
    app.sessionProblem = [
      if (lines > 0) 'The cart ($lines item${lines == 1 ? '' : 's'}) is kept for when you sign in again.',
      if (waiting > 0) '$waiting sale${waiting == 1 ? '' : 's'} waiting to send stay${waiting == 1 ? 's' : ''} on this counter.',
    ].join(' ');
  }
}

/// Numeric keypad with dots for a 4–6 digit PIN. Digits also work from a keyboard.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onSubmit, this.busy = false, this.error, this.minLength = 4, this.maxLength = 6});

  /// Called with the PIN when the person presses OK (or Enter).
  final ValueChanged<String> onSubmit;
  final bool busy;
  final String? error;
  final int minLength;
  final int maxLength;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String pin = '';
  final _focus = FocusNode(debugLabel: 'pin pad');

  @override
  void didUpdateWidget(PinPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rejected PIN clears the dots for the next try.
    if (widget.error != null && widget.error != oldWidget.error) pin = '';
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _digit(String d) {
    if (widget.busy || pin.length >= widget.maxLength) return;
    setState(() => pin += d);
  }

  void _back() {
    if (pin.isEmpty || widget.busy) return;
    setState(() => pin = pin.substring(0, pin.length - 1));
  }

  void _ok() {
    if (widget.busy || pin.length < widget.minLength) return;
    widget.onSubmit(pin);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final char = event.character;
    if (char != null && RegExp(r'^\d$').hasMatch(char)) {
      _digit(char);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _ok();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {VoidCallback? onTap, Widget? child, String? semantics}) => Padding(
          padding: const EdgeInsets.all(5),
          child: SizedBox(
            width: 76,
            height: 60,
            child: Semantics(
              label: semantics ?? label,
              button: true,
              child: OutlinedButton(
                key: ValueKey('pin-key-$label'),
                style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                onPressed: widget.busy ? null : onTap,
                child: child ?? Text(label),
              ),
            ),
          ),
        );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          label: '${pin.length} of up to ${widget.maxLength} digits entered',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < widget.maxLength; i++)
              Container(
                key: ValueKey('pin-dot-$i'),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < pin.length ? scheme.primary : Colors.transparent,
                  border: Border.all(color: i < widget.minLength || i < pin.length ? scheme.primary : scheme.outlineVariant, width: 2),
                ),
              ),
          ]),
        ),
        SizedBox(
          height: 34,
          child: Center(
            child: widget.busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : widget.error == null
                    ? const SizedBox.shrink()
                    : Text(widget.error!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
          ),
        ),
        for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _digit(d))]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          key('back', onTap: _back, child: const Icon(Icons.backspace_outlined), semantics: 'Delete last digit'),
          key('0', onTap: () => _digit('0')),
          key('ok', onTap: pin.length >= widget.minLength ? _ok : null, child: const Icon(Icons.check), semantics: 'Sign in'),
        ]),
      ]),
    );
  }
}

/// Staff tiles, then the PIN pad, for a PIN counter's sign-in screen.
class PinSignIn extends StatefulWidget {
  const PinSignIn({super.key, required this.counter, required this.onUseEmail, this.loadStaff, this.signIn});
  final Json counter;
  final VoidCallback onUseEmail;

  /// Overridable for tests.
  final Future<Json> Function(Json counter)? loadStaff;
  final Future<void> Function(String userId, String pin)? signIn;

  @override
  State<PinSignIn> createState() => _PinSignInState();
}

class _PinSignInState extends State<PinSignIn> {
  Json? _tiles;
  String? _problem;
  Json? _chosen;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _problem = null);
    try {
      final tiles = await (widget.loadStaff ?? PinCounter.staff)(widget.counter);
      if (mounted) setState(() => _tiles = tiles);
    } catch (error) {
      if (mounted) {
        setState(() => _problem = error is ApiError && error.status == 401
            ? 'This counter is no longer set up for PIN sign-in. Sign in with email, then turn it on again in People › Staff.'
            : errorText(error));
      }
    }
  }

  Future<void> _submit(String pin) async {
    final user = _chosen;
    if (user == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = context.appRead;
      await (widget.signIn ?? (id, p) => PinCounter.signIn(app, widget.counter, id, p))('${user['id']}', pin);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staff = (_tiles?['staff'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final chosen = _chosen;
    final emailLink = TextButton.icon(
      onPressed: widget.onUseEmail,
      icon: const Icon(Icons.mail_outline, size: 18),
      label: const Text('Sign in with email instead'),
    );
    final Widget body;
    if (chosen != null) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          IconButton(
            tooltip: 'Back to staff',
            onPressed: _busy ? null : () => setState(() {
              _chosen = null;
              _error = null;
            }),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(child: Text('${chosen['name']}', style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 4),
        Text('Enter your PIN', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        PinPad(onSubmit: _submit, busy: _busy, error: _error),
      ]);
    } else if (_problem != null) {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_problem!, style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      ]);
    } else if (_tiles == null) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else if (staff.isEmpty) {
      body = const Text('No one has a PIN yet. An owner or manager sets PINs in People › Staff.');
    } else {
      body = Wrap(spacing: 10, runSpacing: 10, children: [
        for (final user in staff)
          SizedBox(
            width: 120,
            height: 104,
            child: Card(
              margin: EdgeInsets.zero,
              child: InkWell(
                key: ValueKey('staff-tile-${user['id']}'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() {
                  _chosen = user;
                  _error = null;
                }),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    CircleAvatar(
                      backgroundColor: Brand.lime,
                      foregroundColor: Brand.ink,
                      child: Text(initials('${user['name']}'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(height: 8),
                    Text('${user['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(titleCase('${user['role']}'), style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
            ),
          ),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(chosen == null ? 'Who is at the counter?' : 'Sign in', style: theme.textTheme.headlineMedium),
      const SizedBox(height: 4),
      Text(
        context.app.sessionProblem ??
            '${widget.counter['deviceName'] ?? 'This counter'} · ${_tiles?['branchName'] ?? widget.counter['branchId'] ?? ''}',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 18),
      Center(child: body),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerLeft, child: emailLink),
    ]);
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

// ---------------- set-up (People › Staff) ----------------

/// Turns this device into a PIN counter for the current branch (owner/manager).
Future<void> setUpPinCounter(BuildContext context) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'PIN sign-in on this counter',
    submit: 'Turn on',
    header: const Text('Staff with a PIN can then sign in here by tapping their name and entering their PIN. '
        'Owners and anyone on another device still sign in with email and password.'),
    fields: const [FieldSpec('name', 'Counter name', value: 'Front counter', required: true)],
    onSubmit: (values) async {
      final s = app.session;
      if (s == null) throw FormProblem('Sign in first.');
      final device = await app.api('/devices/enroll', body: {'name': values['name'], 'offlineAllowed': false}) as Map;
      final key = await app.api('/devices/${device['id']}/pin-key', body: {'reason': 'PIN counter'}) as Map;
      await PinCounter.save({
        'api': s.api,
        'organizationId': key['organizationId'] ?? s.organizationId,
        'branchId': key['branchId'] ?? s.branchId,
        'deviceId': key['deviceId'],
        'deviceName': key['deviceName'] ?? values['name'],
        'key': key['key'],
      });
      unawaited(app.sync());
      app.toast('PIN sign-in is on for this counter. Use Switch user (Ctrl+L) to lock it.');
    },
  );
}

Future<void> turnOffPinCounter(BuildContext context, Json counter) async {
  final app = context.appRead;
  if (!await confirm(context, 'Turn off PIN sign-in here?', 'Staff will need email and password on this counter.', action: 'Turn off')) return;
  try {
    if (counter['branchId'] == app.session?.branchId) {
      await app.api('/devices/${counter['deviceId']}/pin-key', body: {'disable': true});
    }
  } catch (error) {
    app.toast('Turned off on this counter. The server could not be told: ${errorText(error)}');
  }
  await PinCounter.save(null);
  app.toast('PIN sign-in is off for this counter.');
}

/// Set or remove a staff member's counter PIN.
Future<void> editPin(BuildContext context, Json user) async {
  final app = context.appRead;
  await showFormDialog<void>(
    context,
    title: 'PIN for ${user['name']}',
    submit: 'Save PIN',
    header: const Text('4 to 6 digits. Used only on counters with PIN sign-in turned on, in this branch.'),
    fields: const [
      FieldSpec('pin', 'New PIN', kind: FieldKind.password, required: true),
      FieldSpec('again', 'Repeat PIN', kind: FieldKind.password, required: true),
    ],
    onSubmit: (v) async {
      final pin = '${v['pin']}'.trim();
      if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) throw FormProblem('PIN must be 4 to 6 digits.');
      if (pin != '${v['again']}'.trim()) throw FormProblem('The two PINs do not match.');
      // Sent without a transaction ID so no request fingerprint of the PIN is kept.
      await app.api('/users/${user['id']}/pin', body: {'pin': pin});
      await app.sync();
      app.toast('PIN saved for ${user['name']}.');
    },
  );
}

Future<void> removePin(BuildContext context, Json user) async {
  final app = context.appRead;
  if (!await confirm(context, 'Remove PIN?', '${user['name']} will need email and password to sign in.', action: 'Remove PIN')) return;
  try {
    await app.api('/users/${user['id']}/pin', body: {'clear': true});
    await app.sync();
    app.toast('PIN removed.');
  } catch (error) {
    app.toast(errorText(error));
  }
}
