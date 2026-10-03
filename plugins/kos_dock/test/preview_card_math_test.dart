// Pure Dart tests for preview_card_math.dart — the `_previewSize` port
// (taskbar window_buttons.dart:914-919) lifted onto raw doubles so `dart
// test` covers it without an engine. Empty/non-finite sources fall back to
// aspect 1.5; results keep the source ratio and never overflow the budget.

import 'package:kos_dock/src/widgets/preview_card_math.dart';
import 'package:test/test.dart';

void main() {
  group('previewCardSize (taskbar _previewSize :914-919)', () {
    test('empty source falls back to aspect 1.5', () {
      // Size.zero previewSize (window has not supplied dimensions yet).
      final s = previewCardSize(
        sourceWidth: 0,
        sourceHeight: 0,
        maxWidth: 320,
        maxHeight: 216,
      );
      // ratio 1.5: h = min(216, 320/1.5) = 213.33 → w = 320.
      expect(s.width, closeTo(320, 1e-9));
      expect(s.height, closeTo(320 / 1.5, 1e-9));
      expect(s.width / s.height, closeTo(1.5, 1e-9));
    });

    test('non-finite source falls back to aspect 1.5', () {
      for (final source in [
        (double.infinity, 600.0),
        (800.0, double.infinity),
        (double.nan, 600.0),
        (800.0, double.nan),
      ]) {
        final s = previewCardSize(
          sourceWidth: source.$1,
          sourceHeight: source.$2,
          maxWidth: 320,
          maxHeight: 216,
        );
        expect(s.width / s.height, closeTo(1.5, 1e-9));
      }
    });

    test('negative edges fall back to aspect 1.5', () {
      final s = previewCardSize(
        sourceWidth: -10,
        sourceHeight: 600,
        maxWidth: 320,
        maxHeight: 216,
      );
      expect(s.width / s.height, closeTo(1.5, 1e-9));
    });

    test('wide source caps at maxWidth, ratio preserved', () {
      // 4:1 in a 320×216 budget: h = min(216, 80) = 80 → w = 320.
      final s = previewCardSize(
        sourceWidth: 1600,
        sourceHeight: 400,
        maxWidth: 320,
        maxHeight: 216,
      );
      expect(s.width, closeTo(320, 1e-9));
      expect(s.height, closeTo(80, 1e-9));
      expect(s.width / s.height, closeTo(4, 1e-9));
    });

    test('tall source caps at maxHeight, ratio preserved', () {
      // 1:4 in a 320×216 budget: h = min(216, 1280) = 216 → w = 54.
      final s = previewCardSize(
        sourceWidth: 100,
        sourceHeight: 400,
        maxWidth: 320,
        maxHeight: 216,
      );
      expect(s.height, closeTo(216, 1e-9));
      expect(s.width, closeTo(54, 1e-9));
      expect(s.width / s.height, closeTo(0.25, 1e-9));
    });

    test('16:9 source fits inside 320×216 without overflow', () {
      final s = previewCardSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        maxWidth: 320,
        maxHeight: 216,
      );
      // ratio 16/9: h = min(216, 180) = 180 → w = 320.
      expect(s.width, closeTo(320, 1e-9));
      expect(s.height, closeTo(180, 1e-9));
      expect(s.width, lessThanOrEqualTo(320));
      expect(s.height, lessThanOrEqualTo(216));
    });

    test('smaller budgets are honoured exactly', () {
      // maxWidth driven by `available` below 320, maxHeight below 216.
      final s = previewCardSize(
        sourceWidth: 800,
        sourceHeight: 600,
        maxWidth: 120,
        maxHeight: 60,
      );
      // ratio 4/3: h = min(60, 90) = 60 → w = 80.
      expect(s.height, closeTo(60, 1e-9));
      expect(s.width, closeTo(80, 1e-9));
    });
  });
}
