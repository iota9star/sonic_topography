import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';
import 'package:sonic_topography/src/audio/audio_bands.dart';

void main() {
  test('output transform brightness vs reference', () async {
    final controller = SonicShaderController();
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    const idle = AudioBands(
      subBass: 0, bass: 0, lowMid: 0, mid: 0, highMid: 0,
      presence: 0, brilliance: 0, air: 0, energy: 0,
      warmth: 0, brightness: 0, sharpness: 0, smoothness: 0.6, density: 0.5,
    );
    final img = await captureSonicFrameForTesting(
      controller: controller, bands: idle, theme: SonicTheme.minimalMonochrome,
      width: 800, height: 600, time: 5.0,
    );
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('build/ours_idle_800.png').writeAsBytes(png!.buffer.asUint8List());
    final rgba = (await img.toByteData())!;
    int px(int x, int y) {
      final i = (y * 800 + x) * 4;
      return (rgba.getUint8(i) << 16) | (rgba.getUint8(i+1) << 8) | rgba.getUint8(i+2);
    }
    String hex(int c) => c.toRadixString(16).padLeft(6, '0');
    double sum = 0; int n = 0;
    for (int y = 0; y < 600; y += 4) for (int x = 0; x < 800; x += 4) {
      final i = (y * 800 + x) * 4;
      sum += (rgba.getUint8(i) + rgba.getUint8(i+1) + rgba.getUint8(i+2)) / 3.0; n++;
    }
    // ignore: avoid_print
    print('COLORCHECK sky_topleft=${hex(px(20, 20))} sky_topright=${hex(px(780, 20))} '
        'center=${hex(px(400, 330))} avgLum=${(sum/n).toStringAsFixed(1)}');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
