// Captures 3 consecutive frames at the same params and checks if they're
// IDENTICAL (stable) or DIFFERENT (flickering). If the terrain is deterministic
// at a fixed time, consecutive frames should match.
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';

AudioBands get _bands => const AudioBands(
      subBass: 0.5, bass: 0.5, lowMid: 0.4, mid: 0.4, highMid: 0.3,
      presence: 0.2, brilliance: 0.15, air: 0.1, energy: 0.5,
      warmth: 0.15, brightness: 0.4, sharpness: 0.2, smoothness: 0.6,
      density: 0.7,
    );

void main() {
  test('flicker check: consecutive identical-time frames must match', () async {
    final controller = SonicShaderController();
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue);

    // Two captures at the SAME time + params. A stable renderer produces
    // near-identical images; a flickering one produces different bytes.
    final img1 = await captureSonicFrameForTesting(
      controller: controller, bands: _bands, theme: SonicTheme.nocturnal,
      width: 256, height: 256, time: 5.0, camAngle: 0.7,
    );
    final img2 = await captureSonicFrameForTesting(
      controller: controller, bands: _bands, theme: SonicTheme.nocturnal,
      width: 256, height: 256, time: 5.0, camAngle: 0.7,
    );
    final b1 = (await img1.toByteData())!;
    final b2 = (await img2.toByteData())!;
    int diff = 0;
    final n = b1.lengthInBytes;
    for (int i = 0; i < n; i += 4) {
      // compare RGB only (skip alpha)
      if ((b1.getUint8(i) - b2.getUint8(i)).abs() > 2 ||
          (b1.getUint8(i + 1) - b2.getUint8(i + 1)).abs() > 2 ||
          (b1.getUint8(i + 2) - b2.getUint8(i + 2)).abs() > 2) {
        diff++;
      }
    }
    final pct = 100.0 * diff / (n / 4);
    // ignore: avoid_print
    print('SONIC_FLICKER differentPixels=${pct.toStringAsFixed(2)}%');
    // A stable renderer at identical inputs should differ on <1% of pixels.
    expect(pct, lessThan(5.0),
        reason: 'identical-input frames differ by $pct% — renderer is non-deterministic/flickering');
    img1.dispose();
    img2.dispose();
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
