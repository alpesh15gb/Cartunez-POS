import 'dart:convert';
import 'package:cartunez_pos/core/store_web.dart';
import 'package:web/web.dart' as web;

// Compile with dart compile js and serve on a dedicated localhost origin.
Future<void> main() async {
  void check(bool pass, String message) {
    if (!pass) throw StateError(message);
  }
  try {
    check(['localhost', '127.0.0.1'].contains(web.window.location.hostname), 'Use a local test server.');
    final key = 'migration-${DateTime.now().microsecondsSinceEpoch}';
    final legacy = 'cartunez-register:$key';
    final workspace = {'cart': {'transactionId': 'one'}, 'pending': [{'transactionId': 'two'}]};
    web.window.localStorage.setItem(legacy, jsonEncode(workspace));
    final store = await LocalStore.open();
    check(jsonEncode(await store.read(key)) == jsonEncode(workspace), 'Legacy cart or queue missing');
    check(web.window.localStorage.getItem(legacy) == null, 'Legacy key still present');
    final reopened = await LocalStore.open();
    check(jsonEncode(await reopened.read(key)) == jsonEncode(workspace), 'Reopening lost register data');
    final large = {'catalog': 'a' * (6 * 1024 * 1024), ...workspace};
    await reopened.write(key, large);
    check((await store.read(key))['catalog'].length == 6 * 1024 * 1024, 'Large catalog truncated');
    await reopened.write(key, null);
    check(await store.read(key) == null, 'Clearing register failed');
    web.document.body!.textContent = 'PASS: cart and payment queue migrated, reopened, saved 6 MiB and cleared.';
  } catch (error) {
    web.document.body!.textContent = 'FAIL: $error';
    rethrow;
  }
}
