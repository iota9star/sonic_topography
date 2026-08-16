import 'dart:io' if (dart.library.html) 'io_web.dart';

import 'package:flutter/scheduler.dart';

/// Whether live performance logging is enabled.
///
/// Enabled by passing `--dart-define=SONIC_PERF=true` at run/build time (the
/// value MUST be the literal `true`; `1` is not accepted by
/// `bool.fromEnvironment`). When on, the visualizer periodically writes the
/// real GPU **rasterizer** frame time (frame-rate independent: a sub-8.3ms
/// raster proves a 120fps budget even when the host monitor is only 60Hz, which
/// caps the *displayed* interval FPS).
const bool kSonicPerf =
    bool.fromEnvironment('SONIC_PERF', defaultValue: false);

/// Lightweight rolling performance sampler used when [kSonicPerf] is on.
///
/// The authoritative GPU-cost signal is the **rasterizer duration** reported by
/// Flutter's [FrameTiming] (`PlatformDispatcher.onReportTimings`). Unlike a
/// wall-clock stopwatch around `canvas.drawRect(shader)` — which only measures
/// *recording* the draw command into a Picture, not the GPU work — the raster
/// duration is the actual time the GPU spent executing the shader, independent
/// of the monitor's refresh rate. That is what proves a 120fps+ render budget.
///
/// It also reports the *displayed* interval FPS (capped by the monitor), so you
/// can see both the headroom and the achieved rate.
class PerfSampler {
  PerfSampler() : _platform = _platformName() {
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback);
  }

  late final TimingsCallback _timingsCallback = _onTimings;

  final String _platform;

  // Rolling windows for min/avg/p99.
  static const int _window = 120;
  final List<double> _raster = <double>[]; // GPU rasterizer ms (the budget)
  final List<double> _frame = <double>[]; // displayed interval ms
  final List<double> _build = <double>[]; // UI-thread build+paint-record ms
  double _lastLog = 0;
  int _frames = 0;

  // Latest adaptive-quality state, surfaced in the log for tuning.
  double _renderScale = 0.75;
  double _marchScale = 1.0;

  // EMA of the GPU rasterizer duration (ms).
  double _rasterEma = 8.3;

  /// Latest EMA of the rasterizer duration (ms).
  double get rasterEmaMs => _rasterEma;

  // EMA of the PRESENTED frame rate — totalSpan per frame is the wall-clock
  // cadence frames actually reached the screen at. This (not the UI ticker
  // cadence, which runs ahead of the rasterizer on desktop) is the signal
  // adaptive quality must key on.
  double _presentedFpsEma = 60;

  /// Latest EMA of the presented frame rate (fps).
  double get presentedFpsEma => _presentedFpsEma;

  /// Record the current adaptive quality so the log line shows it.
  void setQuality({required double renderScale, required double marchScale}) {
    _renderScale = renderScale;
    _marchScale = marchScale;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      // rasterDuration = GPU time to rasterize the frame (the shader cost).
      final r = t.rasterDuration.inMicroseconds / 1000.0;
      _raster.add(r);
      _rasterEma += (r - _rasterEma) * 0.1;
      // totalSpan = wall-clock from build start to raster finish (displayed).
      final f = t.totalSpan.inMicroseconds / 1000.0;
      _frame.add(f);
      if (f > 0) {
        _presentedFpsEma += (1000.0 / f - _presentedFpsEma) * 0.1;
      }
      _build.add(t.buildDuration.inMicroseconds / 1000.0);
    }
    while (_raster.length > _window) {
      _raster.removeAt(0);
    }
    while (_frame.length > _window) {
      _frame.removeAt(0);
    }
    while (_build.length > _window) {
      _build.removeAt(0);
    }
  }

  /// Drive the report cadence from the ticker. [renderMs]/[frameMs] are kept
  /// for API compatibility but the [FrameTiming] path is authoritative.
  void sample(double renderMs, double frameMs, double Function() now) {
    _frames++;
    // Fallback: if the raster window is empty (e.g. very early), seed it from
    // the supplied render ms so the first reports aren't blank.
    if (_raster.isEmpty && renderMs > 0) _raster.add(renderMs);
    if (_frame.isEmpty && frameMs > 0) _frame.add(frameMs);

    final t = now();
    if (t - _lastLog >= 2.0) {
      _lastLog = t;
      _report();
    }
  }

  void _report() {
    if (_raster.isEmpty) return;
    final gMin = _min(_raster), gAvg = _avg(_raster), gP99 = _pct(_raster, 99);
    final fAvg = _frame.isEmpty ? 0.0 : _avg(_frame);
    final bAvg = _build.isEmpty ? 0.0 : _avg(_build);
    final bMax = _build.isEmpty ? 0.0 : _build.reduce((a, b) => a > b ? a : b);
    final intervalFps = fAvg <= 0 ? 0 : 1000.0 / fAvg;
    // Raster-budget fps: how many frames the GPU could rasterize per second if
    // the display were fast enough. >=120 means we hold 120fps on any 120Hz host.
    final rasterFps = 1000.0 / gAvg;
    final rasterFpsP99 = 1000.0 / gP99;
    // ignore: avoid_print
    print('SONIC_PERF | $_platform | frames=$_frames'
        ' | raster avg=${gAvg.toStringAsFixed(2)}ms'
        ' min=${gMin.toStringAsFixed(2)}ms'
        ' p99=${gP99.toStringAsFixed(2)}ms'
        ' => render-budget ${rasterFps.toStringAsFixed(0)}fps'
        ' (p99 ${rasterFpsP99.toStringAsFixed(0)}fps)'
        ' | displayed ${intervalFps.toStringAsFixed(0)}fps'
        ' @ ${(fAvg).toStringAsFixed(2)}ms/frame'
        ' (build avg=${bAvg.toStringAsFixed(2)}ms max=${bMax.toStringAsFixed(2)}ms)'
        ' | renderScale=${_renderScale.toStringAsFixed(2)}'
        ' march=${_marchScale.toStringAsFixed(2)}');
  }

  double _min(List<double> x) {
    double m = x.first;
    for (final v in x) {
      if (v < m) m = v;
    }
    return m;
  }

  double _avg(List<double> x) {
    double s = 0;
    for (final v in x) {
      s += v;
    }
    return s / x.length;
  }

  double _pct(List<double> x, int p) {
    if (x.isEmpty) return 0;
    final sorted = List<double>.from(x)..sort();
    final idx = ((sorted.length - 1) * p / 100).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  static String _platformName() {
    try {
      if (Platform.isMacOS) return 'macos';
      if (Platform.isIOS) return 'ios';
      if (Platform.isAndroid) return 'android';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {
      // Web: Platform throws. Report as web.
    }
    return 'web';
  }
}
