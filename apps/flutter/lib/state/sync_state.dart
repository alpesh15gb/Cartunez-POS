part of 'app_state.dart';

/// Session, server calls, the offline sales queue, the online flag and the
/// 15-second refresh. Notifies on session, connection and sync-status changes;
/// when the server data (snapshot) or the queue changes it also pokes the
/// catalog and shift controllers so their listeners refresh.
class SyncState extends ChangeNotifier {
  SyncState._(this._app);
  final AppState _app;

  late LocalStore _store;
  bool online = false;
  Future<void>? _syncTask;
  bool get syncing => _syncTask != null;
  Session? session;
  Json connection = {'api': 'https://pos.cartunez.in/api/v1', 'organizationId': '', 'branchId': ''};
  Json snapshot = {};
  List<Json> pending = [];
  String? lastSync;
  String? sessionProblem;
  Timer? _timer;

  /// One-line messages for the snackbar; the shell listens to this.
  final messages = StreamController<String>.broadcast();
  void toast(String text) => messages.add(text);

  Json get settings => Map<String, dynamic>.from(snapshot['settings'] as Map? ?? {});
  List<Json> list(String key) => _jsonList(snapshot[key]);

  Object? _seenSnapshot;
  int _seenPending = 0;
  Session? _seenSession;

  /// Notifies sync listeners, and the catalog/shift controllers when the data
  /// they derive from (snapshot, queue, signed-in cashier) has changed.
  void _changed() {
    if (!identical(_seenSnapshot, snapshot) || _seenPending != pending.length || !identical(_seenSession, session)) {
      _seenSnapshot = snapshot;
      _seenPending = pending.length;
      _seenSession = session;
      _app.catalogState._touch();
      _app.shiftState._touch();
    }
    notifyListeners();
  }

  // ---------- lifecycle ----------
  /// On the web the app is served by the shop server itself, so it signs in to
  /// that same server. installation.json (written by the VPS release) adds the
  /// organization and branch codes.
  Future<Json> _installationDefaults() async {
    final defaults = {...connection, 'api': '${Uri.base.origin}/api/v1'};
    try {
      final data = await fetchJson(Uri.base.resolve('/installation.json'));
      if (data is Map) {
        return {
          ...defaults,
          if (data['apiUrl'] is String) 'api': data['apiUrl'],
          if (data['organizationId'] is String) 'organizationId': data['organizationId'],
          if (data['branchId'] is String) 'branchId': data['branchId'],
        };
      }
    } catch (_) {}
    return defaults;
  }

  Future<void> _loadConnection() async {
    final saved = await _store.read('connection');
    if (saved is Map) {
      connection = {...connection, ...Map<String, dynamic>.from(saved)};
    } else if (kIsWeb) {
      connection = await _installationDefaults();
    }
  }

  Future<void> _loadWorkspace() async {
    session = Session.fromJson(await _store.read('session'));
    if (session != null && !_validSession(session!)) {
      session = null;
      sessionProblem = 'Sign in again to open your saved register.';
    }
    if (session != null) {
      final workspace = await _store.read(session!.scope);
      if (workspace is Map) {
        snapshot = Map<String, dynamic>.from(workspace['snapshot'] as Map? ?? {});
        pending = _jsonList(workspace['pending']);
        lastSync = workspace['lastSync'] as String?;
        if (workspace['cart'] is Map) _app.cartState._restore(Map<String, dynamic>.from(workspace['cart'] as Map));
      } else {
        session = null;
      }
    }
    _changed();
  }

  bool _validSession(Session s) =>
      DateTime.tryParse(s.expiresAt)?.isAfter(DateTime.now()) == true;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _app.sync());
  }

  Future<void> _saveWorkspace() async {
    final s = session;
    if (s == null) return;
    await _store.write(s.scope, {
      'snapshot': snapshot,
      'pending': pending,
      'lastSync': lastSync,
      'cart': _app.cartState.cart,
    });
  }

  // ---------- session ----------
  Future<void> login({
    required String api,
    required String organizationId,
    required String branchId,
    required String email,
    required String password,
  }) async {
    final address = api.trim().replaceAll(RegExp(r'/+$'), '');
    final auth = await request(address, '', '/auth/login', body: {
      'email': email.trim(),
      'password': password,
      'organizationId': organizationId.trim(),
      'branchId': branchId.trim(),
    }) as Map;
    final next = Session(
      api: address,
      token: '${auth['token']}',
      user: Map<String, dynamic>.from(auth['user'] as Map),
      branchId: '${auth['branchId']}',
      organizationId: '${auth['organizationId']}',
      expiresAt: '${auth['expiresAt']}',
    );
    connection = {'api': address, 'organizationId': organizationId.trim(), 'branchId': branchId.trim()};
    await _store.write('connection', connection);
    final boot = await request(address, next.token, '/bootstrap') as Map;
    final previous = await _store.read(next.scope);
    _app.catalogState._photoCache.clear();
    session = next;
    snapshot = Map<String, dynamic>.from(boot);
    pending = previous is Map ? _jsonList(previous['pending']) : [];
    _app.cartState._restore(previous is Map && previous['cart'] is Map
        ? Map<String, dynamic>.from(previous['cart'] as Map)
        : emptyCart());
    lastSync = DateTime.now().toIso8601String();
    online = true;
    sessionProblem = null;
    await _store.write('session', next.toJson());
    await _saveWorkspace();
    _startTimer();
    _changed();
  }

  Future<void> logout() async {
    final saved = _saveWorkspace();
    _timer?.cancel();
    _app.catalogState._photoCache.clear();
    _syncTask = null;
    online = false;
    lastSync = null;
    session = null;
    snapshot = {};
    pending = [];
    _app.cartState._reset();
    final signedOut = _store.write('session', null);
    _changed();
    await Future.wait([saved, signedOut]);
  }

  // ---------- server ----------
  Future<dynamic> api(String path, {Object? body, String? method}) {
    final s = session;
    if (s == null) throw ApiError('Sign in to continue.', 401);
    return request(s.api, s.token, path, body: body, method: method);
  }

  Future<void> sync({bool loud = false, bool afterMutation = false}) async {
    final s = session;
    if (s == null) return;
    if (!_validSession(s)) {
      sessionProblem = 'Your session expired. Sign in again to open your saved register.';
      await _app.logout();
      return;
    }
    final active = _syncTask;
    if (active != null) {
      await active;
      if (afterMutation && identical(s, session)) await _app.sync(loud: loud);
      return;
    }
    final task = _refresh(s, loud);
    _syncTask = task;
    _changed();
    try {
      await task;
    } finally {
      if (identical(_syncTask, task)) {
        _syncTask = null;
        _changed();
      }
    }
  }

  Future<void> _refresh(Session s, bool loud) async {
    try {
      for (final item in List<Json>.from(pending)) {
        if (!identical(session, s)) return;
        if (item['transaction']['transactionId'] == _app.cartState._posting ||
            item['status'] == 'awaiting-payment' || item['error'] != null) {
          continue;
        }
        try {
          await request(s.api, s.token, '/invoices', body: item['transaction']);
          if (!identical(session, s)) return;
          pending.remove(item);
        } on ApiError catch (error) {
          if (!error.rejected) rethrow;
          if (!identical(session, s)) return;
          item['error'] = error.message;
        }
      }
      final boot = await request(s.api, s.token, '/bootstrap') as Map;
      if (!identical(session, s)) return;
      snapshot = Map<String, dynamic>.from(boot);
      if (boot['user'] is Map) s.user = {...s.user, ...Map<String, dynamic>.from(boot['user'] as Map)};
      lastSync = DateTime.now().toIso8601String();
      online = true;
      sessionProblem = null;
      try {
        await _saveWorkspace();
      } catch (_) {
        _app.toast('Register refreshed, but local storage is full or unavailable. Check free space on this counter.');
        return;
      }
      if (loud) _app.toast('Up to date.');
    } on ApiError catch (error) {
      if (!identical(session, s)) return;
      online = false;
      if (error.status == 401) {
        sessionProblem = 'Your session has ended. Sign in again to open your saved register.';
        await _app.logout();
      }
    } on OfflineError {
      if (identical(session, s)) online = false;
    }
  }

  /// Sends a change to the server with a stable transaction ID and retries once
  /// on a network failure, then refreshes the workspace.
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    final payload = {...body, 'transactionId': body['transactionId'] ?? uuid()};
    final s = session;
    dynamic result;
    try {
      result = await _app.api(path, body: payload);
    } on OfflineError {
      if (!identical(session, s)) rethrow;
      result = await _app.api(path, body: payload);
    }
    if (!identical(session, s)) return result;
    await _app.sync(afterMutation: true);
    if (message != null) _app.toast(message);
    return result;
  }

  // ---------- offline queue ----------
  Future<void> confirmPayment(String transactionId, Json references) async {
    for (final item in pending) {
      if (item['transaction']['transactionId'] != transactionId) continue;
      item['status'] = 'pending';
      item['transaction']['tenders'] = [
        for (final t in item['transaction']['tenders'] as List)
          if (t['type'] != 'Cash' && t['confirmed'] != true)
            {...Map<String, dynamic>.from(t as Map), 'confirmed': true, 'reference': references[t['type']]}
          else Map<String, dynamic>.from(t as Map),
      ];
    }
    await _saveWorkspace();
    await _app.sync(afterMutation: true);
  }

  Future<void> discardPending(String transactionId) async {
    pending.removeWhere((e) => e['transaction']['transactionId'] == transactionId);
    await _saveWorkspace();
    _changed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    messages.close();
    super.dispose();
  }
}

List<Json> _jsonList(Object? value) =>
    (value as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
