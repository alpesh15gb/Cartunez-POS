import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _HoldRegister extends AppState {
  String? deleted;
  ApiError? failure;
  Completer<void>? started;
  Completer<void>? release;

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    deleted = path;
    started?.complete();
    await release?.future;
    if (failure != null) throw failure!;
    return <String, dynamic>{};
  }

  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}
}

class _CheckoutRegister extends AppState {
  @override
  Future<void> sync({bool loud = false, bool afterMutation = false}) async {}
}

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
        request.response.statusCode = switch (payloads.length) { 1 => 503, 3 => 409, _ => 200 };
        result = switch (request.response.statusCode) {
          503 => {'error': 'temporarily unavailable'}, 409 => {'error': 'Stock already sold'},
          _ => {'id': 'accepted', 'transactionId': payloads.last['transactionId']},
        };
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

    state.updateCart({'lines': [{'productId': 'p', 'qty': 1}]});
    await state.checkout(tenders: [{'type': 'UPI', 'amount': 200, 'confirmed': false}], expectedTotal: 200);
    final awaiting = state.pending.single;
    expect(payloads.length, 2);
    await state.confirmPayment(awaiting['transaction']['transactionId'], {'UPI': 'UTR-19'});
    expect(awaiting['error'], 'Stock already sold');
    expect(state.pending.single, same(awaiting));
    await state.sync();
    expect(payloads.length, 3, reason: 'a rejected invoice waits for deliberate recovery');
    await state.retryPendingPayment(awaiting);
    expect(payloads[2], payloads[3], reason: 'retry posts the same payment, reference and transaction ID');
    expect(payloads[3]['tenders'].single['reference'], 'UTR-19');
    expect(awaiting['postedInvoice']['id'], 'accepted');
    expect(state.pending, isEmpty);
  });

  test('changing the customer invalidates only that customer’s discount approval', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.replaceCart({'customerId': 'c1'});
    state.replaceCart({'customerId': 'c1', 'discount': 500, 'discountApprovalId': 'approval-1'});
    state.updateCart({'priceLevel': 'wholesale'});
    expect(state.cart['discountApprovalId'], 'approval-1');
    state.updateCart({'customerId': 'c1'});
    expect(state.cart['discountApprovalId'], 'approval-1');
    state.updateCart({'customerId': 'c2'});
    expect(state.cart.containsKey('discountApprovalId'), isFalse);
    expect(state.cart['discount'], 500);
    // A different draft recalled from the server has its own valid approval.
    state.replaceCart({'transactionId': 'held-sale', 'customerId': 'c3', 'discountApprovalId': 'held-approval'});
    expect(state.cart['discountApprovalId'], 'held-approval');
  });

  test('a pending held sale does not subtract its own reservation twice', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.snapshot = {
      'locations': [{'id': 'bin', 'kind': 'sellable'}],
      'stock': [{'productId': 'p', 'binId': 'bin', 'quantity': 10, 'reserved': 2}],
      'holds': [
        {'id': 'h1', 'cart': {'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 2}]}},
        {'id': 'h2', 'cart': {'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 1}]}},
      ],
    };
    expect(state.available('p'), 8);
    state.updateCart({'holdId': 'h1', 'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 2}]});
    expect(state.available('p') - 2, 8, reason: 'the counter deducts the current cart lines');
    state.pending = [
      {'transaction': {'holdId': 'h1', 'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 2}]}},
    ];
    expect(state.available('p'), 8, reason: 'the pending sale and its hold refer to the same reserved units');
    state.clearCart();
    state.pending = [
      {'transaction': {'holdId': 'h1', 'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 1}]}},
    ];
    expect(state.available('p'), 8, reason: 'the unused half of the hold is still reserved at the server');
    state.pending = [
      {'transaction': {'lines': [{'productId': 'p', 'binId': 'bin', 'qty': 1}]}},
    ];
    expect(state.available('p'), 7);
  });

  test('clearing a held bill requires a connection and releases the hold before clearing', () async {
    final state = _HoldRegister();
    addTearDown(state.dispose);
    state.updateCart({'holdId': 'h1', 'lines': [{'productId': 'p', 'qty': 1}]});
    await expectLater(state.discardCart(), throwsA(isA<OfflineError>()));
    expect(state.cart['holdId'], 'h1');
    expect(state.deleted, isNull);
    state.online = true;
    await state.discardCart();
    expect(state.deleted, '/holds/h1');
    expect(state.cart['holdId'], isNull);
    expect(state.cart['lines'], isEmpty);
  });

  test('clearing a bill that another register already released succeeds locally', () async {
    final state = _HoldRegister()..failure = ApiError('Hold unavailable in this branch.', 404);
    addTearDown(state.dispose);
    state.online = true;
    state.updateCart({'holdId': 'h1', 'lines': [{'productId': 'p', 'qty': 1}]});
    await state.discardCart();
    expect(state.cart['holdId'], isNull);
    expect(state.cart['lines'], isEmpty);
  });

  test('releasing a hold preserves items added while the request was in flight', () async {
    final state = _HoldRegister()
      ..started = Completer<void>()
      ..release = Completer<void>();
    addTearDown(state.dispose);
    state.online = true;
    state.updateCart({'holdId': 'h1', 'lines': [{'productId': 'old', 'qty': 1}]});
    final discard = state.discardCart();
    await state.started!.future;
    state.updateCart({'lines': [{'productId': 'old', 'qty': 1}, {'productId': 'new', 'qty': 1}]});
    state.release!.complete();
    await discard;
    expect(state.cart['holdId'], isNull);
    expect(state.cart['lines'], hasLength(2));
  });

  test('a rejected checkout cannot overwrite a newer sale started while it was posting', () async {
    LocalStore.overrideDirectory = await Directory.systemTemp.createTemp('cartunez-rejected-checkout');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = _CheckoutRegister();
    addTearDown(() async {
      state.dispose();
      await server.close(force: true);
      await LocalStore.overrideDirectory!.delete(recursive: true);
      LocalStore.overrideDirectory = null;
    });
    final posting = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      posting.complete();
      await release.future;
      request.response.statusCode = HttpStatus.conflict;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Stock already sold'}));
      await request.response.close();
    });
    await state.init();
    state.session = Session(api: 'http://127.0.0.1:${server.port}', token: 'test', organizationId: 'demo', branchId: 'pune',
        user: {'id': 'u', 'role': 'cashier'}, expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String());
    state.online = true;
    state.snapshot = {
      'settings': {'currency': 'INR'},
      'products': [{'id': 'old', 'name': 'Old part', 'retailPrice': 200}],
      'shifts': [{'id': 'shift', 'userId': 'u'}],
    };
    state.updateCart({'lines': [{'productId': 'old', 'qty': 1}]});
    final checkout = state.checkout(tenders: [{'type': 'Cash', 'amount': 200, 'confirmed': true}], expectedTotal: 200);
    await posting.future;
    state.snapshot = {...state.snapshot, 'products': [
      ...state.snapshot['products'] as List,
      {'id': 'new', 'name': 'New part', 'retailPrice': 300},
    ]};
    state.updateCart({'lines': [{'productId': 'new', 'qty': 1}]});
    release.complete();
    await expectLater(checkout, throwsA(isA<ApiError>()));
    expect(state.pending.single['error'], 'Stock already sold');
    expect(state.pending.single['transaction']['lines'].single['productId'], 'old');
    expect((state.cart['lines'] as List).single['productId'], 'new');
  });
}
