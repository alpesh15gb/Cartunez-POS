import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// One committed IndexedDB record per workspace keeps the cart and payment
/// queue together. Existing browser profiles migrate each key on first read.
class LocalStore {
  LocalStore._(this._db);
  final web.IDBDatabase _db;
  static const _table = 'register';
  static const _prefix = 'cartunez-register:';

  static Future<LocalStore> open() async {
    final ready = Completer<LocalStore>();
    final open = web.window.indexedDB.open('cartunez-pos', 1);
    open.onupgradeneeded = ((web.Event _) {
      (open.result as web.IDBDatabase).createObjectStore(_table);
    }).toJS;
    open.onsuccess = ((web.Event _) {
      ready.complete(LocalStore._(open.result as web.IDBDatabase));
    }).toJS;
    open.onerror = ((web.Event _) {
      ready.completeError(StateError(open.error?.message ?? 'Cannot open register storage.'));
    }).toJS;
    return ready.future;
  }

  Future<dynamic> read(String key) async {
    final read = _db.transaction(_table.toJS).objectStore(_table).get(key.toJS);
    final done = Completer<String?>();
    read.onsuccess = ((web.Event _) => done.complete((read.result as JSString?)?.toDart)).toJS;
    read.onerror = ((web.Event _) => done.completeError(StateError('Could not read saved register data.'))).toJS;
    final raw = await done.future;
    if (raw != null) return jsonDecode(raw);
    final old = web.window.localStorage.getItem('$_prefix$key');
    if (old == null) return null;
    final value = jsonDecode(old);
    await write(key, value);
    return value;
  }

  Future<void> write(String key, Object? value) async {
    final raw = jsonEncode(value);
    final tx = _db.transaction(_table.toJS, 'readwrite');
    final committed = Completer<void>();
    tx.oncomplete = ((web.Event _) => committed.complete()).toJS;
    tx.onabort = ((web.Event _) => committed.completeError(StateError(tx.error?.message ?? 'Cannot save register data.'))).toJS;
    tx.objectStore(_table).put(raw.toJS, key.toJS);
    await committed.future;
    web.window.localStorage.removeItem('$_prefix$key');
  }
}
