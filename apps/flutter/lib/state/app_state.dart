import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/billing.dart';
import '../core/store.dart';

const allFeatures = ['transfers', 'fitment', 'offline', 'warranty'];

Json emptyCart() => {
      'transactionId': uuid(),
      'lines': <Json>[],
      'priceLevel': 'retail',
      'discount': 0,
      'vehicle': null,
      'customerId': '',
      'shiftId': '',
    };

class AppState extends ChangeNotifier {
  late LocalStore _store;
  bool ready = false;
  bool online = false;
  bool syncing = false;
  Session? session;
  Json connection = {'api': 'https://pos.cartunez.in/api/v1', 'organizationId': '', 'branchId': ''};
  Json snapshot = {};
  List<Json> pending = [];
  Json cart = emptyCart();
  String? lastSync;
  String? sessionProblem;

  /// This device's label printer (kept on the device, not the server).
  Json labelPrinter = {};
  Timer? _timer;
  Timer? _cartTimer;

  /// One-line messages for the snackbar; the shell listens to this.
  final messages = StreamController<String>.broadcast();
  void toast(String text) => messages.add(text);

  // ---------- lifecycle ----------
  Future<void> saveLabelPrinter(Json value) async {
    labelPrinter = value;
    await _store.write('label-printer', value);
    notifyListeners();
  }

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

  Future<void> init() async {
    _store = await LocalStore.open();
    final saved = await _store.read('connection');
    if (saved is Map) {
      connection = {...connection, ...Map<String, dynamic>.from(saved)};
    } else if (kIsWeb) {
      connection = await _installationDefaults();
    }
    final printer = await _store.read('label-printer');
    if (printer is Map) labelPrinter = Map<String, dynamic>.from(printer);
    session = Session.fromJson(await _store.read('session'));
    if (session != null) {
      final workspace = await _store.read(session!.scope);
      if (workspace is Map) {
        snapshot = Map<String, dynamic>.from(workspace['snapshot'] as Map? ?? {});
        pending = _jsonList(workspace['pending']);
        lastSync = workspace['lastSync'] as String?;
        if (workspace['cart'] is Map) cart = Map<String, dynamic>.from(workspace['cart'] as Map);
      } else {
        session = null;
      }
    }
    ready = true;
    notifyListeners();
    if (session != null) {
      unawaited(sync());
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => sync());
  }

  static List<Json> _jsonList(Object? value) =>
      (value as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _saveWorkspace() async {
    final s = session;
    if (s == null) return;
    await _store.write(s.scope, {
      'snapshot': snapshot,
      'pending': pending,
      'lastSync': lastSync,
      'cart': cart,
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
    session = next;
    snapshot = Map<String, dynamic>.from(boot);
    pending = previous is Map ? _jsonList(previous['pending']) : [];
    cart = previous is Map && previous['cart'] is Map
        ? Map<String, dynamic>.from(previous['cart'] as Map)
        : emptyCart();
    lastSync = DateTime.now().toIso8601String();
    online = true;
    sessionProblem = null;
    await _store.write('session', next.toJson());
    await _saveWorkspace();
    _startTimer();
    notifyListeners();
  }

  Future<void> logout() async {
    await _saveWorkspace();
    _timer?.cancel();
    session = null;
    snapshot = {};
    pending = [];
    cart = emptyCart();
    await _store.write('session', null);
    notifyListeners();
  }

  // ---------- server ----------
  Future<dynamic> api(String path, {Object? body, String? method}) {
    final s = session;
    if (s == null) throw ApiError('Sign in to continue.', 401);
    return request(s.api, s.token, path, body: body, method: method);
  }

  Future<void> sync({bool loud = false}) async {
    final s = session;
    if (s == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      for (final item in List<Json>.from(pending)) {
        if (item['status'] == 'awaiting-payment' || item['error'] != null) continue;
        try {
          await request(s.api, s.token, '/invoices', body: item['transaction']);
          pending.removeWhere((e) => e['transaction']['transactionId'] == item['transaction']['transactionId']);
        } on ApiError catch (error) {
          if (!error.rejected) rethrow;
          item['error'] = error.message;
        }
      }
      final boot = await request(s.api, s.token, '/bootstrap') as Map;
      snapshot = Map<String, dynamic>.from(boot);
      if (boot['user'] is Map) s.user = {...s.user, ...Map<String, dynamic>.from(boot['user'] as Map)};
      lastSync = DateTime.now().toIso8601String();
      online = true;
      sessionProblem = null;
      await _saveWorkspace();
      if (loud) toast('Up to date.');
    } on ApiError catch (error) {
      online = false;
      if (error.status == 401) {
        sessionProblem = 'Your session has ended. Sign in again; saved sales stay on this device.';
      }
    } on OfflineError {
      online = false;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Sends a change to the server with a stable transaction ID and retries once
  /// on a network failure, then refreshes the workspace.
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    final payload = {...body, 'transactionId': body['transactionId'] ?? uuid()};
    dynamic result;
    try {
      result = await api(path, body: payload);
    } on OfflineError {
      result = await api(path, body: payload);
    }
    await sync();
    if (message != null) toast(message);
    return result;
  }

  // ---------- cart ----------
  void updateCart(Json changes) {
    cart = {...cart, ...changes};
    notifyListeners();
    _cartTimer?.cancel();
    _cartTimer = Timer(const Duration(milliseconds: 300), _saveWorkspace);
  }

  void clearCart() => updateCart(emptyCart());

  Quote? get bill {
    try {
      return currentQuote();
    } catch (_) {
      return null;
    }
  }

  Quote currentQuote([Json? value]) => quote(value ?? cart, products,
      roundingIncrement: (settings['roundingIncrement'] ?? 1) as int,
      taxMode: '${settings['taxMode'] ?? 'exclusive'}');

  /// Saves the sale locally first so it survives a crash, then sends it.
  /// Returns the invoice, or null when it was kept for later sending.
  Future<Json?> checkout({required List<Json> tenders, String placeOfSupply = ''}) async {
    final s = session!;
    final bill = currentQuote();
    final shift = openShift;
    if (shift == null) throw ApiError('Open your shift before checkout.', 409);
    final transaction = {
      ...cart,
      'shiftId': shift['id'],
      'placeOfSupply': placeOfSupply.trim(),
      'catalogRevision': snapshot['catalogRevision'],
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      'tenders': tenders,
      'offline': false,
    };
    final awaiting = tenders.any((t) => t['type'] != 'Cash' && t['confirmed'] != true);
    final entry = {
      'transaction': transaction,
      'status': awaiting ? 'awaiting-payment' : 'pending',
      'total': bill.total,
      'createdAt': DateTime.now().toIso8601String(),
    };
    pending.add(entry);
    cart = emptyCart();
    await _saveWorkspace();
    notifyListeners();
    if (awaiting) {
      toast('Payment saved as pending. Confirm the provider reference in Settings › Sync & audit.');
      return null;
    }
    try {
      final invoice = await request(s.api, s.token, '/invoices', body: transaction) as Map;
      pending.removeWhere((e) => e['transaction']['transactionId'] == transaction['transactionId']);
      await _saveWorkspace();
      unawaited(sync());
      return Map<String, dynamic>.from(invoice);
    } on ApiError catch (error) {
      if (error.rejected) {
        pending.removeWhere((e) => e['transaction']['transactionId'] == transaction['transactionId']);
        cart = {
          ...transaction..remove('tenders'),
        };
        await _saveWorkspace();
        notifyListeners();
      }
      rethrow;
    } on OfflineError {
      online = false;
      notifyListeners();
      toast('No connection. The sale is saved and will be sent with the same number when back online.');
      return null;
    }
  }

  Future<void> confirmPayment(String transactionId, String reference) async {
    for (final item in pending) {
      if (item['transaction']['transactionId'] != transactionId) continue;
      item['status'] = 'pending';
      item['transaction']['tenders'] = [
        for (final t in item['transaction']['tenders'] as List)
          {...Map<String, dynamic>.from(t as Map), 'confirmed': true, 'reference': reference},
      ];
    }
    await _saveWorkspace();
    await sync();
  }

  Future<void> discardPending(String transactionId) async {
    pending.removeWhere((e) => e['transaction']['transactionId'] == transactionId);
    await _saveWorkspace();
    notifyListeners();
  }

  // ---------- derived data ----------
  Json get settings => Map<String, dynamic>.from(snapshot['settings'] as Map? ?? {});
  Json get business => Map<String, dynamic>.from(settings['business'] as Map? ?? {});
  List<Json> list(String key) => _jsonList(snapshot[key]);
  List<Json> get products => list('products');
  List<Json> get bins => list('locations');
  List<Json> get stock => list('stock');
  List<Json> get sellableBins => bins.where((b) => b['kind'] == 'sellable').toList();
  String get role => session?.role ?? '';
  bool get isManager => role == 'owner' || role == 'manager';
  bool get isOwner => role == 'owner';
  bool get canSell => isManager || role == 'cashier';
  bool get canStock => isManager || role == 'inventory';
  List<String> get tenderTypes =>
      ((settings['tenderTypes'] as List?) ?? const ['Cash', 'Card', 'UPI']).map((e) => '$e').toList();
  bool get gst => settings['taxScheme'] == 'india-gst';
  bool get usesIndiaBusinessTime => (settings['currency'] ?? 'INR') == 'INR';

  DateTime businessTime(DateTime instant) => instant.toUtc().add(
        usesIndiaBusinessTime ? const Duration(hours: 5, minutes: 30) : Duration.zero,
      );

  bool feature(String key) {
    final features = settings['features'];
    if (features is Map && features[key] == false) return false;
    return true;
  }

  Json? get openShift {
    for (final shift in list('shifts')) {
      if (shift['closedAt'] == null && shift['userId'] == session?.userId) return shift;
    }
    return null;
  }

  String money(num? minor, {String? currency}) {
    final format = NumberFormat.simpleCurrency(locale: 'en_IN', name: currency ?? '${settings['currency'] ?? 'INR'}');
    final value = (minor ?? 0) / 100;
    // Avoid showing "-₹0.00" when a calculation lands on negative zero.
    return format.format(value == 0 ? 0 : value);
  }

  String binName(Json? bin) => bin == null
      ? '—'
      : [bin['area'], bin['rack'], bin['shelf'], bin['bin']].where((e) => e != null && '$e'.isNotEmpty).join(' / ');

  Json? binById(String? id) {
    for (final bin in bins) {
      if (bin['id'] == id) return bin;
    }
    return null;
  }

  String locationName(String? id) => binById(id) == null ? (id ?? '—') : binName(binById(id));

  Json? productById(String? id) {
    for (final product in products) {
      if (product['id'] == id) return product;
    }
    return null;
  }

  String productName(String? id) => productById(id)?['name'] ?? id ?? '—';

  String userName(String? id) {
    if (id == null || id.isEmpty) return '—';
    if (id == session?.userId) return '${session!.user['name'] ?? session!.user['email']}';
    for (final user in list('users')) {
      if (user['id'] == id) return '${user['name'] ?? user['email']}';
    }
    return id;
  }

  String branchName(String? id) {
    for (final branch in list('branches')) {
      if (branch['id'] == id) return '${branch['name']}';
    }
    return id ?? '—';
  }

  Json? customerById(String? id) {
    for (final customer in list('customers')) {
      if (customer['id'] == id) return customer;
    }
    return null;
  }

  /// Stock that can be sold now: server snapshot, less sales waiting to send,
  /// plus anything reserved by the parked sale currently on the counter.
  int available(String productId, [String? binId]) {
    var physical = 0;
    for (final item in stock) {
      if (item['productId'] != productId) continue;
      if (binId != null ? item['binId'] != binId : binById(item['binId'])?['kind'] != 'sellable') continue;
      physical += (item['available'] ?? ((item['quantity'] ?? 0) - (item['reserved'] ?? 0))) as int;
    }
    var waiting = 0;
    for (final entry in pending) {
      for (final line in (entry['transaction']['lines'] as List)) {
        if (line['productId'] == productId && (binId == null || line['binId'] == binId)) {
          waiting += line['qty'] as int;
        }
      }
    }
    var reserved = 0;
    for (final hold in list('holds')) {
      if (hold['id'] != cart['holdId']) continue;
      for (final line in (hold['cart']['lines'] as List)) {
        if (line['productId'] == productId && (binId == null || line['binId'] == binId)) {
          reserved += line['qty'] as int;
        }
      }
    }
    return physical - waiting + reserved;
  }

  List<Json> returnsFor(String invoiceId) =>
      list('returns').where((r) => r['invoiceId'] == invoiceId).toList();

  int returnedQuantity(Json invoice, String lineId) {
    var total = 0;
    for (final credit in returnsFor('${invoice['id']}')) {
      for (final line in credit['lines'] as List) {
        if (line['lineId'] == lineId) total += (line['quantity'] ?? 0) as int;
      }
    }
    return total;
  }

  String invoiceStatus(Json invoice) {
    final credits = returnsFor('${invoice['id']}');
    if (credits.any((c) => c['voided'] == true)) return 'Voided';
    if (credits.isEmpty) return 'Finalized';
    var returned = 0, sold = 0;
    for (final c in credits) {
      for (final l in c['lines'] as List) {
        returned += (l['quantity'] ?? 0) as int;
      }
    }
    for (final l in invoice['lines'] as List) {
      sold += (l['qty'] ?? 0) as int;
    }
    return returned >= sold ? 'Returned' : 'Partially returned';
  }

  int expectedCash(Json shift) {
    var cash = (shift['openingCash'] ?? 0) as int;
    for (final sale in list('invoices').where((i) => i['shiftId'] == shift['id'])) {
      for (final t in sale['tenders'] as List) {
        if (t['type'] == 'Cash') cash += t['amount'] as int;
      }
      cash -= (sale['change'] ?? 0) as int;
    }
    for (final refund in [...list('returns'), ...list('coreReturns')]) {
      if (refund['shiftId'] == shift['id'] && (refund['refundType'] ?? 'Cash') == 'Cash') {
        cash -= (refund['total'] ?? 0) as int;
      }
    }
    return cash;
  }

  /// Barcodes first, then SKU, then manufacturer and cross references.
  List<Json> findByCode(String code) {
    final raw = code.trim();
    if (raw.isEmpty) return [];
    final gtin = canonicalGtin(scannedProductCode(raw));
    final barcodeMatches = products.where((p) => (p['barcodes'] as List? ?? const []).any((v) {
      final stored = '$v'.trim();
      return stored == raw || (gtin != null && canonicalGtin(stored) == gtin);
    })).toList();
    if (barcodeMatches.isNotEmpty) return barcodeMatches;
    final key = normalize(code);
    if (key.isEmpty) return [];
    bool exact(Iterable values) => values.any((v) => normalize(v) == key);
    final tiers = <bool Function(Json)>[
      (p) => exact([p['sku']]),
      (p) => exact([
            p['partNumber'],
            ...(p['oemReferences'] as List? ?? const []),
            ...(p['supplierReferences'] as List? ?? const []),
            ...(p['supersedes'] as List? ?? const []),
            ...(p['interchanges'] as List? ?? const []),
          ]),
    ];
    for (final tier in tiers) {
      final found = products.where(tier).toList();
      if (found.isNotEmpty) return found;
    }
    return [];
  }

  String? uniqueProductIdForCode(String code) {
    final matches = findByCode(code);
    return matches.length == 1 ? matches.single['id'] as String : null;
  }

  String? binIdForCode(String code) => bins.where((bin) => bin['id'] == code.trim()).firstOrNull?['id'] as String?;

  @override
  void dispose() {
    _timer?.cancel();
    _cartTimer?.cancel();
    messages.close();
    super.dispose();
  }
}
