import 'dart:convert';
import 'dart:io';

import 'package:cartunez_pos/core/label_printer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
