/// Smoothed, normalized audio band data consumed by the shader.
///
/// Every field is clamped to roughly 0..1 and exponentially smoothed so the
/// terrain reacts fluidly instead of snapping. This mirrors the
/// `getAudioData()` smoothing in the reference TS engine.
class AudioBands {
  /// Per-band amplitudes (0..1).
  final double subBass, bass, lowMid, mid, highMid, presence, brilliance, air;

  /// Overall loudness (0..1).
  final double energy;

  /// Warm (low) vs bright (high) spectral balance (0..1).
  final double warmth;
  final double brightness;

  /// Attack metric: rises on sharp transients.
  final double sharpness;

  /// Smoothness of the signal (0 chaotic .. 1 smooth).
  final double smoothness;

  /// Active-band density (fraction of bands above threshold), matching the
  /// reference `density` metric. Used to gate the bass lift so sparse material
  /// doesn't lift the whole field.
  final double density;

  const AudioBands({
    this.subBass = 0,
    this.bass = 0,
    this.lowMid = 0,
    this.mid = 0,
    this.highMid = 0,
    this.presence = 0,
    this.brilliance = 0,
    this.air = 0,
    this.energy = 0,
    this.warmth = 0,
    this.brightness = 0,
    this.sharpness = 0,
    this.smoothness = 0.6,
    this.density = 0.5,
  });

  static const AudioBands idle = AudioBands();

  AudioBands copyWith({
    double? subBass,
    double? bass,
    double? lowMid,
    double? mid,
    double? highMid,
    double? presence,
    double? brilliance,
    double? air,
    double? energy,
    double? warmth,
    double? brightness,
    double? sharpness,
    double? smoothness,
    double? density,
  }) {
    return AudioBands(
      subBass: subBass ?? this.subBass,
      bass: bass ?? this.bass,
      lowMid: lowMid ?? this.lowMid,
      mid: mid ?? this.mid,
      highMid: highMid ?? this.highMid,
      presence: presence ?? this.presence,
      brilliance: brilliance ?? this.brilliance,
      air: air ?? this.air,
      energy: energy ?? this.energy,
      warmth: warmth ?? this.warmth,
      brightness: brightness ?? this.brightness,
      sharpness: sharpness ?? this.sharpness,
      smoothness: smoothness ?? this.smoothness,
      density: density ?? this.density,
    );
  }

  @override
  String toString() =>
      'AudioBands(e=${energy.toStringAsFixed(2)} sub=${subBass.toStringAsFixed(2)} '
      'bass=${bass.toStringAsFixed(2)} mid=${mid.toStringAsFixed(2)} '
      'treble=${air.toStringAsFixed(2)})';
}

/// A detected transient used to spawn a ripple / meteor.
class Beat {
  /// 0..1 strength.
  final double strength;

  /// 'kick' (low) or 'snare' (mid/high).
  final String type;

  const Beat(this.strength, this.type);
}

/// Abstract frequency-band source.
///
/// Implementations analyze one block of audio per [read] call and return the
/// smoothed [AudioBands]. Transients detected during that block are surfaced
/// via [consumeBeats] (drains the queue).
abstract class AudioAnalyzer {
  /// Analyze the next block and return current bands. May return
  /// [AudioBands.idle] when nothing is playing.
  AudioBands read();

  /// Drain and return transients detected since the last call.
  List<Beat> consumeBeats();

  /// Whether this analyzer currently has active input.
  bool get isActive;

  /// Start acquiring / synthesizing audio.
  Future<void> start();

  /// Stop acquiring audio and release resources.
  Future<void> stop();

  /// Dispose permanently.
  void dispose();
}
