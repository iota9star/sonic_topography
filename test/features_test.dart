import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';

void main() {
  test('BeatDetector fires on synthetic kick impulses', () {
    final d = BeatDetector();
    Float32List spectrum(double level) {
      final s = Float32List(64);
      for (int i = 0; i < 5; i++) {
        s[i] = level;
      }
      return s;
    }

    // Warm up with a quiet floor for ~2s.
    for (int i = 0; i < 90; i++) {
      d.step(spectrum(0.05), 21 / 1000);
    }
    int onsets = 0;
    double envelopePeak = 0;
    // Kick every 0.5s: quiet 0.4s then loud 0.1s.
    for (int i = 0; i < 400; i++) {
      final loud = (i % 24) < 5;
      final out = d.step(spectrum(loud ? 0.75 : 0.05), 21 / 1000);
      if (out.onset) onsets++;
      if (out.kickEnvelope > envelopePeak) envelopePeak = out.kickEnvelope;
    }
    expect(onsets, greaterThanOrEqualTo(10), reason: 'should lock to the pulse');
    expect(envelopePeak, greaterThan(0.3));
  });

  test('BeatDetector stays silent on flat input', () {
    final d = BeatDetector();
    final s = Float32List(64);
    for (int i = 0; i < 6; i++) {
      s[i] = 0.3;
    }
    int onsets = 0;
    for (int i = 0; i < 300; i++) {
      // Skip the cold-start frames: the initial rise from the empty history
      // is a legitimate flux transient.
      final fired = d.step(s, 21 / 1000).onset;
      if (i >= 100 && fired) onsets++;
    }
    expect(onsets, 0);
  });

  test('All built-in themes exist with fog colors', () {
    expect(SonicTheme.builtIn.length, 18);
    final ids = SonicTheme.builtIn.map((t) => t.id).toSet();
    expect(ids.length, 18);
    for (final t in SonicTheme.builtIn) {
      expect(t.linear.length, 8, reason: '${t.id} needs 8 linear colors');
      expect(t.vFog.x.isFinite, isTrue);
      expect(t.vBase1.x.isFinite, isTrue);
    }
    // Spot-check the ink-wash linear values.
    final ink = SonicTheme.inkWash;
    expect(ink.vBase1.x, 1.0);
    expect(ink.vCoolCore.x, 0.0);
    expect(ink.vRipple.z, closeTo(0.76, 0.001));
    // Palette-derived theme: verify the lerp derivation (cool edge = cool lerp bg 0.35).
    final glacier = SonicTheme.glacierDay;
    expect(glacier.vCoolEdge.x,
        closeTo(glacier.vCoolCore.x + (glacier.vBase1.x - glacier.vCoolCore.x) * 0.35, 1e-4));
  });

  test('Lyrics parse and seek to the active line', () {
    const doc = '''
[00:01.00]first line
[00:05.50][01:00.00]repeated chorus
[00:10.00]last line
''';
    final l = Lyrics.parse(doc);
    expect(l.lines.length, 4); // repeated fan-out
    expect(l.activeIndexAt(const Duration(milliseconds: 500)), -1);
    expect(l.lines[l.activeIndexAt(const Duration(seconds: 2))].text, 'first line');
    expect(l.lines[l.activeIndexAt(const Duration(seconds: 59))].text, 'last line');
    expect(l.lines[l.activeIndexAt(const Duration(seconds: 61))].text, 'repeated chorus');
    expect(l.lines[l.activeIndexAt(const Duration(seconds: 90))].text, 'repeated chorus');
  });
}
