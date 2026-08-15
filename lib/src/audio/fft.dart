/// Tiny radix-2 in-place FFT (Cooley–Tukey) plus band extraction helpers.
///
/// Sufficient for the visualization: we feed 1024 samples at a time. All math
/// is done with double precision in Dart; this runs well under a millisecond
/// per frame on every platform, leaving the GPU budget for the shader.
library;

import 'dart:math';
import 'dart:typed_data';

import 'audio_bands.dart';

class Fft {
  Fft(int size)
      : n = size,
        assert(size > 0 && (size & (size - 1)) == 0,
            'Fft size must be a power of two') {
    _re = Float64List(n);
    _im = Float64List(n);
    _window = _hann(n);
    _bitReverseTable = _bitRevTable(n);
  }

  final int n;
  late final Float64List _re;
  late final Float64List _im;
  late final Float64List _window;
  late final List<int> _bitReverseTable;

  /// Compute magnitudes (0..1 per bin, normalized by n/2) for [samples], which
  /// must have length == n. Output has n/2+1 entries.
  Float64List magnitudes(Float64List samples) {
    assert(samples.length == n);
    for (int i = 0; i < n; i++) {
      _re[i] = samples[i] * _window[i];
      _im[i] = 0.0;
    }
    _transform(_re, _im);
    final out = Float64List(n ~/ 2 + 1);
    final norm = 2.0 / n;
    for (int i = 0; i < out.length; i++) {
      out[i] = sqrt(_re[i] * _re[i] + _im[i] * _im[i]) * norm;
    }
    return out;
  }

  void _transform(Float64List re, Float64List im) {
    final n = this.n;
    // bit-reversal permutation
    for (int i = 0; i < n; i++) {
      final j = _bitReverseTable[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    // butterflies with a recursive (running) twiddle factor — verified against
    // a pure sine to produce a single clean bin peak.
    for (int size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final ang = -2 * pi / size;
      final wr0 = cos(ang);
      final wi0 = sin(ang);
      for (int i = 0; i < n; i += size) {
        double wr = 1.0, wi = 0.0;
        for (int k = 0; k < half; k++) {
          final a = i + k;
          final b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final nwr = wr * wr0 - wi * wi0;
          wi = wi * wr0 + wr * wi0;
          wr = nwr;
        }
      }
    }
  }

  static Float64List _hann(int n) {
    final w = Float64List(n);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 - 0.5 * cos(2 * pi * i / (n - 1));
    }
    return w;
  }

  static List<int> _bitRevTable(int n) {
    final bits = n.bitLength - 1; // log2(n)
    final table = List<int>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      int x = i, r = 0;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      table[i] = r;
    }
    return table;
  }
}

/// Map linear FFT magnitudes onto the reference's AnalyserNode byte scale:
/// each bin becomes `(dB + 75) / 45` clamped to 0..1 — a hard noise gate at
/// −75 dBFS with a 45 dB dynamic window (the reference's minDecibels /
/// maxDecibels). [gain] pre-scales amplitudes (e.g. 2× Hann coherent-gain
/// correction) so full-scale tones read ~1.0.
Float64List dbSpectrum(Float64List magnitudes, {double gain = 1.0}) {
  final out = Float64List(magnitudes.length);
  const k = 20.0 / ln10;
  for (int i = 0; i < magnitudes.length; i++) {
    final m = magnitudes[i] * gain;
    final db = m > 1e-9 ? k * log(m) : -120.0;
    out[i] = ((db + 75.0) / 45.0).clamp(0.0, 1.0);
  }
  return out;
}

/// Maps an FFT magnitude spectrum to the smoothed [AudioBands] used by the
/// shader. Band boundaries match the reference (relative to a 512-bin
/// spectrum). For other bin counts, frequency ratios are used so it works at
/// any sample rate / FFT size. Input should already be on the reference's
/// dB scale (see [dbSpectrum]) — feed linear magnitudes only if they are
/// pre-calibrated (the demo synthesizer does that).
class BandExtractor {
  BandExtractor({this.binCount = 512, this.smoothingTau = 0.15}) {
    _prevMagnitudes = Float64List(binCount + 1);
  }

  final int binCount;

  /// Band EMA time constant (seconds). The reference cascades three stages —
  /// AnalyserNode smoothing 0.8 (τ≈83 ms) + engine EMA 0.15/frame (τ≈111 ms)
  /// + scene responseBlend (τ≈32 ms) — for a damped ~200 ms feel. Paths that
  /// already pre-smooth use a shorter τ here.
  final double smoothingTau;
  late Float64List _prevMagnitudes;

  double _smBass = 0, _smBass2 = 0, _smLowMid = 0, _smMid = 0, _smHighMid = 0;
  double _smPresence = 0, _smBrilliance = 0, _smAir = 0, _smEnergy = 0;
  double _smWarmth = 0, _smBrightness = 0, _smSharpness = 0, _smSmoothness = 0.6;
  double _smDensity = 0.5;
  double _prevBrightness = 0;

  // Reference bin boundaries (for a 512-bin spectrum, ~44.1/48k).
  // We convert to fractions of binCount so this is sample-rate agnostic.
  static const _frac = _Bounds();

  double _avg(Float64List mag, double fromBin, double toBin) {
    final a = (fromBin).clamp(0, mag.length - 1).toInt();
    final b = (toBin).clamp(0, mag.length - 1).toInt();
    if (b < a) return 0;
    double sum = 0;
    for (int i = a; i <= b; i++) {
      sum += mag[i];
    }
    return sum / (b - a + 1);
  }

  /// Sum (not average) of bins in a range — the reference's warmth/brightness
  /// numerators are band SUMS over the full energy sum, so each band's bin
  /// count weights in.
  double _sum(Float64List mag, double fromBin, double toBin) {
    final a = (fromBin).clamp(0, mag.length - 1).toInt();
    final b = (toBin).clamp(0, mag.length - 1).toInt();
    if (b < a) return 0;
    double sum = 0;
    for (int i = a; i <= b; i++) {
      sum += mag[i];
    }
    return sum;
  }

  /// Process a magnitude spectrum and return smoothed bands. [dtSec] is the
  /// seconds since the previous call, so the EMA runs at a fixed time constant
  /// regardless of analysis cadence.
  AudioBands process(Float64List magnitudes, {double dtSec = 0.023}) {
    final len = magnitudes.length;
    if (_prevMagnitudes.length != len) {
      _prevMagnitudes = Float64List(len);
    }
    final n = len.toDouble();
    // Scale reference bins by n/512.
    double bin(double v) => v * n / 512.0;

    final subBass = _avg(magnitudes, bin(_frac.subBass0), bin(_frac.subBass1));
    final bass = _avg(magnitudes, bin(_frac.bass0), bin(_frac.bass1));
    final lowMid = _avg(magnitudes, bin(_frac.lowMid0), bin(_frac.lowMid1));
    final mid = _avg(magnitudes, bin(_frac.mid0), bin(_frac.mid1));
    final highMid = _avg(magnitudes, bin(_frac.highMid0), bin(_frac.highMid1));
    final presence = _avg(magnitudes, bin(_frac.presence0), bin(_frac.presence1));
    final brilliance =
        _avg(magnitudes, bin(_frac.brilliance0), bin(_frac.brilliance1));
    final air = _avg(magnitudes, bin(_frac.air0), bin(_frac.air1));

    double energySum = 0;
    double vol = 0;
    for (int i = 0; i < magnitudes.length; i++) {
      energySum += magnitudes[i];
      vol += (magnitudes[i] - _prevMagnitudes[i]).abs();
      _prevMagnitudes[i] = magnitudes[i];
    }
    final energy = energySum / magnitudes.length;
    final warmth = energySum > 0
        ? (_sum(magnitudes, bin(_frac.subBass0), bin(_frac.mid1)) / energySum)
            .clamp(0.0, 1.0)
        : 0.0;
    final brightness = energySum > 0
        ? (_sum(magnitudes, bin(_frac.presence0), bin(_frac.air1)) / energySum)
            .clamp(0.0, 1.0)
        : 0.0;
    final sharpness = ((brightness - _prevBrightness) * 10.0).clamp(0.0, 9.0);
    _prevBrightness = brightness;
    final smoothness = (1.0 - (vol / magnitudes.length) * 2.0).clamp(0.0, 1.0);
    // Density: fraction of the 8 bands above energy×1.5 — the reference's
    // adaptive threshold, so quiet-but-active material still counts.
    final bandVals = [subBass, bass, lowMid, mid, highMid, presence, brilliance, air];
    int activeBands = 0;
    for (final v in bandVals) {
      if (v > energy * 1.5) activeBands++;
    }
    final density = (activeBands / 8.0).clamp(0.0, 1.0);

    final dt = (1.0 - exp(-dtSec / smoothingTau)).clamp(0.02, 1.0);
    _smBass += (subBass - _smBass) * dt;
    _smBass2 += (bass - _smBass2) * dt;
    _smLowMid += (lowMid - _smLowMid) * dt;
    _smMid += (mid - _smMid) * dt;
    _smHighMid += (highMid - _smHighMid) * dt;
    _smPresence += (presence - _smPresence) * dt;
    _smBrilliance += (brilliance - _smBrilliance) * dt;
    _smAir += (air - _smAir) * dt;
    _smEnergy += (energy - _smEnergy) * dt;
    _smWarmth += (warmth - _smWarmth) * dt;
    _smBrightness += (brightness - _smBrightness) * dt;
    _smSharpness += (sharpness - _smSharpness) * dt;
    _smSmoothness += (smoothness - _smSmoothness) * dt;
    _smDensity += (density - _smDensity) * dt;

    return AudioBands(
      subBass: _smBass.clamp(0.0, 1.0),
      bass: _smBass2.clamp(0.0, 1.0),
      lowMid: _smLowMid.clamp(0.0, 1.0),
      mid: _smMid.clamp(0.0, 1.0),
      highMid: _smHighMid.clamp(0.0, 1.0),
      presence: _smPresence.clamp(0.0, 1.0),
      brilliance: _smBrilliance.clamp(0.0, 1.0),
      air: _smAir.clamp(0.0, 1.0),
      energy: _smEnergy.clamp(0.0, 1.0),
      warmth: _smWarmth.clamp(0.0, 1.0),
      brightness: _smBrightness.clamp(0.0, 1.0),
      sharpness: _smSharpness.clamp(0.0, 1.0),
      smoothness: _smSmoothness.clamp(0.0, 1.0),
      density: _smDensity.clamp(0.0, 1.0),
    );
  }
}

class _Bounds {
  const _Bounds();
  // reference bin indices (inclusive ranges) for 512-bin spectrum
  final double subBass0 = 0, subBass1 = 1;
  final double bass0 = 2, bass1 = 3;
  final double lowMid0 = 4, lowMid1 = 7;
  final double mid0 = 8, mid1 = 18;
  final double highMid0 = 19, highMid1 = 46;
  final double presence0 = 47, presence1 = 93;
  final double brilliance0 = 94, brilliance1 = 186;
  final double air0 = 187, air1 = 372;
}
