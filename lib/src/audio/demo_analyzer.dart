import 'dart:math';

import 'audio_bands.dart';

/// A synthetic audio source that generates evolving, musically-shaped bands
/// without any microphone or file. It models a kick on each beat, a snare on
/// offbeats, and slow harmonic drift across chord sections — then exposes the
/// result directly as [AudioBands].
///
/// This is the default source: it guarantees the visualizer looks alive on
/// every platform with zero permissions, and the terrain visibly pulses and
/// stretches in time with the modeled rhythm. (A live [MicAnalyzer] uses the
/// real FFT + [BandExtractor] pipeline for actual microphone input.)
class DemoAnalyzer extends AudioAnalyzer {
  DemoAnalyzer({this.sampleRate = 44100});

  final int sampleRate;

  double _t = 0;
  bool _active = false;
  double _bpm = 124;
  int _lastBeatIndex = -1;
  // Wall-clock clock so the rhythm advances at real time regardless of the
  // host's frame rate (a 360Hz display would otherwise fast-forward the model
  // 6× and make the terrain flicker). Stopped until start().
  final Stopwatch _clock = Stopwatch();

  @override
  AudioBands read() {
    if (!_active) return AudioBands.idle;
    // Advance by REAL elapsed time (frame-rate independent).
    final now = _clock.elapsedMilliseconds / 1000.0;
    _t = now;
    // Phase offset: start just past a kick peak so the terrain stands at
    // full height from the very first visible frame (no launch rise-up).
    final beat = _t * (_bpm / 60.0) + 0.15;
    // Band drivers shaped like REAL loud music through the FFT pipeline, not
    // smooth sines. Real audio keeps sub-bass fluctuating fast above the
    // kick envelope's adaptive noise floor: a sustained bassline around 0.5
    // with hard kick spikes to ≈0.95 every beat. That above-floor movement
    // is what keeps the reference's breath follower (and thus the terrain
    // dome) alive BETWEEN beats — a flat 0.36 line converges the floor and
    // the dome collapses to the horizon sliver between kicks.
    final beatPhase = beat - beat.floorToDouble();
    final kick01 = exp(-5.0 * beatPhase); // sharp 1 → 0.01 decay per beat
    final snare01 = sin(beat * pi + pi * 0.5) * 0.5 + 0.5;
    final drift1 = sin(beat * 0.5) * 0.5 + 0.5;
    final drift2 = sin(beat * 0.7 + 1.0) * 0.5 + 0.5;
    final drift3 = sin(beat * 1.1 + 2.0) * 0.5 + 0.5;

    // Slow 32-beat intensity cycle (~15s) so the demo breathes like a song
    // with quiet verses and loud choruses instead of pumping at full level
    // forever.
    final intensity = 0.6 + 0.4 * (sin(beat * pi / 16.0) * 0.5 + 0.5);

    // Chord section changes every 16 beats → timbre drift (mostly cool/blue).
    final section = (beat / 16.0).floor();
    final chordIndex = section % 6;
    final warmth = (chordIndex == 3) ? 0.35 : 0.12;
    _bpm = 120 + 6 * sin(_t * 0.05);

    return AudioBands(
      // Real-music levels: sub bassline rides ~0.5 with kick spikes to
      // ≈0.95; bass (their screenshot metrics show 0.55 mid-song) ~0.42-0.56.
      subBass: (0.50 + 0.45 * intensity * kick01).clamp(0.0, 1.0),
      bass: (0.42 + 0.14 * intensity * drift1).clamp(0.0, 1.0),
      lowMid: (0.07 + 0.25 * intensity * drift2).clamp(0.0, 1.0),
      mid: (0.07 + 0.25 * intensity * snare01).clamp(0.0, 1.0),
      highMid: (0.05 + 0.19 * intensity * drift3).clamp(0.0, 1.0),
      presence: (0.04 + 0.13 * intensity * (sin(beat * 1.5) * 0.5 + 0.5)).clamp(
        0.0,
        1.0,
      ),
      brilliance:
          (0.03 + 0.09 * intensity * (sin(beat * 2.0 + 0.5) * 0.5 + 0.5)).clamp(
            0.0,
            1.0,
          ),
      air: (0.02 + 0.06 * intensity * (sin(beat * 2.5) * 0.5 + 0.5)).clamp(
        0.0,
        1.0,
      ),
      energy: (0.15 + 0.5 * intensity * kick01).clamp(0.0, 1.0),
      warmth: warmth,
      brightness: (0.3 + 0.15 * sin(beat * 0.3)).clamp(0.0, 1.0),
      sharpness: (0.18 + 0.12 * sin(beat * 0.9)).clamp(0.0, 1.0),
      smoothness: 0.65,
      density: 0.7,
    );
  }

  @override
  List<Beat> consumeBeats() {
    // Procedural beat detection from the clock: fire a kick on even beats and a
    // snare on odd beats, aligned with the band pulses from read().
    final beat = _t * (_bpm / 60.0) + 0.15;
    final curBeat = beat.floor();
    final out = <Beat>[];
    if (curBeat > _lastBeatIndex) {
      _lastBeatIndex = curBeat;
      if (curBeat % 2 == 0) {
        out.add(Beat(0.75, 'kick'));
      } else {
        out.add(Beat(0.45, 'snare'));
      }
    }
    return out;
  }

  @override
  bool get isActive => _active;

  @override
  Future<void> start() async {
    _active = true;
    _clock.start();
  }

  @override
  Future<void> stop() async {
    _active = false;
    _clock.stop();
  }

  @override
  void dispose() {
    _active = false;
    _clock.stop();
  }
}
