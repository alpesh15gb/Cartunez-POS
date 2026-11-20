import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/purchasing.dart';
import 'package:cartunez_pos/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Register extends AppState {
  Json? saved;
  List<Json> receipts = [];
  String? requested;
  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    requested = path;
    return {'receipts': receipts};
  }
  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    saved = body;
    return {};
  }
}

void main() {
  testWidgets('print selected lines from one partial delivery using its recorded bin', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final order = {
      'id': 'po', 'status': 'partial', 'lines': [
        {'productId': 'a', 'quantity': 10, 'received': 5, 'cost': 100},
        {'productId': 'b', 'quantity': 5, 'received': 3, 'cost': 200},
      ],
    };
    final app = _Register()
      ..snapshot = {
        'purchaseOrders': [order],
        'products': [{'id': 'a', 'name': 'Filter', 'sku': 'FA'}, {'id': 'b', 'name': 'Belt', 'sku': 'BB'}],
        'locations': [{'id': 'one', 'bin': 'Bay One', 'kind': 'sellable'}, {'id': 'two', 'bin': 'Bay Two', 'kind': 'sellable'}],
        'stock': [{'productId': 'a', 'binId': 'one', 'quantity': 100}],
        'settings': {'labelLayout': {'bin': true}},
      }
      ..receipts = [
        {'id': 'first-delivery', 'createdAt': '2026-11-19T09:00Z', 'lines': [{'productId': 'a', 'binId': 'one', 'quantity': 3}]},
        {'id': 'second-delivery', 'createdAt': '2026-11-20T09:00Z', 'lines': [
          {'productId': 'a', 'binId': 'two', 'quantity': 2},
          {'productId': 'b', 'binId': 'one', 'quantity': 3},
        ]},
      ];
    String? job;
    final zebra = (await tester.runAsync(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) async {
        job = await utf8.decoder.bind(client.cast<List<int>>()).join();
        client.destroy();
      });
      return server;
    }))!;
    addTearDown(zebra.close);
    app.labelPrinter = {'mode': 'zebra-network', 'host': '127.0.0.1', 'port': zebra.port};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home:
        ShellScope(controller: ShellController(), child: const Scaffold(body: OrdersScreen())))));
    await tester.tap(find.byTooltip('Print receipt labels'));
    await tester.pumpAndSettle();
    expect(app.requested, '/purchase-orders/po/receipts');
    await tester.tap(find.textContaining('second-delivery'));
    await tester.pumpAndSettle();
    final filter = find.widgetWithText(TextFormField, 'Filter · FA · Bay Two');
    final belt = find.widgetWithText(TextFormField, 'Belt · BB · Bay One');
    expect(tester.widget<TextFormField>(filter).controller!.text, '2');
    expect(tester.widget<TextFormField>(belt).controller!.text, '3');
    await tester.enterText(filter, '5');
    await tester.tap(find.text('Print labels'));
    await tester.pumpAndSettle();
    expect(find.text('Choose 0 to 2 copies for Filter.'), findsOneWidget);
    await tester.enterText(filter, '0');
    await tester.enterText(belt, '0');
    await tester.tap(find.text('Print labels'));
    await tester.pumpAndSettle();
    expect(find.text('Choose at least one label to print.'), findsOneWidget);
    await tester.enterText(filter, '2');
    await tester.tap(find.text('Print labels'));
    for (var attempt = 0; job == null && attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(job, allOf(contains('^PQ2,'), contains('Bay Two'), contains('^FDFA^FS'), isNot(contains('BB'))));
    await tester.pumpAndSettle();
    app.dispose();
  });

  testWidgets('receive two parts into a single delivery with one freight amount', (tester) async {
    final app = _Register()..snapshot = {
      'products': [{'id': 'a', 'name': 'Filter', 'sku': 'FA'}, {'id': 'b', 'name': 'Belt', 'sku': 'BB'}],
      'locations': [{'id': 'bin1', 'kind': 'sellable', 'area': 'A', 'rack': '1', 'shelf': '1', 'bin': '1'}],
    };
    final order = {'id': 'po', 'lines': [
      {'productId': 'a', 'quantity': 3, 'received': 1},
      {'productId': 'b', 'quantity': 4, 'received': 0},
    ]};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => receiveOrder(context, order), child: const Text('Receive')))))));
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    Future<void> line(String label, String quantity) async {
      await tester.tap(find.text('Add part'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(label).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), quantity);
      await tester.tap(find.text('Add line'));
      await tester.pumpAndSettle();
    }
    await line('FA · Filter', '1');
    await line('BB · Belt', '3');
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Belt'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '12.50');
    await tester.tap(find.text('Receive into stock'));
    await tester.pumpAndSettle();
    expect(app.saved!['landedCost'], 1250);
    expect(app.saved!['lines'], [
      {'productId': 'a', 'quantity': 1, 'binId': 'bin1', 'serials': []},
      {'productId': 'b', 'quantity': 3, 'binId': 'bin1', 'serials': []},
    ]);
    app.dispose();
  });
}
