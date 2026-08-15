import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'audio_bands.dart';
import '../diag.dart';
import 'beat_detector.dart';
import 'fft.dart';
import 'freq_trigger.dart';
import 'mic_permission.dart';

/// Captures microphone audio via the `record` package and analyzes it through
/// the shared [Fft] + [BandExtractor] + [BeatDetector] pipeline. Works on
/// Android, iOS, macOS, Windows, Linux and Web (with permissions).
///
/// **Silence detection:** macOS/iOS deliver all-zero samples (instead of an
/// error) when microphone access has been denied at the OS level, so the
/// analyzer tracks absolute digital silence and exposes [muted] for the UI to
/// surface an actionable hint.
class MicAnalyzer extends AudioAnalyzer {
  MicAnalyzer({this.sampleRate = 44100})
      : _fft = Fft(1024),
        // No AnalyserNode-style pre-smoothing on this path, so the extractor
        // carries the full reference cascade τ (~0.23 s).
        _extractor = BandExtractor(binCount: 512, smoothingTau: 0.23),
        _buffer = Float64List(1024),
        _detector = BeatDetector();

  final int sampleRate;
  final Fft _fft;
  final BandExtractor _extractor;
  final FreqTriggers triggers = FreqTriggers();
  double _triggerClock = 0;
  final Float64List _buffer;
  final BeatDetector _detector;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _sub;
  bool _active = false;

  AudioBands _current = AudioBands.idle;
  final List<Beat> _beatQueue = [];

  // Silence tracking: consecutive data chunks (~100ms each) of absolute zeros.
  static const int _muteChunkLimit = 15; // ≈1.5s of digital silence
  int _silentChunks = 0;
  bool _muted = false;

  // Auto-recovery: a TCC grant on macOS/iOS does NOT revive an already-open
  // input tap — the stream keeps delivering zeros until it is restarted. While
  // muted, periodically stop/start the capture so the moment the user grants
  // access in System Settings the audio starts flowing.
  static const double _restartEverySec = 4;
  double _sinceRestartCheck = 0;
  bool _restarting = false;

  /// Latest smooth kick envelope (0..1) from the beat detector.
  double _kickEnvelope = 0;

  /// Whether the input has been absolute digital silence for ~1s — almost
  /// always a denied OS microphone permission (macOS/ iOS inject silence) or
  /// a muted/absent device.
  bool get muted => _muted;

  /// Latest kick envelope 0..1 — pulses with the music's low end.
  double get kickEnvelope => _kickEnvelope;

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
  bool get isActive => _active;

  @override
  Future<void> start() async {
    if (_active) return;

    // On Android / iOS go through permission_handler first so we get a real
    // denied / permanentlyDenied state and a chance to guide the user.
    final perm = await MicPermission.request();
    if (perm == MicPermissionResult.denied) {
      throw const MicPermissionException(
        'Microphone permission was denied.',
        permanent: false,
      );
    } else if (perm == MicPermissionResult.permanentlyDenied) {
      throw const MicPermissionException(
        'Microphone permission is permanently denied. '
        'Please enable it in Settings.',
        permanent: true,
      );
    }
    // perm == granted  -> proceed.
    // perm == unsupported -> desktop / web: skip the gate and let startStream
    //   trigger the host's native (TCC / browser) prompt. The recorder is the
    //   source of truth here; hasPermission() is intentionally NOT used as a
    //   gate because on macOS a cached TCC denial returns false without ever
    //   re-prompting, which would block a legit first request.

    // Ask through the recorder itself (AVCaptureDevice.requestAccess) so the
    // OS prompt shows properly on macOS/iOS BEFORE the audio engine starts —
    // starting the engine with an undetermined permission can block forever
    // behind an invisible prompt. Rebuilt ad-hoc binaries can also lose a
    // previous TCC grant, so this is checked on every start.
    try {
      final granted = await _recorder.hasPermission();
      sonicDiag('mic: hasPermission=$granted');
      if (!granted) {
        // A false here (as opposed to an exception) means the OS reported an
        // explicit denial. macOS never re-prompts once denied, so point the
        // user at System Settings instead of retrying blindly.
        throw const MicPermissionException(
          'Microphone access is blocked for this app. Allow it in '
          'System Settings › Privacy & Security › Microphone, '
          'then switch to MIC again.',
          permanent: true,
        );
      }
    } on MicPermissionException {
      rethrow;
    } catch (e) {
      sonicDiag('mic: hasPermission check failed: $e (continuing)');
    }

    try {
      await _openStream();
      _active = true;
    } catch (e) {
      // Capture failed — almost always a permission denial on platforms where
      // we couldn't pre-request (desktop / web), or the user dismissed the
      // native prompt. Surface it uniformly.
      throw MicPermissionException(
        'Microphone could not be started: $e',
        permanent: false,
      );
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    _current = AudioBands.idle;
  }

  @override
  void dispose() {
    _active = false;
    _sub?.cancel();
    _sub = null;
    _recorder.dispose();
  }

  RecordConfig _config() => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      );

  Future<void> _openStream() async {
    sonicDiag('mic: opening stream ${sampleRate}Hz');
    final stream = await _recorder.startStream(_config());
    _ringOffset = 0;
    _silentChunks = 0;
    _muted = false;
    _sinceRestartCheck = 0;
    sonicDiag('mic: stream opened OK');
    _sub = stream.listen(
      _onData,
      onError: (e) {
        sonicDiag('mic: stream ERROR: $e');
        debugPrint('SONIC_MIC: stream ERROR: $e');
      },
      onDone: () => sonicDiag('mic: stream DONE'),
    );
  }

  /// Stop and reopen the capture (used by the muted auto-recovery loop).
  Future<void> _restartCapture() async {
    if (_restarting || !_active) return;
    _restarting = true;
    try {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stop();
      sonicDiag('mic: restarting capture (muted auto-recovery)');
      await _openStream();
    } catch (e) {
      sonicDiag('mic: restart failed: $e');
      // Still denied: keep the muted flag so the retry cadence continues.
      _muted = true;
    } finally {
      _restarting = false;
    }
  }

  // ---- ring buffer accumulation of 16-bit PCM into 1024-sample windows ----
  int _ringOffset = 0;

  /// Test-only: feed little-endian 16-bit mono PCM chunks straight into the
  /// analysis pipeline (windowing, FFT, normalization, beat detection) without
  /// a live capture stream.
  @visibleForTesting
  void debugFeedPcm(List<int> data) => _onData(data);

  void _onData(List<int> data) {
    // data is little-endian 16-bit PCM bytes.
    bool anyNonZero = false;
    for (int i = 0; i + 1 < data.length; i += 2) {
      final lo = data[i];
      final hi = data[i + 1];
      int s = (hi << 8) | (lo & 0xff);
      if (s >= 0x8000) s -= 0x10000;
      if (s != 0) anyNonZero = true;
      _buffer[_ringOffset++] = s / 32768.0;
      if (_ringOffset == _buffer.length) {
        _ringOffset = 0;
        _processWindow();
      }
    }
    if (anyNonZero) {
      _silentChunks = 0;
      _muted = false;
    } else {
      _silentChunks++;
      if (_silentChunks > _muteChunkLimit) _muted = true;
    }
  }

  int _diagWindow = 0;
  int _diagBeats = 0;

  void _processWindow() {
    // dB scale with Hann coherent-gain correction — the reference's
    // AnalyserNode mapping (−75 dBFS gate, 45 dB window) lifts quiet mic
    // input the same way getByteFrequencyData does, replacing the old AGC
    // (which gain-pumped the whole terrain over seconds).
    final mags = dbSpectrum(_fft.magnitudes(_buffer), gain: 2.0);
    final bands = _extractor.process(mags, dtSec: 1024 / sampleRate);
    _current = bands;
    // Beat detection on the same dB spectrum — its absolute gates (level
    // gate ~0.025) are calibrated for this scale, like the reference.
    final out = _detector.step(mags, 1024 / sampleRate);
    // Frequency triggers (reference evaluateTrigger) — pulse/meteor/snare
    // spectral-flux detection at the analysis cadence, where their
    // frame-based cooldowns hold their 60 fps semantics.
    final windowSec = 1024 / sampleRate;
    _triggerClock += windowSec;
    for (final (action, strength) in triggers.step(mags, _triggerClock, windowSec)) {
      _beatQueue.add(Beat(strength.clamp(0.0, 1.5), action.name));
    }
    triggers.commitFrame(mags);
    if (++_diagWindow % 40 == 0) {
      double pk = 0;
      for (final v in _buffer) {
        final a = v.abs();
        if (a > pk) pk = a;
      }
      sonicDiag('mic: w=$_diagWindow pk=${pk.toStringAsFixed(3)}'
          ' sub=${_current.subBass.toStringAsFixed(2)}'
          ' bass=${_current.bass.toStringAsFixed(2)}'
          ' energy=${_current.energy.toStringAsFixed(2)}'
          ' beats=$_diagBeats'
          ' muted=$_muted');
      _diagBeats = 0;
    }

    _kickEnvelope = out.kickEnvelope;
    if (out.onset) {
      final strength =
          math.max(0.35, math.min(1.0, out.kickLevel * 0.9 + out.kickConfidence * 0.25));
      _beatQueue.add(Beat(strength.clamp(0.0, 1.0), 'kick'));
      _diagBeats++;
    }
    // Snare channel: mid/high energy rise (kept simple — the kick detector is
    // the reference-faithful part).
    final midB = (_current.mid + _current.highMid) * 0.5;
    final low = (_current.subBass + _current.bass) * 0.5;
    if (_snareCooldown <= 0 && midB > 0.28 && low < midB * 1.4) {
      _beatQueue.add(Beat(midB.clamp(0.0, 1.0) * 0.8, 'snare'));
      _snareCooldown = 0.25;
    }
  }

  double _snareCooldown = 0;

  /// Advance cooldown timers by [dtSeconds]. Call from the frame ticker.
  void tick(double dtSeconds) {
    _snareCooldown = math.max(0.0, _snareCooldown - dtSeconds);
    if (_muted && !_restarting) {
      _sinceRestartCheck += dtSeconds;
      if (_sinceRestartCheck >= _restartEverySec) {
        _sinceRestartCheck = 0;
        _restartCapture();
      }
    } else {
      _sinceRestartCheck = 0;
    }
  }
}
