import 'dart:typed_data';

import 'package:cartunez_pos/ui/photos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('large photos are shrunk to 1600 px JPEGs, small ones keep their size', () async {
    final big = Uint8List.fromList(img.encodePng(img.Image(width: 3200, height: 2000)));
    final photo = (await preparePhoto(big))!;
    expect((photo.width, photo.height), (1600, 1000));
    expect(photo.bytes.sublist(0, 3), [0xff, 0xd8, 0xff]);

    final tall = (await preparePhoto(Uint8List.fromList(img.encodeJpg(img.Image(width: 900, height: 2400)))))!;
    expect((tall.width, tall.height), (600, 1600));

    final small = (await preparePhoto(Uint8List.fromList(img.encodePng(img.Image(width: 640, height: 480)))))!;
    expect((small.width, small.height), (640, 480));

    expect(await preparePhoto(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
