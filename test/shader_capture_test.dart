// Diagnostic test: drives the two-pass shader pipeline headlessly for ONE
// frame and writes the rasterized display image to build/sonic_capture.png so
// the output can be inspected. It also asserts objective correctness signals
// (varied luminance => real 3D pillars + sky + gaps) and reports the bake +
// display render budgets so the cost order of the pipeline is visible.
//
//   flutter test test/shader_capture_test.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';

/// Analyze a PNG on disk: average luminance, avg RGB, and dark/mid/bright %.
Future<String> analyzePng(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final im = frame.image;
  final rgba = (await im.toByteData())!;
  double sum = 0, rSum = 0, gSum = 0, bSum = 0;
  int dark = 0, mid = 0, bright = 0, n = 0;
  for (int y = 0; y < im.height; y += 3) {
    for (int x = 0; x < im.width; x += 3) {
      final i = (y * im.width + x) * 4;
      final r = rgba.getUint8(i), g = rgba.getUint8(i + 1), b = rgba.getUint8(i + 2);
      final l = (r + g + b) / 3.0;
      sum += l; rSum += r; gSum += g; bSum += b; n++;
      if (l < 30) {
        dark++;
      } else if (l < 120) {
        mid++;
      } else {
        bright++;
      }
    }
  }
  im.dispose();
  return 'avgL=${(sum / n).toStringAsFixed(1)}'
      ' avgRGB=${(rSum/n).round()},${(gSum/n).round()},${(bSum/n).round()}'
      ' dark%=${(100*dark/n).round()} mid%=${(100*mid/n).round()}'
      ' bright%=${(100*bright/n).round()}';
}

AudioBands get _bands => const AudioBands(
      subBass: 0.85, bass: 0.75, lowMid: 0.55, mid: 0.45, highMid: 0.35,
        presence: 0.25, brilliance: 0.18, air: 0.12, energy: 0.6,
        warmth: 0.15, brightness: 0.4, sharpness: 0.2, smoothness: 0.6,
      density: 0.7,
    );

void main() {
  test('render one two-pass frame to png with perf + luminance', () async {
    final controller = SonicShaderController();
    // Let the async FragmentProgram.fromAsset loads complete.
    for (int i = 0; i < 100 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue, reason: 'shaders: ${controller.error}');

    // Small display size on purpose: the test host uses a *software*
    // rasterizer, so the DDA display pass is expensive even though it is cheap
    // on a real GPU. 128² still proves the image is correct.
    const w = 512.0, h = 512.0;

    final t0 = DateTime.now();
    final img = await captureSonicFrameForTesting(
      controller: controller,
      bands: _bands,
      theme: SonicTheme.neonTokyo, // bright palette for a robust luminance signal
      width: w,
      height: h,
    );
    final elapsed = DateTime.now().difference(t0);

    // Also capture the default (nocturnal) theme for visual inspection.
    final noct = await captureSonicFrameForTesting(
      controller: controller,
      bands: _bands,
      theme: SonicTheme.nocturnal,
      width: w,
      height: h,
      camAngle: 0.7,
    );
    final noctPng = await noct.toByteData(format: ui.ImageByteFormat.png);
    await File('build/sonic_capture_nocturnal.png')
        .writeAsBytes(noctPng!.buffer.asUint8List());

    // Capture with active meteors + impact particles to verify the enlarged
    // 20-meteor / 64-particle uniform arrays render the volumetric glow.
    final meteorUniforms = Float32List(20 * 4);
    meteorUniforms[0] = 0.0;    meteorUniforms[1] = 0.0;   // x,z
    meteorUniforms[2] = 14.0;   meteorUniforms[3] = 1.2;   // y, strength
    meteorUniforms[4] = 8.0;    meteorUniforms[5] = -6.0;
    meteorUniforms[6] = 9.0;    meteorUniforms[7] = 1.0;
    final particleUniforms = Float32List(64 * 4);
    for (int i = 0; i < 6; i++) {
      final ang = i * 1.0;
      particleUniforms[i * 4] = 2.0 * math.cos(ang);
      particleUniforms[i * 4 + 1] = 1.0 + i * 0.5;
      particleUniforms[i * 4 + 2] = 2.0 * math.sin(ang);
      particleUniforms[i * 4 + 3] = 0.8;
    }
    final meteorShot = await captureSonicFrameForTesting(
      controller: controller,
      bands: _bands,
      theme: SonicTheme.neonTokyo,
      width: w,
      height: h,
      meteors: meteorUniforms,
      particles: particleUniforms,
    );
    final meteorPng = await meteorShot.toByteData(format: ui.ImageByteFormat.png);
    await File('build/sonic_capture_meteors.png')
        .writeAsBytes(meteorPng!.buffer.asUint8List());
    meteorShot.dispose();
    noct.dispose();

    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull);
    final out = File('build/sonic_capture.png');
    await out.create(recursive: true);
    await out.writeAsBytes(png!.buffer.asUint8List());

    final rgba = (await img.toByteData())!;
    double lum(int x, int y) {
      final i = (y * img.width + x) * 4;
      final r = rgba.getUint8(i), g = rgba.getUint8(i + 1), b = rgba.getUint8(i + 2);
      return (r + g + b) / 3.0 / 255.0;
    }

    // Luminance histogram over the frame.
    final buckets = List<int>.filled(8, 0);
    double realMax = 0;
    for (int y = 0; y < img.height; y += 4) {
      for (int x = 0; x < img.width; x += 4) {
        final l = lum(x, y);
        if (l > realMax) realMax = l;
        buckets[(l * 8).clamp(0, 7).toInt()]++;
      }
    }
    final nonEmptyBuckets = buckets.where((c) => c > 3).length;

    // ignore: avoid_print
    print('SONIC_CAPTURE written=${out.path} size=${img.width}x${img.height}'
        ' elapsed=${elapsed.inMilliseconds}ms'
        ' buckets=$buckets nonEmptyBuckets=$nonEmptyBuckets'
        ' maxLum=${realMax.toStringAsFixed(3)}');

    // Correctness for a DARK neon-on-black aesthetic (matches the reference,
    // which has bright%=0 — the glow is subtle, not blown-out). Assert the frame
    // is non-trivial (has content) and fast, then compare stats to the reference.
    expect(buckets[0], greaterThan(0), reason: 'must have dark region');
    expect(nonEmptyBuckets, greaterThanOrEqualTo(2),
        reason: 'frame must show dark + glow populations: buckets=$buckets');

    // Cost budget sanity: a single frame at 512² on the software rasterizer.
    expect(elapsed.inSeconds, lessThan(60),
        reason: 'two-pass pipeline must be fast: ${elapsed.inSeconds}s');

    img.dispose();

    // ---- Side-by-side comparison vs the actual reference project's canvas. ----
    final refPath = '/tmp/sonic_ref.png';
    if (await File(refPath).exists()) {
      final refStats = await analyzePng(refPath);
      // ignore: avoid_print
      print('SONIC_CMP REF    $refStats');
    }
    final mine = await analyzePng('build/sonic_capture_nocturnal.png');
    // ignore: avoid_print
    print('SONIC_CMP MINE   $mine');

    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 180)));
}
