<p align="center">
  <img src="assets/icon/app_icon.png" width="128" alt="Sonic Topography logo" />
</p>

<h1 align="center">Sonic Topography</h1>

<p align="center">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-blue" alt="platforms" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license" />
</p>

A GPU-driven, audio-reactive 3D terrain visualizer built with Flutter and
Impeller fragment shaders. Music becomes a rotating planet of pillars that
lift, glow and ripple with the beat — rendered in a single display pass with
an async heightfield bake.

## Highlights

- **Single-pass GPU rendering** — the whole scene (ray-marched pillar grid,
  fog, meteors, particles, floating crystal blocks) draws in one fragment
  shader via `CustomPaint`. Elevation is baked into a small heightfield
  texture off the critical path, so the CPU only pushes ~30 uniforms a frame.
- **Real audio analysis** — a hand-rolled radix-2 FFT feeds 8 frequency bands
  onto a dB scale (−75 dBFS gate, 45 dB window), a kick-envelope follower,
  and spectral-flux frequency triggers with sensitivity / cooldown / band
  controls and an advanced crosshair mode.
- **18 built-in themes** with exact linear shader colors, theme rotation,
  and a ground-EQ mixer that reshapes how each band lifts the terrain.
- **Adaptive quality** — quality-first: renders at full device resolution and
  probes into supersampling while the display's refresh rate is met, shedding
  resolution only when frames are actually dropped.
- **Responsive chrome** — phone through desktop layouts, official right-hand
  settings drawer, validated by automated multi-size layout tests.

## Platforms

Desktop-class rendering (Impeller/Metal/Vulkan) on macOS, Windows and Linux;
touch-ready on Android and iOS. Web is not a target.

## Getting started

```bash
fvm flutter pub get
fvm flutter run -d macos   # or windows / linux / an attached device
```

Run the test suite (shader compile, layout, trigger math, band ranges):

```bash
fvm flutter test
```

## Controls

- **Audio sources** — DEMO (built-in synthesizer), MUSIC (pick audio
  files from the system dialog) and MIC (live microphone input with
  dB-scale normalization).
- **Settings drawer** (right edge or the theme pill in the top bar):
  - *Audio source* — the DEMO / MUSIC / MIC picker lives here.
  - *Themes* — 18 presets, tap to apply, optional auto-rotation.
  - *Scene* — glow, amplitude, pillar width/spacing, rotation speed and
    terrain density (96–224 cells per side).
  - *Floating blocks* — kick-driven crystal cubes with intensity / size /
    speed / count controls.
  - *Pulse / Meteor triggers* — spectral-flux detection with sensitivity,
    cooldown, FFT band and strength; advanced mode aims a crosshair on the
    live spectrum.
  - *Ground EQ* — 8-band mixer shaping each frequency's terrain response.

## CI & releases

Every push builds all supported platforms (Android APK, unsigned iOS IPA,
macOS app, Windows and Linux bundles) via GitHub Actions and publishes them
to a GitHub release. Android artifacts are signed with the committed debug
key so they install directly — swap in your own keystore for store
distribution.

## Project layout

```
lib/
  main.dart                     # app shell, overlay chrome, drawer panel
  src/sonic_shader_controller.dart  # uniform packing, tick loop, bake pipeline
  src/scene/scene_state.dart    # ripples, meteors, particles, blocks
  src/audio/                    # FFT, band extraction, beat + freq triggers
  src/theme/sonic_theme.dart    # 18 built-in palettes
shaders/
  sonic_topography.frag         # display pass (DDA ray march + shading)
  sonic_heightfield.frag        # async bake pass
test/                           # layout, color, trigger and shader tests
```

## License

Released under the [MIT License](LICENSE).
