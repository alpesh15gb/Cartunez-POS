import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/billing.dart';
import '../core/store.dart';

part 'cart_state.dart';
part 'catalog_state.dart';
part 'shift_state.dart';
part 'sync_state.dart';

const allFeatures = ['transfers', 'fitment', 'warranty', 'onlineStore', 'negativeStock'];

Json emptyCart() => {
      'transactionId': uuid(),
      'lines': <Json>[],
      'priceLevel': 'retail',
      'discount': 0,
      'vehicle': null,
      'customerId': '',
      'shiftId': '',
    };

/// The register, split into scoped controllers:
///
/// * [syncState]: session, server calls, the offline queue, online flag, toasts.
/// * [catalogState]: parts, bins, stock available to sell, code lookups, photos.
/// * [shiftState]: the cashier's open shift and the cash expected in the drawer.
/// * [cartState]: the sale on the counter, parking and checkout.
///
/// [AppState] owns them and forwards the old API so every screen keeps working.
/// It notifies when sync, catalog or shift data changes, but NOT when only the
/// cart changes: widgets that show the cart listen to [cartState] (or to
/// [CartState.terms] for price level / vehicle / customer), so scanning a
/// barcode rebuilds the cart pane and not the whole shell.
class AppState extends ChangeNotifier {
  AppState() {
    syncState.addListener(_relay);
    catalogState.addListener(_relay);
    shiftState.addListener(_relay);
  }

  late final SyncState syncState = SyncState._(this);
  late final CatalogState catalogState = CatalogState._(this);
  late final ShiftState shiftState = ShiftState._(this);
  late final CartState cartState = CartState._(this);

  void _relay() => notifyListeners();

  bool ready = false;
  String? startupProblem;

  /// This device's label printer (kept on the device, not the server).
  Json labelPrinter = {};

  // ---------- lifecycle ----------
  Future<void> saveLabelPrinter(Json value) async {
    labelPrinter = value;
    await syncState._store.write('label-printer', value);
    notifyListeners();
  }

  Future<void> init() async {
    startupProblem = null;
    try {
      await _load();
    } catch (_) {
      ready = false;
      startupProblem = 'Cannot open the saved register. Check browser storage permissions or disk space, then retry.';
      notifyListeners();
    }
  }

  Future<void> _load() async {
    final store = await LocalStore.open();
    syncState._store = store;
    await syncState._loadConnection();
    final printer = await store.read('label-printer');
    if (printer is Map) labelPrinter = Map<String, dynamic>.from(printer);
    await syncState._loadWorkspace();
    ready = true;
    notifyListeners();
    if (session != null) {
      unawaited(sync());
      syncState._startTimer();
    }
  }

  // ---------- sync (forwarded) ----------
  Session? get session => syncState.session;
  set session(Session? value) => syncState.session = value;
  Json get connection => syncState.connection;
  set connection(Json value) => syncState.connection = value;
  Json get snapshot => syncState.snapshot;
  set snapshot(Json value) => syncState.snapshot = value;
  List<Json> get pending => syncState.pending;
  set pending(List<Json> value) => syncState.pending = value;
  bool get online => syncState.online;
  set online(bool value) => syncState.online = value;
  bool get syncing => syncState.syncing;
  String? get lastSync => syncState.lastSync;
  set lastSync(String? value) => syncState.lastSync = value;
  String? get sessionProblem => syncState.sessionProblem;
  set sessionProblem(String? value) => syncState.sessionProblem = value;

  /// One-line messages for the snackbar; the shell listens to this.
  StreamController<String> get messages => syncState.messages;
  void toast(String text) => syncState.toast(text);

  Future<void> login({
    required String api,
    required String organizationId,
    required String branchId,
    required String email,
    required String password,
  }) =>
      syncState.login(api: api, organizationId: organizationId, branchId: branchId, email: email, password: password);

  Future<void> logout() => syncState.logout();

  Future<dynamic> api(String path, {Object? body, String? method}) => syncState.api(path, body: body, method: method);

  Future<void> sync({bool loud = false, bool afterMutation = false}) =>
      syncState.sync(loud: loud, afterMutation: afterMutation);

  /// Sends a change to the server with a stable transaction ID and retries once
  /// on a network failure, then refreshes the workspace.
  Future<dynamic> mutate(String path, Json body, [String? message]) => syncState.mutate(path, body, message);

  Future<void> confirmPayment(String transactionId, Json references) => syncState.confirmPayment(transactionId, references);
  Future<void> retryPendingPayment(Json item) => syncState.retryPendingPayment(item);

  Future<void> discardPending(String transactionId) => syncState.discardPending(transactionId);

  Json get settings => syncState.settings;
  List<Json> list(String key) => syncState.list(key);

  // ---------- cart (forwarded) ----------
  Json get cart => cartState.cart;
  void updateCart(Json changes) => cartState.updateCart(changes);
  void replaceCart(Json value) => cartState.replaceCart(value);
  void clearCart() => cartState.clearCart();
  Future<void> parkCart({Json meta = const {}}) => cartState.parkCart(meta: meta); // WS-A: hold label / reg no
  Quote? get bill => cartState.bill;
  Quote currentQuote([Json? value]) => cartState.currentQuote(value);

  /// Saves the sale locally first so it survives a crash, then sends it.
  /// Returns the invoice, or null when it was kept for later sending.
  Future<Json?> checkout({required List<Json> tenders, required int expectedTotal, String placeOfSupply = ''}) =>
      cartState.checkout(tenders: tenders, expectedTotal: expectedTotal, placeOfSupply: placeOfSupply);

  // ---------- catalog (forwarded) ----------
  List<Json> photosOf(String productId) => catalogState.photosOf(productId);
  Future<Uint8List> fileBytes(String fileId) => catalogState.fileBytes(fileId);
  Future<Uint8List> photoBytes(String imageId) => catalogState.photoBytes(imageId);
  List<Json> get products => catalogState.products;
  List<Json> get saleProducts => catalogState.saleProducts;
  List<Json> get stockParts => catalogState.stockParts;
  List<Json> get bins => catalogState.bins;
  List<Json> get stock => catalogState.stock;
  List<Json> get sellableBins => catalogState.sellableBins;
  String binName(Json? bin) => catalogState.binName(bin);
  Json? binById(String? id) => catalogState.binById(id);
  String locationName(String? id) => catalogState.locationName(id);
  Json? productById(String? id) => catalogState.productById(id);
  String productName(String? id) => catalogState.productName(id);

  /// Stock that can be sold now: server snapshot, less sales waiting to send,
  /// plus anything reserved by the parked sale currently on the counter.
  int available(String productId, [String? binId]) => catalogState.available(productId, binId);

  /// Barcodes first, then SKU, then manufacturer and cross references.
  List<Json> findByCode(String code, {bool forSale = false}) => catalogState.findByCode(code, forSale: forSale);
  String? uniqueProductIdForCode(String code) => catalogState.uniqueProductIdForCode(code);
  String? binIdForCode(String code) => catalogState.binIdForCode(code);

  // ---------- shifts (forwarded) ----------
  Json? get openShift => shiftState.openShift;
  int expectedCash(Json shift) => shiftState.expectedCash(shift);

  // ---------- shop facts ----------
  Json get business => Map<String, dynamic>.from(settings['business'] as Map? ?? {});
  String get role => session?.role ?? '';
  bool get isManager => role == 'owner' || role == 'manager';
  bool get isOwner => role == 'owner';
  bool get canSell => isManager || role == 'cashier';
  bool get canStock => isManager || role == 'inventory';
  List<String> get tenderTypes =>
      ((settings['tenderTypes'] as List?) ?? const ['Cash', 'Card', 'UPI']).map((e) => '$e').toList();
  bool get gst => settings['taxScheme'] == 'india-gst';
  /// "Not GST registered": bills carry final prices with no tax, GSTIN or HSN.
  bool get noTax => settings['taxScheme'] == 'none';
  bool get usesIndiaBusinessTime => (settings['currency'] ?? 'INR') == 'INR';

  DateTime businessTime(DateTime instant) => instant.toUtc().add(
        usesIndiaBusinessTime ? const Duration(hours: 5, minutes: 30) : Duration.zero,
      );

  bool feature(String key) {
    final features = settings['features'];
    // The online store is new: off until the owner switches it on.
    if (key == 'onlineStore') return features is Map && features[key] == true;
    if (features is Map && features[key] == false) return false;
    return true;
  }

  String money(num? minor, {String? currency}) {
    final format = NumberFormat.simpleCurrency(locale: 'en_IN', name: currency ?? '${settings['currency'] ?? 'INR'}');
    final value = (minor ?? 0) / 100;
    // Avoid showing "-₹0.00" when a calculation lands on negative zero.
    return format.format(value == 0 ? 0 : value);
  }

  /// What we owe a supplier, or what a customer owes us (negative = advance).
  int partyBalance(String kind, String? id) {
    final all = snapshot['partyBalances'];
    if (all is! Map || id == null) return 0;
    final map = all[kind];
    return map is Map ? ((map[id] as num?) ?? 0).toInt() : 0;
  }

  Json? supplierById(String? id) => list('suppliers').where((s) => s['id'] == id).firstOrNull;

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

  @override
  void dispose() {
    syncState.removeListener(_relay);
    catalogState.removeListener(_relay);
    shiftState.removeListener(_relay);
    syncState.dispose();
    cartState.dispose();
    catalogState.dispose();
    shiftState.dispose();
    super.dispose();
  }
}
