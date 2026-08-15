import 'dart:math' as math;
import 'dart:typed_data';

/// Spectral-flux kick detector — a faithful Dart port of the reference
/// `beatDetector.ts` + `kickEnvelope.ts` (v1.1.3+).
///
/// Four overlapping windows watch the low FFT bins (the kick region). Each
/// frame the active window's positive spectral flux is compared against an
/// adaptive threshold (rolling mean + gain·σ over a 90-frame history). A
/// local flux maximum above the threshold fires an onset. A kick envelope
/// follower (noise floor + attack/release) turns the raw kick level into a
/// smooth 0..1 pump the terrain can ride.
class BeatWindowDef {
  const BeatWindowDef(this.name, this.start, this.end);
  final String name;
  final int start, end;
}

class BeatDetectorOutput {
  const BeatDetectorOutput({
    required this.onset,
    required this.kickLevel,
    required this.kickFlux,
    required this.kickThreshold,
    required this.kickEnvelope,
    required this.kickConfidence,
    required this.activeWindow,
  });

  /// Whether a kick onset fired this frame.
  final bool onset;

  /// Gated kick level (0..1) of the active window.
  final double kickLevel;

  /// The flux value at the detected peak (0 when no onset).
  final double kickFlux;

  /// The adaptive threshold flux had to exceed.
  final double kickThreshold;

  /// Smooth 0..1 envelope — breathes with the kick, punches on onsets.
  final double kickEnvelope;

  /// 0..1 confidence of the last detection.
  final double kickConfidence;

  /// Name of the window currently driving detection.
  final String activeWindow;
}

class BeatDetector {
  BeatDetector({this.sensitivity = 100});

  /// 0..100 — lower is stricter, higher is more sensitive.
  int sensitivity;

  static const List<BeatWindowDef> windows = [
    BeatWindowDef('Deep', 0, 2),
    BeatWindowDef('Classic', 1, 4),
    BeatWindowDef('Punch', 2, 6),
    BeatWindowDef('Wide', 0, 7),
  ];

  static const int _fluxHistorySize = 90;
  static const double _windowScoreDecay = 0.965;
  static const double _fluxSmoothing = 0.35;
  static const double _cooldownSeconds = 0.12;

  // State.
  int _activeWindowIndex = 1;
  final List<double> _windowScores = List.filled(4, 0);
  final List<double> _previousWindowLevels = List.filled(4, 0);
  final Float32List _fluxHistory = Float32List(_fluxHistorySize);
  int _fluxHistoryIndex = 0;
  double _smoothedFlux = 0;
  double _previousSmoothedFlux = 0;
  double _cooldownRemaining = 0;

  // Kick envelope state (kickEnvelope.ts).
  double _noiseFloor = 0;
  double _kickEnvelope = 0;

  static const double _noiseFloorAttackRate = 1.15;
  static const double _noiseFloorReleaseRate = 0.35;
  static const double _levelGate = 0.025;
  static const double _breathGain = 0.18;
  static const double _maxBreath = 0.11;
  static const double _onsetMinImpulse = 0.48;
  static const double _onsetGain = 0.95;
  static const double _envelopeAttackRate = 42;
  static const double _envelopeReleaseRate = 11.5;

  /// Derived trigger params from [sensitivity] (strict → default → sensitive).
  ({double gain, double floor, double minFlux}) get _params {
    final s = sensitivity.clamp(0, 100).toDouble();
    final lowerHalf = s <= 50 ? s / 50 : 1.0;
    final upperHalf = s > 50 ? (s - 50) / 50 : 0.0;
    double mix(double strict, double def, double sensitive) {
      final first = strict + (def - strict) * lowerHalf;
      return first + (sensitive - first) * upperHalf;
    }

    return (
      gain: mix(2.6, 1.8, 1.1),
      floor: mix(0.05, 0.028, 0.016),
      minFlux: mix(0.07, 0.045, 0.025),
    );
  }

  static double _blendForRate(double rate, double dt) =>
      (1.0 - math.exp(-rate * dt)).clamp(0.0, 1.0);

  /// Advance the detector one analysis frame.
  ///
  /// [spectrum] is the magnitude spectrum (values ~0..1, bin 0 = DC).
  /// [dt] is the seconds since the previous analysis frame.
  BeatDetectorOutput step(List<double> spectrum, double dt) {
    final safeDt = dt.isFinite && dt > 0 ? dt : 0.0;
    final p = _params;

    // Per-window weighted levels (triangular weighting around the center).
    final levels = List<double>.filled(windows.length, 0);
    for (int w = 0; w < windows.length; w++) {
      final win = windows[w];
      final center = (win.start + win.end) / 2;
      final halfWidth = math.max(1, (win.end - win.start + 1) / 2);
      double weighted = 0, weightTotal = 0;
      for (int bin = win.start; bin <= win.end; bin++) {
        final v = bin < spectrum.length ? spectrum[bin] : 0.0;
        final distance = (bin - center).abs();
        final weight = 0.35 + 0.65 * (1 - math.min(1, distance / halfWidth));
        weighted += v * weight;
        weightTotal += weight;
      }
      levels[w] = weightTotal > 0 ? weighted / weightTotal : 0;
    }

    // Window auto-selection by decaying flux score.
    final nextScores = List<double>.filled(windows.length, 0);
    for (int w = 0; w < windows.length; w++) {
      final flux = math.max(0.0, levels[w] - _previousWindowLevels[w]);
      final width = windows[w].end - windows[w].start + 1;
      nextScores[w] =
          _windowScores[w] * _windowScoreDecay + flux * (1 / math.sqrt(width));
    }
    for (int w = 0; w < nextScores.length; w++) {
      if (nextScores[w] > nextScores[_activeWindowIndex] * 1.03) {
        _activeWindowIndex = w;
      }
    }

    final rawFlux =
        math.max(0.0, levels[_activeWindowIndex] - _previousWindowLevels[_activeWindowIndex]);
    _smoothedFlux += (rawFlux - _smoothedFlux) * _fluxSmoothing;

    // Adaptive threshold from the flux history.
    double sum = 0;
    for (final v in _fluxHistory) {
      sum += v;
    }
    final avg = sum / _fluxHistorySize;
    double varSum = 0;
    for (final v in _fluxHistory) {
      varSum += (v - avg) * (v - avg);
    }
    final stdDev = math.sqrt(varSum / _fluxHistorySize);
    final threshold =
        math.max(p.floor, avg + stdDev * p.gain);

    final cooldown = math.max(0.0, _cooldownRemaining - safeDt);
    final isPeak = _previousSmoothedFlux > threshold &&
        _previousSmoothedFlux >= _smoothedFlux &&
        _previousSmoothedFlux >= p.minFlux;
    final onset = cooldown <= 0 && isPeak;
    final displayedFlux = onset ? _previousSmoothedFlux : _smoothedFlux;

    _fluxHistory[_fluxHistoryIndex] = _smoothedFlux;
    _fluxHistoryIndex = (_fluxHistoryIndex + 1) % _fluxHistorySize;
    _previousWindowLevels.setAll(0, levels);
    _previousSmoothedFlux = _smoothedFlux;
    _cooldownRemaining = onset ? _cooldownSeconds : cooldown;

    // Kick envelope follower.
    final rawLevel = levels[_activeWindowIndex].clamp(0.0, 1.0);
    final floorRate =
        rawLevel > _noiseFloor ? _noiseFloorAttackRate : _noiseFloorReleaseRate;
    _noiseFloor += (rawLevel - _noiseFloor) * _blendForRate(floorRate, safeDt);
    final kickLevel =
        (rawLevel - _noiseFloor - _levelGate).clamp(0.0, 1.0);
    final breathTarget = math.min(_maxBreath, kickLevel * _breathGain);
    final onsetTarget = onset
        ? math.max(_onsetMinImpulse, kickLevel * _onsetGain)
        : 0.0;
    final targetEnvelope = math.max(breathTarget, onsetTarget);
    final envelopeRate = targetEnvelope > _kickEnvelope
        ? _envelopeAttackRate
        : _envelopeReleaseRate;
    _kickEnvelope = math.max(
        breathTarget,
        _kickEnvelope +
            (targetEnvelope - _kickEnvelope) * _blendForRate(envelopeRate, safeDt));
    _kickEnvelope = _kickEnvelope.clamp(0.0, 1.0);

    final confidence =
        (displayedFlux / math.max(0.001, threshold * 2.2)).clamp(0.0, 1.0);

    return BeatDetectorOutput(
      onset: onset,
      kickLevel: kickLevel,
      kickFlux: onset ? displayedFlux : 0.0,
      kickThreshold: threshold,
      kickEnvelope: _kickEnvelope,
      kickConfidence: confidence,
      activeWindow: windows[_activeWindowIndex].name,
    );
  }
}
