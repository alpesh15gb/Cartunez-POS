// WS-D: switching user on a PIN counter keeps each person's cart.
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/shift/pin_counter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('switch user keeps each person\'s cart on the counter', () async {
    LocalStore.overrideDirectory = await Directory.systemTemp.createTemp('cartunez-pin-test');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = AppState();
    addTearDown(() async {
      state.dispose();
      await server.close(force: true);
      await LocalStore.overrideDirectory!.delete(recursive: true);
      LocalStore.overrideDirectory = null;
    });
    final pins = <Map>[];
    server.listen((request) async {
      final path = request.uri.path;
      Object result;
      if (path.endsWith('/auth/pin-login')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        pins.add(body);
        final id = body['userId'];
        result = {'token': id, 'organizationId': 'demo', 'branchId': 'pune', 'user': {'id': id, 'role': 'cashier', 'name': id},
          'expiresAt': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String()};
      } else {
        final id = request.headers.value('Authorization')!.substring(7);
        result = {'products': [{'id': 'p', 'retailPrice': 200, 'name': 'Wiper'}], 'shifts': [{'id': 'shift-$id', 'userId': id}]};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    await state.init();
    final counter = {'api': 'http://127.0.0.1:${server.port}/api/v1', 'organizationId': 'demo', 'deviceId': 'd1', 'key': 'k'};
    await PinCounter.signIn(state, counter, 'ravi', '4826');
    expect(state.session!.userId, 'ravi');
    state.updateCart({'lines': [{'productId': 'p', 'qty': 2}]});
    await lockCounter(state);
    expect(state.session, isNull);
    expect(state.sessionProblem, contains('kept'));
    await PinCounter.signIn(state, counter, 'meera', '5937');
    expect(state.cart['lines'], isEmpty, reason: 'the next person starts with an empty counter');
    await lockCounter(state);
    await PinCounter.signIn(state, counter, 'ravi', '4826');
    expect((state.cart['lines'] as List).single['qty'], 2, reason: "Ravi's cart is back");
    expect(pins.first['deviceKey'], 'k');
  });
}
