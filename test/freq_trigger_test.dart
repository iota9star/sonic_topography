import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/src/audio/freq_trigger.dart';

void main() {
  Float64List flat([double level = 0.3]) =>
      Float64List.fromList(List<int>.filled(512, 0).map((_) => level).toList());

  test('pulse trigger fires on a rising transient in its band', () {
    final tr = FreqTriggers();
    const dt = 1 / 60;
    double t = 0;
    // Idle floor so the adaptive threshold settles.
    for (int i = 0; i < 60; i++) {
      tr.step(flat(), t, dt);
      tr.commitFrame(flat());
      t += dt;
    }
    // Kick: bins 1-2 jump from 0.3 to 0.95 for one frame.
    final kick = flat();
    kick[1] = 0.95;
    kick[2] = 0.95;
    tr.step(kick, t, dt);
    tr.commitFrame(kick);
    t += dt;
    // Peak is detected on the following falling frame (prevSmoothedFlux was
    // the peak and is now >= current).
    final fired = tr.step(flat(), t, dt);
    tr.commitFrame(flat());
    expect(fired, isNotEmpty);
    expect(fired.any((e) => e.$1 == FreqTriggerAction.pulse), isTrue);
  });

  test('disabled trigger never fires; advanced mode uses the crosshair', () {
    final tr = FreqTriggers();
    tr.meteor.enabled = false;
    var fired = tr.step(flat(0.9), 0, 1 / 60);
    tr.commitFrame(flat(0.9));
    expect(fired.where((e) => e.$1 == FreqTriggerAction.meteor), isEmpty);

    tr.meteor.enabled = true;
    tr.meteor.mode = FreqTriggerMode.advanced;
    tr.meteor.freqIndex = 100;
    tr.meteor.threshold = 0.5;
    fired = tr.step(flat(0.9), 1 / 60, 1 / 60);
    expect(
      fired.where((e) => e.$1 == FreqTriggerAction.meteor),
      isNotEmpty,
      reason: '0.9 level over the 0.5 crosshair threshold must fire',
    );
  });

  test('auto-track locks the pulse band onto the strongest transient', () {
    final tr = FreqTriggers();
    const dt = 1 / 60;
    double t = 0;
    // ~1.2 s of frames where bin 5 punches on every 10th frame.
    for (int i = 0; i < 72; i++) {
      final s = flat();
      if (i % 10 == 0) s[5] = 1.0;
      tr.step(s, t, dt);
      tr.commitFrame(s);
      t += dt;
    }
    expect(tr.pulse.bandStart, lessThanOrEqualTo(5));
    expect(tr.pulse.bandEnd, greaterThanOrEqualTo(5));
    expect(tr.pulse.sensitivity, 0.85);
  });
}
