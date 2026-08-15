import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('png stats', () async {
    for (final path in ['/tmp/ref_headless.png', '/tmp/sonic_final_0.png']) {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final im = frame.image;
      final d = (await im.toByteData())!;
      int px(int x, int y) {
        final i = (y * im.width + x) * 4;
        return (d.getUint8(i) << 16) | (d.getUint8(i + 1) << 8) | d.getUint8(i + 2);
      }
      String hex(int c) => c.toRadixString(16).padLeft(6, '0');
      double sum = 0; int n = 0;
      for (int y = 0; y < im.height; y += 4) {
        for (int x = 0; x < im.width; x += 4) {
          final i = (y * im.width + x) * 4;
          sum += (d.getUint8(i) + d.getUint8(i + 1) + d.getUint8(i + 2)) / 3.0;
          n++;
        }
      }
      // ignore: avoid_print
      print('PNGSTAT $path ${im.width}x${im.height} sky=${hex(px(20, 20))} skyR=${hex(px(780, 20))} center=${hex(px(400, 330))} avgLum=${(sum / n).toStringAsFixed(1)}');
      im.dispose();
    }
  });
}
