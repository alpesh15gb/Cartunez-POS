import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/label_printer.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

class _LabelApp extends AppState {
  String? notice;
  @override
  void toast(String text) => notice = text;
}

void main() {
  testWidgets('the print dialog checks every selected barcode before submitting the job', (tester) async {
    final app = _LabelApp()..labelPrinter = {'mode': 'dialog'};
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
        Scaffold(body: TextButton(onPressed: () => printLabels(context, [
          const LabelItem('Filter', '4006381333931'), LabelItem('Long part code', 'W' * 65),
        ]), child: const Text('Open labels')))))));
    await tester.tap(find.text('Open labels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print labels'));
    await tester.pumpAndSettle();
    expect(app.notice, startsWith('Cannot print Long part code. This barcode is too long'));
    app.dispose();
  });

  test('network printing delivers the exact ZPL to the raw port', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = server.first.then((client) => client.fold<List<int>>([], (a, b) => a..addAll(b)));
    const zpl = '^XA^FO20,20^A0N,30,30^FDTest ₹^FS^XZ';
    await printRawToNetwork('127.0.0.1', server.port, zpl);
    expect(utf8.decode(await received), zpl);
    await server.close();
  });

  test('an unreachable network printer reports an error', () async {
    expect(() => printRawToNetwork('127.0.0.1', 1, '^XA^XZ'), throwsA(isA<SocketException>()));
  });
}
