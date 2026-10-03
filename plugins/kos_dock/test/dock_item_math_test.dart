// Pure Dart tests for dock_item_math.dart — the source-copied constants and
// branches that need no Flutter: 10px drag gate (DockItem.qml:219-222),
// indicator bar geometry (Denial deviation of :180-189), active/inactive alpha
// (:188), icon opacity (:126). Runs with `dart test` (no engine).

import 'package:kos_dock/src/widgets/dock_item_math.dart';
import 'package:test/test.dart';

void main() {
  group('indicator bar geometry (Denial deviation, DockItem.qml:183-188)', () {
    test('bar is 10 × 3 with a derived 1.5 radius', () {
      expect(kDockIndicatorBarLength, 10);
      expect(kDockIndicatorBarThickness, 3);
      expect(kDockIndicatorBarRadius, 1.5);
      expect(kDockIndicatorBarRadius, kDockIndicatorBarThickness / 2);
    });
    test('bar occupies the bottom inset lane above the band bottom', () {
      expect(kDockIndicatorTopOffset, 6); // band bottom → bar top edge
      expect(kDockIndicatorBarThickness, 3);
      expect(kDockIndicatorBottomInset, 3); // band bottom → bar bottom edge
    });
  });

  group('dockIndicatorAlpha (DockItem.qml:188)', () {
    test('focused → 1.0, unfocused → 0.8', () {
      expect(dockIndicatorAlpha(focused: true), 1.0);
      expect(dockIndicatorAlpha(focused: false), 0.8);
    });
  });

  group('dockDragGatePassed (DockItem.qml:219-222)', () {
    test('below 10px hypot stays a click', () {
      expect(dockDragGatePassed(0, 0), isFalse);
      expect(dockDragGatePassed(5, 5), isFalse); // 7.07
      expect(dockDragGatePassed(9.99, 0), isFalse);
      expect(dockDragGatePassed(6, -6), isFalse); // 8.49
    });
    test('at/over 10px hypot becomes a drag', () {
      expect(dockDragGatePassed(10, 0), isTrue);
      expect(dockDragGatePassed(0, -10), isTrue);
      expect(dockDragGatePassed(8, 6), isTrue); // exactly 10
      expect(dockDragGatePassed(50, 50), isTrue);
    });
  });

  group('constants', () {
    test('drag threshold is the source 10px', () {
      expect(kDockItemDragThreshold, 10);
    });
    test('unavailable opacity is the source 0.45', () {
      expect(kDockItemUnavailableOpacity, 0.45);
    });
    test('icon size default/range matches the brief', () {
      expect(kDockItemDefaultIconSize, 48);
      expect(kDockItemMinIconSize, 32);
      expect(kDockItemMaxIconSize, 80);
    });
  });
}
