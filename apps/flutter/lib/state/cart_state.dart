part of 'app_state.dart';

/// Fires when the cart's pricing terms change: price level, vehicle, customer
/// or the parked sale it resumes. The catalog grid listens to this instead of
/// the whole cart, so adding a line does not rebuild every part card.
class CartTerms extends ChangeNotifier {
  CartTerms._();
  void _changed() => notifyListeners();
}

/// The sale on the counter: lines, terms, parking (holds) and checkout.
/// Notifies on every cart change; [AppState] does not, so only widgets that
/// listen here rebuild while a cashier scans.
class CartState extends ChangeNotifier {
  CartState._(this._app);
  final AppState _app;

  Json cart = emptyCart();
  final terms = CartTerms._();
  String? _posting;
  String? _releasingHold;
  bool _parking = false;
  Timer? _cartTimer;

  static const _termKeys = ['priceLevel', 'vehicle', 'customerId', 'holdId'];

  List<Map> get lines => (cart['lines'] as List).cast<Map>();
  int get units => (cart['lines'] as List).fold<int>(0, (total, line) => total + (line['qty'] as int));
  Set<String> get pendingHoldIds => {
    for (final payment in _app.syncState.pending)
      if (payment['transaction']['holdId'] is String) payment['transaction']['holdId'] as String,
  };

  void updateCart(Json changes) {
    final next = {...cart, ...changes};
    if (!_same(cart['customerId'], next['customerId'])) next.remove('discountApprovalId');
    replaceCart(next);
  }

  void replaceCart(Json value) {
    _set(Map<String, dynamic>.from(value));
    _cartTimer?.cancel();
    _cartTimer = Timer(const Duration(milliseconds: 300), _app.syncState._saveWorkspace);
  }

  void clearCart() => replaceCart(emptyCart());

  Future<void> discardCart() async {
    final draft = cart;
    final holdId = '${draft['holdId'] ?? ''}';
    if (_parking) throw ApiError('Wait for this bill to finish holding before clearing it.', 409);
    if (holdId.isEmpty) {
      clearCart();
      return;
    }
    if (!_app.syncState.online) throw OfflineError('Reconnect to release this held bill before clearing it.');
    if (_releasingHold != null) throw ApiError('A held bill is already being released.', 409);
    final cashier = _app.session;
    _releasingHold = holdId;
    try {
      try {
        await _app.api('/holds/$holdId', method: 'DELETE');
      } on ApiError catch (error) {
        // Another counter may already have removed or billed this hold.
        if (error.status != 404) rethrow;
      }
      if (!identical(cashier, _app.session)) return;
      if (identical(cart, draft)) {
        clearCart();
      } else if (cart['holdId'] == holdId) {
        updateCart({'holdId': null});
      }
      await _app.sync(afterMutation: true);
    } finally {
      if (identical(cashier, _app.session)) _releasingHold = null;
    }
  }

  /// Sets the cart and tells exactly the listeners that care.
  void _set(Json value) {
    final before = cart;
    cart = value;
    notifyListeners();
    if (_termKeys.any((k) => !_same(before[k], value[k]))) terms._changed();
    // Stock available to sell counts what the resumed parked sale reserved.
    if (before['holdId'] != value['holdId']) _app.catalogState._touch();
  }

  static bool _same(Object? a, Object? b) =>
      identical(a, b) || (a is Map && b is Map ? mapEquals(a, b) : a == b);

  /// Loaded from the saved workspace (no save back needed).
  void _restore(Json value) => _set(value);

  /// Signed out: drop the in-flight state and start an empty sale.
  void _reset() {
    _cartTimer?.cancel();
    _posting = null;
    _releasingHold = null;
    _set(emptyCart());
  }

  /// [meta]: label, customerName, regNo, expiresAt shown in the held-bills drawer (WS-A).
  Future<void> parkCart({Json meta = const {}}) async {
    if (_parking || _posting != null || (_releasingHold != null && _releasingHold == cart['holdId'])) {
      throw ApiError('Wait for the previous counter action to finish before holding this bill.', 409);
    }
    if ((cart['returns'] as List? ?? const []).isNotEmpty) {
      throw ApiError('Complete or remove the exchange instead of holding it.', 409);
    }
    final draft = cart;
    final cashier = _app.session;
    _parking = true;
    try {
      final hold = await _app.mutate('/holds', {...meta, 'id': draft['holdId'], 'cart': draft}, 'Sale parked. Its stock is reserved.');
      if (!identical(cashier, _app.session)) return;
      if (identical(draft, cart)) {
        clearCart();
      } else if (cart['transactionId'] == draft['transactionId']) {
        updateCart({'holdId': hold['id']});
      }
      await _app.syncState._saveWorkspace();
    } finally {
      _parking = false;
    }
  }

  Quote? get bill {
    try {
      return currentQuote();
    } catch (_) {
      return null;
    }
  }

  Quote currentQuote([Json? value]) => quote(value ?? cart, _app.products,
      roundingIncrement: (_app.settings['roundingIncrement'] ?? 1) as int,
      taxMode: '${_app.settings['taxMode'] ?? 'exclusive'}',
      noTax: _app.noTax);

  /// Saves the sale locally first so it survives a crash, then sends it.
  /// Returns the invoice, or null when it was kept for later sending.
  Future<Json?> checkout({required List<Json> tenders, required int expectedTotal, String placeOfSupply = ''}) async {
    final sync = _app.syncState;
    final s = sync.session;
    if (s == null || !sync._validSession(s)) throw ApiError('Sign in again before taking payment.', 401);
    if (!sync.online) throw OfflineError('Reconnect before taking payment. Your cart is saved on this counter.');
    if (_parking) throw ApiError('Wait for the sale to finish parking.', 409);
    if (_releasingHold != null && _releasingHold == cart['holdId'])
      throw ApiError('Wait for the held bill to be released before taking payment.', 409);
    if (_posting != null) throw ApiError('The previous payment is still being submitted.', 409);
    final bill = _app.currentQuote();
    if (bill.total != expectedTotal) throw ApiError('The bill total changed. Reopen checkout to review the amount.', 409);
    final originalCart = cart;
    final shift = _app.openShift;
    if (shift == null) throw ApiError('Open your shift before checkout.', 409);
    final transaction = {
      ...cart,
      'shiftId': shift['id'],
      'placeOfSupply': placeOfSupply.trim(),
      'expectedTotal': expectedTotal,
      'discount': bill.discount,
      'catalogRevision': sync.snapshot['catalogRevision'],
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
    final transactionId = transaction['transactionId'] as String;
    _posting = transactionId;
    sync.pending.add(entry);
    cart = emptyCart();
    final clearedCart = cart;
    try {
      await sync._saveWorkspace();
    } catch (_) {
      if (identical(sync.session, s)) {
        sync.pending.remove(entry);
        final activeCart = cart;
        if (identical(cart, clearedCart)) cart = originalCart;
        _posting = null;
        _changedAll(activeCart);
      }
      throw BillingError('Cannot save this sale on the counter. Check available storage before taking payment.');
    }
    if (!identical(sync.session, s)) return null;
    _changedAll(originalCart);
    if (awaiting) {
      _posting = null;
      _app.toast('Payment saved as pending. Confirm the provider reference in Settings › Sync & audit.');
      return null;
    }
    try {
      final invoice = await request(s.api, s.token, '/invoices', body: transaction) as Map;
      if (!identical(sync.session, s)) return null;
      sync.pending.remove(entry);
      // The invoice is already posted even if the local cache is full.
      // The saved copy can safely replay the same transaction after restart.
      try {
        await sync._saveWorkspace();
      } catch (_) {
        _app.toast('Invoice posted. Check free space on this counter.');
      }
      unawaited(_app.sync(afterMutation: true));
      return Map<String, dynamic>.from(invoice);
    } on ApiError catch (error) {
      if (!identical(sync.session, s)) rethrow;
      if (error.rejected) {
        final activeCart = cart;
        if (identical(cart, clearedCart)) {
          sync.pending.remove(entry);
          cart = originalCart;
        } else {
          // Keep a rejected payment visible in Sync & audit when a newer cart
          // already occupies the register, so its reference can be reconciled.
          entry['error'] = error.message;
        }
        try {
          await sync._saveWorkspace();
        } catch (_) {
          if (identical(sync.session, s)) {
            _app.toast('Could not save the latest register changes. Check available storage.');
          }
        }
        if (identical(sync.session, s)) {
          _changedAll(activeCart);
          unawaited(_app.sync(afterMutation: true));
        }
        rethrow;
      }
      if (error.status == 401) {
        sync.sessionProblem = 'Sign in again to check the saved payment.';
        await _app.logout();
      } else {
        _app.toast('Payment status is pending. Check Sync & audit before taking payment again.');
      }
      return null;
    } on OfflineError {
      if (!identical(sync.session, s)) return null;
      sync.online = false;
      sync._changed();
      _app.toast('Connection lost during checkout. The payment is saved for verification. Check Sync & audit before charging again.');
      return null;
    } finally {
      if (_posting == transactionId) _posting = null;
    }
  }

  /// Checkout swapped the cart and the queue together: tell both sides.
  void _changedAll(Json previousCart) {
    final now = cart;
    cart = previousCart;
    _set(now);
    _app.syncState._changed();
  }

  @override
  void dispose() {
    _cartTimer?.cancel();
    terms.dispose();
    super.dispose();
  }
}
