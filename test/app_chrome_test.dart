// Diagnostic: does the app chrome (top bar / band meters / settings) build
// and paint above the scene, at sane positions, without layout overflow?
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/main.dart';
import 'package:sonic_topography/src/audio/audio_bands.dart';
import 'package:sonic_topography/src/audio/demo_analyzer.dart';

void main() {
  testWidgets('app chrome builds and paints at expected positions', (tester) async {
    await tester.pumpWidget(const SonicApp());

    // Let the shader load + a few frames animate.
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('SONIC'), findsOneWidget);
    // Source tabs live in the settings drawer, not the top bar.
    expect(find.text('DEMO'), findsNothing);
    expect(find.text('MUSIC'), findsNothing);
    expect(find.text('MIC'), findsNothing);

    // Band meters sit at the bottom, above the settings panel.
    final subTop = tester.getTopLeft(find.text('SUB'));
    expect(subTop.dy, greaterThan(300), reason: 'band meters must be low');
    expect(tester.takeException(), isNull,
        reason: 'no layout overflow anywhere in the chrome');
  });

  test('demo bands stay in music-like ranges (no over-driven strobing)', () async {
    final demo = DemoAnalyzer();
    await demo.start();
    AudioBands maxBands = AudioBands.idle;
    AudioBands minBands = AudioBands(
      subBass: 1, bass: 1, lowMid: 1, mid: 1, highMid: 1, presence: 1,
      brilliance: 1, air: 1, energy: 1, warmth: 1, brightness: 1, sharpness: 1,
      smoothness: 1, density: 1,
    );
    // Sample ~20s of wall-clock-equivalent by calling read() repeatedly; the
    // analyzer advances on its own stopwatch.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    for (int i = 0; i < 200; i++) {
      final b = demo.read();
      maxBands = AudioBands(
        subBass: maxBands.subBass > b.subBass ? maxBands.subBass : b.subBass,
        bass: maxBands.bass > b.bass ? maxBands.bass : b.bass,
        lowMid: maxBands.lowMid > b.lowMid ? maxBands.lowMid : b.lowMid,
        mid: maxBands.mid > b.mid ? maxBands.mid : b.mid,
        highMid: maxBands.highMid > b.highMid ? maxBands.highMid : b.highMid,
        presence: maxBands.presence > b.presence ? maxBands.presence : b.presence,
        brilliance:
            maxBands.brilliance > b.brilliance ? maxBands.brilliance : b.brilliance,
        air: maxBands.air > b.air ? maxBands.air : b.air,
        energy: maxBands.energy > b.energy ? maxBands.energy : b.energy,
        warmth: 0, brightness: 0, sharpness: 0, smoothness: 0, density: 0,
      );
      minBands = AudioBands(
        subBass: minBands.subBass < b.subBass ? minBands.subBass : b.subBass,
        bass: minBands.bass < b.bass ? minBands.bass : b.bass,
        lowMid: minBands.lowMid < b.lowMid ? minBands.lowMid : b.lowMid,
        mid: minBands.mid < b.mid ? minBands.mid : b.mid,
        highMid: minBands.highMid < b.highMid ? minBands.highMid : b.highMid,
        presence: minBands.presence < b.presence ? minBands.presence : b.presence,
        brilliance:
            minBands.brilliance < b.brilliance ? minBands.brilliance : b.brilliance,
        air: minBands.air < b.air ? minBands.air : b.air,
        energy: minBands.energy < b.energy ? minBands.energy : b.energy,
        warmth: 0, brightness: 0, sharpness: 0, smoothness: 0, density: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    demo.dispose();
    // Music-like ceilings: sub spikes to ≈0.95 on loud kicks (real-music
    // FFT level) but never sits pinned at 1.0 (that strobes the terrain
    // center through the ×5 bake lift).
    expect(maxBands.subBass, lessThan(1.0),
        reason: 'demo sub-bass peak ${maxBands.subBass}');
    expect(maxBands.bass, lessThan(0.62));
    expect(maxBands.mid, lessThan(0.4));
    // The bassline must stay ALIVE between beats: a sustained ≈0.5 floor
    // keeps the kick envelope's breath follower (and the terrain dome)
    // from collapsing — flat-line bands converge the noise floor instead.
    expect(minBands.subBass, greaterThan(0.45),
        reason: 'demo sub-bass floor collapsed to ${minBands.subBass}');
    expect(maxBands.subBass, greaterThan(0.85));
  });
}
