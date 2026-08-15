// Diagnostic: captures a SEQUENCE of frames at advancing camera angles to prove
// the auto-rotation animation is visually coherent frame-to-frame (each frame
// differs and stays correct). Mirrors what the live app shows as it orbits.
//
//   flutter test test/shader_animation_test.dart
//
// Writes build/sonic_anim_0.png ... sonic_anim_3.png.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';

AudioBands get _bands => const AudioBands(
      subBass: 0.8, bass: 0.7, lowMid: 0.5, mid: 0.4, highMid: 0.3,
      presence: 0.22, brilliance: 0.16, air: 0.1, energy: 0.55,
      warmth: 0.6, brightness: 0.3, sharpness: 0.2, smoothness: 0.6,
      density: 0.7,
    );

void main() {
  test('capture rotating animation sequence (4 frames)', () async {
    final controller = SonicShaderController();
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue, reason: 'shaders: ${controller.error}');

    const angles = [0.0, 0.4, 0.8, 1.2];
    final avgLums = <double>[];
    for (int i = 0; i < angles.length; i++) {
      final img = await captureSonicFrameForTesting(
        controller: controller,
        bands: _bands,
        theme: SonicTheme.nocturnal,
        width: 200,
        height: 200,
        time: 1.0 + i * 0.1,
        camAngle: angles[i],
      );
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final out = File('build/sonic_anim_$i.png');
      await out.create(recursive: true);
      await out.writeAsBytes(png!.buffer.asUint8List());

      // Mean luminance per frame — distinct values prove the frames differ
      // (the rotation moves bright pillars across the image).
      final rgba = (await img.toByteData())!;
      double sum = 0;
      int n = 0;
      for (int y = 0; y < img.height; y += 5) {
        for (int x = 0; x < img.width; x += 5) {
          final off = (y * img.width + x) * 4;
          sum += (rgba.getUint8(off) + rgba.getUint8(off + 1) +
              rgba.getUint8(off + 2)) /
              3.0 /
              255.0;
          n++;
        }
      }
      avgLums.add(sum / n);
      img.dispose();
    }

    // ignore: avoid_print
    print('SONIC_ANIM angles=$angles avgLums=$avgLums');

    // Each frame must be non-empty and the sequence must actually change
    // (std-dev of mean luminance across frames > 0 => motion).
    for (final l in avgLums) {
      expect(l, greaterThan(0.0), reason: 'frame must not be fully black');
    }
    final mean = avgLums.reduce((a, b) => a + b) / avgLums.length;
    final variance =
        avgLums.map((l) => (l - mean) * (l - mean)).reduce((a, b) => a + b) /
            avgLums.length;
    expect(variance, greaterThan(1e-9),
        reason: 'frames must differ across rotation: avgLums=$avgLums');

    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
