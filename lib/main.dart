import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Directory, File, Platform, ServerSocket, InternetAddress;
import 'dart:typed_data' show Float64List;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show MethodChannel;

import 'dart:ui' as ui show ImageByteFormat;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';

import 'package:sonic_topography/src/diag.dart';
import 'package:sonic_topography/sonic_topography.dart';

void main() {
  runApp(const SonicApp());
}

/// When `--dart-define=SONIC_FULLRES=true`, force full resolution + disable
/// adaptive scaling — used to capture best-quality 120fps+ proof runs.
const bool kSonicFullres = bool.fromEnvironment(
  'SONIC_FULLRES',
  defaultValue: false,
);

/// Initial audio source: `demo` (default), `mic`, or `player`.
const String kSonicSource = String.fromEnvironment(
  'SONIC_SOURCE',
  defaultValue: 'demo',
);

/// A/B experiment switch: disable floating blocks to isolate their cost.
const bool kSonicNoBlocks = bool.fromEnvironment(
  'SONIC_NO_BLOCKS',
  defaultValue: false,
);

class SonicApp extends StatelessWidget {
  const SonicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sonic Topography',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        fontFamily: 'system-ui',
      ),
      home: const SonicHomePage(),
    );
  }
}

enum AudioSourceMode { demo, mic, player }

enum PlayMode { repeatAll, repeatOne, shuffle }

class _Track {
  _Track(this.path, this.title);
  final String path;
  String title;
  Lyrics? lyrics;
}

/// Reference-aligned tuning knobs surfaced in the settings panel. Values are
/// the reference's own scales (0..100 ground-eq settings, rad/s rotation,
/// 0..1 trigger sensitivity, 60 fps cooldown frames).
class PanelTuning {
  const PanelTuning({
    this.rotationSpeed = 0.15,
    this.blockIntensity = 55,
    this.blockMin = 9,
    this.blockMax = 26,
    this.blockSpeed = 77,
    this.blockCount = 32,
    this.density = 46,
    this.pulse = const TriggerTuning(
      sensitivity: 0.85,
      cooldownFrames: 15,
      bandStart: 1,
      bandEnd: 2,
      strength: 0.2,
    ),
    this.meteor = const TriggerTuning(
      sensitivity: 0.45,
      cooldownFrames: 241,
      bandStart: 159,
      bandEnd: 174,
      strength: 0.5,
    ),
    this.themeRotation = false,
    this.themeRotationSec = 10,
  });

  final double rotationSpeed;
  final double blockIntensity, blockMin, blockMax, blockSpeed;
  final int blockCount;

  /// Reference terrainDensity (0..100) → grid = 96 + 128·d/100 cells/side.
  final double density;
  final TriggerTuning pulse, meteor;
  final bool themeRotation;
  final int themeRotationSec;

  PanelTuning copyWith({
    double? rotationSpeed,
    double? blockIntensity,
    double? blockMin,
    double? blockMax,
    double? blockSpeed,
    int? blockCount,
    double? density,
    TriggerTuning? pulse,
    TriggerTuning? meteor,
    bool? themeRotation,
    int? themeRotationSec,
  }) =>
      PanelTuning(
        rotationSpeed: rotationSpeed ?? this.rotationSpeed,
        blockIntensity: blockIntensity ?? this.blockIntensity,
        blockMin: blockMin ?? this.blockMin,
        blockMax: blockMax ?? this.blockMax,
        blockSpeed: blockSpeed ?? this.blockSpeed,
        blockCount: blockCount ?? this.blockCount,
        density: density ?? this.density,
        pulse: pulse ?? this.pulse,
        meteor: meteor ?? this.meteor,
        themeRotation: themeRotation ?? this.themeRotation,
        themeRotationSec: themeRotationSec ?? this.themeRotationSec,
      );

  /// Reference grid formula: gridSize = 96 + 128 · density/100.
  int get gridN => (96 + 128 * density / 100).round().clamp(96, 224);
}

/// One frequency trigger's user-facing config (reference FreqTriggerPanel).
class TriggerTuning {
  const TriggerTuning({
    this.enabled = true,
    this.advanced = false,
    this.sensitivity = 0.5,
    this.cooldownFrames = 60,
    this.bandStart = 0,
    this.bandEnd = 16,
    this.strength = 0.2,
    this.freqIndex = -1,
    this.threshold = 0.5,
  });

  final bool enabled;
  final bool advanced; // false = Auto Beat, true = Advanced (crosshair)
  final double sensitivity;
  final int cooldownFrames;
  final int bandStart, bandEnd;
  final double strength;
  final int freqIndex;
  final double threshold;

  TriggerTuning copyWith({
    bool? enabled,
    bool? advanced,
    double? sensitivity,
    int? cooldownFrames,
    int? bandStart,
    int? bandEnd,
    double? strength,
    int? freqIndex,
    double? threshold,
  }) =>
      TriggerTuning(
        enabled: enabled ?? this.enabled,
        advanced: advanced ?? this.advanced,
        sensitivity: sensitivity ?? this.sensitivity,
        cooldownFrames: cooldownFrames ?? this.cooldownFrames,
        bandStart: bandStart ?? this.bandStart,
        bandEnd: bandEnd ?? this.bandEnd,
        strength: strength ?? this.strength,
        freqIndex: freqIndex ?? this.freqIndex,
        threshold: threshold ?? this.threshold,
      );
}

class SonicHomePage extends StatefulWidget {
  const SonicHomePage({super.key});

  @override
  State<SonicHomePage> createState() => _SonicHomePageState();
}

class _SonicHomePageState extends State<SonicHomePage> {
  final SonicShaderController _shader = SonicShaderController();
  late final DemoAnalyzer _demo = DemoAnalyzer();
  final MicAnalyzer _mic = MicAnalyzer();
  final PlayerAnalyzer _player = PlayerAnalyzer();

  AudioSourceMode _source = AudioSourceMode.demo;
  SonicTheme _theme = SonicTheme.neonTokyo;
  double _glow = 1.0;
  // Derived from the reference's default density 46 → 155 cells, spacing
  // 168/155 ≈ 1.084, fill ratio 0.857.
  double _pillarWidth = 0.9290;
  double _spacing = 1.0839;
  double _amplitude = 1.0;
  bool _meteors = true;
  bool _ripples = true;
  bool _blocks = !kSonicNoBlocks;
  bool _autoRotate = true;
  bool _adaptive = true;
  bool _showLyrics = true;
  List<int> _eqCurve = List<int>.from(GroundEq.defaultCurve);

  /// Reference-aligned tuning (ground-eq settings + global scene settings),
  /// bundled so the settings panel needs one parameter through the overlay.
  PanelTuning _tuning = const PanelTuning();

  /// Grid cells/side from the density slider. Spacing/pillar width derive
  /// from it (reference: 168/gridSize and fill ratio 0.857) — the manual
  /// sliders still override afterwards.
  int get _gridN => _tuning.gridN;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _themeRotationTimer;
  QualityMetrics _metrics = const QualityMetrics();
  AudioAnalyzer? _active;

  // Player state.
  final List<_Track> _playlist = [];
  int _trackIndex = -1;
  PlayMode _playMode = PlayMode.repeatAll;
  double _volume = 0.9;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playerReady = false;
  Timer? _posTicker;

  // ---- debug-only remote frame capture ----
  // `echo x | nc 127.0.0.1 50777` makes the running app dump a burst of real
  // rendered frames (Impeller/Metal path, live scene state) plus band values
  // to the diag log, so rendering issues can be inspected without screen
  // recording permissions.
  static bool _dbgServerStarted = false;
  static final GlobalKey _dbgBoundaryKey = GlobalKey(
    debugLabel: 'sonic_dbg_capture',
  );
  static final GlobalKey _dbgOverlayKey = GlobalKey(
    debugLabel: 'sonic_dbg_overlay',
  );

  Future<void> _startDebugCaptureServer() async {
    if (_dbgServerStarted || kReleaseMode) return;
    _dbgServerStarted = true;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        50777,
      );
      sonicDiag('dbgcap: listening on 50777');
      server.listen((socket) {
        socket.drain<void>().catchError((_) {});
        socket.destroy();
        sonicDiag('dbgcap: triggered');
        unawaited(_debugCaptureFrames());
      });
    } catch (e) {
      sonicDiag('dbgcap: server failed: $e');
    }
  }

  Future<void> _debugCaptureFrames() async {
    try {
      final ctx = _dbgBoundaryKey.currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        sonicDiag('dbgcap: no repaint boundary attached');
        return;
      }
      final dir = Directory.systemTemp;
      // Diagnostics: prove whether the overlay chrome is in the render tree
      // and where its layers land relative to the captured boundary.
      sonicDiag(
        'dbgcap: boundary size=${ro.size} '
        'paintBounds=${ro.paintBounds}',
      );
      final octx = _dbgOverlayKey.currentContext;
      final oro = octx?.findRenderObject();
      sonicDiag(
        'dbgcap: overlay ro=$oro '
        '${oro is RenderRepaintBoundary ? 'boundary size=${oro.size} paintBounds=${oro.paintBounds}' : '(not a boundary)'}',
      );
      if (oro is RenderRepaintBoundary) {
        final oimg = await oro.toImage(pixelRatio: 1.0);
        final obytes = await oimg.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/sonic_dbg_overlay.png')
            .writeAsBytes(obytes!.buffer.asUint8List());
        sonicDiag('dbgcap: overlay-only image saved');
      }
      for (int i = 0; i < 8; i++) {
        final img = await ro.toImage(pixelRatio: 1.0);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        final path = '${dir.path}/sonic_dbg_$i.png';
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        final b = _active?.read() ?? AudioBands.idle;
        sonicDiag(
          'dbgcap: $i -> $path'
          ' sub=${b.subBass.toStringAsFixed(2)} bass=${b.bass.toStringAsFixed(2)}'
          ' mid=${b.mid.toStringAsFixed(2)} energy=${b.energy.toStringAsFixed(2)}',
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    } catch (e) {
      sonicDiag('dbgcap: capture failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_startDebugCaptureServer());
    _applyTriggers();
    final initial = switch (kSonicSource) {
      'mic' => AudioSourceMode.mic,
      'player' => AudioSourceMode.player,
      _ => AudioSourceMode.demo,
    };
    _activate(initial);
  }

  @override
  void dispose() {
    _posTicker?.cancel();
    _themeRotationTimer?.cancel();
    _demo.dispose();
    _mic.dispose();
    _player.dispose();
    _shader.dispose();
    super.dispose();
  }

  /// Reference themeRotation: auto-cycle the built-in palette. We rotate
  /// through all built-ins (the reference cycles a user-picked subset).
  void _syncThemeRotation() {
    _themeRotationTimer?.cancel();
    _themeRotationTimer = null;
    if (!_tuning.themeRotation) return;
    _themeRotationTimer = Timer.periodic(
      Duration(seconds: _tuning.themeRotationSec),
      (_) => setState(() {
        final i = SonicTheme.builtIn.indexWhere((t) => t.id == _theme.id);
        _theme = SonicTheme.builtIn[(i + 1) % SonicTheme.builtIn.length];
      }),
    );
  }

  /// Push the panel's trigger tuning into the real-input analyzers (the demo
  /// synthesizer has no spectrum, so its triggers stay at engine defaults).
  void _applyTriggers() {
    for (final a in [_mic, _player]) {
      final tr = _triggersOf(a);
      if (tr == null) continue;
      _applyTrigger(tr.pulse, _tuning.pulse);
      _applyTrigger(tr.meteor, _tuning.meteor);
    }
  }

  static void _applyTrigger(FreqTriggerConfig c, TriggerTuning t) {
    c.enabled = t.enabled;
    c.mode = t.advanced ? FreqTriggerMode.advanced : FreqTriggerMode.autoBeat;
    c.sensitivity = t.sensitivity;
    c.cooldown = t.cooldownFrames;
    c.bandStart = t.bandStart;
    c.bandEnd = t.bandEnd;
    c.strength = t.strength;
    c.freqIndex = t.freqIndex;
    c.threshold = t.threshold;
  }

  // ---- source switching ----

  Future<void> _activate(AudioSourceMode src) async {
    sonicDiag('ui: activate $src');
    if (src == _source && _active != null) return;
    try {
      await _active?.stop();
    } catch (_) {}
    setState(() => _source = src);
    switch (src) {
      case AudioSourceMode.demo:
        await _demo.start();
        if (mounted) setState(() => _active = _demo);
      case AudioSourceMode.mic:
        try {
          await _mic.start();
          if (mounted) setState(() => _active = _mic);
        } on MicPermissionException catch (e) {
          if (!mounted) return;
          setState(() => _source = AudioSourceMode.demo);
          if (e.permanent) {
            final ok = await _confirm(
              'Microphone access required',
              e.message,
              'Open settings',
            );
            if (ok == true) await MicPermission.openSettings();
          } else {
            _toast(e.message);
          }
          await _fallbackToDemo();
        } catch (e) {
          if (!mounted) return;
          setState(() => _source = AudioSourceMode.demo);
          _toast('Could not start microphone: $e');
          await _fallbackToDemo();
        }
      case AudioSourceMode.player:
        if (_playlist.isEmpty) {
          final added = await _pickFiles();
          sonicDiag('ui: pickFiles -> $added');
          if (!added || _playlist.isEmpty) {
            if (!mounted) return;
            setState(() => _source = AudioSourceMode.demo);
            await _fallbackToDemo();
            return;
          }
        }
        await _playIndex(_trackIndex >= 0 ? _trackIndex : 0);
        if (mounted) setState(() => _active = _player);
    }
  }

  Future<void> _fallbackToDemo() async {
    await _demo.start();
    if (mounted) {
      setState(() {
        _source = AudioSourceMode.demo;
        _active = _demo;
      });
    }
  }

  // ---- playlist ----

  /// file_picker's macOS entitlement check uses SecTask, which cannot read
  /// entitlements from ad-hoc signed local builds — every pick would fail with
  /// ENTITLEMENT_CHECK_FAILED even though the sandbox entitlement is present.
  /// The plugin exposes a native escape hatch we invoke once up front.
  static const _pickerChannel = MethodChannel(
    'miguelruivo.flutter.plugins.filepicker',
  );

  Future<void> _skipPickerEntitlementChecks() async {
    if (!Platform.isMacOS) return;
    try {
      await _pickerChannel.invokeMethod<void>('skipEntitlementsChecks');
      sonicDiag('picker: skipEntitlementsChecks OK');
    } catch (e) {
      sonicDiag('picker: skipEntitlementsChecks failed: $e');
    }
  }

  Future<bool> _pickFiles() async {
    await _skipPickerEntitlementChecks();
    sonicDiag('picker: pickFiles() calling');
    List<PlatformFile> files;
    try {
      // file_picker 12 static facade returns the picked list directly
      // (null = the user closed the dialog); 11.x is incompatible with
      // Flutter 3.47's built-in Kotlin on Android.
      files = await FilePicker.pickFiles(type: FileType.audio);
    } catch (e) {
      sonicDiag('picker: pickFiles THREW: $e');
      _toast('File picker failed: $e');
      return false;
    }
    sonicDiag('picker: pickFiles -> ${files.length} files');
    if (files.isEmpty) return false;
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      final name = f.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final track = _Track(path, name);
      track.lyrics = _sidecarLyrics(path);
      _playlist.add(track);
    }
    if (_trackIndex < 0) _trackIndex = 0;
    return _playlist.isNotEmpty;
  }

  /// Look for a `.lrc` file next to the audio file.
  Lyrics? _sidecarLyrics(String audioPath) {
    final base = audioPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
    for (final ext in ['.lrc', '.LRC']) {
      final f = File('$base$ext');
      if (f.existsSync()) {
        try {
          return Lyrics.parse(f.readAsStringSync());
        } catch (_) {}
      }
    }
    return null;
  }

  Future<void> _addMoreFiles() async {
    final before = _playlist.length;
    final ok = await _pickFiles();
    if (ok && _playlist.length > before) {
      _toast('Added ${_playlist.length - before} track(s)');
      if (!_playerReady && _trackIndex >= 0) {
        await _playIndex(_trackIndex);
      }
    }
  }

  Future<void> _playIndex(int i) async {
    if (_playlist.isEmpty) return;
    i = i.clamp(0, _playlist.length - 1);
    final t = _playlist[i];
    try {
      await _player.loadFile(t.path, volume: _volume);
    } catch (e) {
      _toast('Could not play ${t.title}: $e');
      return;
    }
    _trackIndex = i;
    _playerReady = true;
    _startPosTicker();
    setState(() {});
  }

  void _startPosTicker() {
    _posTicker?.cancel();
    _posTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_playerReady || !mounted) return;
      final pos = _player.position;
      final dur = _player.duration;
      if (pos != _position || dur != _duration) {
        setState(() {
          _position = pos;
          _duration = dur;
        });
      }
      if (dur > Duration.zero &&
          pos >= dur - const Duration(milliseconds: 300)) {
        _onTrackEnd();
      }
    });
  }

  Future<void> _onTrackEnd() async {
    if (_playMode == PlayMode.repeatOne) {
      await _player.seekTo(Duration.zero);
      await _player.resume();
      return;
    }
    int next;
    if (_playMode == PlayMode.shuffle) {
      next = _playlist.length > 1
          ? (_trackIndex +
                    1 +
                    (DateTime.now().microsecond % (_playlist.length - 1))) %
                _playlist.length
          : 0;
    } else {
      next = _trackIndex + 1;
      if (next >= _playlist.length && _playMode == PlayMode.repeatAll) {
        next = 0;
      }
    }
    if (next < _playlist.length) {
      await _playIndex(next);
    }
  }

  Future<void> _togglePlay() async {
    if (!_playerReady) return;
    await _player.togglePlayPause();
    setState(() {});
  }

  Future<void> _prev() async {
    if (_trackIndex > 0) {
      await _playIndex(_trackIndex - 1);
    } else {
      await _player.seekTo(Duration.zero);
    }
  }

  Future<void> _next() async {
    await _playIndex((_trackIndex + 1).clamp(0, _playlist.length - 1));
  }

  void _cyclePlayMode() {
    setState(() {
      _playMode = switch (_playMode) {
        PlayMode.repeatAll => PlayMode.repeatOne,
        PlayMode.repeatOne => PlayMode.shuffle,
        PlayMode.shuffle => PlayMode.repeatAll,
      };
    });
  }

  // ---- misc helpers ----

  void _toast(String msg) {
    sonicDiag('toast: $msg');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          width: 420,
        ),
      );
  }

  Future<bool?> _confirm(String title, String body, String action) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _theme.copyWith(glowIntensity: _glow);
    final micMuted = _active is MicAnalyzer && (_active as MicAnalyzer).muted;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      // Official right-hand drawer — the whole control panel lives here.
      // Width clamps to the screen so phones keep an edge to grab/close.
      endDrawer: Drawer(
        width: math.min(344.0, MediaQuery.sizeOf(context).width - 40),
        backgroundColor: _theme.background.withValues(alpha: 0.97),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
        ),
        child: SafeArea(
          child: _SettingsPanel(
            theme: t,
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
            source: _source,
            onSource: _activate,
            onPickTheme: (th) => setState(() => _theme = th),
            adaptive: _adaptive,
            onAdaptive: (v) => setState(() => _adaptive = v),
            glow: _glow,
            onGlow: (v) => setState(() => _glow = v),
            amplitude: _amplitude,
            onAmplitude: (v) => setState(() => _amplitude = v),
            meteors: _meteors,
            onMeteors: (v) => setState(() => _meteors = v),
            ripples: _ripples,
            onRipples: (v) => setState(() => _ripples = v),
            blocks: _blocks,
            onBlocks: (v) => setState(() => _blocks = v),
            autoRotate: _autoRotate,
            onAutoRotate: (v) => setState(() => _autoRotate = v),
            pillarWidth: _pillarWidth,
            onPillarWidth: (v) => setState(() => _pillarWidth = v),
            spacing: _spacing,
            onSpacing: (v) => setState(() => _spacing = v),
            eqCurve: _eqCurve,
            onEq: (band, v) => setState(() {
              _eqCurve = List<int>.from(_eqCurve)
                ..[band * 2] = v.round()
                ..[band * 2 + 1] = v.round();
            }),
            onEqReset: () =>
                setState(() => _eqCurve = List<int>.from(GroundEq.defaultCurve)),
            tuning: _tuning,
            onTuning: (t2) {
              final rotationChanged =
                  t2.themeRotation != _tuning.themeRotation ||
                      t2.themeRotationSec != _tuning.themeRotationSec;
              setState(() {
                if (t2.density != _tuning.density) {
                  // Reference: spacing = 168/gridSize, fill ratio 0.857.
                  _spacing = 168.0 / t2.gridN;
                  _pillarWidth = _spacing * 0.857;
                }
                _tuning = t2;
              });
              if (rotationChanged) _syncThemeRotation();
              _applyTriggers();
            },
            analyzer: _active,
            metrics: _metrics,
          ),
        ),
      ),
      body: RepaintBoundary(
        key: _dbgBoundaryKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SonicTopography(
              controller: _shader,
              theme: t,
              audioAnalyzer: _active,
              adaptiveQuality: kSonicFullres ? false : _adaptive,
              // Start full-res like the reference (three.js has no dynamic
              // resolution); adaptive quality can still step down under load.
              renderScale: 1.0,
              rotationSpeed: _tuning.rotationSpeed,
              pillarWidth: _pillarWidth,
              spacing: _spacing,
              amplitude: _amplitude,
              enableMeteors: _meteors,
              enableRipples: _ripples,
              enableBlocks: _blocks,
              autoRotate: _autoRotate,
              gridSize: _gridN,
              blockIntensity: _tuning.blockIntensity,
              blockMinSize: _tuning.blockMin,
              blockMaxSize: _tuning.blockMax,
              blockSpeed: _tuning.blockSpeed,
              blockCount: _tuning.blockCount,
              groundEq: GroundEq(_eqCurve),
              background: t.background,
              onMetrics: (m) {
                final oldFps = _metrics.fps.round();
                if (m.fps.round() != oldFps ||
                    (m.renderScale - _metrics.renderScale).abs() > 0.02) {
                  setState(() => _metrics = m);
                } else {
                  _metrics = m;
                }
              },
            ),
            RepaintBoundary(
              key: _dbgOverlayKey,
              child: _Overlay(
                theme: t,
                source: _source,
                onSource: _activate,
                onOpenSettings: () =>
                    _scaffoldKey.currentState?.openEndDrawer(),
                bands: _active?.read() ?? AudioBands.idle,
                micMuted: micMuted,
                // player bits
                hasTrack: _playerReady,
                trackTitle: _trackIndex >= 0 && _trackIndex < _playlist.length
                    ? _playlist[_trackIndex].title
                    : null,
                lyrics: _trackIndex >= 0 && _trackIndex < _playlist.length
                    ? _playlist[_trackIndex].lyrics
                    : null,
                showLyrics: _showLyrics,
                onToggleLyrics: () =>
                    setState(() => _showLyrics = !_showLyrics),
                position: _position,
                duration: _duration,
                playing: _playerReady && _player.isPlaying,
                onPlayPause: _togglePlay,
                onPrev: _prev,
                onNext: _next,
                volume: _volume,
                onVolume: (v) {
                  setState(() => _volume = v);
                  _player.setVolume(v);
                },
                playMode: _playMode,
                onCyclePlayMode: _cyclePlayMode,
                onSeek: (ms) => _player.seekTo(Duration(milliseconds: ms)),
                onAddFiles: _addMoreFiles,
                playlist: [for (final t in _playlist) t.title],
                trackIndex: _trackIndex,
                onPlayTrack: _playIndex,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════ Overlay ══════════════════════════════

class _Overlay extends StatefulWidget {
  const _Overlay({
    required this.theme,
    required this.source,
    required this.onSource,
    required this.onOpenSettings,
    required this.bands,
    required this.micMuted,
    required this.hasTrack,
    required this.trackTitle,
    required this.lyrics,
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onPrev,
    required this.onNext,
    required this.volume,
    required this.onVolume,
    required this.playMode,
    required this.onCyclePlayMode,
    required this.onSeek,
    required this.onAddFiles,
    required this.playlist,
    required this.trackIndex,
    required this.onPlayTrack,
  });

  final SonicTheme theme;
  final AudioSourceMode source;
  final ValueChanged<AudioSourceMode> onSource;

  /// Opens the right-hand settings drawer (Scaffold.endDrawer).
  final VoidCallback onOpenSettings;
  final AudioBands bands;
  final bool micMuted;

  // Player.
  final bool hasTrack;
  final String? trackTitle;
  final Lyrics? lyrics;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;
  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final double volume;
  final ValueChanged<double> onVolume;
  final PlayMode playMode;
  final VoidCallback onCyclePlayMode;
  final ValueChanged<int> onSeek;
  final VoidCallback onAddFiles;
  final List<String> playlist;
  final int trackIndex;
  final ValueChanged<int> onPlayTrack;

  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay> {
  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TopBar(
              theme: t,
              onOpenSettings: widget.onOpenSettings,
            ),
            if (widget.micMuted) ...[
              const SizedBox(height: 8),
              _MuteBanner(theme: t),
            ],
            const Spacer(),
            if (widget.source == AudioSourceMode.player && widget.hasTrack)
              _LyricsView(
                theme: t,
                lyrics: widget.lyrics,
                visible: widget.showLyrics,
                position: widget.position,
              ),
            const SizedBox(height: 8),
            _BandMeters(theme: t, bands: widget.bands),
            const SizedBox(height: 10),
            if (widget.source == AudioSourceMode.player)
              _PlayerBar(
                theme: t,
                title: widget.trackTitle,
                position: widget.position,
                duration: widget.duration,
                playing: widget.playing,
                onPlayPause: widget.onPlayPause,
                onPrev: widget.onPrev,
                onNext: widget.onNext,
                volume: widget.volume,
                onVolume: widget.onVolume,
                playMode: widget.playMode,
                onCyclePlayMode: widget.onCyclePlayMode,
                onSeek: widget.onSeek,
                onAddFiles: widget.onAddFiles,
                showLyrics: widget.showLyrics,
                onToggleLyrics: widget.onToggleLyrics,
                playlist: widget.playlist,
                trackIndex: widget.trackIndex,
                onPlayTrack: widget.onPlayTrack,
              ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════ Top bar ══════════════════════════════

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.theme,
    required this.onOpenSettings,
  });

  final SonicTheme theme;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // Single row at every size — the audio-source picker lives in the drawer.
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final logo = _Glass(
      color: theme.background,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.ripple,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: theme.ripple.withValues(alpha: 0.9),
                  blurRadius: 10,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'SONIC',
            style: TextStyle(
              color: theme.ripple,
              fontWeight: FontWeight.w800,
              letterSpacing: 5,
              fontSize: 14,
            ),
          ),
          if (!narrow) ...[
            const SizedBox(width: 6),
            Text(
              'TOPOGRAPHY',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontWeight: FontWeight.w200,
                letterSpacing: 5,
                fontSize: 14,
              ),
            ),
          ],
        ],
      ),
    );

    final settingsPill = _Glass(
      color: theme.background,
      onTap: onOpenSettings,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _swatch(theme.coolCore),
          const SizedBox(width: 3),
          _swatch(theme.warmCore),
          const SizedBox(width: 3),
          _swatch(theme.ripple),
          // Theme name only when there is room for it.
          if (!narrow) ...[
            const SizedBox(width: 8),
            Text(
              theme.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Icon(
            Icons.tune_rounded,
            size: 15,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ],
      ),
    );

    // spaceBetween (not Spacer): a Flexible logo slot shares free space with
    // a Spacer by flex factor, and its unused share strands the trailing pill
    // mid-row on wide windows. spaceBetween always pins first-child-start /
    // last-child-end; the Flexible still lets the logo shrink on tiny widths.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: logo)),
        FittedBox(fit: BoxFit.scaleDown, child: settingsPill),
      ],
    );
  }

  Widget _swatch(Color c) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: c.withValues(alpha: 0.7), blurRadius: 6)],
    ),
  );
}

class _MuteBanner extends StatelessWidget {
  const _MuteBanner({required this.theme});
  final SonicTheme theme;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      color: Colors.black,
      child: Row(
        children: [
          Icon(
            Icons.mic_off_rounded,
            size: 15,
            color: Colors.amber.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Microphone is silent — grant access in System Settings › Privacy '
              '& Security › Microphone (denied input returns silence on macOS/iOS).',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.items,
    required this.current,
    required this.accent,
    required this.onPick,
  });

  final List<(AudioSourceMode, String)> items;
  final AudioSourceMode current;
  final Color accent;
  final ValueChanged<AudioSourceMode> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (mode, label) in items)
            GestureDetector(
              onTap: () => onPick(mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                // Roomier pills on phone layouts — finger-friendly targets
                // (~40px tall) instead of the compact desktop size.
                padding: EdgeInsets.symmetric(
                  horizontal: MediaQuery.sizeOf(context).width < 700 ? 18 : 14,
                  vertical: MediaQuery.sizeOf(context).width < 700 ? 11 : 7,
                ),
                decoration: BoxDecoration(
                  color: current == mode
                      ? accent.withValues(alpha: 0.22)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: current == mode
                        ? accent
                        : Colors.white.withValues(alpha: 0.55),
                    fontSize: MediaQuery.sizeOf(context).width < 700 ? 12 : 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════ Lyrics ══════════════════════════════

class _LyricsView extends StatelessWidget {
  const _LyricsView({
    required this.theme,
    required this.lyrics,
    required this.visible,
    required this.position,
  });

  final SonicTheme theme;
  final Lyrics? lyrics;
  final bool visible;
  final Duration position;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final l = lyrics;
    if (l == null || !l.hasLyrics) {
      return const SizedBox(height: 60);
    }
    final idx = l.activeIndexAt(position);
    String now = '', next = '';
    if (idx >= 0 && idx < l.lines.length) now = l.lines[idx].text;
    if (idx + 1 < l.lines.length) next = l.lines[idx + 1].text;
    return SizedBox(
      height: 60,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: Text(
              now,
              key: ValueKey(now),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.95),
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                shadows: [
                  Shadow(
                    color: theme.ripple.withValues(alpha: 0.5),
                    blurRadius: 18,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            next,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════ Player bar ══════════════════════════════

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.theme,
    required this.title,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onPrev,
    required this.onNext,
    required this.volume,
    required this.onVolume,
    required this.playMode,
    required this.onCyclePlayMode,
    required this.onSeek,
    required this.onAddFiles,
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.playlist,
    required this.trackIndex,
    required this.onPlayTrack,
  });

  final SonicTheme theme;
  final String? title;
  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final double volume;
  final ValueChanged<double> onVolume;
  final PlayMode playMode;
  final VoidCallback onCyclePlayMode;
  final ValueChanged<int> onSeek;
  final VoidCallback onAddFiles;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;
  final List<String> playlist;
  final int trackIndex;
  final ValueChanged<int> onPlayTrack;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);
    return _Glass(
      color: theme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.music_note_rounded,
                size: 14,
                color: theme.ripple.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title ?? 'No track',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _IconBtn(
                icon: Icons.playlist_add_rounded,
                tip: 'Add files',
                onTap: onAddFiles,
              ),
              const SizedBox(width: 2),
              _IconBtn(
                icon: showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
                tip: 'Lyrics',
                active: showLyrics,
                onTap: onToggleLyrics,
              ),
              const SizedBox(width: 2),
              _IconBtn(
                icon: switch (playMode) {
                  PlayMode.repeatAll => Icons.repeat_rounded,
                  PlayMode.repeatOne => Icons.repeat_one_rounded,
                  PlayMode.shuffle => Icons.shuffle_rounded,
                },
                tip: switch (playMode) {
                  PlayMode.repeatAll => 'Repeat all',
                  PlayMode.repeatOne => 'Repeat one',
                  PlayMode.shuffle => 'Shuffle',
                },
                onTap: onCyclePlayMode,
              ),
              const SizedBox(width: 2),
              _IconBtn(
                icon: Icons.queue_music_rounded,
                tip: 'Playlist',
                onTap: () => _openPlaylist(context),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                _fmt(position),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 10,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: theme.ripple,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: totalMs > 0 ? posMs / totalMs : 0,
                    onChanged: totalMs > 0
                        ? (v) => onSeek((v * totalMs).round())
                        : null,
                  ),
                ),
              ),
              Text(
                _fmt(duration),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 10,
                ),
              ),
            ],
          ),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: Row(
                  children: [
                    Icon(
                      Icons.volume_down_rounded,
                      size: 14,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          activeTrackColor: Colors.white.withValues(alpha: 0.5),
                          inactiveTrackColor: Colors.white.withValues(
                            alpha: 0.12,
                          ),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(value: volume, onChanged: onVolume),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _CircleBtn(icon: Icons.skip_previous_rounded, onTap: onPrev),
              const SizedBox(width: 10),
              _CircleBtn(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                primary: true,
                onTap: onPlayPause,
                accent: theme.ripple,
              ),
              const SizedBox(width: 10),
              _CircleBtn(icon: Icons.skip_next_rounded, onTap: onNext),
            ],
          ),
        ],
      ),
    );
  }

  void _openPlaylist(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.25,
        maxChildSize: 0.85,
        builder: (ctx, scroll) => Container(
          decoration: BoxDecoration(
            color: theme.background.withValues(alpha: 0.97),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
            itemCount: playlist.length,
            itemBuilder: (ctx, i) => ListTile(
              dense: true,
              selected: i == trackIndex,
              selectedColor: theme.ripple,
              leading: Icon(
                i == trackIndex
                    ? Icons.graphic_eq_rounded
                    : Icons.music_note_outlined,
                size: 16,
                color: i == trackIndex
                    ? theme.ripple
                    : Colors.white.withValues(alpha: 0.35),
              ),
              title: Text(
                playlist[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              onTap: () {
                onPlayTrack(i);
                Navigator.of(ctx).pop();
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tip,
    required this.onTap,
    this.active,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool? active;

  @override
  Widget build(BuildContext context) {
    final on = active ?? false;
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: onTap,
        child: Icon(
          icon,
          size: 17,
          color: on
              ? Theme.of(context).colorScheme.primary
              : Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.accent,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent ?? const Color(0xFF33E6FF);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: primary ? 40 : 32,
        height: primary ? 40 : 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary
              ? c.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.08),
          boxShadow: primary
              ? [BoxShadow(color: c.withValues(alpha: 0.45), blurRadius: 16)]
              : null,
        ),
        child: Icon(
          icon,
          size: primary ? 24 : 19,
          color: primary ? Colors.black.withValues(alpha: 0.85) : Colors.white,
        ),
      ),
    );
  }
}

// ══════════════════════════════ Band meters ══════════════════════════════

class _BandMeters extends StatelessWidget {
  const _BandMeters({required this.theme, required this.bands});
  final SonicTheme theme;
  final AudioBands bands;

  static const _labels = [
    'SUB',
    'BASS',
    'LMID',
    'MID',
    'HMID',
    'PRES',
    'BRIL',
    'AIR',
  ];
  List<double> get _vals => [
    bands.subBass,
    bands.bass,
    bands.lowMid,
    bands.mid,
    bands.highMid,
    bands.presence,
    bands.brilliance,
    bands.air,
  ];

  @override
  Widget build(BuildContext context) {
    final vals = _vals;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < vals.length; i++) ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    curve: Curves.easeOut,
                    height: (4 + vals[i].clamp(0.0, 1.0) * 26),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          theme.coolCore.withValues(alpha: 0.85),
                          Color.lerp(
                            theme.coolCore,
                            theme.warmCore,
                            i / (vals.length - 1),
                          )!,
                          theme.ripple,
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 8,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
            if (i < vals.length - 1) const SizedBox(width: 5),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════ Settings panel ══════════════════════════════

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.theme,
    required this.onClose,
    required this.source,
    required this.onSource,
    required this.onPickTheme,
    required this.adaptive,
    required this.onAdaptive,
    required this.glow,
    required this.onGlow,
    required this.amplitude,
    required this.onAmplitude,
    required this.meteors,
    required this.onMeteors,
    required this.ripples,
    required this.onRipples,
    required this.blocks,
    required this.onBlocks,
    required this.autoRotate,
    required this.onAutoRotate,
    required this.pillarWidth,
    required this.onPillarWidth,
    required this.spacing,
    required this.onSpacing,
    required this.eqCurve,
    required this.onEq,
    required this.onEqReset,
    required this.tuning,
    required this.onTuning,
    required this.analyzer,
    required this.metrics,
  });

  final SonicTheme theme;
  final VoidCallback onClose;
  final AudioSourceMode source;
  final ValueChanged<AudioSourceMode> onSource;
  final ValueChanged<SonicTheme> onPickTheme;
  final bool adaptive;
  final ValueChanged<bool> onAdaptive;
  final double glow;
  final ValueChanged<double> onGlow;
  final double amplitude;
  final ValueChanged<double> onAmplitude;
  final bool meteors;
  final ValueChanged<bool> onMeteors;
  final bool ripples;
  final ValueChanged<bool> onRipples;
  final bool blocks;
  final ValueChanged<bool> onBlocks;
  final bool autoRotate;
  final ValueChanged<bool> onAutoRotate;
  final double pillarWidth;
  final ValueChanged<double> onPillarWidth;
  final double spacing;
  final ValueChanged<double> onSpacing;
  final List<int> eqCurve;
  final void Function(int index, double value) onEq;
  final VoidCallback onEqReset;
  final PanelTuning tuning;
  final ValueChanged<PanelTuning> onTuning;
  final AudioAnalyzer? analyzer;
  final QualityMetrics metrics;

  void _openEqSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.background.withValues(alpha: 0.97),
      isScrollControlled: true,
      builder: (ctx) => _GroundEqSheet(
        curve: List<int>.from(eqCurve),
        accent: theme.coolCore,
        onChange: onEq,
        onReset: onEqReset,
      ),
    );
  }

  /// How many of the 8 reference bands differ from their default gain.
  static int _changedBands(List<int> curve) {
    final d = GroundEq.defaultCurve;
    var n = 0;
    for (int b = 0; b < 8; b++) {
      if (curve[b * 2] != d[b * 2]) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final tr = _triggersOf(analyzer);
    // The Drawer is the surface — content column with a header + scroll.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'VISUALIZER',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  '${metrics.fps.round()} fps · ${(metrics.renderScale * 100).round()}%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.ripple.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onClose,
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PanelSection(
                    title: 'AUDIO SOURCE',
                    hint: 'DEMO synth · MUSIC files · MIC input',
                    theme: theme,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Center(
                          child: _Segmented(
                            items: const [
                              (AudioSourceMode.demo, 'DEMO'),
                              (AudioSourceMode.player, 'MUSIC'),
                              (AudioSourceMode.mic, 'MIC'),
                            ],
                            current: source,
                            accent: theme.ripple,
                            onPick: onSource,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _PanelSection(
                    title: 'THEMES',
                    hint: '${SonicTheme.builtIn.length} presets — '
                        'tap to apply',
                    theme: theme,
                    children: [
                      _ThemeGrid(current: theme, onPick: onPickTheme),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      _Toggle(
                        label: 'Auto-rotate',
                        value: autoRotate,
                        onChanged: onAutoRotate,
                        accent: theme.ripple,
                      ),
                      _Toggle(
                        label: 'Ripples',
                        value: ripples,
                        onChanged: onRipples,
                        accent: theme.ripple,
                      ),
                      _Toggle(
                        label: 'Meteors',
                        value: meteors,
                        onChanged: onMeteors,
                        accent: theme.warmCore,
                      ),
                      _Toggle(
                        label: 'Floating blocks',
                        value: blocks,
                        onChanged: onBlocks,
                        accent: theme.warmEdge,
                      ),
                      _Toggle(
                        label: 'Adaptive 120fps',
                        value: adaptive,
                        onChanged: onAdaptive,
                        accent: theme.coolCore,
                      ),
                    ],
                  ),
                  const Divider(height: 22, color: Color(0x14FFFFFF)),
                  _Slider(
                    label: 'Glow',
                    value: glow,
                    min: 0.4,
                    max: 2.2,
                    accent: theme.warmEdge,
                    onChanged: onGlow,
                  ),
                  _Slider(
                    label: 'Amplitude',
                    value: amplitude,
                    min: 0.2,
                    max: 2.0,
                    accent: theme.ripple,
                    onChanged: onAmplitude,
                  ),
                  _Slider(
                    label: 'Pillar width',
                    value: pillarWidth,
                    min: 0.2,
                    max: 1.0,
                    accent: theme.coolCore,
                    onChanged: onPillarWidth,
                  ),
                  _Slider(
                    label: 'Spacing',
                    value: spacing.clamp(pillarWidth, 2.0),
                    min: pillarWidth,
                    max: 2.0,
                    accent: theme.coolEdge,
                    onChanged: onSpacing,
                  ),
                  _Slider(
                    label: 'Rotation speed',
                    value: tuning.rotationSpeed,
                    min: 0,
                    max: 2,
                    accent: theme.ripple,
                    onChanged: (v) =>
                        onTuning(tuning.copyWith(rotationSpeed: v)),
                  ),
                  _Slider(
                    label: 'Density',
                    value: tuning.density,
                    min: 0,
                    max: 100,
                    accent: theme.coolCore,
                    format: (v) =>
                        '${(96 + 128 * v / 100).round().clamp(96, 224)}²',
                    onChanged: (v) =>
                        onTuning(tuning.copyWith(density: v)),
                  ),
                  const Divider(height: 22, color: Color(0x14FFFFFF)),
                  _PanelSection(
                    title: 'FLOATING BLOCKS',
                    hint: 'Crystals swell with the kick — reference ground-EQ '
                        'scales (0–100)',
                    theme: theme,
                    children: [
                      _Slider(
                        label: 'Intensity',
                        value: tuning.blockIntensity,
                        min: 0,
                        max: 100,
                        accent: theme.warmEdge,
                        onChanged: (v) =>
                            onTuning(tuning.copyWith(blockIntensity: v)),
                      ),
                      _Slider(
                        label: 'Min size',
                        value: tuning.blockMin.clamp(0, tuning.blockMax),
                        min: 0,
                        max: tuning.blockMax,
                        accent: theme.coolEdge,
                        onChanged: (v) => onTuning(tuning.copyWith(
                          blockMin: v.clamp(0, tuning.blockMax),
                        )),
                      ),
                      _Slider(
                        label: 'Max size',
                        value: tuning.blockMax.clamp(tuning.blockMin, 100),
                        min: tuning.blockMin,
                        max: 100,
                        accent: theme.warmCore,
                        onChanged: (v) => onTuning(tuning.copyWith(
                          blockMax: v.clamp(tuning.blockMin, 100),
                        )),
                      ),
                      _Slider(
                        label: 'Speed',
                        value: tuning.blockSpeed,
                        min: 0,
                        max: 100,
                        accent: theme.coolCore,
                        onChanged: (v) =>
                            onTuning(tuning.copyWith(blockSpeed: v)),
                      ),
                      _Slider(
                        label: 'Count',
                        value: tuning.blockCount.toDouble(),
                        min: 4,
                        max: 32,
                        accent: theme.ripple,
                        onChanged: (v) => onTuning(
                            tuning.copyWith(blockCount: v.round())),
                      ),
                    ],
                  ),
                  const Divider(height: 22, color: Color(0x14FFFFFF)),
                  _buildTriggerSection(
                    title: 'PULSE EFFECT',
                    hint: 'Spectral-flux trigger — kicks ripple the terrain. '
                        'Auto-track locks onto the strongest transient.',
                    cfg: tuning.pulse,
                    live: tr?.pulse,
                    spectrum: tr?.liveSpectrum,
                    update: (t) => onTuning(tuning.copyWith(pulse: t)),
                  ),
                  const Divider(height: 22, color: Color(0x14FFFFFF)),
                  _buildTriggerSection(
                    title: 'METEOR EFFECT',
                    hint: 'High-band flux trigger — treble transients throw '
                        'meteors (default band ≈ 6.8–7.5 kHz).',
                    cfg: tuning.meteor,
                    live: tr?.meteor,
                    spectrum: tr?.liveSpectrum,
                    update: (t) => onTuning(tuning.copyWith(meteor: t)),
                  ),
                  const Divider(height: 22, color: Color(0x14FFFFFF)),
                  _PanelSection(
                    title: 'THEME ROTATION',
                    hint: 'Auto-cycle the palette — reference rotation is off '
                        'by default',
                    theme: theme,
                    children: [
                      _Toggle(
                        label: 'Rotate themes',
                        value: tuning.themeRotation,
                        onChanged: (v) =>
                            onTuning(tuning.copyWith(themeRotation: v)),
                        accent: theme.ripple,
                      ),
                      if (tuning.themeRotation)
                        _Slider(
                          label: 'Interval',
                          value: tuning.themeRotationSec.toDouble(),
                          min: 3,
                          max: 120,
                          accent: theme.ripple,
                          format: (v) => '${v.round()} s',
                          onChanged: (v) => onTuning(
                              tuning.copyWith(themeRotationSec: v.round())),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          'Ground EQ',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _openEqSheet(context),
                          icon: Icon(
                            Icons.equalizer_rounded,
                            size: 15,
                            color: theme.coolCore,
                          ),
                          label: Text(
                            '${_changedBands(eqCurve)} bands',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
  }

  /// One trigger's controls (reference FreqTriggerPanel): enable, mode,
  /// auto-beat sliders or the advanced crosshair. [live] is the active
  /// analyzer's runtime config — auto-track may have retuned the band since
  /// the panel last wrote it, and the reference updates its UI the same way.
  Widget _buildTriggerSection({
    required String title,
    required String hint,
    required TriggerTuning cfg,
    required FreqTriggerConfig? live,
    required Float64List? spectrum,
    required ValueChanged<TriggerTuning> update,
  }) {
    final bandStart = (live?.bandStart ?? cfg.bandStart).clamp(0, 250);
    final bandEnd = (live?.bandEnd ?? cfg.bandEnd).clamp(2, 256);
    final sens = live?.sensitivity ?? cfg.sensitivity;
    return _PanelSection(
      title: title,
      hint: hint,
      theme: theme,
      children: [
        _Toggle(
          label: 'Enable',
          value: cfg.enabled,
          onChanged: (v) => update(cfg.copyWith(enabled: v)),
          accent: theme.ripple,
        ),
        const SizedBox(height: 6),
        _ModeChips(
          advanced: cfg.advanced,
          accent: theme.coolCore,
          onPick: (adv) => update(cfg.copyWith(advanced: adv)),
        ),
        if (cfg.advanced) ...[
          const SizedBox(height: 8),
          _SpectrumCrosshair(
            spectrum: spectrum,
            freqIndex: cfg.freqIndex < 0 ? 102 : cfg.freqIndex,
            threshold: cfg.threshold,
            accent: theme.ripple,
            onChanged: (i, th) =>
                update(cfg.copyWith(freqIndex: i, threshold: th)),
          ),
        ] else ...[
          _Slider(
            label: 'Sensitivity',
            value: sens.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            accent: theme.coolCore,
            onChanged: (v) =>
                update(cfg.copyWith(sensitivity: (v * 20).round() / 20)),
          ),
          _Slider(
            label: 'Cooldown',
            value: cfg.cooldownFrames.toDouble(),
            min: 0,
            max: 300,
            accent: theme.warmEdge,
            format: (v) => '${v.round()} f',
            onChanged: (v) => update(cfg.copyWith(cooldownFrames: v.round())),
          ),
          _BandRange(
            start: bandStart.clamp(0, bandEnd - 2),
            end: bandEnd,
            accent: theme.ripple,
            onChanged: (s, e) => update(cfg.copyWith(bandStart: s, bandEnd: e)),
          ),
          _Slider(
            label: 'Strength',
            value: cfg.strength,
            min: 0,
            max: 5,
            accent: theme.warmCore,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) =>
                update(cfg.copyWith(strength: (v * 10).round() / 10)),
          ),
        ],
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.accent,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: value
              ? accent.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: value
                ? accent.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? accent : Colors.white.withValues(alpha: 0.25),
                boxShadow: value
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.7),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: value
                    ? Colors.white.withValues(alpha: 0.95)
                    : Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.accent,
    required this.onChanged,
    this.format,
  });
  final String label;
  final double value, min, max;
  final Color accent;
  final ValueChanged<double> onChanged;

  /// Value readout override (e.g. "10 s", "4.0 s" instead of raw double).
  final String Function(double value)? format;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: accent,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            format != null ? format!(value.clamp(min, max)) : value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
        ),
      ],
    );
  }
}

/// The active analyzer's frequency triggers, if it has any (mic/player only).
FreqTriggers? _triggersOf(AudioAnalyzer? a) => switch (a) {
      MicAnalyzer m => m.triggers,
      PlayerAnalyzer p => p.triggers,
      _ => null,
    };

/// Auto Beat ↔ Advanced mode switch (reference trigger mode segmented).
class _ModeChips extends StatelessWidget {
  const _ModeChips({
    required this.advanced,
    required this.accent,
    required this.onPick,
  });

  final bool advanced;
  final Color accent;
  final ValueChanged<bool> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (isAdv, label) in const [(false, 'Auto Beat'), (true, 'Advanced')])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onPick(isAdv),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: advanced == isAdv
                      ? accent.withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: advanced == isAdv
                        ? accent.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: advanced == isAdv
                        ? Colors.white.withValues(alpha: 0.95)
                        : Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dual-thumb FFT band selector (reference trigger band range slider).
class _BandRange extends StatelessWidget {
  const _BandRange({
    required this.start,
    required this.end,
    required this.accent,
    required this.onChanged,
  });

  final int start, end;
  final Color accent;
  final void Function(int start, int end) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            'Band',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              rangeThumbShape:
                  const RoundRangeSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: accent,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
              thumbColor: Colors.white,
            ),
            child: RangeSlider(
              values: RangeValues(start.toDouble(), end.toDouble()),
              min: 0,
              max: 256,
              divisions: 256,
              onChanged: (r) {
                final s = r.start.round().clamp(0, r.end.round() - 2);
                final e = r.end.round().clamp(s + 2, 256);
                onChanged(s, e);
              },
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$start-$end',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
        ),
      ],
    );
  }
}

/// Advanced-mode crosshair: live dB spectrum with a draggable point —
/// x = frequency bin, y = trigger threshold (reference FreqCrosshair).
class _SpectrumCrosshair extends StatefulWidget {
  const _SpectrumCrosshair({
    required this.spectrum,
    required this.freqIndex,
    required this.threshold,
    required this.accent,
    required this.onChanged,
  });

  final Float64List? spectrum;
  final int freqIndex;
  final double threshold;
  final Color accent;
  final void Function(int freqIndex, double threshold) onChanged;

  @override
  State<_SpectrumCrosshair> createState() => _SpectrumCrosshairState();
}

class _SpectrumCrosshairState extends State<_SpectrumCrosshair>
    with SingleTickerProviderStateMixin {
  late final AnimationController _repaint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  )..repeat();

  @override
  void dispose() {
    _repaint.dispose();
    super.dispose();
  }

  void _update(Offset p, Size s) {
    if (s.width <= 0 || s.height <= 0) return;
    final bin = (p.dx / s.width * 511).round().clamp(0, 511);
    final th = (1.0 - p.dy / s.height).clamp(0.02, 1.0);
    widget.onChanged(bin, (th * 100).round() / 100);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 96,
            width: double.infinity,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) =>
                  _update(d.localPosition, context.size ?? Size.zero),
              onPanUpdate: (d) =>
                  _update(d.localPosition, context.size ?? Size.zero),
              child: AnimatedBuilder(
                animation: _repaint,
                builder: (context, child) => CustomPaint(
                  painter: _SpectrumPainter(
                    spectrum: widget.spectrum,
                    freqIndex: widget.freqIndex,
                    threshold: widget.threshold,
                    accent: widget.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'bin ${widget.freqIndex} (${(widget.freqIndex * 43)} Hz) · '
          'thresh ${widget.threshold.toStringAsFixed(2)} — drag to aim',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.38),
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter({
    required this.spectrum,
    required this.freqIndex,
    required this.threshold,
    required this.accent,
  });

  final Float64List? spectrum;
  final int freqIndex;
  final double threshold;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bg,
    );

    final spec = spectrum;
    if (spec == null || spec.isEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'live spectrum: mic / player input only',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 16);
      tp.paint(canvas, Offset(8, size.height / 2 - tp.height / 2));
      return;
    }

    // Spectrum bars (dB scale 0..1 per bin).
    final bars = Paint()..color = Colors.white.withValues(alpha: 0.30);
    final n = spec.length;
    final bw = size.width / n;
    for (int i = 0; i < n; i++) {
      final h = spec[i].clamp(0.0, 1.0) * size.height;
      if (h < 0.5) continue;
      canvas.drawRect(Rect.fromLTWH(i * bw, size.height - h, bw + 0.5, h), bars);
    }

    // Threshold line.
    final ty = (1.0 - threshold) * size.height;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, ty), Offset(size.width, ty), line);

    // Crosshair: vertical bin line + knob.
    final cx = freqIndex / 511.0 * size.width;
    final cross = Paint()
      ..color = accent
      ..strokeWidth = 1.4;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), cross);
    canvas.drawCircle(Offset(cx, ty), 4.5, Paint()..color = accent);
    canvas.drawCircle(
      Offset(cx, ty),
      4.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => true;
}

/// Titled group inside the settings panel (mirrors the reference's tab
/// sections like "Floating Blocks Effect" with a hint line).
class _PanelSection extends StatelessWidget {  const _PanelSection({
    required this.title,
    required this.hint,
    required this.theme,
    required this.children,
  });

  final String title;
  final String hint;
  final SonicTheme theme;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.ripple.withValues(alpha: 0.9),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.5,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          hint,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    );
  }
}

/// Frosted glass pill / panel.
class _Glass extends StatelessWidget {
  const _Glass({required this.color, required this.child, this.onTap});
  final Color color;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final inner = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
    if (onTap == null) return inner;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: inner,
    );
  }
}

// ══════════════════════════════ Sheets ══════════════════════════════

/// Theme picker grid (drawer THEMES section) — the built-in presets
/// with color dots, current one highlighted.
class _ThemeGrid extends StatelessWidget {
  const _ThemeGrid({required this.current, required this.onPick});
  final SonicTheme current;
  final ValueChanged<SonicTheme> onPick;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 3.4,
      children: [
        for (final t in SonicTheme.builtIn)
          GestureDetector(
            onTap: () => onPick(t),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: t.background.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: t.id == current.id
                      ? t.ripple
                      : Colors.white.withValues(alpha: 0.08),
                  width: t.id == current.id ? 1.6 : 1,
                ),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _dot(t.coolCore),
                      const SizedBox(height: 3),
                      _dot(t.warmCore),
                      const SizedBox(height: 3),
                      _dot(t.ripple),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _dot(Color c) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: c.withValues(alpha: 0.8), blurRadius: 4)],
    ),
  );
}


/// 16-band ground-EQ equalizer sheet.
class _GroundEqSheet extends StatefulWidget {
  const _GroundEqSheet({
    required this.curve,
    required this.accent,
    required this.onChange,
    required this.onReset,
  });

  final List<int> curve;
  final Color accent;
  final void Function(int index, double value) onChange;
  final VoidCallback onReset;

  @override
  State<_GroundEqSheet> createState() => _GroundEqSheetState();
}

class _GroundEqSheetState extends State<_GroundEqSheet> {
  // The reference's 8 ground-EQ bands (SubBass..Air) with their marker colors.
  static const _bands = [
    ('Sub Bass', Color(0xFF6EE7FF)),
    ('Bass', Color(0xFF5EEAD4)),
    ('Low Mid', Color(0xFFA7F3D0)),
    ('Mid', Color(0xFFFDE68A)),
    ('High Mid', Color(0xFFFBBF24)),
    ('Presence', Color(0xFFFB7185)),
    ('Brilliance', Color(0xFFC084FC)),
    ('Air', Color(0xFF93C5FD)),
  ];

  // Band i drives curve points [2i, 2i+1] — the positions our sampler reads
  // for that band's normalized frequency slot.
  int _bandValue(int band) => widget.curve[band * 2];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text(
                  'GROUND EQ',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    widget.onReset();
                    setState(() {});
                  },
                  child: const Text(
                    'Reset',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Boost or attenuate how strongly each frequency band lifts the terrain',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < _bands.length; i++)
                    Expanded(
                      child: _EqBandSlider(
                        index: i,
                        value: _bandValue(i).toDouble(),
                        label: _bands[i].$1,
                        accent: _bands[i].$2,
                        onChanged: (v) {
                          widget.onChange(i, v);
                          setState(() {});
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqBandSlider extends StatelessWidget {
  const _EqBandSlider({
    required this.index,
    required this.value,
    required this.label,
    required this.accent,
    required this.onChanged,
  });

  final int index;
  final double value;
  final String label;
  final Color accent;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '${value.round()}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 9,
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3, // counter-clockwise → bottom = 0, top = 100
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: value,
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 8,
          ),
        ),
      ],
    );
  }
}
