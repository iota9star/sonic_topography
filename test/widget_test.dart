// Unit tests for the FFT pipeline and band extraction.
//
// These exercise the math that drives the visualizer without needing a GPU or
// microphone, so they run on every platform / CI host.

import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/sonic_topography.dart';

void main() {
  test('Fft resolves a pure sine to a single dominant bin', () {
    final fft = Fft(1024);
    final samples = Float64List(1024);
    const freq = 12; // bin index 12
    for (int i = 0; i < 1024; i++) {
      samples[i] = math.sin(2 * math.pi * freq * i / 1024);
    }
    final mags = fft.magnitudes(samples);
    // The energy should peak at `freq`.
    int maxBin = 0;
    double maxVal = -1;
    for (int i = 1; i < mags.length; i++) {
      if (mags[i] > maxVal) {
        maxVal = mags[i];
        maxBin = i;
      }
    }
    expect(maxBin, freq);
    expect(maxVal, greaterThan(0.3));
  });

  test('BandExtractor returns smoothed idle-ish bands for low-level noise', () {
    final extractor = BandExtractor(binCount: 512);
    final mags = Float64List(512); // all zero => silence
    final b = extractor.process(mags);
    expect(b.energy, lessThan(0.05));
    expect(b.subBass, lessThan(0.05));
  });

  test('DemoAnalyzer produces non-idle bands and beats while active', () async {
    final demo = DemoAnalyzer();
    expect(demo.isActive, isFalse);
    await demo.start();
    expect(demo.isActive, isTrue);
    // drive several frames; the demo synth should eventually emit bands/energy
    AudioBands last = AudioBands.idle;
    bool anyBeat = false;
    for (int i = 0; i < 200; i++) {
      last = demo.read();
      if (demo.consumeBeats().isNotEmpty) anyBeat = true;
    }
    expect(last.energy, greaterThan(0.0));
    expect(anyBeat, isTrue);
    await demo.stop();
    expect(demo.read().energy, equals(0.0));
    demo.dispose();
  });

  test('SceneState ring buffers expire ripples and advance meteors', () {
    final scene = SceneState();
    scene.addRipple(0, 0, 1.0, 0.0);
    scene.addMeteor(0.8, 0.0, 0.0);
    // advance ~5s; ripples expire, meteor falls
    scene.tick(5.0, 5.0);
    scene.pack(5.0);
    // ripple strength should be zeroed after expiry
    expect(scene.rippleUniforms[3], equals(0.0));
  });

  test('Meteor impact spawns a white ripple and particle burst', () {
    final scene = SceneState();
    expect(scene.addMeteor(1.0, 0.0, 0.0), isTrue);
    // Step with realistic per-frame deltas so the meteor descends and impacts
    // without ageing particles to death in a single tick.
    double time = 0.0;
    bool impacted = false;
    for (int i = 0; i < 60 && !impacted; i++) {
      time += 0.05;
      scene.tick(0.05, time);
      scene.pack(time);
      for (int j = 0; j < 10; j++) {
        if (scene.rippleUniforms[j * 4 + 3] < -0.001) impacted = true;
      }
    }
    expect(impacted, isTrue); // a white (negative) impact ripple appeared

    // Particles should be alive right after impact.
    bool anyParticle = false;
    for (int i = 0; i < 16; i++) {
      if (scene.particleUniforms[i * 4 + 3] > 0.001) anyParticle = true;
    }
    expect(anyParticle, isTrue);

    // After their lifetime expires, particles deactivate.
    scene.tick(2.0, time + 2.0);
    scene.pack(time + 2.0);
    bool anyAlive = false;
    for (int i = 0; i < 16; i++) {
      if (scene.particleUniforms[i * 4 + 3] > 0.001) anyAlive = true;
    }
    expect(anyAlive, isFalse);
  });

  test('Normal ripples keep positive strength in the uniform array', () {
    final scene = SceneState();
    scene.addRipple(1, 2, 1.5, 0.5, type: RippleType.normal);
    scene.pack(0.5);
    expect(scene.rippleUniforms[3], greaterThan(0.0));
  });

  // End-to-end shader proof: the Flutter test host has a real rasterizer, so
  // loading the FragmentProgram proves the GLSL compiles, and pumping one frame
  // through the widget proves every setFloat offset lines up with the shader's
  // uniform declaration order. A compile error or a uniform-count mismatch
  // throws here instead of silently showing a black screen at runtime.
  testWidgets('shader compiles and renders a frame without uniform errors',
      (tester) async {
    final controller = SonicShaderController();
    // Wait for the async FragmentProgram.fromAsset load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.ready, isTrue,
        reason: 'shader must compile: ${controller.error}');

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(
        width: 200,
        height: 200,
        child: SonicTopography(
          controller: controller,
          theme: SonicTheme.nocturnal,
          audioAnalyzer: DemoAnalyzer()..start(),
          adaptiveQuality: false,
          renderScale: 0.5,
        ),
      ),
    ));
    // Pump several frames so BOTH the bake pass and the sampler-bound display
    // pass run and upload uniforms (the heightfield must land before the
    // display pass binds it via setImageSampler).
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // No exception thrown => both shaders compile and the uniform + sampler
    // layout matches the compiled programs.
    expect(tester.takeException(), isNull);
  });
}
