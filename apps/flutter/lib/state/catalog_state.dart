part of 'app_state.dart';

/// Parts, bins and stock from the server snapshot: what can be sold now,
/// code lookups (barcode, SKU, part number) and photos. Notifies when the
/// snapshot, the offline queue or the resumed parked sale changes.
class CatalogState extends ChangeNotifier {
  CatalogState._(this._app);
  final AppState _app;

  void _touch() => notifyListeners();

  List<Json> _list(String key) => _app.syncState.list(key);

  List<Json> get products => _list('products');
  List<Json> get saleProducts => products.where((p) => p['salesStopped'] != true).toList();
  List<Json> get bins => _list('locations');
  List<Json> get stock => _list('stock');
  List<Json> get sellableBins => bins.where((b) => b['kind'] == 'sellable').toList();

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
    for (final entry in _app.syncState.pending) {
      for (final line in (entry['transaction']['lines'] as List)) {
        if (line['productId'] == productId && (binId == null || line['binId'] == binId)) {
          waiting += line['qty'] as int;
        }
      }
    }
    var reserved = 0;
    final holdId = _app.cartState.cart['holdId'];
    for (final hold in _list('holds')) {
      if (hold['id'] != holdId) continue;
      for (final line in (hold['cart']['lines'] as List)) {
        if (line['productId'] == productId && (binId == null || line['binId'] == binId)) {
          reserved += line['qty'] as int;
        }
      }
    }
    return physical - waiting + reserved;
  }

  /// Barcodes first, then SKU, then manufacturer and cross references.
  List<Json> findByCode(String code, {bool forSale = false}) {
    final raw = code.trim();
    if (raw.isEmpty) return [];
    final gtin = canonicalGtin(scannedProductCode(raw));
    final catalog = products;
    List<Json> allowed(List<Json> matches) =>
        forSale ? matches.where((p) => p['salesStopped'] != true).toList() : matches;
    final barcodeMatches = catalog.where((p) => (p['barcodes'] as List? ?? const []).any((v) {
      final stored = '$v'.trim();
      return stored == raw || (gtin != null && canonicalGtin(stored) == gtin);
    })).toList();
    if (barcodeMatches.isNotEmpty) return allowed(barcodeMatches);
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
      final found = catalog.where(tier).toList();
      if (found.isNotEmpty) return allowed(found);
    }
    return [];
  }

  String? uniqueProductIdForCode(String code) {
    final matches = findByCode(code);
    return matches.length == 1 ? matches.single['id'] as String : null;
  }

  String? binIdForCode(String code) => bins.where((bin) => bin['id'] == code.trim()).firstOrNull?['id'] as String?;

  // ---------- photos and files ----------
  /// Photos of a part, main photo first.
  List<Json> photosOf(String productId) =>
      _list('productImages').where((i) => i['productId'] == productId).toList()..sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));

  final _photoCache = <String, Future<Uint8List>>{};

  /// A supplier-bill photo or PDF, downloaded once per app session.
  Future<Uint8List> fileBytes(String fileId) {
    final s = _app.session;
    if (s == null) return Future.error(ApiError('Sign in to continue.', 401));
    return _photoCache.putIfAbsent('file:$fileId', () async {
      try {
        return Uint8List.fromList(await fetchBytes(s.api, s.token, '/attachments/$fileId'));
      } catch (e) {
        _photoCache.remove('file:$fileId');
        rethrow;
      }
    });
  }

  /// A photo's bytes, downloaded once per app session (photo IDs never change).
  Future<Uint8List> photoBytes(String imageId) {
    final s = _app.session;
    if (s == null) return Future.error(ApiError('Sign in to continue.', 401));
    return _photoCache.putIfAbsent(imageId, () async {
      try {
        return Uint8List.fromList(await fetchBytes(s.api, s.token, '/product-images/$imageId'));
      } catch (e) {
        _photoCache.remove(imageId);
        rethrow;
      }
    });
  }
}
