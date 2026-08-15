import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('measure terrain silhouette in captured frames', () async {
    final dir = Platform.environment['SONIC_TMP'] ??
        '${Platform.environment['HOME']}/Library/Containers/dev.sonic.sonicTopography/Data/tmp';
    for (final name in ['sonic_dbg_0.png', 'sonic_dbg_4.png']) {
      final f = File('$dir/$name');
      if (!await f.exists()) continue;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      final im = (await codec.getNextFrame()).image;
      final rgba = (await im.toByteData())!;
      int w = im.width, h = im.height;
      // Per column, find the topmost row where "terrain" begins: pixel differs
      // from the sky color by a threshold. Sky = color at (col, 10).
      int skyAt(int x, int y) {
        final i = (y * w + x) * 4;
        return (rgba.getUint8(i) << 16) | (rgba.getUint8(i+1) << 8) | rgba.getUint8(i+2);
      }
      final sb = StringBuffer('$name ${w}x$h silhouette rows (col:top): ');
      for (int x = 40; x < w; x += (w ~/ 10)) {
        final sky = skyAt(x, 12);
        int top = -1;
        for (int y = 20; y < h; y++) {
          final c = skyAt(x, y);
          final dr = (((c >> 16) & 255) - ((sky >> 16) & 255)).abs();
          final dg = (((c >> 8) & 255) - ((sky >> 8) & 255)).abs();
          final db = ((c & 255) - (sky & 255)).abs();
          if (dr + dg + db > 60) { top = y; break; }
        }
        sb.write('$x:${top < 0 ? "-" : (100 * top / h).round()}% ');
      }
      // ignore: avoid_print
      print(sb);
      im.dispose();
    }
  });
}
