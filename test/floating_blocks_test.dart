// Regression guard for the floating crystal blocks (reference FloatingBlocks).
// Renders the same frame with and without a block pulse and asserts the block
// pass actually produces pixels — guards both the uniform index layout
// (uBlockA/uBlockQ/uBlockPulse) and the ray-box slab test against regressions.
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';
import 'package:sonic_topography/src/audio/audio_bands.dart';

Future<ui.Image> _render(SonicShaderController c, double pulse) async {
  const bands = AudioBands(
    subBass: 0.3, bass: 0.3, lowMid: 0.2, mid: 0.2, highMid: 0.15,
    presence: 0.3, brilliance: 0.2, air: 0.15, energy: 0.4,
    warmth: 0.2, brightness: 0.3, sharpness: 0.2, smoothness: 0.6,
    density: 0.5,
  );
  return captureSonicFrameForTesting(
    controller: c, bands: bands, theme: SonicTheme.blueHour,
    width: 400, height: 300, time: 5.0, blockPulse: pulse,
  );
}

void main() {
  test('floating blocks render visible pixels at kick pulse', () async {
    final controller = SonicShaderController();
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue, reason: '${controller.error}');
    final a = await _render(controller, 0);
    final b = await _render(controller, 0.85);
    final da = (await a.toByteData())!;
    final db = (await b.toByteData())!;
    int changed = 0;
    for (int i = 0; i < da.lengthInBytes; i += 4) {
      final d = (da.getUint8(i) - db.getUint8(i)).abs() +
          (da.getUint8(i + 1) - db.getUint8(i + 1)).abs() +
          (da.getUint8(i + 2) - db.getUint8(i + 2)).abs();
      if (d > 20) changed++;
    }
    a.dispose();
    b.dispose();
    // ~2k changed pixels at 800x600 → scale for the 400x300 render here.
    expect(changed, greaterThan(300),
        reason: 'block pass produced no visible pixels: $changed');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
