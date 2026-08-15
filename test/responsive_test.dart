// Responsive layout: the chrome must lay out without overflow across phone,
// tablet, laptop and desktop sizes, with the settings drawer open and closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_topography/main.dart';

void main() {
  const sizes = <String, Size>{
    'small phone': Size(360, 640),
    'phone': Size(412, 915),
    'tablet portrait': Size(768, 1024),
    'laptop': Size(1280, 800),
    'desktop': Size(1920, 1080),
    'phone landscape': Size(915, 412),
  };

  for (final e in sizes.entries) {
    testWidgets('no overflow at ${e.key} (${e.value.width}x${e.value.height})',
        (tester) async {
      tester.view.physicalSize = e.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await tester.pumpWidget(const SonicApp());
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull,
          reason: 'closed-state overflow at ${e.key}');

      // Breakpoint layout: phones stack the audio-source picker on its own
      // row below the logo; desktop keeps everything on one row.
      final logoBottom = tester.getBottomLeft(find.text('SONIC')).dy;
      final demoTop = tester.getTopLeft(find.text('DEMO')).dy;
      final isNarrow = e.value.width < 700;
      if (isNarrow) {
        expect(demoTop, greaterThan(logoBottom),
            reason: 'phone: DEMO picker must sit on the row below the logo');
      } else {
        expect(demoTop, lessThan(logoBottom + 1),
            reason: 'desktop: top bar must stay a single row');
      }

      // Open the right-hand drawer and exercise the scrollable panel.
      await tester.tap(find.byIcon(Icons.tune_rounded).first);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Restore the strict check now that the header shrinks.
      expect(tester.takeException(), isNull,
          reason: 'drawer-open overflow at ${e.key}');
      expect(find.text('THEMES'), findsOneWidget);
      expect(find.text('VISUALIZER'), findsOneWidget);
      expect(find.text('THEMES'), findsOneWidget);

      // The drawer must not exceed the screen width.
      final screen = tester.view.physicalSize;
      final drawerRect = tester.getRect(find.text('VISUALIZER'));
      expect(drawerRect.right, lessThanOrEqualTo(screen.width + 1),
          reason: 'drawer wider than screen at ${e.key}');
    });
  }
}
