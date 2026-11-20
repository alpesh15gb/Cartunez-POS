import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stale refresh cannot replace the next cashier workspace; a retry posts the saved sale once', () async {
    LocalStore.overrideDirectory = await Directory.systemTemp.createTemp('cartunez-session-test');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = AppState();
    addTearDown(() async {
      state.dispose();
      await server.close(force: true);
      await LocalStore.overrideDirectory!.delete(recursive: true);
      LocalStore.overrideDirectory = null;
    });
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    final payloads = <Map>[];
    var block = false;
    server.listen((request) async {
      final path = request.uri.path;
      Object result;
      if (path.endsWith('/auth/login')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        final id = body['email'];
        result = {'token': id, 'organizationId': 'demo', 'branchId': 'a',
          'user': {'id': id, 'role': 'cashier'},
          'expiresAt': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String()};
      } else if (path.endsWith('/bootstrap')) {
        final id = request.headers.value('Authorization')!.substring(7);
        if (block && id == 'first') {
          refreshStarted.complete();
          await releaseRefresh.future;
        }
        result = {'operator': id, 'products': [{'id': 'p', 'retailPrice': 200}],
          'shifts': [{'id': 'shift', 'userId': id}]};
      } else {
        payloads.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map);
        request.response.statusCode = payloads.length == 1 ? 503 : 200;
        result = payloads.length == 1 ? {'error': 'temporarily unavailable'} : {'id': 'accepted'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    Future<void> login(String id) => state.login(api: 'http://127.0.0.1:${server.port}', organizationId: 'demo',
        branchId: 'a', email: id, password: 'test');
    await state.init();
    await login('first');
    block = true;
    final oldRefresh = state.sync();
    await refreshStarted.future;
    await state.logout();
    await login('second');
    releaseRefresh.complete();
    await oldRefresh;
    expect(state.snapshot['operator'], 'second');

    state.updateCart({'holdId': 'old', 'approvalId': 'old-approval'});
    state.clearCart();
    expect(state.cart.containsKey('holdId'), isFalse);
    expect(state.cart.containsKey('approvalId'), isFalse);
    state.updateCart({'lines': [{'productId': 'p', 'qty': 1}]});
    final tenders = [{'type': 'Cash', 'amount': 200}];
    await expectLater(state.checkout(tenders: tenders, expectedTotal: 199), throwsA(isA<ApiError>()));
    expect(payloads, isEmpty);
    expect(await state.checkout(tenders: tenders, expectedTotal: 200), isNull);
    expect(state.pending.length, 1);
    expect(state.cart['lines'], isEmpty);
    await state.logout();
    await login('second');
    expect(state.pending.length, 1);
    await state.sync();
    expect(state.pending, isEmpty);
    expect(payloads.length, 2);
    expect(payloads[0], payloads[1]);
    expect(payloads[1]['expectedTotal'], 200);
  });
}
