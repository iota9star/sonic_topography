/// Frequency triggers — a faithful port of the reference `TriggerConfig` +
/// `AudioEngine.evaluateTrigger` (Auto Beat spectral-flux detection, Advanced
/// crosshair mode) plus `trackAutoPulse`'s auto band tracking.
///
/// One instance per effect (Pulse / Meteor / Snare). Feed it the dB-scaled
/// spectrum (0..1 per bin, the AnalyserNode byte mapping) once per analysis
/// frame; [step] returns the fired strength, or null.
library;

import 'dart:math' as math;
import 'dart:typed_data';

enum FreqTriggerMode { autoBeat, advanced }

enum FreqTriggerAction { pulse, meteor, snare }

/// Mutable runtime config (the reference mutates these live from its UI).
class FreqTriggerConfig {
  FreqTriggerConfig(this.action, {
    this.enabled = true,
    this.mode = FreqTriggerMode.autoBeat,
    this.freqIndex = -1,
    this.threshold = 0.5,
    required this.sensitivity,
    required this.cooldown,
    required this.bandStart,
    required this.bandEnd,
    required this.strength,
  });

  final FreqTriggerAction action;
  bool enabled;
  FreqTriggerMode mode;

  // Advanced mode: crosshair position on the spectrum canvas.
  int freqIndex;
  double threshold;

  // Auto Beat mode.
  double sensitivity; // 0..1
  int cooldown; // reference frames (~60 fps)
  int bandStart, bandEnd; // 512-bin spectrum indices
  double strength; // pulseStrength 0..5

  /// Reference getTriggerRange: the monitored bins. Advanced mode widens the
  /// crosshair bin ±2.
  int get rangeStart => mode == FreqTriggerMode.autoBeat
      ? bandStart
      : math.max(0, (freqIndex >= 0 ? freqIndex : 102) - 2);
  int get rangeEnd => mode == FreqTriggerMode.autoBeat
      ? bandEnd
      : math.min(511, (freqIndex >= 0 ? freqIndex : 102) + 2);

  // Reference per-config evaluation state.
  double _smoothedFlux = 0;
  double _prevSmoothedFlux = 0;
  final Float64List _fluxHistory = Float64List(40);
  int _fluxHistoryIndex = 0;
  double _cooldownCounter = 0;
  int _beatHold = 0;
}

class _Fire {
  const _Fire(this.strength);
  final double strength;
}

/// The three triggers the reference engine runs each frame.
class FreqTriggers {
  FreqTriggers()
      : pulse = FreqTriggerConfig(FreqTriggerAction.pulse,
            sensitivity: 0.85, cooldown: 15, bandStart: 1, bandEnd: 2,
            strength: 0.2),
        meteor = FreqTriggerConfig(FreqTriggerAction.meteor,
            sensitivity: 0.45, cooldown: 241, bandStart: 159, bandEnd: 174,
            strength: 0.5),
        snare = FreqTriggerConfig(FreqTriggerAction.snare,
            sensitivity: 0.6, cooldown: 30, bandStart: 47, bandEnd: 120,
            strength: 0.3);

  final FreqTriggerConfig pulse, meteor, snare;

  /// Latest dB spectrum (for the crosshair canvas).
  Float64List? liveSpectrum;

  // Auto-track state (reference trackAutoPulse): 3 s of the low 30 bins,
  // re-evaluated every second, locking the pulse band onto the strongest
  // transient pair.
  final List<(double time, Float64List data)> _pulseTracker = [];
  double _lastAutoTrackTime = -1e9;

  /// Run all three triggers over [spectrum] (dB scale, 0..1 per bin, 512
  /// layout). Returns fired (action, strength) pairs. [time] is a monotonic
  /// seconds clock; [dtSec] the interval since the previous analysis frame.
  List<(FreqTriggerAction, double)> step(
      Float64List spectrum, double time, double dtSec) {
    liveSpectrum = spectrum;
    final frameDt = dtSec * 60.0; // reference counters are 60 fps frames
    _trackAutoPulse(spectrum, time);
    final out = <(FreqTriggerAction, double)>[];
    final f = _evaluate(pulse, spectrum, frameDt);
    if (f != null) out.add((FreqTriggerAction.pulse, f.strength));
    final m = _evaluate(meteor, spectrum, frameDt);
    if (m != null) out.add((FreqTriggerAction.meteor, m.strength));
    final s = _evaluate(snare, spectrum, frameDt);
    if (s != null) out.add((FreqTriggerAction.snare, s.strength));
    return out;
  }

  void _trackAutoPulse(Float64List spectrum, double time) {
    const watchBins = 30;
    final low = Float64List.sublistView(
        spectrum, 0, math.min(watchBins, spectrum.length));
    _pulseTracker.add((time, Float64List.fromList(low)));
    while (_pulseTracker.isNotEmpty && time - _pulseTracker.first.$1 > 3.0) {
      _pulseTracker.removeAt(0);
    }
    if (time - _lastAutoTrackTime <= 1.0) return;
    _lastAutoTrackTime = time;
    if (_pulseTracker.length < 30) return;

    final n = _pulseTracker.length;
    final bins = _pulseTracker.first.$2.length;
    final maxDiff = Float64List(bins);
    for (int f = 1; f < n; f++) {
      final cur = _pulseTracker[f].$2, prev = _pulseTracker[f - 1].$2;
      for (int b = 0; b < bins; b++) {
        final diff = cur[b] - prev[b];
        if (diff > 0.01 && diff > maxDiff[b]) maxDiff[b] = diff;
      }
    }
    // Top two bins by max positive diff.
    int b1 = 0, b2 = 0;
    for (int b = 1; b < bins; b++) {
      if (maxDiff[b] > maxDiff[b1]) b1 = b;
    }
    b2 = b1 == 0 ? 1 : 0;
    for (int b = 0; b < bins; b++) {
      if (b != b1 && maxDiff[b] > maxDiff[b2]) b2 = b;
    }
    // Silence/mud guard: a weak top transient means no punchy kick in the
    // window — keep the previous lock.
    if (maxDiff[b1] < 0.15) return;
    pulse.bandStart = math.min(b1, b2);
    pulse.bandEnd = math.max(b1, b2);
    pulse.sensitivity = 0.85;
  }

  _Fire? _evaluate(FreqTriggerConfig c, Float64List spectrum, double frameDt) {
    if (!c.enabled) return null;
    _Fire? fired;

    if (c.mode == FreqTriggerMode.advanced && c.freqIndex >= 0) {
      // Crosshair: mean level of the ±2-bin window vs the threshold line.
      double sum = 0;
      int count = 0;
      for (int k = c.rangeStart; k <= c.rangeEnd; k++) {
        if (k >= 0 && k < spectrum.length) {
          sum += spectrum[k];
          count++;
        }
      }
      final eVal = count > 0 ? sum / count : 0.0;
      if (c._cooldownCounter <= 0 && eVal > c.threshold) {
        fired = _Fire(eVal);
        c._cooldownCounter = 60; // 1 s fixed
      }
    }

    if (c._cooldownCounter > 0) c._cooldownCounter -= frameDt;

    if (c.mode == FreqTriggerMode.autoBeat) {
      // Band spectral flux with a 1%-of-scale noise gate, normalized by the
      // band's bin count.
      double flux = 0;
      final prev = _prevSpectrum;
      final start = c.bandStart.clamp(0, spectrum.length - 1);
      final end = c.bandEnd.clamp(0, spectrum.length - 1);
      for (int i = start; i <= end; i++) {
        final diff = spectrum[i] - (i < prev.length ? prev[i] : 0.0);
        if (diff > 0.01) flux += diff;
      }
      final fluxScore = flux / math.max(1, end - start + 1);

      c._smoothedFlux += (fluxScore - c._smoothedFlux) * 0.4;
      c._fluxHistory[c._fluxHistoryIndex] = c._smoothedFlux;
      c._fluxHistoryIndex = (c._fluxHistoryIndex + 1) % c._fluxHistory.length;

      double avg = 0;
      for (final v in c._fluxHistory) {
        avg += v;
      }
      avg /= c._fluxHistory.length;
      double variance = 0;
      for (final v in c._fluxHistory) {
        variance += (v - avg) * (v - avg);
      }
      final stdDev = math.sqrt(variance / c._fluxHistory.length);

      final thresholdMultiplier = math.max(0.1, 5.0 - c.sensitivity * 4.0);
      final adaptiveThreshold =
          math.max(0.01, avg + stdDev * thresholdMultiplier);
      final isPeak = c._prevSmoothedFlux > adaptiveThreshold &&
          c._prevSmoothedFlux >= c._smoothedFlux;

      if (c._beatHold > 0) {
        c._beatHold--;
      } else if (isPeak &&
          c._prevSmoothedFlux - c._smoothedFlux > 0.0001) {
        // ×30 compensates the per-bin flux normalization so the effect
        // strength clears the scene's thresholds (reference comment).
        fired = _Fire(c._prevSmoothedFlux * 30.0 * c.strength);
        c._beatHold = c.cooldown;
      }
      c._prevSmoothedFlux = c._smoothedFlux;
    }

    return fired;
  }

  Float64List _prevSpectrum = Float64List(0);

  /// Must be called with the same spectrum right after every [step] so the
  /// next frame's flux has its previous frame (the reference stores prevData
  /// in its main loop).
  void commitFrame(Float64List spectrum) {
    if (_prevSpectrum.length != spectrum.length) {
      _prevSpectrum = Float64List.fromList(spectrum);
    } else {
      _prevSpectrum.setAll(0, spectrum);
    }
  }
}
