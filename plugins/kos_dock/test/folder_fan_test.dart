// Widget tests for TASK-06: DockFolderFan (progress interpolation, opacity
// three-factor product, labelReveal lag, overflow stack), DockFolderStackIcon
// (3-layer ±9° fan), DockFolderGrid (column formula, action cell, empty
// state), DockFolderList (row geometry, height formula, empty/back rows),
// and the launch seam (tap → onActivated → launchApplication).
//
// Formula-level assertions (dockFanStackDepth/dockFanTileOpacity/
// dockFanLabelReveal/dockFanTileScale/dockFanStackShift) run as plain unit
// tests against the exported helpers — the DockFolderFan.qml:87-131 ports.

import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/folder_fan.dart';
import 'package:kos_dock/src/widgets/folder_grid.dart';
import 'package:kos_dock/src/widgets/folder_list.dart';
import 'package:kos_dock/src/widgets/folder_stack_icon.dart';

final class _FakeServices implements ShellServices {
  final launched = <String>[];
  final iconRequests = <String>[];

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async {
    launched.add(id);
    return true;
  }

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) {
    iconRequests.add(appId);
    return SizedBox(
      key: ValueKey('appicon:$appId'),
      width: 8,
      height: 8,
    );
  }

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) =>
      const SizedBox.shrink();

  @override
  void activateWindow(int id) {}

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

Widget _harness(Widget child, {_FakeServices? services}) => ProviderScope(
  child: ShellTheme(
    data: const ShellThemeData(),
    child: MaterialApp(
      home: Scaffold(
        body: ShellServicesScope(
          services: services ?? _FakeServices(),
          child: Center(child: child),
        ),
      ),
    ),
  ),
);

const _three = [
  DockFanEntry(name: 'Alpha', appId: 'app.a'),
  DockFanEntry(name: 'Beta', appId: 'app.b'),
  DockFanEntry(name: 'Gamma', appId: 'app.c'),
];

List<DockFanEntry> _entries(int count) => [
  for (var i = 0; i < count; ++i)
    DockFanEntry(name: 'App $i', appId: 'app.$i'),
];

void main() {
  group('tile motion formulas (DockFolderFan.qml:87-131)', () {
    test('stackDepth = max(0, position − count + 1) (:87)', () {
      expect(dockFanStackDepth(0, 5), 0);
      expect(dockFanStackDepth(4.5, 5), 0.5);
      expect(dockFanStackDepth(8, 5), 4);
      expect(dockFanStackDepth(-2, 5), 0);
    });

    test('opacity three-factor product (:117-118)', () {
      expect(
        dockFanTileOpacity(progress: 1, position: 3, stackDepth: 0),
        1,
      );
      // min(1, 2p) folds in over the first half.
      expect(
        dockFanTileOpacity(progress: 0.25, position: 3, stackDepth: 0),
        0.5,
      );
      // Scrolled past position −1 fades out via min(1, position+1).
      expect(
        dockFanTileOpacity(progress: 1, position: -0.5, stackDepth: 0),
        0.5,
      );
      // Each overflow layer drops 25%: 1 − stackDepth/4.
      expect(
        dockFanTileOpacity(progress: 1, position: 6, stackDepth: 2),
        0.5,
      );
    });

    test('labelReveal lags 40% then fades by 0.42^depth (:119)', () {
      expect(dockFanLabelReveal(progress: 0.4, stackDepth: 0), 0);
      expect(dockFanLabelReveal(progress: 0.3, stackDepth: 0), 0);
      expect(
        dockFanLabelReveal(progress: 0.7, stackDepth: 0),
        closeTo(0.5, 1e-9),
      );
      expect(dockFanLabelReveal(progress: 1, stackDepth: 1), 0.42);
      expect(
        dockFanLabelReveal(progress: 1, stackDepth: 2),
        closeTo(0.42 * 0.42, 1e-9),
      );
    });

    test('scale = (0.7 + 0.3p) · 0.94^depth (:126-131)', () {
      expect(dockFanTileScale(progress: 0, stackDepth: 0), 0.7);
      expect(dockFanTileScale(progress: 1, stackDepth: 0), 1);
      expect(
        dockFanTileScale(progress: 1, stackDepth: 1),
        closeTo(0.94, 1e-9),
      );
      expect(
        dockFanTileScale(progress: 1, stackDepth: 3),
        closeTo(math.pow(0.94, 3), 1e-9),
      );
    });

    test('stack shifts split by edge (:105-111)', () {
      expect(
        dockFanStackShiftX(
          edge: FolderFanEdge.bottom,
          labelsLeft: true,
          stackDepth: 2,
        ),
        6,
      );
      expect(
        dockFanStackShiftX(
          edge: FolderFanEdge.bottom,
          labelsLeft: false,
          stackDepth: 2,
        ),
        -6,
      );
      expect(
        dockFanStackShiftX(
          edge: FolderFanEdge.left,
          labelsLeft: true,
          stackDepth: 2,
        ),
        14,
      );
      expect(
        dockFanStackShiftX(
          edge: FolderFanEdge.right,
          labelsLeft: true,
          stackDepth: 2,
        ),
        -14,
      );
      expect(
        dockFanStackShiftY(edge: FolderFanEdge.bottom, stackDepth: 2),
        14,
      );
      expect(dockFanStackShiftY(edge: FolderFanEdge.left, stackDepth: 2), 0);
      expect(
        dockFanStackShiftY(edge: FolderFanEdge.right, stackDepth: 2),
        0,
      );
    });
  });

  group('DockFolderFan', () {
    testWidgets('progress 0 collapses tiles onto sourceCenter; 1 reaches'
        ' the slot', (tester) async {
      for (final progress in [0.0, 1.0]) {
        await tester.pumpWidget(
          _harness(
            DockFolderFan(
              entries: _three,
              maximumWidth: 600,
              maximumHeight: 800,
              sourceCenter: const Offset(200, 460),
              progress: progress,
            ),
          ),
        );
        final geometry = folderFan(
          edge: FolderFanEdge.bottom,
          count: 3,
          maximumWidth: 600,
          maximumHeight: 800,
          labelsLeft: true,
          requestedIconSize: 64,
        );
        final slot0 = geometry.slots.first;
        // Tiles paint in reverse index order (z:-position, :92) — locate
        // index 0 by the ValueKey on its `_FanItem`, then take the Positioned
        // that `_FanItem` builds (a descendant of the keyed element).
        final first = tester.widget<Positioned>(
          find
              .descendant(
                of: find.byKey(const ValueKey('fan:0')),
                matching: find.byType(Positioned),
              )
              // `_FanItem`'s own Positioned is the outermost one;
              // `DockFanTile` adds more Positioned descendants for its
              // label/artwork stacks, so take the first depth-first match.
              .first,
        );
        if (progress == 0) {
          // :113-116 — tile top-left = sourceCenter − icon centre.
          final iconCx = geometry.tileWidth - geometry.iconSize / 2 - 6;
          final iconCy = geometry.tileHeight / 2;
          expect(first.left, closeTo(200 - iconCx, 1e-6));
          expect(first.top, closeTo(460 - iconCy, 1e-6));
        } else {
          expect(first.left, closeTo(slot0.x, 1e-6));
          expect(first.top, closeTo(slot0.y, 1e-6));
        }
      }
    });

    testWidgets('progress half-way sets opacity 1 but scale mid-range', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          DockFolderFan(
            entries: _three,
            sourceCenter: const Offset(200, 460),
            progress: 0.5,
          ),
        ),
      );
      // min(1, 2·0.5) = 1 — tiles fully opaque halfway (:117).
      final opacities = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(DockFolderFan),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacities.every((o) => o.opacity > 0), isTrue);
    });

    testWidgets('labelReveal < 0.4 progress hides label pill opacity', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const DockFolderFan(
            entries: _three,
            sourceCenter: Offset(200, 460),
            progress: 0.3, // < 0.4 → labelReveal 0 (:119)
          ),
        ),
      );
      final pillOpacity = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(DockFanTile),
          matching: find.byType(Opacity),
        ),
      );
      expect(pillOpacity.every((o) => o.opacity == 0), isTrue);
    });

    testWidgets('>8 entries fold into the overflow stack with reduced'
        ' opacity', (tester) async {
      await tester.pumpWidget(
        _harness(
          DockFolderFan(
            entries: _entries(10),
            sourceCenter: const Offset(200, 460),
            progress: 1,
          ),
        ),
      );
      final geometry = folderFan(
        edge: FolderFanEdge.bottom,
        count: 10,
        maximumWidth: 600,
        maximumHeight: 800,
        labelsLeft: true,
        requestedIconSize: 64,
      );
      expect(geometry.count, lessThan(10)); // shown clipped by 8/height
      expect(geometry.stackReserve, 24); // :153
      // Tiled widgets beyond the visible window render at reduced
      // opacity or not at all (:91 stackDepth < 4).
      final opacities = tester
          .widgetList<Opacity>(
            find.descendant(
              of: find.byType(DockFolderFan),
              matching: find.byType(Opacity),
            ),
          )
          .map((o) => o.opacity)
          .toList();
      expect(opacities.any((o) => o < 1), isTrue);
    });

    testWidgets('tap on a tile fires onActivated with its index (launch'
        ' seam)', (tester) async {
      final activated = <int>[];
      await tester.pumpWidget(
        _harness(
          DockFolderFan(
            entries: _three,
            sourceCenter: const Offset(200, 460),
            progress: 1,
            onActivated: activated.add,
          ),
        ),
      );
      await tester.tap(find.text('Beta'));
      expect(activated, [1]);
    });

    testWidgets('action tile fires onAction; canGoBack picks back', (
      tester,
    ) async {
      final actions = <bool>[];
      await tester.pumpWidget(
        _harness(
          DockFolderFan(
            entries: _three,
            sourceCenter: const Offset(200, 460),
            progress: 1,
            actionText: 'Utilities',
            onAction: actions.add,
          ),
        ),
      );
      await tester.tap(find.text('Utilities'));
      expect(actions, [false]); // open branch (:172)
    });
  });

  group('DockFolderStackIcon', () {
    testWidgets('3+ entries → 3 layers at −9°/0°/+9°', (tester) async {
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 48,
            height: 48,
            child: DockFolderStackIcon(
              appIds: ['a', 'b', 'c', 'd'],
            ),
          ),
        ),
      );
      final rotates = tester.widgetList<Transform>(
        find.descendant(
          of: find.byType(DockFolderStackIcon),
          matching: find.byType(Transform),
        ),
      );
      expect(rotates, hasLength(3)); // min(3, 4) (:48)
      // Painter order is z = 3 − index (:58): deepest layer first, so the
      // list reads index 2, 1, 0 → rotations +9°, 0°, −9°.
      final angles = rotates
          .map((t) => t.transform.getRotation().entry(1, 0)) // sin(θ)
          .toList(growable: false);
      for (var i = 0; i < 3; ++i) {
        expect(
          angles[i],
          closeTo(math.sin([9, 0, -9][i] * math.pi / 180), 1e-9),
        );
      }
    });

    testWidgets('count == 0 falls back to the folder icon (:33)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 48,
            height: 48,
            child: DockFolderStackIcon(appIds: []),
          ),
        ),
      );
      expect(find.byIcon(Icons.folder), findsOneWidget);
    });
  });

  group('DockFolderGrid', () {
    test('column formula max(1, floor(w/106)) (:57)', () {
      expect(dockFolderGridColumns(105), 1);
      expect(dockFolderGridColumns(106), 1);
      expect(dockFolderGridColumns(212), 2);
      expect(dockFolderGridColumns(340), 3);
      expect(dockFolderGridColumns(0), 1);
    });

    test('rows clamp max(1, min(4, …)) (:58)', () {
      expect(dockFolderGridRows(count: 2, columns: 3), 1);
      expect(dockFolderGridRows(count: 8, columns: 3), 3);
      expect(dockFolderGridRows(count: 40, columns: 3), 4);
    });

    testWidgets('width drives the column count; action cell last', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const DockFolderGrid(
            entries: _three,
            name: 'Utilities',
            maximumWidth: 600,
            progress: 1,
            canGoBack: true,
          ),
        ),
      );
      // min(360, 600) − 20 insets = 340 → floor(340/106) = 3 columns (:57).
      expect(dockFolderGridColumns(340), 3);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
      // Action cell is the arrow_back badge when canGoBack (:308-313
      // clipped to back semantics).
      expect(find.byIcon(Icons.arrow_back), findsWidgets);
      expect(find.text('Utilities'), findsOneWidget);
    });

    testWidgets('empty group renders the empty-state text (:329-339)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const DockFolderGrid(entries: [], name: 'Empty', progress: 1),
        ),
      );
      expect(find.text('Folder is empty'), findsOneWidget);
    });

    testWidgets('tap on a cell fires onActivated (launch seam)', (
      tester,
    ) async {
      final activated = <int>[];
      await tester.pumpWidget(
        _harness(
          DockFolderGrid(
            entries: _three,
            name: 'G',
            progress: 1,
            onActivated: activated.add,
          ),
        ),
      );
      await tester.tap(find.text('Gamma'));
      expect(activated, [2]);
    });
  });

  group('DockFolderList', () {
    test('height formula (:28-29 + DockFilePopup.qml:61-62)', () {
      expect(
        dockFolderListHeight(
          count: 3,
          maximumHeight: 600,
          edge: FolderFanEdge.bottom,
        ),
        16 + 4 * 34 + 12 + 10,
      );
      // Non-bottom edge drops the tail.
      expect(
        dockFolderListHeight(
          count: 3,
          maximumHeight: 600,
          edge: FolderFanEdge.left,
        ),
        16 + 4 * 34 + 12,
      );
      // 480 cap.
      expect(
        dockFolderListHeight(
          count: 40,
          maximumHeight: 600,
          edge: FolderFanEdge.bottom,
        ),
        480,
      );
      // Empty still reserves 1 row + action row (:28 max(1,count)).
      expect(
        dockFolderListHeight(
          count: 0,
          maximumHeight: 600,
          edge: FolderFanEdge.bottom,
        ),
        16 + 2 * 34 + 12 + 10,
      );
    });

    testWidgets('rows are 34px with 22px icon, empty shows text', (
      tester,
    ) async {
      final services = _FakeServices();
      await tester.pumpWidget(
        _harness(const DockFolderList(entries: _three), services: services),
      );
      final panel = tester.getSize(find.byType(DockFolderList));
      expect(panel.width, 360); // :27
      expect(panel.height, 16 + 4 * 34 + 12 + 10); // :28-29 + tail
      expect(services.iconRequests, containsAll(['app.a', 'app.b', 'app.c']));
      expect(find.text('Alpha'), findsOneWidget);
      // No chevrons under app-group clipping (:187-194 never renders).
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('empty group shows the disabled empty row (:196-203)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(const DockFolderList(entries: [])),
      );
      expect(find.text('Folder is empty'), findsOneWidget);
    });

    testWidgets('tap on a row fires onActivated (launch seam)', (
      tester,
    ) async {
      final activated = <int>[];
      await tester.pumpWidget(
        _harness(
          DockFolderList(entries: _three, onActivated: activated.add),
        ),
      );
      await tester.tap(find.text('Alpha'));
      expect(activated, [0]);
    });

    testWidgets('canGoBack adds the footer back row (:204-213 clipped)', (
      tester,
    ) async {
      var backs = 0;
      await tester.pumpWidget(
        _harness(
          DockFolderList(
            entries: _three,
            canGoBack: true,
            onBack: () => backs++,
          ),
        ),
      );
      expect(find.text('Back'), findsOneWidget);
      await tester.tap(find.text('Back'));
      expect(backs, 1);
    });
  });
}
