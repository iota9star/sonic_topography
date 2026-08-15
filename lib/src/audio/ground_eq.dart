import 'audio_bands.dart';

/// A 16-point ground-EQ curve that reshapes how strongly each frequency band
/// drives the terrain elevation — a faithful port of the reference
/// `groundEqSettings.ts` (`applyGroundEqValue`).
///
/// Each control point is a value in `0..100` where `50` is neutral (no change).
/// Points are linearly interpolated across the 8 bands by their normalized
/// frequency position. A point above 50 boosts the band; below 50 attenuates it
/// (a "dulling" curve that also shrinks the value so silence stays silent).
class GroundEq {
  /// Number of control points in the curve (matches the reference).
  static const int pointCount = 16;

  /// Neutral value — the no-op midpoint.
  static const int defaultValue = 50;

  /// The reference's default band gains (groundEqSettings defaults
  /// [90, 92, 50, 50, 50, 50, 50, 48]), expanded onto our 16-point curve so
  /// each band's sampled position reads its reference default.
  static final List<int> defaultCurve = normalize(const [
    90, 90, 92, 92, 50, 50, 50, 50,
    50, 50, 50, 50, 50, 50, 48, 48,
  ]);

  /// Flat (neutral) curve: every band passes through unchanged.
  const GroundEq.flat()
      : curve = const [
          50, 50, 50, 50, 50, 50, 50, 50,
          50, 50, 50, 50, 50, 50, 50, 50,
        ];

  /// Build from a raw curve. Values are clamped to 0..100 and the curve is
  /// padded/trimmed to exactly [pointCount] entries.
  const GroundEq(List<int> source)
      : curve = source; // validated lazily by [sample]

  /// The 16 control points (0..100).
  final List<int> curve;

  /// Validate/normalize a raw curve to exactly [pointCount] entries in 0..100.
  static List<int> normalize(List<int>? raw) {
    final src = raw ?? const [];
    return List<int>.generate(pointCount, (i) {
      final v = i < src.length ? src[i] : defaultValue;
      final n = int.tryParse('$v') ?? defaultValue;
      if (n < 0) return 0;
      if (n > 100) return 100;
      return n;
    });
  }

  /// Sample the curve at a normalized frequency position `unit` in 0..1.
  /// Mirrors the reference `readGroundEqCurveValue` (linear interpolation).
  double sample(double unit) {
    final safeUnit = unit < 0 ? 0.0 : (unit > 1 ? 1.0 : unit);
    final scaled = safeUnit * (pointCount - 1);
    final left = scaled.floor();
    final right = (left + 1 > pointCount - 1) ? pointCount - 1 : left + 1;
    final mix = scaled - left;
    final l = curve[left < curve.length ? left : curve.length - 1];
    final r = curve[right < curve.length ? right : curve.length - 1];
    return l * (1 - mix) + r * mix;
  }

  /// Apply the EQ to a band value (0..1) at normalized frequency position
  /// `unit` (0..1). Mirrors the reference `applyGroundEqValue`:
  ///   * above 50 → boost: `value * (1 + delta*1.8)`, clamped 0..cap
  ///   * below 50 → dull:  `(max(0, value - dull*0.35)) * (1 - dull*0.35)`
  /// [cap] gives the kick-mixed low bands their reference headroom (1.2 sub,
  /// 1.15 bass) so the center lift doesn't flatten at 1.0 mid-beat.
  double apply(double value, double unit, {double cap = 1.0}) {
    final eq = sample(unit);
    final delta = (eq - defaultValue) / defaultValue;
    if (delta >= 0) {
      final v = value * (1 + delta * 1.8);
      return v < 0 ? 0 : (v > cap ? cap : v);
    }
    final dullness = -delta; // 0..1
    final dim = value - dullness * 0.35;
    final v = (dim < 0 ? 0 : dim) * (1 - dullness * 0.35);
    return v < 0 ? 0 : (v > cap ? cap : v);
  }

  /// Apply this EQ to all 8 bands of [bands], returning a reshaped copy. The
  /// `unit` positions match the reference: 0.00, 0.12, 0.28, 0.42, 0.58, 0.72,
  /// 0.86, 1.00 for subBass..air; energy uses the average curve position.
  AudioBands applyToBands(AudioBands bands,
      {double subCap = 1.0, double bassCap = 1.0}) {
    return bands.copyWith(
      subBass: apply(bands.subBass, 0.00, cap: subCap),
      bass: apply(bands.bass, 0.12, cap: bassCap),
      lowMid: apply(bands.lowMid, 0.28),
      mid: apply(bands.mid, 0.42),
      highMid: apply(bands.highMid, 0.58),
      presence: apply(bands.presence, 0.72),
      brilliance: apply(bands.brilliance, 0.86),
      air: apply(bands.air, 1.00),
    );
  }
}
