import 'dart:convert';

import 'package:web/web.dart' as web;

/// Browser version of the register store. Each key is one JSON entry in the
/// site's local storage, which survives reloads and browser restarts.
class LocalStore {
  LocalStore._();

  static Future<LocalStore> open() async => LocalStore._();

  static const _prefix = 'cartunez-register:';

  Future<dynamic> read(String key) async {
    final raw = web.window.localStorage.getItem('$_prefix$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, Object? value) async {
    if (value == null) {
      web.window.localStorage.removeItem('$_prefix$key');
    } else {
      web.window.localStorage.setItem('$_prefix$key', jsonEncode(value));
    }
  }
}
