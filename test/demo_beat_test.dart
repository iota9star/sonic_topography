import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/src/audio/demo_analyzer.dart';

void main() {
  test('demo emits beats continuously while active', () async {
    final demo = DemoAnalyzer();
    await demo.start();
    int kicks = 0, snares = 0;
    double lastSub = 0, maxSub = 0;
    // Simulate ~4s of the 60Hz tick loop, exactly like the controller does.
    for (int i = 0; i < 240; i++) {
      final b = demo.read();
      if (b.subBass > maxSub) maxSub = b.subBass;
      lastSub = b.subBass;
      for (final beat in demo.consumeBeats()) {
        if (beat.type == 'kick') {
          kicks++;
        } else if (beat.type == 'snare') {
          snares++;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    demo.dispose();
    // ~120bpm over 4s → ~8 beats total (alternating kick/snare).
    expect(kicks, greaterThan(2), reason: 'kicks=$kicks snares=$snares');
    expect(snares, greaterThan(2), reason: 'kicks=$kicks snares=$snares');
    expect(maxSub, greaterThan(0.5), reason: 'sub peak $maxSub');
    expect(lastSub, greaterThan(0.3), reason: 'sub floor $lastSub');
  });
}
