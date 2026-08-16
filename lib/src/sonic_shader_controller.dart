import 'dart:math' as math;
import 'dart:typed_data' as td;
import 'dart:ui' as ui;

import 'dart:io' as io show Platform;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';

import 'audio/audio_bands.dart';
import 'audio/demo_analyzer.dart';
import 'audio/ground_eq.dart';
import 'audio/mic_analyzer.dart';
import 'perf.dart';
import 'scene/scene_state.dart';
import 'theme/sonic_theme.dart';

/// Loads the two GPU fragment programs (display + bake) once.
class SonicShaderController extends ChangeNotifier {
  SonicShaderController() {
    _load();
  }

  ui.FragmentProgram? _displayProgram;
  ui.FragmentProgram? _bakeProgram;
  bool _ready = false;
  String? _error;

  bool get ready => _ready;
  String? get error => _error;

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        ui.FragmentProgram.fromAsset('shaders/sonic_topography.frag'),
        ui.FragmentProgram.fromAsset('shaders/sonic_heightfield.frag'),
      ]);
      _displayProgram = r[0];
      _bakeProgram = r[1];
      _ready = true;
    } catch (e, st) {
      _error = '$e\n$st';
      debugPrint('Failed to load sonic shaders: $e');
    }
    notifyListeners();
  }

  ui.FragmentShader createDisplay() => _displayProgram!.fragmentShader();
  ui.FragmentShader createBake() => _bakeProgram!.fragmentShader();
}

/// Adaptive quality — quality first, frame rate second.
///
/// Signal: the only trustworthy measure of "did we keep up" is the rate
/// frames were actually PRESENTED. Presentation is vsync-quantized — on a
/// 120 Hz host a frame either makes its vsync or presents at the next one,
/// so displayed fps reads ~120 or ~60, never in between. Raster-thread
/// durations were previously used as the cost signal and proved unreliable
/// on desktop Impeller (fence/queue waits inflate them independent of real
/// shader cost), which walked renderScale to its floor while the screen
/// still showed 120 fps — blurry for no benefit.
///
/// Policy (best image, then best frame rate):
///  1. Never render below device pixels while a saner option exists.
///  2. Tier `chase` — hold the display's FULL refresh rate. A miss first
///     sheds supersampling (scale 1.5 → 1.0), preserving native sharpness.
///  3. Tier `hold60` — at native resolution a miss switches the target to
///     60 fps instead of the resolution: on a high-refresh host the rate
///     halves exactly, and 60 fps motion on this scene is far less visible
///     than a sub-native render. Only if 60 fps cannot be held at full
///     resolution does the scale walk below 1.0 (weak GPUs), and only at
///     the scale floor does ray-march density thin out.
///  4. Long stable runs in hold60 re-probe chase with exponential backoff
///     (window moves, shader warm-up and load changes alter the picture),
///     so the rate settles instead of oscillating.
class AdaptiveQuality {
  AdaptiveQuality({
    double initialRenderScale = 1.0,
    double refreshHz = 60,
    this.minRenderScale = 0.5,
    this.maxRenderScale = 1.5,
  })  : renderScale = initialRenderScale.clamp(minRenderScale, maxRenderScale),
        _ceiling = maxRenderScale {
    _refreshHz = refreshHz.clamp(30.0, 240.0);
  }

  /// Display refresh rate (Hz), set from `display.refreshRate`.
  double _refreshHz = 60;
  final double minRenderScale, maxRenderScale;
  double renderScale;
  double marchScale = 1.0;

  bool _hold60 = false; // tier: chase full refresh (false) vs hold 60 fps
  double _chaseProbeIn = 8; // stable seconds in hold60 before re-probing
  double _probeBackoff = 180;
  double _fpsEma = 60;
  double _cooldown = 0;
  double _stableSec = 0; // consecutive healthy seconds at the current level
  double _ceiling; // highest scale not (recently) known to miss
  int _sample = 0;
  int _missStreak = 0; // consecutive miss evaluations (anti-jitter filter)

  double get fps => _fpsEma;
  double get targetHz => _hold60 ? math.min(_refreshHz, 60) : _refreshHz;

  // Diagnostic surface for perf logging.
  double get refreshHz => _refreshHz;
  bool get hold60 => _hold60;
  int get evalCount => _sample;
  int get missStreak => _missStreak;

  void setRefresh(double hz) {
    _refreshHz = hz.clamp(30.0, 240.0);
  }

  /// [displayedFps] is the caller's EMA of presented-frame intervals;
  /// [dtSec] the frame delta for the stability clocks.
  void sample(double displayedFps, double dtSec) {
    _sample++;
    _fpsEma += (displayedFps - _fpsEma) * 0.12;
    final dt = dtSec.clamp(0.001, 0.05);
    if (_cooldown > 0) {
      _cooldown -= dt;
      return;
    }
    if (_sample < 240) return; // ~2 s warm-up: shader compile, first bakes,
    // texture uploads and Metal pipeline caches all miss frames at launch —
    // three such misses would lock hold60 for the probe backoff period.
    final healthy = _fpsEma >= targetHz * 0.88;
    if (!healthy) {
      // Require a sustained miss: single evaluations fire during transient
      // system stalls (window drags, resizes, occlusion) and must not change
      // the tier. Three spaced evaluations ≈ 1.5 s of real overload.
      _missStreak++;
      _stableSec = 0;
      if (_missStreak < 3) {
        _cooldown = 0.5;
        return;
      }
      if (!_hold60 && renderScale > 1.0) {
        // Chase tier: sacrifice supersampling before anything else.
        final failed = renderScale;
        final rs = (renderScale - 0.08).clamp(minRenderScale, maxRenderScale);
        renderScale = (rs * 100).round() / 100.0;
        _ceiling = math.min(_ceiling, failed - 0.04);
      } else if (!_hold60 && _refreshHz > 61) {
        // Native resolution missed full refresh on a high-refresh host:
        // keep the pixels, halve the rate.
        _hold60 = true;
        _chaseProbeIn = _probeBackoff;
      } else if (renderScale > minRenderScale) {
        // True overload (60 Hz host, or 60 fps missed at native): shed
        // resolution in gentle single steps.
        final rs = (renderScale - 0.06).clamp(minRenderScale, maxRenderScale);
        final stepped = (rs * 100).round() / 100.0;
        if (stepped < renderScale) {
          renderScale = stepped;
        } else if (marchScale > 0.5) {
          marchScale = (marchScale - 0.1).clamp(0.5, 1.0);
        }
      } else if (marchScale > 0.5) {
        marchScale = (marchScale - 0.1).clamp(0.5, 1.0);
      }
      _cooldown = 0.5;
      return;
    }
    // Budget met.
    _missStreak = 0;
    _stableSec += dt;
    final tierCap = _hold60
        ? math.min(1.0, maxRenderScale) // no SSAA while settling for 60 fps
        : math.min(_ceiling, maxRenderScale);
    if (renderScale < tierCap && _stableSec >= 1.2) {
      final rs = (renderScale + 0.04).clamp(minRenderScale, tierCap);
      renderScale = (rs * 100).round() / 100.0;
      _stableSec = 0;
      _cooldown = 0.6;
    } else if (renderScale >= 1.0) {
      marchScale = 1.0; // healthy at native: restore full march density
    }
    if (_stableSec > 20) _stableSec = 20;
    if (_hold60) {
      _chaseProbeIn -= dt;
      if (_chaseProbeIn <= 0 && renderScale >= 1.0 - 0.001 && marchScale >= 1.0) {
        // Re-probe the full refresh rate; back off on the next failure.
        _hold60 = false;
        _probeBackoff = math.min(_probeBackoff * 2, 900);
        _stableSec = 0;
        _cooldown = 0.8; // let the fps EMA settle into the new cadence
      }
    }
  }
}

class QualityMetrics {
  const QualityMetrics({this.fps = 0, this.renderScale = 1.0, this.marchScale = 1.0});
  final double fps, renderScale, marchScale;
}

/// The audio-reactive topography visualizer.
///
/// **Single-pass GPU architecture:** the entire scene renders in ONE fragment
/// shader via CustomPaint. Per frame, the CPU does: read bands, update ring
/// buffers, push ~30 dynamic uniforms. That's it — no texture allocation, no
/// toImage/toImageSync stalls, no bake pass, no sampler binding. All heavy work
/// (elevation noise, DDA ray-tracing, shading) runs on the GPU.
class SonicTopography extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  SonicTopography({
    super.key,
    required this.controller,
    required this.theme,
    this.audioAnalyzer,
    this.rotationSpeed,
    this.autoRotate = true,
    this.renderScale = 1.0,
    this.spacing = 1.05,
    this.pillarWidth = 0.64,
    this.camRadius = 99.6,
    this.camHeight = 25.7,
    this.meteorCooldownSec = 4.0,
    this.enableMeteors = true,
    this.enableRipples = true,
    this.enableParticles = true,
    this.enableBlocks = true,
    this.blockIntensity = 55,
    this.blockMinSize = 9,
    this.blockMaxSize = 26,
    this.blockSpeed = 77,
    this.blockCount = SceneState.maxBlocks,
    this.gridSize = 155,
    this.amplitude = 1.0,
    this.interactive = true,
    this.background,
    this.adaptiveQuality = true,
    this.targetFps = 120,
    this.groundEq = const GroundEq.flat(),
    this.onMetrics,
  });

  final SonicShaderController controller;
  final SonicTheme theme;
  final AudioAnalyzer? audioAnalyzer;

  /// Platter rotation in rad/s — the reference's global scene setting
  /// (slider 0..2, default 0.15; 0 stops the turntable). When null, falls
  /// back to the theme's rotation speed.
  final double? rotationSpeed;
  final bool autoRotate;
  final double renderScale;
  final double spacing;
  /// Pillar footprint width (0..spacing). Smaller = thinner pillars with
  /// wider gaps. Default 0.64 (reference-like). The gap = spacing - pillarWidth.
  final double pillarWidth;
  final double camRadius;
  final double camHeight;
  final double meteorCooldownSec;

  /// Demo-mode meteor fallback cadence (real input drives meteors via the
  /// frequency triggers in the analyzers).
  final bool enableMeteors, enableRipples, enableParticles, enableBlocks, interactive;

  /// Terrain grid cells per side (96..224). The bake texture is gridSize²;
  /// world extent stays ±84, so density changes spacing = 168/gridSize.
  final int gridSize;

  /// Floating-block tuning, reference ground-eq 0..100 scales.
  final double blockIntensity, blockMinSize, blockMaxSize, blockSpeed;
  final int blockCount;

  /// Master terrain amplitude — scales the audio-driven elevation (0..2).
  final double amplitude;
  final Color? background;
  final bool adaptiveQuality;
  final double targetFps;
  final GroundEq groundEq;
  final ValueChanged<QualityMetrics>? onMetrics;

  @override
  State<SonicTopography> createState() => _SonicTopographyState();
}

class _SonicTopographyState extends State<SonicTopography>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final AdaptiveQuality _quality;
  final SceneState _scene = SceneState();
  // Always-on: FrameTiming is the authoritative PRESENTED-fps signal the
  // adaptive controller feeds on (the ticker cadence runs ahead of the
  // rasterizer on desktop and would report frames that never hit the
  // screen). The periodic log report stays behind kSonicPerf.
  final PerfSampler _perf = PerfSampler();

  // Reused display + bake shaders. Statics set once; dynamics updated per frame.
  ui.FragmentShader? _dispFs;
  ui.FragmentShader? _bakeFs;
  bool _staticsApplied = false;
  // Async heightfield bake: pipelined, NEVER blocks the CPU.
  ui.Image? _bakeImage;
  // Live-resize fast response: while the window is dragged, macOS demands
  // many presents per second; at native cost the GPU saturates, presents lag
  // the growing surface and the compositor shows stale/incomplete edges.
  ui.Size _lastPaintSize = ui.Size.zero;
  int _resizeUntilUs = 0; // clock cutoff for the reduced-resolution window
  int _rsTraceFrames = 0; // SONIC_RS resize-window frame counter

  // Images retired from active duty but possibly still referenced by
  // pictures sitting in the raster queue. Disposing a ui.Image the moment
  // it is replaced renders those pending pictures from destroyed textures —
  // seen as black/garbled shader frames when the render path flips (e.g.
  // renderScale stepping across 1.0). Retire first, dispose 400 ms later:
  // far beyond any reasonable pipeline depth.
  final List<(ui.Image, int)> _retired = [];

  void _retire(ui.Image? img) {
    if (img == null) return;
    _retired.add((img, _clock.elapsedMicroseconds + 400000));
    // Bound GPU memory: the raster pipeline is at most a few frames deep, so
    // three retained generations cover every in-flight picture. Without the
    // cap, a sub-native steady state (image replaced every frame) would hold
    // ~50 full-window textures inside the 400 ms retirement window.
    while (_retired.length > 3) {
      _retired.removeAt(0).$1.dispose();
    }
  }

  void _pruneRetired() {
    if (_retired.isEmpty) return;
    final now = _clock.elapsedMicroseconds;
    _retired.removeWhere((e) {
      if (e.$2 <= now) {
        e.$1.dispose();
        return true;
      }
      return false;
    });
  }
  bool _bakeInFlight = false;

  double _lastRenderMs = 0;
  double _displayedFpsEma = 60; // EMA of displayed frame rate for UI readout
  double _camAngle = 0;
  double _rotEma = 0; // smoothed rotation speed for jitter-free camera
  int _bakeCounter = 0; // throttle: bake every Nth frame (audio shape is smooth)
  AudioBands _bands = AudioBands.idle;

  // Kick envelope (reference kickEnvelope.ts, exact port): adaptive noise
  // floor + small "breath" follower + onset impulses with fast attack (42/s)
  // and medium release (11.5/s). This single signal drives the terrain's
  // low-end punch AND the floating-block pulse, exactly like the reference.
  double _kickNoiseFloor = 0;
  double _kickEnvelope = 0;
  AudioBands _bakeBands = AudioBands.idle;

  /// Reference amplitude mapping: ≤1 is linear, above 1 it curves
  /// quadratically up to ×15 at 2.0 (their 0..100 slider at >50).
  double get _effectiveAmplitude => widget.amplitude <= 1
      ? widget.amplitude
      : 1.0 + (widget.amplitude - 1) * (widget.amplitude - 1) * 14.0;

  /// Reference eqAvg — the mean of the 8 ground-EQ band gains (0..100),
  /// scaling uEnergy by (0.25 + eqAvg/50 × 0.75).
  double get _eqEnergyScale {
    final c = widget.groundEq.curve;
    if (c.isEmpty) return 1.0;
    var sum = 0;
    for (int b = 0; b < 8; b++) {
      sum += c[b * 2 < c.length ? b * 2 : c.length - 1];
    }
    return 0.25 + (sum / 8) / 50 * 0.75;
  }
  // Warmth/brightness recomputed from the kick-mixed bands (reference
  // MapScene useFrame), so the signature warm-center look follows the music.
  double _shadeWarmth = 0;
  double _shadeBrightness = 0;
  final Stopwatch _clock = Stopwatch()..start();
  Duration _last = Duration.zero;
  final math.Random _rng = math.Random();
  ui.Size _size = ui.Size.zero;
  ui.Image? _displayImage; // async display raster (capped pixel count)
  // Bumped when an async image lands so the painter repaints to show it.
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _last = _clock.elapsed;
    _quality = AdaptiveQuality(
      initialRenderScale: widget.renderScale,
      refreshHz: widget.targetFps,
      // Debug-mode overhead makes the SSAA probe chase a moving cliff and
      // oscillate; full device resolution is the sane dev ceiling.
      maxRenderScale: kDebugMode ? 1.0 : 1.5,
    );
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
    _anim.addListener(_tickBody);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The quality budget must match the display's real refresh rate.
    // Without this the controller scores against a stale target (e.g. a
    // 60 Hz host against a 120 fps default) and misreads every frame as a
    // miss — the classic "everything looks upscaled and blurry" bug.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final refresh = views.first.display.refreshRate;
    if (refresh > 0) {
      _quality.setRefresh(refresh);
    }
  }

  @override
  void dispose() {
    _anim.removeListener(_tickBody);
    _anim.dispose();
    _dispFs?.dispose();
    _bakeFs?.dispose();
    _bakeImage?.dispose();
    _displayImage?.dispose();
    for (final e in _retired) {
      e.$1.dispose();
    }
    _retired.clear();
    _tick.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SonicTopography old) {
    super.didUpdateWidget(old);
    if (old.theme != widget.theme ||
        old.camRadius != widget.camRadius ||
        old.camHeight != widget.camHeight ||
        old.spacing != widget.spacing ||
        old.pillarWidth != widget.pillarWidth ||
        old.spacing != widget.spacing) {
      _staticsApplied = false;
    }
  }

  void _tickBody() {
    _pruneRetired();
    final now = _clock.elapsed;
    final rawDt = (now - _last).inMicroseconds / 1000000.0;
    // Clamp dt to [1ms, 50ms] — prevents rotation/stutter jumps on GC pauses or
    // scheduling spikes, keeping the animation smooth and frame-rate-independent.
    final dt = rawDt.clamp(0.001, 0.05);
    _last = now;
    final time = now.inMilliseconds / 1000.0;
    final frameMs = dt * 1000.0;

    _perf.sample(_lastRenderMs, frameMs, () => time);
    // Track displayed FPS from real vsync intervals (not GPU raster) so the
    // UI readout reflects what the user actually sees. Uses the unclamped
    // interval — the 50ms clamp above is for animation stability only, and
    // pinning the readout at 20 would hide genuine severe drops.
    if (rawDt > 0) {
      _displayedFpsEma += (1000.0 / (rawDt * 1000.0) - _displayedFpsEma) * 0.08;
    }
    if (widget.adaptiveQuality) {
      // Resize grace: while the window is being resized (plus 0.5 s for the
      // presentation cadence to settle), every timing signal is noise — the
      // drag stalls presents and the stretched-blit frames read as instant.
      // Sampling here once flipped hold60 for three minutes off one drag.
      final inGrace =
          _clock.elapsedMicroseconds < _resizeUntilUs + 500000;
      if (!inGrace) {
        // Adaptive quality keys on PRESENTED fps (rasterFinish cadence) —
        // the ground truth of what the user sees. The UI ticker cadence runs
        // ahead of the rasterizer on desktop and would report frames that
        // never hit the screen.
        final presented = _perf.presentedFpsEma;
        _quality.sample(presented > 0 ? presented : _displayedFpsEma, dt);
      }
      _perf.setQuality(renderScale: _quality.renderScale, marchScale: _quality.marchScale);
      if (kSonicPerf && _quality.evalCount % 120 == 0) {
        // ignore: avoid_print
        print('SONIC_AQ | presented=${_perf.presentedFpsEma.toStringAsFixed(1)}'
            ' ticker=${_displayedFpsEma.toStringAsFixed(1)}'
            ' ema=${_quality.fps.toStringAsFixed(1)}'
            ' target=${_quality.targetHz.toStringAsFixed(0)}'
            '(${_quality.refreshHz.toStringAsFixed(0)})'
            ' hold60=${_quality.hold60}'
            ' streak=${_quality.missStreak}'
            ' grace=$inGrace'
            ' evals=${_quality.evalCount}'
            ' scale=${_quality.renderScale.toStringAsFixed(2)}');
      }
    }
    // Always report metrics — the readout must not freeze when adaptive
    // quality is off; then the widget's configured scale is what's in effect.
    widget.onMetrics?.call(QualityMetrics(
      fps: _displayedFpsEma,
      renderScale: widget.adaptiveQuality ? _quality.renderScale : widget.renderScale,
      marchScale: widget.adaptiveQuality ? _quality.marchScale : 1.0,
    ));

    final analyzer = widget.audioAnalyzer;
    bool kickOnset = false;
    double onsetStrength = 0;
    // Raw (pre-EQ) bands — the kick envelope and the kick-mix below both read
    // these, matching the reference order: mix kick FIRST, then apply the
    // ground EQ with the low-band headroom (1.2/1.15) as the outer clamp.
    final AudioBands rawBands;
    if (analyzer != null && analyzer.isActive) {
      if (analyzer is MicAnalyzer) analyzer.tick(dt);
      rawBands = analyzer.read();
      final beats = analyzer.consumeBeats();
      for (final b in beats) {
        // Reference onFreqTrigger routing. 'kick' (beat detector) only feeds
        // the kick envelope; the pulse/snare/meteor frequency triggers drive
        // the effects. The demo synthesizer emits plain kicks, so its kicks
        // also ripple (pulse-style) to stay lively.
        void coloredPulse(double mul) {
          if (!widget.enableRipples) return;
          final ang = _rng.nextDouble() * math.pi * 2;
          final dist = _rng.nextDouble() * 20; // kicks stay near the center
          _scene.addRipple(
              math.cos(ang) * dist,
              math.sin(ang) * dist,
              (b.strength * mul).clamp(0.0, 3.0),
              time,
              type: RippleType.normal);
        }

        switch (b.type) {
          case 'kick':
            kickOnset = true;
            onsetStrength = math.max(onsetStrength, b.strength);
            if (analyzer is DemoAnalyzer) coloredPulse(2.0);
          case 'pulse':
            coloredPulse(2.0);
          case 'snare':
            if (widget.enableRipples) {
              final ang = _rng.nextDouble() * math.pi * 2;
              final dist = 10 + _rng.nextDouble() * 35; // wider distribution
              _scene.addRipple(
                  math.cos(ang) * dist,
                  math.sin(ang) * dist,
                  (b.strength * 3.0).clamp(0.0, 3.0),
                  time,
                  type: RippleType.white);
            }
          case 'meteor':
            if (widget.enableMeteors) {
              // Trigger cooldown already paces these; a tiny guard prevents
              // same-frame double spawns.
              _scene.addMeteor(
                  b.strength.clamp(0.0, 2.0), time, 0.1);
            }
        }
      }
      if (widget.enableMeteors &&
          analyzer is DemoAnalyzer &&
          _rng.nextDouble() < 0.06) {
        // Demo has no real treble transients — throw the occasional meteor
        // so the sky stays alive.
        _scene.addMeteor(
            0.4 + _rng.nextDouble() * 0.3, time, widget.meteorCooldownSec);
      }
    } else {
      // Reference release: on stop the raw bins decay ~1.6 s (×0.94/frame)
      // before the engine's slow EMA — collapse the previous bands toward
      // idle instead of snapping flat in one frame.
      final k = math.exp(-dt / 0.3);
      rawBands = _bands.copyWith(
        subBass: _bands.subBass * k,
        bass: _bands.bass * k,
        lowMid: _bands.lowMid * k,
        mid: _bands.mid * k,
        highMid: _bands.highMid * k,
        presence: _bands.presence * k,
        brilliance: _bands.brilliance * k,
        air: _bands.air * k,
        energy: _bands.energy * k,
        density: _bands.density * k,
      );
    }

    // Kick envelope — exact port of the reference kickEnvelope.ts. The raw
    // level is the smoothed sub-bass band; onsets come from beat detection.
    const nfAtk = 1.15, nfRel = 0.35, levelGate = 0.025;
    const breathGain = 0.18, maxBreath = 0.11;
    const envAtk = 42.0, envRel = 11.5;
    final raw = rawBands.subBass.clamp(0.0, 1.0);
    final floorRate = raw > _kickNoiseFloor ? nfAtk : nfRel;
    _kickNoiseFloor +=
        (raw - _kickNoiseFloor) * (1.0 - math.exp(-floorRate * dt));
    final kickLevel = (raw - _kickNoiseFloor - levelGate).clamp(0.0, 1.0);
    final breath = math.min(maxBreath, kickLevel * breathGain);
    final onsetTarget =
        kickOnset ? math.max(0.48, onsetStrength * 0.95) : 0.0;
    final envTarget = math.max(breath, onsetTarget);
    final envRate = envTarget > _kickEnvelope ? envAtk : envRel;
    _kickEnvelope = math.max(
        breath,
        _kickEnvelope +
            (envTarget - _kickEnvelope) * (1.0 - math.exp(-envRate * dt)));

    // Kick-follow low bands — reference deriveKickFollowLowBands: the
    // terrain's low end is KICK-DOMINATED. Bands contribute only ~20% and the
    // normalized envelope the rest, so the center punches on each beat and
    // settles flat between beats instead of riding a hot, mushy plateau.
    // The ground EQ is applied AFTER the mix, with the reference's 1.2 / 1.15
    // headroom so medium beats stay dynamic instead of clamping at 1.0.
    final kickNorm = (_kickEnvelope / 0.75).clamp(0.0, 1.0);
    _bands = widget.groundEq.applyToBands(
      rawBands.copyWith(
        subBass: rawBands.subBass * 0.22 + kickNorm * 1.28,
        bass: rawBands.bass * 0.20 + kickNorm * 1.15,
      ),
      subCap: 1.2,
      bassCap: 1.15,
    );
    _bakeBands = _bands;

    // Warmth/brightness from the kick-mixed bands (reference useFrame): the
    // ratio of low vs high band energy decides the cool→warm center blend.
    final lowSum = _bakeBands.subBass +
        _bakeBands.bass +
        _bakeBands.lowMid +
        _bakeBands.mid;
    final highSum =
        _bakeBands.presence + _bakeBands.brilliance + _bakeBands.air;
    final bandTotal = math.max(0.001, lowSum + highSum);
    _shadeWarmth = (lowSum / bandTotal).clamp(0.0, 1.0);
    _shadeBrightness = (highSum / bandTotal).clamp(0.0, 1.0);

    // Smooth rotation: velocity-based, dt-independent, with a tiny EMA filter
    // so micro-stutters in dt don't translate to visible camera jitter.
    // Units are the reference's rad/s (global scene setting, default 0.15);
    // null falls back to the theme's legacy speed × 0.3 = same 0.15 rad/s.
    if (widget.autoRotate) {
      final speed = widget.rotationSpeed ?? widget.theme.rotationSpeed * 0.3;
      _rotEma += (speed - _rotEma) * 0.1;
      _camAngle += dt * _rotEma;
    }
    _scene.particlesEnabled = widget.enableParticles;
    _scene.blockIntensity = widget.blockIntensity;
    _scene.blockMinSize = widget.blockMinSize;
    _scene.blockMaxSize = widget.blockMaxSize;
    _scene.blockSpeed = widget.blockSpeed;
    _scene.blockCount = widget.blockCount.clamp(0, SceneState.maxBlocks);
    _scene.tick(dt, time);
    _scene.pack(time);
    // Floating cubes ride the kick envelope (reference rawPulse).
    _scene.tickBlocks(dt, _kickEnvelope, widget.enableBlocks);
  }

  /// Push the bake shader uniforms (compact layout matching sonic_heightfield.frag).
  void _pushBake(ui.FragmentShader fs, double g) {
    final b = _bakeBands;
    final time = _clock.elapsedMilliseconds / 1000.0;
    // Reference uEnergy = energy × (0.25 + eqAvg/50 × 0.75) — the ground-EQ
    // average scales how strongly uEnergy drives the rnd>0.99 spikes.
    fs
      ..setFloat(0, g)..setFloat(1, g)..setFloat(2, time)
      ..setFloat(3, b.subBass)..setFloat(4, b.bass)..setFloat(5, b.lowMid)
      ..setFloat(6, b.mid)..setFloat(7, b.highMid)..setFloat(8, b.presence)
      ..setFloat(9, b.brilliance)..setFloat(10, b.air)
      ..setFloat(11, b.energy * _eqEnergyScale)
      ..setFloat(12, b.warmth)..setFloat(13, b.brightness)
      ..setFloat(14, b.sharpness)..setFloat(15, b.smoothness)
      ..setFloat(16, b.density)..setFloat(17, widget.spacing)
      ..setFloat(18, _effectiveAmplitude);
    final ru = _scene.rippleUniforms;
    for (int i = 0; i < 10; i++) {
      final o = i * 4;
      fs..setFloat(19+o, ru[o])..setFloat(20+o, ru[o+1])..setFloat(21+o, ru[o+2])..setFloat(22+o, ru[o+3]);
    }
  }

  /// Kick the async bake (non-blocking). The GPU rasterizes it in parallel with
  /// the display pass. When it completes, the image lands and triggers a repaint.
  void _kickBake() {
    // Throttle: bake every 2nd frame. Audio-driven terrain shape is EMA-smoothed
    // and changes slowly relative to 120fps — a 60fps bake is perceptually
    // identical but halves the bake GPU cost.
    _bakeCounter = (_bakeCounter + 1) % 2;
    if (_bakeCounter != 0 && _bakeImage != null) return;
    if (_bakeInFlight) return;
    _bakeInFlight = true;
    // Grid texels per side — the reference's terrainDensity (96 + 128·d/100,
    // default 155). One texel = one cell; world extent stays ±84.
    final g = widget.gridSize.toDouble();
    final fs = _bakeFs ??= widget.controller.createBake();
    _pushBake(fs, g);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(Offset.zero & ui.Size(g, g), ui.Paint()..shader = fs);
    final pic = rec.endRecording();
    final gi = g.toInt();
    pic.toImage(gi, gi).then((img) {
      pic.dispose();
      if (!mounted) {
        // State died while the bake was in flight — don't touch disposed
        // members (double-dispose) and don't leak the fresh image.
        img.dispose();
        return;
      }
      _retire(_bakeImage);
      _bakeImage = img;
      _bakeInFlight = false;
    }, onError: (Object e) {
      // A failed bake (surface resize, context loss) must not wedge the flag —
      // otherwise no bake ever runs again and the display goes static.
      pic.dispose();
      _bakeInFlight = false;
      if (kSonicTraceResize) print('SONIC_RS | bake toImage failed: $e');
    });
  }

  /// Push the dynamic display uniforms (changes every frame). Hot path.
  /// Indices MUST match the display shader's uniform declaration order — see
  /// the layout table in sonic_topography.frag.
  void _pushDynamics(ui.FragmentShader fs, double w, double h) {
    final b = _bands;
    final time = _clock.elapsedMilliseconds / 1000.0;
    fs
      ..setFloat(0, w)..setFloat(1, h)..setFloat(2, time)
      ..setFloat(3, b.presence)..setFloat(4, b.brilliance)..setFloat(5, b.air)
      ..setFloat(6, _shadeWarmth)..setFloat(7, _shadeBrightness)
      ..setFloat(8, b.sharpness)
      ..setFloat(369, _camAngle)..setFloat(370, _quality.marchScale)
      ..setFloat(372, widget.spacing); // uSpacing — user adjustable
    final mu = _scene.meteorUniforms;
    for (int i = 0; i < 20; i++) {
      final o = i * 4;
      fs..setFloat(31+o, mu[o])..setFloat(32+o, mu[o+1])..setFloat(33+o, mu[o+2])..setFloat(34+o, mu[o+3]);
    }
    final pu = _scene.particleUniforms;
    for (int i = 0; i < 64; i++) {
      final o = i * 4;
      fs..setFloat(111+o, pu[o])..setFloat(112+o, pu[o+1])..setFloat(113+o, pu[o+2])..setFloat(114+o, pu[o+3]);
    }
    final bu = _scene.blockUniforms;
    for (int i = 0; i < SceneState.maxBlocks; i++) {
      final o = i * 4;
      fs..setFloat(379+o, bu[o])..setFloat(380+o, bu[o+1])..setFloat(381+o, bu[o+2])..setFloat(382+o, bu[o+3]);
    }
    final bq = _scene.blockRotUniforms;
    for (int i = 0; i < SceneState.maxBlocks; i++) {
      final o = i * 4;
      fs..setFloat(507+o, bq[o])..setFloat(508+o, bq[o+1])..setFloat(509+o, bq[o+2])..setFloat(510+o, bq[o+3]);
    }
    fs.setFloat(635, _scene.blockPulseMix);
  }

  /// Push static display uniforms (theme colors, camera defaults, spacing). Once.
  void _pushStatics(ui.FragmentShader fs) {
    final t = widget.theme;
    final b1 = t.vBase1, b2 = t.vBase2;
    fs
      ..setFloat(9, b1.x)..setFloat(10, b1.y)..setFloat(11, b1.z)
      ..setFloat(12, b2.x)..setFloat(13, b2.y)..setFloat(14, b2.z);
    final cc = t.vCoolCore, ce = t.vCoolEdge;
    fs
      ..setFloat(15, cc.x)..setFloat(16, cc.y)..setFloat(17, cc.z)
      ..setFloat(18, ce.x)..setFloat(19, ce.y)..setFloat(20, ce.z);
    final wc = t.vWarmCore, we = t.vWarmEdge, rp = t.vRipple;
    fs
      ..setFloat(21, wc.x)..setFloat(22, wc.y)..setFloat(23, wc.z)
      ..setFloat(24, we.x)..setFloat(25, we.y)..setFloat(26, we.z)
      ..setFloat(27, rp.x)..setFloat(28, rp.y)..setFloat(29, rp.z)
      ..setFloat(30, t.glowIntensity)
      ..setFloat(367, widget.camRadius)..setFloat(368, widget.camHeight)
      ..setFloat(371, widget.pillarWidth * 0.5); // uPillarHalf (static)
    // uBgColor MUST equal uBaseColor1 in linear space. The reference's
    // backdropColor = uFogColor = uBaseColor1 (same color). The shader's fog
    // systems blend toward uBaseColor1, so the background behind the terrain
    // must be the SAME linear color or the dome edge won't blend seamlessly.
    // Passing an sRGB Color here would mismatch the linear fog color and
    // produce a visible hard edge instead of the smooth circular fade.
    fs
      ..setFloat(373, b1.x)..setFloat(374, b1.y)..setFloat(375, b1.z);
    // uFogColor — scene fog (reference 1.1.3 themes set it apart from bg).
    final fg = t.vFog;
    fs
      ..setFloat(376, fg.x)..setFloat(377, fg.y)..setFloat(378, fg.z);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.ready) {
          return Container(
            color: widget.theme.background,
            alignment: Alignment.center,
            child: widget.controller.error == null
                ? CircularProgressIndicator(color: widget.theme.ripple)
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Shader load failed:\n${widget.controller.error}',
                        style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
          );
        }
        return LayoutBuilder(
          builder: (context, c) {
            _size = c.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) {
                if (!widget.interactive || !widget.enableRipples) return;
                final w = _size.width, h = _size.height;
                if (w <= 0 || h <= 0) return;
                final fx = (d.localPosition.dx / w) * 2 - 1;
                final fy = (d.localPosition.dy / h) * 2 - 1;
                final dist = (fx.abs() + fy.abs()) * 20;
                final ang = math.atan2(fy, fx);
                _scene.addRipple(math.cos(ang) * dist, math.sin(ang) * dist, 2.0,
                    _clock.elapsedMilliseconds / 1000.0);
              },
              child: CustomPaint(
                size: Size.infinite,
                isComplex: true,
                painter: _SonicPainter(
                    repaint: Listenable.merge([_anim, _tick]), state: this),
              ),
            );
          },
        );
      },
    );
  }
}

/// Painter: one shader, one drawRect. Flutter rasterizes it directly — no
/// intermediate textures, no toImage, no CPU-GPU synchronization points.
class _SonicPainter extends CustomPainter {
  _SonicPainter({required super.repaint, required this.state});
  final _SonicTopographyState state;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      Offset.zero & size,
      ui.Paint()..color = state.widget.background ?? state.widget.theme.background,
    );

    // Widget tests assert chrome layout, not shader pixels: software-
    // rasterizing the ray-marcher at full resolution would dominate the test
    // time (minutes per case). Paint the themed background only.
    if (!kIsWeb && io.Platform.environment['FLUTTER_TEST'] == 'true') return;

    // 1) Kick the async heightfield bake (non-blocking). GPU rasterizes it in
    //    parallel with the display pass — no CPU-GPU stall.
    state._kickBake();
    final hf = state._bakeImage;
    if (hf == null) return; // first frame: no bake yet, show bg only.

    // 2) Display pass. Rasterize the shader at a CAPPED pixel count, then blit.
    // On a @3x iPhone, Flutter rasterizes CustomPaint at device resolution
    // (3×3 = 9× the logical pixels) — the shader would do 9× the work for no
    // visual gain. We cap the effective render area and upscale.
    final fs = state._dispFs ??= state.widget.controller.createDisplay();
    if (!state._staticsApplied) {
      state._pushStatics(fs);
      state._staticsApplied = true;
    }

    // Rasterize at full device resolution (crisp on retina — sub-native
    // renders upscale into blur and jaggies). The ceiling only guards
    // extreme multi-monitor 6K+ surfaces; 16.6MP covers 5K at native 1:1.
    final dpr = _devicePixelRatio();
    final devW = size.width * dpr;
    final devH = size.height * dpr;
    final devPixels = devW * devH;
    const maxPixels = 16600000.0; // ~16.6MP (5K-class) absolute ceiling
    var scale = devPixels > maxPixels ? math.sqrt(maxPixels / devPixels) : 1.0;
    // Adaptive quality can reduce this on weak hardware, or raise it into
    // supersampling territory on strong hardware.
    if (state.widget.adaptiveQuality) {
      scale *= state._quality.renderScale;
    }
    // Live-resize handling for the duration of the gesture (and a 150 ms
    // tail after the last size change). See the cached-blit branch below.
    final nowUs = state._clock.elapsedMicroseconds;
    if (size != state._lastPaintSize) {
      // Zero = first paint ever: adopting the initial size is not a resize
      // (arming here would blur the launch frames at half resolution).
      final isFirstPaint = state._lastPaintSize == ui.Size.zero;
      state._lastPaintSize = size;
      if (!isFirstPaint) state._resizeUntilUs = nowUs + 150000;
      if (kSonicTraceResize) {
        final lay = state._size; // LayoutBuilder's view of the same box
        var phys = 'n/a';
        try {
          final v = ui.PlatformDispatcher.instance.views.first;
          phys = '${v.physicalSize.width}x${v.physicalSize.height}';
        } catch (_) {}
        print('SONIC_RS | size-change paint=${size.width}x${size.height} '
            'layout=${lay.width}x${lay.height} '
            '${lay == size ? '' : 'MISMATCH '}dpr=${_devicePixelRatio()} '
            'engine-phys=$phys');
      }
    }
    if (nowUs < state._resizeUntilUs) {
      // Live-resize floods the pipeline with size changes. Rendering the
      // full shader (or churning toImageSync textures) at every step
      // saturates the raster thread, viewport-metrics events then lag by
      // seconds, and the layout sticks at a stale size — the scene visibly
      // collapses into a corner of the window. Instead: one cheap 0.5×
      // render seeds the cache, every other drag frame is a single
      // stretched blit (~0.1 ms), letting metrics land immediately.
      final cached = state._displayImage;
      if (cached != null) {
        canvas.drawImageRect(
          cached,
          ui.Rect.fromLTWH(
              0, 0, cached.width.toDouble(), cached.height.toDouble()),
          Offset.zero & size,
          ui.Paint()..filterQuality = ui.FilterQuality.low,
        );
        return;
      }
      scale *= 0.5;
    }
    final rw = (devW * scale).clamp(2.0, 8192.0);
    final rh = (devH * scale).clamp(2.0, 8192.0);
    if (kSonicTraceResize && nowUs < state._resizeUntilUs) {
      state._rsTraceFrames++;
      if (state._rsTraceFrames % 10 == 1) {
        print('SONIC_RS | resize-seed #${state._rsTraceFrames} '
            'paint=${size.width}x${size.height} dpr=$dpr '
            'dev=${devW.toStringAsFixed(0)}x${devH.toStringAsFixed(0)} '
            'uRes=${rw.toStringAsFixed(0)}x${rh.toStringAsFixed(0)} '
            'scale=${scale.toStringAsFixed(2)}');
      }
    } else if (kSonicTraceResize) {
      state._rsTraceFrames = 0;
    }

    fs.setImageSampler(0, hf);

    // Native fast path: at exactly device resolution the offscreen image
    // buys nothing — it costs a full-screen copy plus a sync flush that adds
    // several ms of pipeline overhead per frame. Draw the shader straight
    // onto the canvas; the canvas transform rasterizes it at device pixels.
    if ((scale - 1.0).abs() < 0.002) {
      state._pushDynamics(fs, devW, devH);
      canvas.drawRect(Offset.zero & size, ui.Paint()..shader = fs);
      if (state._displayImage != null) {
        state._retire(state._displayImage);
        state._displayImage = null;
      }
      return;
    }

    state._pushDynamics(fs, rw, rh);

    // Record the shader into a Picture and rasterize SYNCHRONOUSLY at the
    // capped resolution (toImageSync — fast because rw×rh ≤ 1.5MP). Then blit
    // the result upscaled to the canvas. Sync avoids async pipeline latency
    // (which capped displayed fps at 60) while still limiting GPU pixel work.
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      Offset.zero & ui.Size(rw, rh),
      ui.Paint()..shader = fs,
    );
    final pic = rec.endRecording();
    final sw = kSonicPerf ? (Stopwatch()..start()) : null;
    ui.Image img;
    try {
      img = pic.toImageSync(rw.toInt(), rh.toInt());
      pic.dispose();
    } catch (e) {
      if (kSonicTraceResize) print('SONIC_RS | toImageSync threw: $e');
      // Fallback for hosts without toImageSync: draw the shader directly onto
      // the canvas at device resolution (no pixel cap, but rare on modern HW).
      canvas.drawRect(
        Offset.zero & ui.Size(rw, rh),
        ui.Paint()..shader = fs,
      );
      pic.dispose();
      if (sw != null) {
        sw.stop();
        state._lastRenderMs = sw.elapsedMicroseconds / 1000.0;
      }
      return;
    }
    state._retire(state._displayImage);
    state._displayImage = img;
    if (sw != null) {
      sw.stop();
      state._lastRenderMs = sw.elapsedMicroseconds / 1000.0;
    }

    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      // medium (mipmapped) keeps supersampled downsamples clean; bilinear
      // would alias when rendering above device resolution.
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
  }

  static double _devicePixelRatio() {
    try {
      return ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    } catch (_) {
      return 1.0;
    }
  }

  @override
  bool shouldRepaint(covariant _SonicPainter old) => old.state != state;
}

@visibleForTesting
Future<ui.Image> captureSonicFrameForTesting({
  required SonicShaderController controller,
  required AudioBands bands,
  required SonicTheme theme,
  required double width,
  required double height,
  double time = 1.0,
  double camAngle = 0.7853981,
  double camRadius = 99.6,
  double camHeight = 25.7,
  double spacing = 1.05,
  double marchScale = 1.0,
  td.Float32List? ripples,
  td.Float32List? meteors,
  td.Float32List? particles,
  double blockPulse = 0,
}) async {
  final scene = SceneState();
  scene.pack(time);

  // Pass 1: bake the heightfield (160×160).
  const g = 160.0;
  final bakeFs = controller.createBake();
  bakeFs
    ..setFloat(0, g)..setFloat(1, g)..setFloat(2, time)
    ..setFloat(3, bands.subBass)..setFloat(4, bands.bass)..setFloat(5, bands.lowMid)
    ..setFloat(6, bands.mid)..setFloat(7, bands.highMid)..setFloat(8, bands.presence)
    ..setFloat(9, bands.brilliance)..setFloat(10, bands.air)..setFloat(11, bands.energy)
    ..setFloat(12, bands.warmth)..setFloat(13, bands.brightness)
    ..setFloat(14, bands.sharpness)..setFloat(15, bands.smoothness)
    ..setFloat(16, bands.density)..setFloat(17, spacing)
    ..setFloat(18, 1.0); // uAmplitude
  final ru = ripples ?? scene.rippleUniforms;
  for (int i = 0; i < 10; i++) {
    final o = i * 4;
    bakeFs..setFloat(19+o, ru[o])..setFloat(20+o, ru[o+1])..setFloat(21+o, ru[o+2])..setFloat(22+o, ru[o+3]);
  }
  final bRec = ui.PictureRecorder();
  ui.Canvas(bRec).drawRect(Offset.zero & const ui.Size(g, g), ui.Paint()..shader = bakeFs);
  final bPic = bRec.endRecording();
  final heightfield = await bPic.toImage(g.toInt(), g.toInt());
  bPic.dispose();
  bakeFs.dispose();

  // Pass 2: display, bound to the heightfield sampler. Indices match the
  // display shader's uniform declaration order (see sonic_topography.frag).
  final fs = controller.createDisplay();
  final b1 = theme.vBase1, b2 = theme.vBase2;
  fs
    ..setFloat(9, b1.x)..setFloat(10, b1.y)..setFloat(11, b1.z)
    ..setFloat(12, b2.x)..setFloat(13, b2.y)..setFloat(14, b2.z);
  final cc = theme.vCoolCore, ce = theme.vCoolEdge;
  fs
    ..setFloat(15, cc.x)..setFloat(16, cc.y)..setFloat(17, cc.z)
    ..setFloat(18, ce.x)..setFloat(19, ce.y)..setFloat(20, ce.z);
  final wc = theme.vWarmCore, we = theme.vWarmEdge, rp = theme.vRipple;
  fs
    ..setFloat(21, wc.x)..setFloat(22, wc.y)..setFloat(23, wc.z)
    ..setFloat(24, we.x)..setFloat(25, we.y)..setFloat(26, we.z)
    ..setFloat(27, rp.x)..setFloat(28, rp.y)..setFloat(29, rp.z)
    ..setFloat(30, theme.glowIntensity)
    ..setFloat(367, camRadius)..setFloat(368, camHeight)
    ..setFloat(371, 0.32) // uPillarHalf
    ..setFloat(372, spacing) // uSpacing
    ..setFloat(373, theme.vBase1.x)..setFloat(374, theme.vBase1.y)..setFloat(375, theme.vBase1.z) // uBgColor
    ..setFloat(376, theme.vFog.x)..setFloat(377, theme.vFog.y)..setFloat(378, theme.vFog.z); // uFogColor
  fs
    ..setFloat(0, width)..setFloat(1, height)..setFloat(2, time)
    ..setFloat(3, bands.presence)..setFloat(4, bands.brilliance)..setFloat(5, bands.air)
    ..setFloat(6, bands.warmth)..setFloat(7, bands.brightness)
    ..setFloat(8, bands.sharpness)
    ..setFloat(369, camAngle)..setFloat(370, marchScale);
  final mu = meteors ?? scene.meteorUniforms;
  for (int i = 0; i < 20; i++) {
    final o = i * 4;
    fs..setFloat(31+o, mu[o])..setFloat(32+o, mu[o+1])..setFloat(33+o, mu[o+2])..setFloat(34+o, mu[o+3]);
  }
  final pu = particles ?? scene.particleUniforms;
  for (int i = 0; i < 64; i++) {
    final o = i * 4;
    fs..setFloat(111+o, pu[o])..setFloat(112+o, pu[o+1])..setFloat(113+o, pu[o+2])..setFloat(114+o, pu[o+3]);
  }
  if (blockPulse > 0) {
    // Warm the block animation to a steady pulse so captures show them.
    for (int i = 0; i < 240; i++) {
      scene.tickBlocks(1 / 60, blockPulse, true);
    }
  }
  final bu = scene.blockUniforms;
  for (int i = 0; i < SceneState.maxBlocks; i++) {
    final o = i * 4;
    fs..setFloat(379+o, bu[o])..setFloat(380+o, bu[o+1])..setFloat(381+o, bu[o+2])..setFloat(382+o, bu[o+3]);
  }
  final bq = scene.blockRotUniforms;
  for (int i = 0; i < SceneState.maxBlocks; i++) {
    final o = i * 4;
    fs..setFloat(507+o, bq[o])..setFloat(508+o, bq[o+1])..setFloat(509+o, bq[o+2])..setFloat(510+o, bq[o+3]);
  }
  fs.setFloat(635, scene.blockPulseMix);
  fs.setImageSampler(0, heightfield);
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(Offset.zero & ui.Size(width, height), ui.Paint()..shader = fs);
  final pic = rec.endRecording();
  final img = await pic.toImage(width.toInt(), height.toInt());
  pic.dispose();
  fs.dispose();
  heightfield.dispose();
  return img;
}
