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

/// Adaptive quality — maximum fidelity at the display's full refresh rate.
///
/// Policy: fps always wins, quality absorbs the slack. The budget is the
/// display's real refresh interval (set from `display.refreshRate`). Cost is
/// wall-clock frame time, which vsync quantizes to multiples of that interval:
/// either we hit every vsync (≈1.0) or we drop to 2×/3× it. Sub-vsync GPU
/// headroom is therefore invisible — the only way to discover it is to probe.
///
/// Stability matters more than squeezing the last notch: every renderScale
/// change visibly re-rasters the grid, so a naive probe/retreat loop makes
/// the whole scene pulse. This controller uses AIMD with a learned ceiling:
/// a level that missed vsync once is remembered and not re-tried for ~20s of
/// stable operation, drops are gentle single steps, and climbs require 1.2s
/// of consecutive on-budget frames. The result settles just under the cliff
/// and stays there.
class AdaptiveQuality {
  AdaptiveQuality({
    double initialRenderScale = 1.0,
    this.targetFrameTimeMs = 1000 / 120,
    this.minRenderScale = 0.4,
    this.maxRenderScale = 1.5,
  })  : renderScale = initialRenderScale.clamp(minRenderScale, maxRenderScale),
        _ceiling = maxRenderScale;

  double targetFrameTimeMs;
  final double minRenderScale, maxRenderScale;
  double renderScale;
  double marchScale = 1.0;

  double _ema = 1000 / 120;
  double _cooldown = 0;
  double _stableSec = 0; // consecutive on-budget time at the current scale
  double _ceiling; // highest level not (recently) known to miss vsync
  int _sample = 0;

  double get fps => _ema <= 0 ? 0 : 1000 / _ema;

  void sample(double costMs) {
    _sample++;
    _ema += (costMs - _ema) * 0.08;
    final dtSec = (costMs / 1000.0).clamp(0.001, 0.05);
    if (_cooldown > 0) {
      _cooldown -= dtSec;
      return;
    }
    if (_sample < 20) return;
    final ratio = _ema / targetFrameTimeMs;
    if (ratio > 1.15) {
      // Missing vsync: this level fails — record it as the new ceiling, shed
      // one gentle notch (further misses walk down the staircase), and only
      // touch ray-march density once resolution is at the floor.
      final failed = renderScale;
      final rs = (renderScale - 0.06).clamp(minRenderScale, maxRenderScale);
      final stepped = (rs * 100).round() / 100.0;
      if (stepped < renderScale) {
        renderScale = stepped;
        _ceiling = math.min(_ceiling, failed - 0.02);
      } else {
        marchScale = (marchScale - 0.1).clamp(0.5, 1.0);
      }
      _stableSec = 0;
      _cooldown = 0.5;
      return;
    }
    // Budget met.
    _stableSec += dtSec;
    final cap = math.min(_ceiling, maxRenderScale);
    if (renderScale < cap && _stableSec >= 1.2) {
      // Climb one notch only after sustained stability, never above the
      // learned ceiling.
      final rs = (renderScale + 0.04).clamp(minRenderScale, cap);
      renderScale = (rs * 100).round() / 100.0;
      _stableSec = 0;
      _cooldown = 0.6;
    } else if (renderScale >= maxRenderScale - 0.001) {
      marchScale = 1.0;
    }
    if (_stableSec >= 20) {
      // Long stable run: relax the ceiling one notch so load changes
      // (window moved, shaders warmed up) get re-explored eventually.
      _ceiling = (_ceiling + 0.04).clamp(minRenderScale, maxRenderScale);
      _stableSec = 0;
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
  final PerfSampler? _perf = kSonicPerf ? PerfSampler() : null;

  // Reused display + bake shaders. Statics set once; dynamics updated per frame.
  ui.FragmentShader? _dispFs;
  ui.FragmentShader? _bakeFs;
  bool _staticsApplied = false;
  // Async heightfield bake: pipelined, NEVER blocks the CPU.
  ui.Image? _bakeImage;
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
      targetFrameTimeMs: 1000 / widget.targetFps,
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
    // The quality budget must match the display's real refresh interval.
    // Without the perf sampler the controller scores the plain frame
    // interval, which on a 60 Hz display (16.7 ms) would forever exceed a
    // fixed 120 fps budget (8.3 ms) and drive renderScale to the floor —
    // the classic "everything looks upscaled and blurry" bug.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final refresh = views.first.display.refreshRate;
    if (refresh > 0) {
      _quality.targetFrameTimeMs = 1000.0 / refresh.clamp(30.0, 240.0);
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
    final now = _clock.elapsed;
    final rawDt = (now - _last).inMicroseconds / 1000000.0;
    // Clamp dt to [1ms, 50ms] — prevents rotation/stutter jumps on GC pauses or
    // scheduling spikes, keeping the animation smooth and frame-rate-independent.
    final dt = rawDt.clamp(0.001, 0.05);
    _last = now;
    final time = now.inMilliseconds / 1000.0;
    final frameMs = dt * 1000.0;

    if (_perf != null) _perf.sample(_lastRenderMs, frameMs, () => time);
    // Track displayed FPS from real vsync intervals (not GPU raster) so the
    // UI readout reflects what the user actually sees. Uses the unclamped
    // interval — the 50ms clamp above is for animation stability only, and
    // pinning the readout at 20 would hide genuine severe drops.
    if (rawDt > 0) {
      _displayedFpsEma += (1000.0 / (rawDt * 1000.0) - _displayedFpsEma) * 0.08;
    }
    if (widget.adaptiveQuality) {
      // Adaptive quality uses GPU raster cost (the true shader budget).
      final cost = (_perf != null && _perf.rasterEmaMs > 0) ? _perf.rasterEmaMs : frameMs;
      _quality.sample(cost);
      if (_perf != null) {
        _perf.setQuality(renderScale: _quality.renderScale, marchScale: _quality.marchScale);
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
      _bakeImage?.dispose();
      _bakeImage = img;
      _bakeInFlight = false;
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

    // Rasterize at full device resolution by default (crisp on retina — a
    // 1.5MP cap would render at ~half res on modern displays and look soft),
    // with only a sanity ceiling for extreme 5K/6K surfaces. Adaptive quality
    // may push beyond 1.0 (supersampling) when the GPU has headroom.
    final dpr = _devicePixelRatio();
    final devW = size.width * dpr;
    final devH = size.height * dpr;
    final devPixels = devW * devH;
    const maxPixels = 8400000.0; // ~8.4MP (4K-class) absolute ceiling
    var scale = devPixels > maxPixels ? math.sqrt(maxPixels / devPixels) : 1.0;
    // Adaptive quality can reduce this on weak hardware, or raise it into
    // supersampling territory on strong hardware.
    if (state.widget.adaptiveQuality) {
      scale *= state._quality.renderScale;
    }
    final rw = (devW * scale).clamp(2.0, 4096.0);
    final rh = (devH * scale).clamp(2.0, 4096.0);

    state._pushDynamics(fs, rw, rh);
    fs.setImageSampler(0, hf);

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
    } catch (_) {
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
    state._displayImage?.dispose();
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
