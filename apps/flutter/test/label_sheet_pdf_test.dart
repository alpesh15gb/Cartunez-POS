// WS-F: web label printing. PDF pages are exactly the configured label size,
// sheets fit the page, and the local ZPL bridge receives the same ZPL.
import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/label_layout.dart';
import 'package:cartunez_pos/core/label_sheet_pdf.dart';
import 'package:cartunez_pos/core/zpl_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

const _label = LabelData(name: 'Engine Air Filter', code: '4006381333931', sku: 'ML-AIR-01', price: 'Rs. 649.00');

/// Every page's MediaBox in the saved PDF, in points.
List<List<double>> _mediaBoxes(List<int> bytes) => RegExp(r'/MediaBox\s*\[\s*([\d.\s-]+)\]')
    .allMatches(latin1.decode(bytes))
    .map((m) => m[1]!.trim().split(RegExp(r'\s+')).map(double.parse).toList())
    .toList();

void main() {
  test('roll PDF pages match the configured label size exactly', () async {
    for (final layout in const [
      LabelLayout(widthMm: 50, heightMm: 25),
      LabelLayout(widthMm: 38, heightMm: 25),
      LabelLayout(widthMm: 100, heightMm: 50),
      LabelLayout(widthMm: 50, heightMm: 30, columns: 2, gapMm: 3),
    ]) {
      final plans = List.filled(3, planLabel(layout, _label));
      expect(labelRollFormat(layout).width, closeTo(layout.rollWidthMm * PdfPageFormat.mm, 0.001));
      expect(labelRollFormat(layout).height, closeTo(layout.heightMm * PdfPageFormat.mm, 0.001));
      final boxes = _mediaBoxes(await labelPdf(layout, plans));
      expect(boxes, hasLength((3 / layout.columns).ceil()));
      for (final box in boxes) {
        expect(box[2] - box[0], closeTo(layout.rollWidthMm * 72 / 25.4, 0.01));
        expect(box[3] - box[1], closeTo(layout.heightMm * 72 / 25.4, 0.01));
      }
    }
  });

  test('A4 sheets hold columns × rows labels and refuse grids that do not fit', () async {
    const layout = LabelLayout(widthMm: 63.5, heightMm: 38.1);
    const grid = SheetGrid(columns: 3, rows: 7, marginTopMm: 15.1, marginLeftMm: 7.2, gapXMm: 2.5, gapYMm: 0);
    expect(grid.problem(layout), isNull);
    final plans = List.filled(25, planLabel(layout, _label));
    final pages = labelSheetPages(layout, plans, grid);
    expect(pages, hasLength(2)); // 21 + 4
    final boxes = _mediaBoxes(await labelPdf(layout, plans, sheet: grid));
    expect(boxes, hasLength(2));
    expect(boxes.first[2], closeTo(210 * 72 / 25.4, 0.01));
    expect(boxes.first[3], closeTo(297 * 72 / 25.4, 0.01));
    expect(labelSheetPages(layout, plans, grid, skip: 20), hasLength(3)); // a part-used sheet first

    expect(const SheetGrid(columns: 4).problem(layout), contains('do not fit across'));
    expect(const SheetGrid(rows: 8).problem(layout), contains('do not fit down'));
    expect(() => labelSheetPages(layout, plans, const SheetGrid(columns: 4)), throwsArgumentError);
    final saved = SheetGrid.fromJson(grid.toJson());
    expect(saved.toJson(), grid.toJson());
  });

  group('local ZPL bridge', () {
    late HttpServer server;
    final received = <String, String>{};
    setUp(() async {
      received.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        received['${request.method} ${request.uri.path}'] = body;
        if (request.uri.path == '/default') request.response.write(jsonEncode({'name': 'ZD421', 'uid': 'zebra-1', 'connection': 'usb'}));
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('Zebra Browser Print gets its default device and the exact ZPL', () async {
      const zpl = '^XA^FO20,20^A0N,30,30^FDFilter ₹649^FS^XZ';
      await sendZplToBridge('http://127.0.0.1:${server.port}/write', zpl);
      expect(received.keys, containsAll(['GET /default', 'POST /write']));
      final sent = jsonDecode(received['POST /write']!) as Map;
      expect(sent['data'], zpl);
      expect((sent['device'] as Map)['uid'], 'zebra-1');
    });

    test('another bridge gets the ZPL as plain text', () async {
      await sendZplToBridge('http://127.0.0.1:${server.port}/print', '^XA^XZ');
      expect(received['POST /print'], '^XA^XZ');
    });

    test('only addresses on this computer are allowed, and failures are explained', () async {
      expect(() => bridgeUri('http://192.168.1.20:9100/write'), throwsA(isA<BridgeError>()));
      expect(() => bridgeUri('ftp://127.0.0.1/write'), throwsA(isA<BridgeError>()));
      expect(bridgeUri(defaultBridgeUrl).port, 9100);
      await expectLater(sendZplToBridge('http://127.0.0.1:1/write', '^XA^XZ'),
          throwsA(isA<BridgeError>().having((e) => e.message, 'message', contains('Could not reach the label bridge'))));
    });
  });
}
