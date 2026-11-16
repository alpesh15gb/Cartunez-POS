import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

void main() {
  test('bundled font has the rupee sign', () {
    for (final name in ['Regular', 'Bold']) {
      final bytes = File('assets/fonts/Roboto-$name.ttf').readAsBytesSync();
      final font = TtfParser(ByteData.view(Uint8List.fromList(bytes).buffer));
      expect(font.charToGlyphIndexMap.containsKey(0x20B9), isTrue, reason: name);
    }
  });
}
