import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan reference structure', () async {
    final bytes = await File('/tmp/ref_headless.png').readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final im = (await codec.getNextFrame()).image;
    final d = (await im.toByteData())!;
    int v(int x, int y) {
      final i = (y * im.width + x) * 4;
      return (d.getUint8(i) + d.getUint8(i + 1) + d.getUint8(i + 2)) ~/ 3;
    }
    final sb = StringBuffer('SCAN x=400 y150..500 step6:');
    for (int y = 150; y <= 500; y += 6) {
      sb.write(' ${y}:${v(400, y)}');
    }
    sb.write('\nSCAN x=200 y180..420 step8:');
    for (int y = 180; y <= 420; y += 8) {
      sb.write(' ${y}:${v(200, y)}');
    }
    sb.write('\nSCAN x=600 y180..420 step8:');
    for (int y = 180; y <= 420; y += 8) {
      sb.write(' ${y}:${v(600, y)}');
    }
    // ignore: avoid_print
    print(sb);
  });
}
