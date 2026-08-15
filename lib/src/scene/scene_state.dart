import 'dart:math';
import 'dart:typed_data';

/// Type of ripple, controlling how it renders in the shader.
enum RippleType {
  /// Themed-color ground wave from a kick/snare beat or a tap.
  normal,

  /// Sharp, fast, pure-white wave from a meteor impact.
  white,
}

/// Manages the ring buffers of ripples, meteors and impact particles and packs
/// them into the float uniform arrays the shader consumes each frame. All three
/// are updated on the CPU (cheap: 10/12/16 vec4s) and uploaded as `vec4[]`.
///
/// Ripple type is encoded in the sign of the strength slot: positive = normal
/// themed ripple, negative = white impact ripple (the shader keys off the sign).
class SceneState {
  SceneState();

  static const int maxRipples = 10;
  static const int maxMeteors = 20;
  static const int maxParticles = 64;

  /// Floating crystal cubes above the terrain — exact reference layout
  /// (MapScene.tsx): fixed positions on a 5-turn spiral, radius 14..75,
  /// height 6..24, tumbling in place, size swollen by the kick envelope.
  /// The reference renders 80; 32 keeps the same spiral distribution at a
  /// per-fragment cost the single-pass shader can afford.
  static const int maxBlocks = 32;

  // ripple slots: x, z, spawnTime, strength (sign = type)
  final List<_Ripple> _ripples = List.generate(maxRipples, (_) => _Ripple());
  int _rippleIndex = 0;

  // meteor slots: x, z, currentY, strength
  final List<_Meteor> _meteors = List.generate(maxMeteors, (_) => _Meteor());
  int _meteorIndex = 0;

  // impact particle slots: x, y, z, strength (alpha)
  final List<_Particle> _particles =
      List.generate(maxParticles, (_) => _Particle());
  int _particleIndex = 0;

  final Random _rng = Random();
  double _lastMeteorTime = -1e9;

  /// Whether impact/trail particles simulate and upload. When toggled off the
  /// packed uniforms are zeroed so stale slots don't linger in the shader.
  bool particlesEnabled = true;

  /// Flattened vec4 arrays (x,y,z,w) for upload.
  final Float32List rippleUniforms = Float32List(maxRipples * 4);
  final Float32List meteorUniforms = Float32List(maxMeteors * 4);
  final Float32List particleUniforms = Float32List(maxParticles * 4);

  /// Blocks pack into two arrays: A = (x, y, z, halfSize), Q = tumble
  /// quaternion (unit, xyzw). Brightness is a shared scalar (blockPulseMix)
  /// because the reference drives every block with one uPulse uniform.
  final Float32List blockUniforms = Float32List(maxBlocks * 4);
  final Float32List blockRotUniforms = Float32List(maxBlocks * 4);

  /// Reference uPulse for the block material = clamp(pulse × (0.5 +
  /// intensity×1.7)) with defaults intensity 55 → ×1.435. Drives both the
  /// crystal brightness (normElevation = uPulse × 2.5) and size mix.
  double blockPulseMix = 0;

  // Floating-block tuning — the reference's ground-eq settings (0..100
  // scales, reference defaults 55 / 9 / 26 / 77 / 80). Count is capped by the
  // shader's uniform arrays (the reference renders 80 real meshes).
  double blockIntensity = 55;
  double blockMinSize = 9;
  double blockMaxSize = 26;
  double blockSpeed = 77;
  int blockCount = maxBlocks;

  // Static per-block seeds from the reference formulas.
  final List<_BlockSeed> _blockSeeds = List.generate(maxBlocks, _BlockSeed.new);

  // Smoothed kick envelope (reference floatingBlockPulseRef).
  double _blockPulse = 0;
  double _blockTime = 0;

  /// Add a ripple. [time] is the current scene clock (seconds).
  void addRipple(double x, double z, double strength, double time,
      {RippleType type = RippleType.normal}) {
    final r = _ripples[_rippleIndex];
    r.x = x;
    r.z = z;
    r.spawnTime = time;
    r.strength = strength;
    r.type = type;
    r.active = true;
    _rippleIndex = (_rippleIndex + 1) % maxRipples;
  }

  /// Add a meteor (returns whether it was spawned, respecting cooldown).
  bool addMeteor(double strength, double time, double cooldownSec) {
    if (time - _lastMeteorTime < cooldownSec) return false;
    _lastMeteorTime = time;
    final m = _meteors[_meteorIndex];
    final angle = _rng.nextDouble() * pi * 2;
    final dist = _rng.nextDouble() * 25;
    m.x = cos(angle) * dist;
    m.z = sin(angle) * dist;
    m.y = 30 + _rng.nextDouble() * 10;
    m.speed = 1.0 + _rng.nextDouble() * 0.5 + strength * 1.5;
    m.strength = strength;
    m.active = true;
    _meteorIndex = (_meteorIndex + 1) % maxMeteors;
    return true;
  }

  /// Spawn an impact particle burst at (x, ground, z). Matches the reference:
  /// 10 sparks on impact.
  void _spawnImpactBurst(double x, double z, double speed) {
    if (!particlesEnabled) return;
    const count = 10;
    for (int i = 0; i < count; i++) {
      final p = _particles[_particleIndex];
      final ang = _rng.nextDouble() * pi * 2;
      final rad = _rng.nextDouble() * 0.8;
      p.x = x + cos(ang) * rad;
      p.y = 0.5 + _rng.nextDouble() * 0.6;
      p.z = z + sin(ang) * rad;
      p.vx = cos(ang) * (1.0 + _rng.nextDouble() * 2.0);
      p.vz = sin(ang) * (1.0 + _rng.nextDouble() * 2.0);
      p.vy = (1.0 + _rng.nextDouble() * 2.0) + speed * 2.0;
      p.life = 0;
      p.maxLife = 0.4 + _rng.nextDouble() * 0.5;
      p.strength = 0.6 + _rng.nextDouble() * 0.4;
      p.active = true;
      _particleIndex = (_particleIndex + 1) % maxParticles;
    }
  }

  /// Spawn a single trail particle behind a falling meteor. Matches the
  /// reference: small upward/outward drift, short life, dim.
  void _spawnTrail(double x, double y, double z, double speed) {
    if (!particlesEnabled) return;
    final p = _particles[_particleIndex];
    p.x = x + (_rng.nextDouble() - 0.5) * 1.5;
    p.y = y + (_rng.nextDouble() - 0.5) * 1.5;
    p.z = z + (_rng.nextDouble() - 0.5) * 1.5;
    p.vx = (_rng.nextDouble() - 0.5) * 2.0;
    p.vy = _rng.nextDouble() * 2.0 + speed * 10.0;
    p.vz = (_rng.nextDouble() - 0.5) * 2.0;
    p.life = 0;
    p.maxLife = 0.4 + _rng.nextDouble() * 0.4;
    p.strength = 0.3 + _rng.nextDouble() * 0.3;
    p.active = true;
    _particleIndex = (_particleIndex + 1) % maxParticles;
  }

  /// Advance ripples + meteors + particles by [dt].
  void tick(double dt, double time) {
    for (final r in _ripples) {
      if (r.active && time - r.spawnTime > 3.0) {
        r.active = false;
        r.strength = 0;
      }
    }
    for (final m in _meteors) {
      if (!m.active) continue;
      m.y -= m.speed * 60 * dt;
      if (m.y <= 0) {
        m.active = false;
        // White impact ripple + particle burst (matching the reference).
        addRipple(m.x, m.z, m.strength.clamp(0.0, 1.2), time,
            type: RippleType.white);
        _spawnImpactBurst(m.x, m.z, m.speed);
        m.strength = 0;
      } else if (_rng.nextDouble() > 0.3) {
        // Falling: emit a continuous trail (70% of frames), matching reference.
        _spawnTrail(m.x, m.y, m.z, m.speed * 0.2);
      }
    }
    for (final p in _particles) {
      if (!p.active) continue;
      p.life += dt;
      if (p.life >= p.maxLife) {
        p.active = false;
        p.strength = 0;
        continue;
      }
      p.x += p.vx * dt * 10;
      p.y += p.vy * dt * 10;
      p.z += p.vz * dt * 10;
      p.vy -= 6.0 * dt; // gravity so sparks fall back
      p.strength = (1.0 - p.life / p.maxLife).clamp(0.0, 1.0) *
          (0.6 + _rng.nextDouble() * 0.4);
    }
  }

  /// Advance floating blocks. [kickEnv] is the raw kick envelope (0..1) — the
  /// reference smooths it with lerp(3, 36, speed)/s, swells block size between
  /// the min/max scale lerps and lifts them pulse×intensity×1.4. [enabled]
  /// mirrors the reference's enabledScale (0 collapses all blocks).
  void tickBlocks(double dt, double kickEnv, bool enabled) {
    _blockTime += dt;
    final speedRate = 3.0 + (blockSpeed / 100.0) * (36.0 - 3.0);
    final blend = (1.0 - exp(-speedRate * dt)).clamp(0.0, 1.0);
    _blockPulse += (kickEnv.clamp(0.0, 1.0) - _blockPulse) * blend;
    final intensity = blockIntensity / 100.0;
    blockPulseMix = (_blockPulse * (0.5 + intensity * 1.7)).clamp(0.0, 1.0);
    final minScale = 0.12 + (blockMinSize / 100.0) * (0.75 - 0.12);
    final maxScale = 0.45 + (blockMaxSize / 100.0) * (3.2 - 0.45);
    final pulseScale =
        minScale + (maxScale - minScale) * blockPulseMix;
    final lift = _blockPulse * intensity * 1.4;
    final b = blockUniforms;
    final q = blockRotUniforms;
    final t = _blockTime;
    for (int i = 0; i < maxBlocks; i++) {
      final s = _blockSeeds[i];
      final off = i * 4;
      final bob = sin(t * (0.55 + s.rotationSpeed) + s.phase) * 0.45;
      final half = (enabled && i < blockCount)
          ? s.baseScale * pulseScale * 0.5
          : 0.0;
      b[off] = s.x;
      b[off + 1] = s.height + bob + lift;
      b[off + 2] = s.z;
      b[off + 3] = half;
      // Tumble: three-axis Euler at per-block speed (reference setFromEuler).
      final ex = t * s.rotationSpeed + s.phase;
      final ey = t * s.rotationSpeed * 0.7 + s.phase;
      final ez = t * s.rotationSpeed * 0.45 + s.phase;
      final cx = cos(ex * 0.5), sx = sin(ex * 0.5);
      final cy = cos(ey * 0.5), sy = sin(ey * 0.5);
      final cz = cos(ez * 0.5), sz = sin(ez * 0.5);
      // Quaternion.fromRotation(Rx·Ry·Rz), written out (hot path, 32/frame).
      q[off] = sx * cy * cz + cx * sy * sz;
      q[off + 1] = cx * sy * cz - sx * cy * sz;
      q[off + 2] = cx * cy * sz + sx * sy * cz;
      q[off + 3] = cx * cy * cz - sx * sy * sz;
    }
  }

  /// Pack active ripples into [rippleUniforms] using elapsed time since spawn
  /// (so values stay small). Strength sign encodes the type: negative = white.
  void pack(double time) {
    final r = rippleUniforms;
    for (int i = 0; i < maxRipples; i++) {
      final rip = _ripples[i];
      final off = i * 4;
      r[off] = rip.x;
      r[off + 1] = rip.z;
      r[off + 2] = rip.active ? time - rip.spawnTime : 0.0;
      final s = rip.active ? rip.strength.clamp(0.0, 2.0) : 0.0;
      r[off + 3] = rip.type == RippleType.white ? -s : s;
    }
    final m = meteorUniforms;
    for (int i = 0; i < maxMeteors; i++) {
      final met = _meteors[i];
      final off = i * 4;
      m[off] = met.x;
      m[off + 1] = met.z;
      m[off + 2] = met.active ? met.y : 0.0;
      m[off + 3] = met.active ? met.strength.clamp(0.0, 2.0) : 0.0;
    }
    final pp = particleUniforms;
    if (!particlesEnabled) {
      pp.fillRange(0, pp.length, 0.0);
      return;
    }
    for (int i = 0; i < maxParticles; i++) {
      final part = _particles[i];
      final off = i * 4;
      pp[off] = part.active ? part.x : 0.0;
      pp[off + 1] = part.active ? part.y : 0.0;
      pp[off + 2] = part.active ? part.z : 0.0;
      pp[off + 3] = part.active ? part.strength : 0.0;
    }
  }

  void clear() {
    for (final r in _ripples) {
      r.active = false;
      r.strength = 0;
    }
    for (final m in _meteors) {
      m.active = false;
      m.strength = 0;
    }
    for (final p in _particles) {
      p.active = false;
      p.strength = 0;
    }
  }
}

class _Ripple {
  double x = 0, z = 0;
  double spawnTime = -100;
  double strength = 0;
  RippleType type = RippleType.normal;
  bool active = false;
}

class _Meteor {
  double x = 0, z = 0, y = -1000;
  double speed = 0;
  double strength = 0;
  bool active = false;
}

class _Particle {
  double x = 0, y = 0, z = 0;
  double vx = 0, vy = 0, vz = 0;
  double life = 0;
  double maxLife = 1;
  double strength = 0;
  bool active = false;
}

/// Static layout of one floating block — exact reference formulas
/// (MapScene.tsx floatingBlocks useMemo), with count folded from 80 to 32:
/// the spiral still makes 5 turns spanning radius 14..75.
class _BlockSeed {
  _BlockSeed(int index) {
    final ring = index / SceneState.maxBlocks;
    final angle = ring * pi * 2 * 5.0 + sin(index * 12.9898) * 0.7;
    final radius = 14.0 + ((index * 37) % 62);
    height = 6.0 + ((index * 17) % 19);
    x = cos(angle) * radius;
    z = sin(angle) * radius;
    baseScale = 0.75 + ((index * 11) % 9) * 0.05;
    phase = index * 0.73;
    rotationSpeed = 0.18 + ((index * 7) % 10) * 0.035;
  }
  double x = 0, z = 0;
  double height = 0;
  double baseScale = 1;
  double phase = 0;
  double rotationSpeed = 0;
}
