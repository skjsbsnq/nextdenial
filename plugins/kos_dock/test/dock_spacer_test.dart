// Tests for the TASK-07 spacer entity + trailing trash entry
// (lib/src/widgets/dock_spacer.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/dock_spacer.dart';

void main() {
  group('trash entry helpers (DockService.qml:232-243)', () {
    test('icon name follows the trash count', () {
      expect(dockTrashIconName(0), 'user-trash');
      expect(dockTrashIconName(1), 'user-trash-full');
      expect(dockTrashIconName(42), 'user-trash-full');
    });

    test('dockTrashEntry is the fixed, always-available trailing row', () {
      final entry = dockTrashEntry(trashCount: 3);
      expect(entry.key, 'trash');
      expect(entry.kind, 'trash');
      expect(entry.appId, 'user-trash-full');
      expect(entry.available, isTrue);
      expect(entry.windowCount, 0);
      expect(entry.name, 'Trash');
      expect(dockTrashEntry(trashCount: 0).appId, 'user-trash');
    });
  });

  group('spacer helpers (DockItem.qml:28, DockDragVisual.qml:127-136)', () {
    test('ghost width halves for small-spacer', () {
      expect(dockSpacerGhostWidth(48, small: false), 48);
      expect(dockSpacerGhostWidth(48, small: true), 24);
    });

    test('dockSpacerEntry carries the layout kind and key', () {
      final full = dockSpacerEntry(id: 's1', small: false);
      expect(full.key, 'spacer:s1');
      expect(full.kind, 'spacer');
      final small = dockSpacerEntry(id: 's2', small: true);
      expect(small.key, 'spacer:s2');
      expect(small.kind, 'small-spacer');
    });
  });

  group('DockSpacer widget', () {
    Future<void> pump(WidgetTester tester, DockSpacer spacer) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: spacer))),
    );

    testWidgets('is invisible at rest', (tester) async {
      await pump(tester, const DockSpacer(size: 48));
      final opacity = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(DockSpacer),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 0);
    });

    testWidgets('shows the half-width outline while dragging', (tester) async {
      await pump(
        tester,
        const DockSpacer(small: true, dragging: true, size: 48),
      );
      final opacity = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(DockSpacer),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1);
      final ghost = tester.getSize(
        find.descendant(
          of: find.byType(DockSpacer),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(ghost.width, 24); // 0.5 × 48
      expect(ghost.height, 48);
    });
  });
}
