import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

/// Visual theme for the topography. Colors are stored as linear [Vector3]
/// (0..1) ready to upload to the shader, plus human-readable Material colors
/// used by the demo overlay UI. Mirrors the built-in themes from the reference
/// (`themes.ts`, v1.1.3+): the four originals port their exact reference
/// values; the nine newer ones are derived from the reference palettes with
/// proper sRGB→linear conversion (Three.js color management).
class SonicTheme {
  final String id;
  final String name;
  final Color background;
  final Color background2;
  final Color fog;
  final Color coolCore;
  final Color coolEdge;
  final Color warmCore;
  final Color warmEdge;
  final Color ripple;
  final double glowIntensity;
  final double rotationSpeed;
  final bool showPlayerPanel;

  /// Build a theme from Material [Color]s (used for user-defined themes). The
  /// shader colors are derived from these sRGB values.
  const SonicTheme({
    required this.id,
    required this.name,
    required this.background,
    required this.background2,
    required this.fog,
    required this.coolCore,
    required this.coolEdge,
    required this.warmCore,
    required this.warmEdge,
    required this.ripple,
    this.glowIntensity = 1.0,
    this.rotationSpeed = 0.5,
    this.showPlayerPanel = true,
  }) : _linear = const [];

  /// Colors as linear 0..1 vectors for the shader.
  /// Order: [base1, base2, coolCore, coolEdge, warmCore, warmEdge, ripple, fog].
  Vector3 get vBase1 => linear[0];
  Vector3 get vBase2 => linear[1];
  Vector3 get vCoolCore => linear[2];
  Vector3 get vCoolEdge => linear[3];
  Vector3 get vWarmCore => linear[4];
  Vector3 get vWarmEdge => linear[5];
  Vector3 get vRipple => linear[6];
  Vector3 get vFog => linear[7];

  /// The 8 linear shader colors. Built-ins use exact reference values via
  /// [SonicTheme.fromLinear]; user themes derive them from the sRGB [Color]s.
  List<Vector3> get linear => _linear.isNotEmpty
      ? _linear
      : [
          _vec(background),
          _vec(background2),
          _vec(coolCore),
          _vec(coolEdge),
          _vec(warmCore),
          _vec(warmEdge),
          _vec(ripple),
          _vec(fog),
        ];

  /// Exact reference linear shader colors (0..1), used directly so the palette
  /// matches the Three.js reference one-to-one. Material [Color]s are kept
  /// alongside for the overlay UI (best-effort sRGB approximation).
  final List<Vector3> _linear;

  /// Build a theme from exact linear shader colors (the authoritative path).
  const SonicTheme.fromLinear({
    required this.id,
    required this.name,
    required this.background,
    required this.background2,
    required this.fog,
    required this.coolCore,
    required this.coolEdge,
    required this.warmCore,
    required this.warmEdge,
    required this.ripple,
    required List<Vector3> linear,
    this.glowIntensity = 1.0,
    this.rotationSpeed = 0.5,
    this.showPlayerPanel = true,
  }) : _linear = linear; // ignore: prefer_initializing_formals

  static Vector3 _vec(Color c) {
    // The original four reference themes pass raw sRGB component values
    // straight through as GL colors (the neon look). Mirror that for
    // user-defined themes.
    final argb = c.toARGB32();
    return Vector3(
      ((argb >> 16) & 0xFF) / 255.0,
      ((argb >> 8) & 0xFF) / 255.0,
      (argb & 0xFF) / 255.0,
    );
  }

  static double _srgbToLinear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static Vector3 _lin(Color c) {
    final argb = c.toARGB32();
    return Vector3(
      _srgbToLinear(((argb >> 16) & 0xFF) / 255.0),
      _srgbToLinear(((argb >> 8) & 0xFF) / 255.0),
      _srgbToLinear((argb & 0xFF) / 255.0),
    );
  }

  static Vector3 _lerp3(Vector3 a, Vector3 b, double t) =>
      Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);

  /// Build a theme from a reference-style palette (hex colors + glow), using
  /// the reference's exact derivation:
  ///   base2 = background lerp white 0.12
  ///   coolEdge/warmEdge = core color lerp background 0.35
  /// Colors are converted sRGB→linear like Three.js color management does.
  factory SonicTheme.fromPalette({
    required String id,
    required String name,
    required Color background,
    required Color fog,
    required Color cool,
    required Color warm,
    required Color accent,
    required double glowIntensity,
  }) {
    final bg = _lin(background);
    final white = Vector3(1, 1, 1);
    final coolL = _lin(cool);
    final warmL = _lin(warm);
    return SonicTheme.fromLinear(
      id: id,
      name: name,
      background: background,
      background2: background,
      fog: fog,
      coolCore: cool,
      coolEdge: cool,
      warmCore: warm,
      warmEdge: warm,
      ripple: accent,
      glowIntensity: glowIntensity,
      linear: [
        bg,
        _lerp3(bg, white, 0.12),
        coolL,
        _lerp3(coolL, bg, 0.35),
        warmL,
        _lerp3(warmL, bg, 0.35),
        _lin(accent),
        _lin(fog),
      ],
    );
  }

  SonicTheme copyWith({
    String? name,
    Color? background,
    Color? background2,
    Color? fog,
    Color? coolCore,
    Color? coolEdge,
    Color? warmCore,
    Color? warmEdge,
    Color? ripple,
    double? glowIntensity,
    double? rotationSpeed,
    bool? showPlayerPanel,
  }) {
    // Preserve the exact reference linear colors when present (built-in themes).
    // If we returned a plain SonicTheme, the authoritative _linear list would be
    // dropped and the shader would receive sRGB-derived approximations instead,
    // which noticeably shifts the fog / edge blend away from the reference.
    final keepLinear = _linear.isNotEmpty;
    final linear = keepLinear
        ? _linear
        : [
            _vec(background ?? this.background),
            _vec(background2 ?? this.background2),
            _vec(coolCore ?? this.coolCore),
            _vec(coolEdge ?? this.coolEdge),
            _vec(warmCore ?? this.warmCore),
            _vec(warmEdge ?? this.warmEdge),
            _vec(ripple ?? this.ripple),
            _vec(fog ?? this.fog),
          ];
    return SonicTheme.fromLinear(
      id: id,
      name: name ?? this.name,
      background: background ?? this.background,
      background2: background2 ?? this.background2,
      fog: fog ?? this.fog,
      coolCore: coolCore ?? this.coolCore,
      coolEdge: coolEdge ?? this.coolEdge,
      warmCore: warmCore ?? this.warmCore,
      warmEdge: warmEdge ?? this.warmEdge,
      ripple: ripple ?? this.ripple,
      glowIntensity: glowIntensity ?? this.glowIntensity,
      rotationSpeed: rotationSpeed ?? this.rotationSpeed,
      showPlayerPanel: showPlayerPanel ?? this.showPlayerPanel,
      linear: linear,
    );
  }

  /// All built-in themes, reference order.
  static final List<SonicTheme> builtIn = [
    neonTokyo,
    inkWash,
    nocturnal,
    cyberForest,
    minimalMonochrome,
    glacierDay,
    koiPond,
    coralReef,
    mossGlass,
    blueHour,
    porcelainTeal,
    wineSignal,
    daybreakLime,
    solarFlare,
    ultraviolet,
    deepSea,
    auroraVeil,
    crimsonPulse,
  ];

  /// Ported from the reference `ink-wash` theme (raw linear values).
  static final SonicTheme inkWash = SonicTheme.fromLinear(
    id: 'ink-wash',
    name: 'Ink Wash',
    background: const Color(0xFFFFFFFF),
    background2: const Color(0xFFFFFFFF),
    fog: const Color(0xFFFFFFFF),
    coolCore: const Color(0xFF000000),
    coolEdge: const Color(0xFF595959),
    warmCore: const Color(0xFF000000),
    warmEdge: const Color(0xFF595959),
    ripple: const Color(0xFFA8BDC2),
    glowIntensity: 1.1,
    rotationSpeed: 0.5,
    linear: [
      Vector3(1.0, 1.0, 1.0),
      Vector3(1.0, 1.0, 1.0),
      Vector3(0.0, 0.0, 0.0),
      Vector3(0.35, 0.35, 0.35),
      Vector3(0.0, 0.0, 0.0),
      Vector3(0.35, 0.35, 0.35),
      Vector3(0.66, 0.74, 0.76),
      Vector3(1.0, 1.0, 1.0),
    ],
  );

  /// Ported from the reference `nocturnal` theme. Linear shader colors are the
  /// EXACT reference values (THREE.Color args); the Material [Color]s are the
  /// closest sRGB equivalents for overlay UI.
  static final SonicTheme nocturnal = SonicTheme.fromLinear(
    id: 'nocturnal',
    name: 'Nocturnal',
    background: const Color(0xFF050A14),
    background2: const Color(0xFF0C1424),
    fog: const Color(0xFF050A14),
    coolCore: const Color(0xFF004DFF),
    coolEdge: const Color(0xFF9933FF),
    warmCore: const Color(0xFFFF3300),
    warmEdge: const Color(0xFFFF9900),
    ripple: const Color(0xFF33E6FF),
    glowIntensity: 1.0,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.01, 0.02, 0.04), // base1
      Vector3(0.03, 0.05, 0.09), // base2
      Vector3(0.0, 0.3, 1.0), // coolCore
      Vector3(0.6, 0.2, 1.0), // coolEdge
      Vector3(1.0, 0.2, 0.1), // warmCore
      Vector3(1.0, 0.6, 0.0), // warmEdge
      Vector3(0.2, 0.9, 1.0), // ripple
      Vector3(0.01, 0.02, 0.04), // fog (= base1)
    ],
  );

  static final SonicTheme neonTokyo = SonicTheme.fromLinear(
    id: 'neon-tokyo',
    name: 'Neon Tokyo',
    background: const Color(0xFF03050D),
    background2: const Color(0xFF0A0A1A),
    fog: const Color(0xFF03050D),
    coolCore: const Color(0xFFFF1999),
    coolEdge: const Color(0xFF991AFF),
    warmCore: const Color(0xFF1AFFCC),
    warmEdge: const Color(0xFF1A66FF),
    ripple: const Color(0xFFFFFFFF),
    glowIntensity: 1.5,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.01, 0.005, 0.02),
      Vector3(0.04, 0.01, 0.06),
      Vector3(1.0, 0.1, 0.6),
      Vector3(0.6, 0.1, 1.0),
      Vector3(0.1, 1.0, 0.8),
      Vector3(0.1, 0.4, 1.0),
      Vector3(1.0, 1.0, 1.0),
      Vector3(0.01, 0.005, 0.02),
    ],
  );

  static final SonicTheme cyberForest = SonicTheme.fromLinear(
    id: 'cyber-forest',
    name: 'Cyber Forest',
    background: const Color(0xFF030A05),
    background2: const Color(0xFF070F0A),
    fog: const Color(0xFF030A05),
    coolCore: const Color(0xFF1AFF80),
    coolEdge: const Color(0xFF0D8050),
    warmCore: const Color(0xFFCCFF1A),
    warmEdge: const Color(0xFFE6801A),
    ripple: const Color(0xFF99FF4D),
    glowIntensity: 1.3,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.01, 0.02, 0.01),
      Vector3(0.02, 0.05, 0.02),
      Vector3(0.1, 1.0, 0.5),
      Vector3(0.05, 0.5, 0.3),
      Vector3(0.8, 1.0, 0.1),
      Vector3(0.9, 0.5, 0.1),
      Vector3(0.6, 1.0, 0.3),
      Vector3(0.01, 0.02, 0.01),
    ],
  );

  static final SonicTheme minimalMonochrome = SonicTheme.fromLinear(
    id: 'minimal-monochrome',
    name: 'Minimal Monochrome',
    background: const Color(0xFF050505),
    background2: const Color(0xFF0F0F0F),
    fog: const Color(0xFF050505),
    coolCore: const Color(0xFFE6E6E6),
    coolEdge: const Color(0xFF666666),
    warmCore: const Color(0xFFFFFFFF),
    warmEdge: const Color(0xFFB3B3B3),
    ripple: const Color(0xFFFFFFFF),
    glowIntensity: 0.8,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.02, 0.02, 0.02),
      Vector3(0.06, 0.06, 0.06),
      Vector3(0.9, 0.9, 0.9),
      Vector3(0.4, 0.4, 0.4),
      Vector3(1.0, 1.0, 1.0),
      Vector3(0.7, 0.7, 0.7),
      Vector3(1.0, 1.0, 1.0),
      Vector3(0.02, 0.02, 0.02),
    ],
  );

  // ---- Reference v1.1.3 palette themes (sRGB→linear derivation) ----

  static final SonicTheme glacierDay = SonicTheme.fromPalette(
    id: 'glacier-day',
    name: 'Glacier Day',
    background: const Color(0xFFD8E6EA),
    fog: const Color(0xFFE5EEF0),
    cool: const Color(0xFF2D8EA3),
    warm: const Color(0xFFD96F4D),
    accent: const Color(0xFF2F5963),
    glowIntensity: 0.82,
  );

  static final SonicTheme koiPond = SonicTheme.fromPalette(
    id: 'koi-pond',
    name: 'Koi Pond',
    background: const Color(0xFF123A36),
    fog: const Color(0xFF0F2C2A),
    cool: const Color(0xFF55D6B2),
    warm: const Color(0xFFF2A65A),
    accent: const Color(0xFFC8EEE4),
    glowIntensity: 1.12,
  );

  static final SonicTheme coralReef = SonicTheme.fromPalette(
    id: 'coral-reef',
    name: 'Coral Reef',
    background: const Color(0xFF40252A),
    fog: const Color(0xFF2F2024),
    cool: const Color(0xFF5FCAD0),
    warm: const Color(0xFFE8705F),
    accent: const Color(0xFFF0B7A4),
    glowIntensity: 1.08,
  );

  static final SonicTheme mossGlass = SonicTheme.fromPalette(
    id: 'moss-glass',
    name: 'Moss Glass',
    background: const Color(0xFF2E3A24),
    fog: const Color(0xFF24301E),
    cool: const Color(0xFF88C8A3),
    warm: const Color(0xFFD6C36D),
    accent: const Color(0xFFDDE8B3),
    glowIntensity: 0.98,
  );

  static final SonicTheme blueHour = SonicTheme.fromPalette(
    id: 'blue-hour',
    name: 'Blue Hour',
    background: const Color(0xFF273C55),
    fog: const Color(0xFF1D3148),
    cool: const Color(0xFF8BC5E7),
    warm: const Color(0xFFF28C72),
    accent: const Color(0xFFCFE7F4),
    glowIntensity: 1.05,
  );

  static final SonicTheme porcelainTeal = SonicTheme.fromPalette(
    id: 'porcelain-teal',
    name: 'Porcelain Teal',
    background: const Color(0xFFDDE8E4),
    fog: const Color(0xFFEEF4F1),
    cool: const Color(0xFF24786F),
    warm: const Color(0xFFB85D4D),
    accent: const Color(0xFF4F706A),
    glowIntensity: 0.78,
  );

  static final SonicTheme wineSignal = SonicTheme.fromPalette(
    id: 'wine-signal',
    name: 'Wine Signal',
    background: const Color(0xFF3A2430),
    fog: const Color(0xFF2F202A),
    cool: const Color(0xFF83C5BE),
    warm: const Color(0xFFD95D73),
    accent: const Color(0xFFF0CBD3),
    glowIntensity: 1.06,
  );

  static final SonicTheme daybreakLime = SonicTheme.fromPalette(
    id: 'daybreak-lime',
    name: 'Daybreak Lime',
    background: const Color(0xFFD9E7C8),
    fog: const Color(0xFFE6EFD9),
    cool: const Color(0xFF2A7C72),
    warm: const Color(0xFFC65B47),
    accent: const Color(0xFF5C6F42),
    glowIntensity: 0.8,
  );

  /// Molten gold-and-copper terrain on a near-black maroon sky.
  static final SonicTheme solarFlare = SonicTheme.fromLinear(
    id: 'solar-flare',
    name: 'Solar Flare',
    background: const Color(0xFF0A0301),
    background2: const Color(0xFF170803),
    fog: const Color(0xFF0A0301),
    coolCore: const Color(0xFFFF9933),
    coolEdge: const Color(0xFFCC4D08),
    warmCore: const Color(0xFFFFE566),
    warmEdge: const Color(0xFFFF7A26),
    ripple: const Color(0xFFFFD9A6),
    glowIntensity: 1.25,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.04, 0.01, 0.0), // base1
      Vector3(0.09, 0.03, 0.01), // base2
      Vector3(1.0, 0.6, 0.1), // coolCore
      Vector3(0.8, 0.3, 0.05), // coolEdge
      Vector3(1.0, 0.9, 0.35), // warmCore
      Vector3(1.0, 0.48, 0.12), // warmEdge
      Vector3(1.0, 0.85, 0.6), // ripple
      Vector3(0.04, 0.01, 0.0), // fog (= base1)
    ],
  );

  /// Violet/magenta plasma — deep-purple sky, electric lilac pillars.
  static final SonicTheme ultraviolet = SonicTheme.fromLinear(
    id: 'ultraviolet',
    name: 'Ultraviolet',
    background: const Color(0xFF08010F),
    background2: const Color(0xFF12041C),
    fog: const Color(0xFF08010F),
    coolCore: const Color(0xFFCC33FF),
    coolEdge: const Color(0xFF8C26E6),
    warmCore: const Color(0xFFFF4DE6),
    warmEdge: const Color(0xFFE62680),
    ripple: const Color(0xFFE699FF),
    glowIntensity: 1.4,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.02, 0.0, 0.04), // base1
      Vector3(0.05, 0.01, 0.09), // base2
      Vector3(0.8, 0.2, 1.0), // coolCore
      Vector3(0.45, 0.1, 0.9), // coolEdge
      Vector3(1.0, 0.3, 0.9), // warmCore
      Vector3(0.9, 0.15, 0.5), // warmEdge
      Vector3(0.9, 0.6, 1.0), // ripple
      Vector3(0.02, 0.0, 0.04), // fog (= base1)
    ],
  );

  /// Abyssal teal — black ocean floor, cyan bioluminescence.
  static final SonicTheme deepSea = SonicTheme.fromLinear(
    id: 'deep-sea',
    name: 'Deep Sea',
    background: const Color(0xFF00070C),
    background2: const Color(0xFF001019),
    fog: const Color(0xFF00070C),
    coolCore: const Color(0xFF1AE6E6),
    coolEdge: const Color(0xFF0D7399),
    warmCore: const Color(0xFF4DFFCC),
    warmEdge: const Color(0xFF1A9980),
    ripple: const Color(0xFF66FFFF),
    glowIntensity: 1.2,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.0, 0.02, 0.03), // base1
      Vector3(0.0, 0.05, 0.07), // base2
      Vector3(0.1, 0.9, 0.9), // coolCore
      Vector3(0.05, 0.45, 0.6), // coolEdge
      Vector3(0.3, 1.0, 0.8), // warmCore
      Vector3(0.1, 0.6, 0.5), // warmEdge
      Vector3(0.4, 1.0, 1.0), // ripple
      Vector3(0.0, 0.02, 0.03), // fog (= base1)
    ],
  );

  /// Aurora over tundra — green↔violet curtains, pale mint ripples.
  static final SonicTheme auroraVeil = SonicTheme.fromLinear(
    id: 'aurora-veil',
    name: 'Aurora Veil',
    background: const Color(0xFF020708),
    background2: const Color(0xFF04100D),
    fog: const Color(0xFF020708),
    coolCore: const Color(0xFF33FF99),
    coolEdge: const Color(0xFF1A99E6),
    warmCore: const Color(0xFFB366FF),
    warmEdge: const Color(0xFF6633CC),
    ripple: const Color(0xFF99FFE6),
    glowIntensity: 1.3,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.005, 0.015, 0.02), // base1
      Vector3(0.01, 0.04, 0.05), // base2
      Vector3(0.2, 1.0, 0.6), // coolCore
      Vector3(0.1, 0.6, 0.9), // coolEdge
      Vector3(0.7, 0.4, 1.0), // warmCore
      Vector3(0.4, 0.2, 0.8), // warmEdge
      Vector3(0.6, 1.0, 0.9), // ripple
      Vector3(0.005, 0.015, 0.02), // fog (= base1)
    ],
  );

  /// Crimson circuitry — black-red sky, scarlet pillars, ember glow.
  static final SonicTheme crimsonPulse = SonicTheme.fromLinear(
    id: 'crimson-pulse',
    name: 'Crimson Pulse',
    background: const Color(0xFF0A0102),
    background2: const Color(0xFF170307),
    fog: const Color(0xFF0A0102),
    coolCore: const Color(0xFFFF2640),
    coolEdge: const Color(0xFF990D26),
    warmCore: const Color(0xFFFF7326),
    warmEdge: const Color(0xFFCC330D),
    ripple: const Color(0xFFFFBFB3),
    glowIntensity: 1.35,
    rotationSpeed: 0.5,
    linear: [
      Vector3(0.04, 0.005, 0.01), // base1
      Vector3(0.09, 0.01, 0.03), // base2
      Vector3(1.0, 0.15, 0.25), // coolCore
      Vector3(0.6, 0.05, 0.15), // coolEdge
      Vector3(1.0, 0.45, 0.15), // warmCore
      Vector3(0.8, 0.2, 0.05), // warmEdge
      Vector3(1.0, 0.75, 0.7), // ripple
      Vector3(0.04, 0.005, 0.01), // fog (= base1)
    ],
  );
}
