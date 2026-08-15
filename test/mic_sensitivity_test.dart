// End-to-end DSP check for the mic path's band-level auto-normalization:
// quiet-but-audible music must lift the bands into terrain-driving range and
// trigger beat onsets, while room-noise-level input must stay near idle.
//
// AudioRecorder's constructor is pure Dart (a UUID), so MicAnalyzer can be
// instantiated here; the recorder is never started.
@Timeout(Duration(seconds: 120))
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/src/audio/mic_analyzer.dart';

/// Synthesizes [seconds] of "quiet music" at peak amplitude [amp]:
/// 120 BPM kick (55 Hz burst every 0.5 s), a sustained 110 Hz bass note, a
/// 440 Hz melody line, and a touch of hiss — mimicking a mic across the room
/// from a speaker.
List<int> _musicPcm(double seconds, double amp, {int sampleRate = 44100}) {
  final n = (seconds * sampleRate).round();
  final out = List<int>.filled(n * 2, 0);
  void writeSample(int i, double v) {
    final s = (v.clamp(-1.0, 1.0) * 32767).round();
    out[i * 2] = s & 0xff;
    out[i * 2 + 1] = (s >> 8) & 0xff;
  }

  final rng = math.Random(7);
  for (int i = 0; i < n; i++) {
    final t = i / sampleRate;
    // Kick: 55 Hz with an exponential decay, retriggered every 0.5 s.
    final phase = t % 0.5;
    final kick = math.sin(2 * math.pi * 55 * t) *
        math.exp(-phase * 18) *
        0.9;
    final bass = math.sin(2 * math.pi * 110 * t) * 0.5;
    final melody =
        math.sin(2 * math.pi * 440 * t) * 0.25 * (0.5 + 0.5 * math.sin(t * 3));
    final hiss = (rng.nextDouble() * 2 - 1) * 0.02;
    writeSample(i, (kick + bass + melody + hiss) * amp);
  }
  return out;
}

/// White-noise room floor at a tiny amplitude.
List<int> _noisePcm(double seconds, double amp, {int sampleRate = 44100}) {
  final n = (seconds * sampleRate).round();
  final rng = math.Random(11);
  final out = List<int>.filled(n * 2, 0);
  for (int i = 0; i < n; i++) {
    final s = ((rng.nextDouble() * 2 - 1) * amp * 32767).round();
    out[i * 2] = s & 0xff;
    out[i * 2 + 1] = (s >> 8) & 0xff;
  }
  return out;
}

void feed(MicAnalyzer mic, List<int> pcm) {
  // Real streams deliver ~50 ms chunks; match that granularity so the
  // ring-buffer/window path is exercised as in production.
  const chunk = 4096;
  for (int i = 0; i < pcm.length; i += chunk) {
    mic.debugFeedPcm(pcm.sublist(i, math.min(i + chunk, pcm.length)));
  }
}

void main() {
  // AudioRecorder's constructor asynchronously calls into its platform channel;
  // provide a benign mock so MicAnalyzer can be built off-device.
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (call) async => null,
  );

  test('quiet music (pk≈0.05) drives bands into terrain range and fires beats',
      () {
    final mic = MicAnalyzer();
    // Prime the normalizer with 2 s of the quiet track so bandPeak converges,
    // then measure reactivity over the next 3 s.
    feed(mic, _musicPcm(2, 0.05));
    var beats = mic.consumeBeats().length;
    final pcm = _musicPcm(3, 0.05);
    feed(mic, pcm);
    beats += mic.consumeBeats().length;

    final bands = mic.read();
    expect(bands.bass, greaterThan(0.15),
        reason: 'bass should be normalized from ~0.02 up to a visible level, '
            'got ${bands.bass}');
    expect(bands.subBass + bands.bass + bands.mid, greaterThan(0.15));
    expect(beats, greaterThanOrEqualTo(3),
        reason: '120 BPM over 3 s should fire several kick onsets');
  });

  test('very quiet music (pk≈0.02) still becomes visible after riding gain',
      () {
    final mic = MicAnalyzer();
    feed(mic, _musicPcm(4, 0.02));
    feed(mic, _musicPcm(2, 0.02));
    mic.consumeBeats();
    final bands = mic.read();
    expect(bands.bass, greaterThan(0.06),
        reason: 'even whisper-level music should reach a visible level, '
            'got ${bands.bass}');
  });

  test('room noise stays near idle (no dancing to hiss)', () {
    final mic = MicAnalyzer();
    feed(mic, _musicPcm(2, 0.05)); // establish that music was playing
    feed(mic, _noisePcm(3, 0.004));
    final bands = mic.read();
    expect(bands.subBass + bands.bass, lessThan(0.08),
        reason: 'hiss below the normalization floor must not be amplified, '
            'got sub=${bands.subBass} bass=${bands.bass}');
    expect(mic.muted, isFalse, reason: 'non-zero noise is not digital silence');
  });

  test('digital silence reports muted', () {
    final mic = MicAnalyzer();
    feed(mic, List.filled(44100 * 3, 0)); // 3 s of zero bytes
    expect(mic.muted, isTrue);
    expect(mic.read().bass, 0.0);
  });
}
