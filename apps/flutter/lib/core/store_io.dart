import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Small durable key-value store. Each key is one JSON file written atomically,
/// so a power cut can never leave a half-written outbox behind.
class LocalStore {
  LocalStore._(this._dir);
  final Directory _dir;

  /// Tests point storage at a temporary folder instead of the app folder.
  static Directory? overrideDirectory;

  static Future<LocalStore> open() async {
    final base = overrideDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}register');
    await dir.create(recursive: true);
    return LocalStore._(dir);
  }

  File _file(String key) =>
      File('${_dir.path}${Platform.pathSeparator}${key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.json');

  Future<dynamic> read(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Writes per key run one after another, so two saves of the same key
  /// (say the cart and a sync) can never race over the same temporary file.
  final _queues = <String, Future<void>>{};
  int _seq = 0;

  Future<void> write(String key, Object? value) {
    final previous = _queues[key] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) => _write(key, value));
    _queues[key] = next;
    next.whenComplete(() {
      if (identical(_queues[key], next)) _queues.remove(key);
    }).ignore();
    return next;
  }

  Future<void> _write(String key, Object? value) async {
    final file = _file(key);
    if (value == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    final temp = File('${file.path}.$pid.${_seq++}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }
}
