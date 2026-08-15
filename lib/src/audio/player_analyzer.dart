import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_bands.dart';
import '../diag.dart';
import 'beat_detector.dart';
import 'fft.dart';
import 'freq_trigger.dart';

/// Plays real audio files through `flutter_soloud` and analyzes the very
/// signal being played — the Flutter equivalent of the reference player's
/// Web-Audio `AnalyserNode`. This is the source that makes the terrain react
/// to actual music with no microphone involved.
///
/// The engine exposes a 256-bin FFT of the mix (~86 Hz/bin at 44.1 kHz). We
/// linearly upsample it to the 512-bin layout the shared [BandExtractor]
/// expects, and run the same [BeatDetector] used by [MicAnalyzer].
class PlayerAnalyzer extends AudioAnalyzer {
  SoLoud get _soloud => SoLoud.instance;

  late final AudioData _audioData = AudioData(GetSamplesKind.linear);
  AudioSource? _source;
  SoundHandle? _handle;
  bool _active = false;
  bool _initialized = false;
  double _volume = 1.0;

  AudioBands _current = AudioBands.idle;
  final List<Beat> _beatQueue = [];
  // Shorter extractor τ: soloud's own FFT smoothing (0.8 below) provides the
  // AnalyserNode stage of the reference's cascade.
  final BandExtractor _extractor =
      BandExtractor(binCount: 512, smoothingTau: 0.15);
  final BeatDetector _detector = BeatDetector();
  final FreqTriggers triggers = FreqTriggers();
  double _triggerClock = 0;
  Timer? _pullTimer;

  // Linear-upsampled spectrum handed to the extractor/detector (513 bins).
  final Float64List _spectrum = Float64List(513);

  double _kickEnvelope = 0;

  static const Duration _pullInterval = Duration(milliseconds: 21);

  /// Latest smooth kick envelope (0..1).
  double get kickEnvelope => _kickEnvelope;

  /// The currently loaded source, if any.
  AudioSource? get source => _source;

  /// Whether a track is loaded.
  bool get hasTrack => _source != null;

  double get volume => _volume;

  /// Initialize the engine. Safe to call multiple times.
  Future<void> _ensureInit() async {
    if (_initialized) return;
    await _soloud.init(sampleRate: 44100, bufferSize: 2048);
    _soloud.setVisualizationEnabled(true);
    // Reference AnalyserNode smoothingTimeConstant = 0.8.
    _soloud.setFftSmoothing(0.8);
    _initialized = true;
  }

  /// Load an audio file and start playing it. Replaces any current track.
  Future<void> loadFile(String path, {double? volume}) async {
    await _ensureInit();
    await stop();
    final src = await _soloud.loadFile(path, mode: LoadMode.memory);
    _source = src;
    _volume = volume ?? _volume;
    _handle = _soloud.play(src, volume: _volume);
    _active = true;
    _startPulling();
  }

  void _startPulling() {
    _pullTimer?.cancel();
    // ~46 analysis frames/second — matches the mic pipeline's cadence.
    _pullTimer = Timer.periodic(_pullInterval, (_) => _pull());
  }

  void _pull() {
    if (!_active) return;
    try {
      _audioData.updateSamples();
      final samples = _audioData.getAudioData();
      if (samples.length < 256) {
        _diag();
        return;
      }
      // Linear layout: [0..255] FFT values 0..1.
      // Upsample 256 → 513 bins, then map onto the reference's dB scale —
      // linear magnitudes leave mid/treble under the terrain's noise gate.
      final last = _spectrum.length - 1;
      for (int i = 0; i <= last; i++) {
        final x = i * 255 / last;
        final i0 = x.floor();
        final i1 = math.min(i0 + 1, 255);
        final t = x - i0;
        _spectrum[i] = samples[i0] * (1 - t) + samples[i1] * t;
      }
      // soloud's linear FFT magnitudes run ~20 dB hotter than the windowed-
      // FFT scale this dB mapping was calibrated for — without the 0.1 gain
      // every audible bin clamps to 1.0 and the low/mid bands sit pinned
      // (verified with a live probe: sub/bass/mid flatlined at 1.000 while a
      // 2 Hz kick pattern played; kick envelope never refired).
      final db = dbSpectrum(_spectrum, gain: 0.1);
      final dtSec = _pullInterval.inMilliseconds / 1000;
      _current = _extractor.process(db, dtSec: dtSec);
      final out = _detector.step(db, dtSec);
      _kickEnvelope = out.kickEnvelope;
      if (out.onset) {
        _beatQueue.add(Beat(out.kickLevel.clamp(0.35, 1.0), 'kick'));
      }
      // Frequency triggers (reference evaluateTrigger) replace the old
      // band-level snare/meteor heuristics — spectral-flux detection with
      // sensitivity/cooldown/band controls, running at analysis cadence.
      _triggerClock += dtSec;
      for (final (action, strength)
          in triggers.step(db, _triggerClock, dtSec)) {
        _beatQueue.add(Beat(strength.clamp(0.0, 1.5), action.name));
      }
      triggers.commitFrame(db);
      _diag(rawMax: samples.isEmpty ? 0 : samples.reduce(math.max));
    } catch (e) {
      sonicDiag('player: pull FAILED: $e');
      if (_errorCount++ < 5) debugPrint('SONIC_PLAYER: pull failed: $e');
    }
  }

  int _errorCount = 0;

  /// Heartbeat into the SONIC_DIAG log (~every 2s): engine raw level,
  /// processed bands, playback flags. Field-debugging "it froze" reports.
  DateTime _lastDiag = DateTime.fromMillisecondsSinceEpoch(0);
  void _diag({double? rawMax}) {
    final now = DateTime.now();
    if (now.difference(_lastDiag).inMilliseconds < 2000) return;
    _lastDiag = now;
    sonicDiag('player: active=$_active play=${isPlaying} rawMax='
        '${rawMax?.toStringAsFixed(3) ?? '-'}'
        ' sub=${_current.subBass.toStringAsFixed(2)} '
        'E=${_current.energy.toStringAsFixed(2)} pos=${position.inSeconds}s');
  }

  // ---- playback state & controls ----

  bool get isPlaying {
    final h = _handle;
    if (h == null) return false;
    return _source!.handles.contains(h);
  }

  Future<void> pause() async {
    final h = _handle;
    if (h != null) _soloud.setPause(h, true);
  }

  Future<void> resume() async {
    final h = _handle;
    if (h != null) _soloud.setPause(h, false);
  }

  Future<void> togglePlayPause() async {
    final h = _handle;
    if (h != null) _soloud.pauseSwitch(h);
  }

  Future<void> seekTo(Duration position) async {
    final h = _handle;
    if (h != null) _soloud.seek(h, position);
  }

  Duration get position {
    final h = _handle;
    if (h == null) return Duration.zero;
    try {
      return _soloud.getPosition(h);
    } catch (_) {
      return Duration.zero;
    }
  }

  Duration get duration {
    final s = _source;
    if (s == null) return Duration.zero;
    try {
      return _soloud.getLength(s);
    } catch (_) {
      return Duration.zero;
    }
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    final h = _handle;
    if (h != null) _soloud.setVolume(h, _volume);
  }

  /// Fires when the current track finishes playing naturally.
  Stream<void> get onTrackFinished =>
      _source?.allInstancesFinished ?? const Stream.empty();

  @override
  AudioBands read() => _current;

  @override
  List<Beat> consumeBeats() {
    if (_beatQueue.isEmpty) return const [];
    final out = List<Beat>.from(_beatQueue);
    _beatQueue.clear();
    return out;
  }

  @override
  bool get isActive => _active && hasTrack;

  @override
  Future<void> start() async {
    await _ensureInit();
    if (hasTrack) _startPulling();
  }

  @override
  Future<void> stop() async {
    _pullTimer?.cancel();
    _pullTimer = null;
    final h = _handle;
    if (h != null) {
      try {
        await _soloud.stop(h);
      } catch (_) {}
    }
    _handle = null;
    _active = false;
    _current = AudioBands.idle;
  }

  /// Unload the current source from engine memory.
  Future<void> unload() async {
    await stop();
    final s = _source;
    if (s != null) {
      try {
        await _soloud.disposeSource(s);
      } catch (_) {}
    }
    _source = null;
  }

  @override
  void dispose() {
    _pullTimer?.cancel();
    _pullTimer = null;
    try {
      if (_initialized) _soloud.deinit();
    } catch (_) {}
    _audioData.dispose();
    _initialized = false;
    _active = false;
  }
}
