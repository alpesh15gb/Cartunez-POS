// End to end: Online store screen → real API → API's sync worker → a fake
// Magento in this test. Run: flutter test visual/online_test.dart --update-goldens
// (needs the demo API on 127.0.0.1:4100, started from this repo)
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/store.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/online.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    loader.addFont(File(file).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

void main() {
  const api = String.fromEnvironment('API', defaultValue: 'http://127.0.0.1:4100/api/v1');
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter'}/bin/cache/artifacts/material_fonts';
  setUpAll(() async {
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(Uri.parse(api).host)) {
      throw StateError('Use a loopback demo API.');
    }
    HttpOverrides.global = null;
    for (final family in ['Roboto', 'Segoe UI']) {
      await _font(family, ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    }
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  });

  testWidgets('publish parts to Magento from the Online store screen', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Fake Magento: answers the connection test and records product saves.
    final saves = <Map<String, dynamic>>[];
    final media = <String>[];
    final categories = <Map<String, dynamic>>[];
    final orders = <Map<String, dynamic>>[];
    // Unique order numbers per run, so a failed earlier run cannot collide.
    final run = DateTime.now().millisecondsSinceEpoch ~/ 1000 % 10000000 * 10;
    var tick = DateTime.now().toUtc();
    String stamp() => (tick = tick.add(const Duration(seconds: 2))).toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    Map<String, dynamic> order(int n, String sku, int qty, {int invoiced = 0}) => {
          'entity_id': run + n,
          'increment_id': '${run + n}',
          'state': invoiced > 0 ? 'processing' : 'new',
          'status': invoiced > 0 ? 'processing' : 'pending',
          'created_at': stamp(),
          'updated_at': stamp(),
          'customer_firstname': 'Asha',
          'customer_lastname': 'Rao',
          'customer_email': 'asha@example.com',
          'grand_total': 689.24 * qty,
          'billing_address': {'telephone': '9800000000', 'city': 'Pune', 'postcode': '411001', 'street': ['12 MG Road']},
          'items': [
            {'item_id': n * 10, 'sku': sku, 'name': sku, 'qty_ordered': qty, 'qty_invoiced': invoiced, 'qty_canceled': 0, 'qty_refunded': 0, 'price_incl_tax': 689.24},
          ],
        };
    // Bound and listened inside runAsync so it answers real requests.
    final magento = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      if (req.headers.value('authorization') != 'Bearer fake-token') {
        req.response.statusCode = 401;
        req.response.write(jsonEncode({'message': 'The consumer isn\'t authorized.'}));
      } else if (req.uri.path == '/rest/V1/store/storeConfigs') {
        req.response.write(jsonEncode([{'code': 'default', 'base_currency_code': 'INR', 'base_url': 'http://127.0.0.1/'}]));
      } else if (req.uri.path == '/rest/all/V1/categories/list') {
        final params = req.uri.queryParameters;
        final name = params['searchCriteria[filter_groups][0][filters][0][value]'];
        final parent = params['searchCriteria[filter_groups][1][filters][0][value]'];
        final found = categories.where((c) => c['name'] == name && '${c['parent_id']}' == parent).toList();
        req.response.write(jsonEncode({'items': found, 'total_count': found.length}));
      } else if (req.method == 'POST' && req.uri.path == '/rest/all/V1/categories') {
        final category = Map<String, dynamic>.from(jsonDecode(body)['category'] as Map);
        category['id'] = 10 + categories.length;
        categories.add(category);
        req.response.write(jsonEncode(category));
      } else if (req.uri.path == '/rest/all/V1/orders') {
        req.response.write(jsonEncode({'items': orders, 'total_count': orders.length}));
      } else if (req.method == 'POST' && req.uri.path.endsWith('/media')) {
        media.add(req.uri.path);
        req.response.write(jsonEncode('${media.length}'));
      } else if (req.method == 'PUT' && req.uri.path.startsWith('/rest/all/V1/products/')) {
        final product = (jsonDecode(body) as Map)['product'] as Map<String, dynamic>;
        saves.add(product);
        req.response.write(jsonEncode({'id': 500 + saves.length, ...product}));
      } else {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({'message': 'Not found'}));
      }
      await req.response.close();
      });
      return server;
    }))!;

    LocalStore.overrideDirectory = Directory.systemTemp.createTempSync('cartunez-online');
    final state = AppState();
    await tester.runAsync(state.init);
    await tester.runAsync(() => state.login(
        api: api, organizationId: 'demo', branchId: 'pune',
        email: 'owner@motorline.local', password: 'MotorlineDemo123!'));
    // Switch the module on (as Settings › Modules does).
    await tester.runAsync(() => state.mutate('/settings', {'features': {'onlineStore': true}}));
    // Start disconnected with nothing published (the demo database keeps earlier runs).
    await tester.runAsync(() async {
      await state.mutate('/integrations/magento', {'enabled': false});
      final ids = [for (final l in state.list('onlineListings')) l['productId']];
      if (ids.isNotEmpty) {
        await state.mutate('/online-listings', {'productIds': ids, 'changes': {'published': false, 'pricing': {'mode': 'mrp'}}});
      }
    });
    await tester.pumpWidget(CartunezApp(state: state, initialLocation: '/catalog/online'));
    await tester.pumpAndSettle();

    expect(find.text('Magento is not connected'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-01-not-connected.png'));

    // Connect through the dialog (it tests the connection before saving).
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Store address'), 'http://127.0.0.1:${magento.port}');
    await tester.enterText(find.ancestor(of: find.textContaining('Access token'), matching: find.byType(TextFormField)), 'fake-token');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-02-connect.png'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 50 && !state.magentoConnectedForTest; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-02b-after-connect.png'));
    expect(state.magentoConnectedForTest, isTrue);

    // A photo for the first part (the screen resizes picked photos the same way).
    await tester.runAsync(() async {
      // (Resizing runs in a background isolate in the app; it has its own unit test.)
      final jpeg = img.encodeJpg(img.Image(width: 400, height: 300)..clear(img.ColorRgb8(196, 236, 120)), quality: 85);
      for (final old in state.photosOf('${state.products.first['id']}')) {
        await state.api('/products/${state.products.first['id']}/images/${old['id']}', method: 'DELETE');
      }
      final saved = await state.api('/products/${state.products.first['id']}/images', body: {'contentType': 'image/jpeg', 'data': base64Encode(jpeg)});
      // Load the photo before the screen sees it, so it is fetched outside the test's fake clock.
      await state.photoBytes('${saved['id']}');
      await state.sync();
    });
    await tester.pump(const Duration(milliseconds: 300));

    // Select two parts and publish them at 10% off MRP.
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(1)); // first part (index 0 is "select all")
    await tester.tap(boxes.at(2));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-03-selected.png'));
    await tester.tap(find.text('Set price'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Apply'));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Publish'));
      // The API's worker runs every 5 seconds; wait until both parts are on the website.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await state.sync();
        final synced = state.list('onlineListings').where((l) => l['published'] == true && (l['sync'] as Map?)?['state'] == 'synced');
        if (synced.length >= 2) break;
      }
    });
    await tester.pumpAndSettle();
    expect(saves.length, greaterThanOrEqualTo(2));
    final sent = saves.last;
    expect(sent['status'], 1);
    final special = (sent['custom_attributes'] as List).firstWhere((a) => a['attribute_code'] == 'special_price')['value'];
    expect(double.parse('$special'), closeTo((sent['price'] as num) * 0.9, 0.02));
    expect(find.text('On website'), findsNWidgets(3)); // the filter chip + two published parts
    expect(media, hasLength(1)); // the first part's photo went to Magento
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-04-published.png'));

    // One part's own settings.
    final listing = find.text('On website').at(1);
    await tester.ensureVisible(listing);
    await tester.pump();
    await tester.runAsync(() => tester.tap(listing));
    for (var attempt = 0; attempt < 160; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 30));
      if (find.text('Show on the website').evaluate().isNotEmpty && !state.syncing) break;
    }
    expect(find.text('Show on the website'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-05-part.png'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // An online order arrives: Check now reads it and holds the stock.
    final first = '${state.products.first['sku']}';
    final firstId = '${state.products.first['id']}';
    final before = state.available(firstId);
    orders.add(order(1, first, 2));
    GoRouter.of(tester.element(find.byType(OnlineStoreScreen))).go('/orders/online');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Check now'));
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('#${run + 1}'), findsOneWidget);
    expect(find.text('Reserved'), findsWidgets);
    expect(state.available(firstId), before - 2);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-06-orders.png'));

    // Marketplace invoices leave POS stock reserved until this counter bills it.
    orders[0] = {...orders[0], 'updated_at': stamp(), 'state': 'processing', 'status': 'processing',
      'items': [{...(orders[0]['items'] as List).first as Map, 'qty_invoiced': 2}]};
    orders.add(order(2, first, before + 3, invoiced: before + 3));
    final webPart = await tester.runAsync(() => state.mutate('/products', {
      'sku': 'QA-WEB-$run', 'name': 'Website order fixture', 'brand': 'Fixture', 'category': 'Fixtures',
      'unit': 'Each', 'retailPrice': 16000, 'cost': 8000, 'taxRate': 0, 'hsnSac': '8421',
      'supplierId': state.list('suppliers').first['id'], 'onlineOnly': true,
    })) as Map;
    orders.add(order(3, webPart['sku'] as String, 5));
    await tester.runAsync(() async {
      await tester.tap(find.text('Check now'));
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump(const Duration(seconds: 1));
    final placed = {for (final o in state.list('onlineOrders')) o['number']: o['posState']};
    expect(placed['${run + 1}'], 'reserved');
    expect(placed['${run + 2}'], 'reserved');
    expect(placed['${run + 3}'], 'reserved');
    await tester.tap(find.text('#${run + 2}'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/online-07-order.png'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Order missing parts'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump(const Duration(seconds: 1));
    final po = state.list('onlineOrders').firstWhere((o) => o['number'] == '${run + 2}')['purchaseOrderIds'] as List;
    expect(po, hasLength(1));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Order the website-only SKU from the normal order dialog. It occupies no bin.
    await tester.tap(find.text('#${run + 3}'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Create purchase order'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();
    final webOrder = state.list('onlineOrders').firstWhere((o) => o['number'] == '${run + 3}');
    final webPoId = (webOrder['purchaseOrderIds'] as List).single;
    final webPo = state.list('purchaseOrders').firstWhere((p) => p['id'] == webPoId);
    final webLine = (webPo['lines'] as List).single as Map;
    expect(webLine['productId'], webPart['id']);
    expect(webLine['quantity'], 5);
    expect(webLine['onlineOnly'], true);
    expect(state.available(webPart['id'] as String), 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Remove the test photo.
    await tester.runAsync(() async {
      final id = state.products.first['id'];
      for (final p in state.photosOf('$id')) {
        await state.api('/products/$id/images/${p['id']}', method: 'DELETE');
      }
    });
    // Refund the stocked reservations. Neither had a local POS invoice.
    for (var i = 0; i < 2; i++) {
      final item = (orders[i]['items'] as List).first as Map;
      orders[i] = {...orders[i], 'updated_at': stamp(), 'state': 'closed',
        'items': [{...item, 'qty_refunded': item['qty_invoiced']}]};
    }
    await tester.runAsync(() async {
      await state.api('/integrations/magento/orders/poll', body: {});
      await state.sync();
    });
    expect(state.available(firstId), before);
    await tester.runAsync(() async {
      final ids = [for (final l in state.list('onlineListings')) l['productId']];
      await state.mutate('/online-listings', {'productIds': ids, 'changes': {'published': false}});
      await Future<void>.delayed(const Duration(seconds: 7));
      await state.mutate('/integrations/magento', {'enabled': false});
      await state.mutate('/settings', {'features': {'onlineStore': false}});
      await magento.close(force: true);
    });
    expect(saves.last['status'], 2);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}

extension on AppState {
  bool get magentoConnectedForTest {
    final m = ((settings['integrations'] as Map?)?['magento'] as Map?) ?? {};
    return m['enabled'] == true && m['tokenSet'] == true;
  }
}
