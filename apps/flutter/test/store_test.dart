import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('many saves of the same key at once all succeed and the last one wins', () async {
    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-store');
    final store = await LocalStore.open();
    await Future.wait([for (var i = 0; i < 50; i++) store.write('workspace', {'n': i})]);
    expect(await store.read('workspace'), {'n': 49});
    await store.write('workspace', null);
    expect(await store.read('workspace'), isNull);
    final leftovers = Directory('${LocalStore.overrideDirectory!.path}${Platform.pathSeparator}register')
        .listSync()
        .where((f) => f.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });
}
