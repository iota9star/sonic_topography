import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';
import 'package:sonic_topography/src/audio/audio_bands.dart';

Future<ui.Image> render(SonicShaderController c, double pulse) async {
  const bands = AudioBands(
    subBass: 0.3, bass: 0.3, lowMid: 0.2, mid: 0.2, highMid: 0.15,
    presence: 0.3, brilliance: 0.2, air: 0.15, energy: 0.4,
    warmth: 0.2, brightness: 0.3, sharpness: 0.2, smoothness: 0.6, density: 0.5,
  );
  return captureSonicFrameForTesting(
    controller: c, bands: bands, theme: SonicTheme.blueHour,
    width: 800, height: 600, time: 5.0, blockPulse: pulse,
  );
}

void main() {
  test('diff idle vs blockPulse frames', () async {
    final controller = SonicShaderController();
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue, reason: '${controller.error}');
    final a = await render(controller, 0);
    final b = await render(controller, 0.85);
    final da = (await a.toByteData())!;
    final db = (await b.toByteData())!;
    int changed = 0; int maxD = 0;
    int minY = 1 << 30, maxY = -1;
    for (int y = 0; y < 600; y++) {
      for (int x = 0; x < 800; x++) {
        final i = (y * 800 + x) * 4;
        int d = (da.getUint8(i) - db.getUint8(i)).abs()
              + (da.getUint8(i+1) - db.getUint8(i+1)).abs()
              + (da.getUint8(i+2) - db.getUint8(i+2)).abs();
        if (d > 20) {
          changed++;
          if (d > maxD) maxD = d;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    print('BLOCKDIFF changed=$changed maxD=$maxD yRange=$minY..$maxY');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
