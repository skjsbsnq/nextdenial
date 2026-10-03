// Widget tests for DockSurface + the KosDockPlugin surface contract
// (plugins/kos_dock/lib/src/widgets/dock_surface.dart, lib/kos_dock.dart).
//
// Covers the TASK-03 acceptance checks: empty-dock render (glass base +
// safe empty row), legal `place()` placement per output, divider/spacer
// geometry vs `layout()` truth, band bottom inset 8, and the
// `edgeOffset + restingThickness = 57` thickness formula (Denial iconSize 36 +
// glass padding 13 = 4 + 9; source-equivalent 78 at iconSize 48 / padding 22).

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/kos_dock.dart';
import 'package:kos_dock/src/layout/dock_magnifier.dart' as magnifier;
import 'package:kos_dock/src/widgets/dock_item.dart';
import 'package:kos_dock/src/widgets/dock_surface.dart';

/// Minimal ShellServices test double (same seam as dock_item_test.dart).
final class _FakeServices implements ShellServices {
  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      ColoredBox(
        key: ValueKey('icon:$appId'),
        color: Theme.of(context).colorScheme.primary,
      );

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

const _output = Rect.fromLTWH(0, 0, 800, 600);

ShellSurfaceEnvironment _env({
  Rect output = _output,
  Rect? workArea,
  int monitorId = 0,
  bool isMainOutput = true,
  bool locked = false,
  bool wallpaperSelectorVisible = false,
  bool fullscreen = false,
  bool overview = false,
  bool desktopVisible = true,
}) => ShellSurfaceEnvironment(
  output: DisplayOutput(
    monitorId: monitorId,
    name: 'test-$monitorId',
    logicalRect: output,
    pixelSize: output.size,
    scale: 1,
    refreshRate: 60,
  ),
  workArea: workArea ?? output,
  isMainOutput: isMainOutput,
  workspaceId: 1,
  fullscreen: fullscreen,
  overview: overview,
  desktopVisible: desktopVisible,
  wallpaperSelectorVisible: wallpaperSelectorVisible,
  locked: locked,
  settings: const ShellSettings(),
  defaultOutputSelected: true,
);

/// Pumps a DockSurface into the real placement strip (800 × thickness) with
/// the production icon size.
Future<void> _pumpSurface(
  WidgetTester tester, {
  List<DockEntry> entries = const [],
  int pinnedAppCount = 0,
  void Function(String fromKey, String toKey)? onItemReordered,
}) {
  return tester.pumpWidget(
    ProviderScope(
      // ShellInputRegion is a ConsumerStatefulWidget — needs a scope.
      child: ShellTheme(
        data: const ShellThemeData(),
        // MaterialApp provides the Localizations + Overlay ancestors the
        // surface host supplies in production (the per-item DockPreviewCard
        // renders through OverlayPortal).
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: _output.width,
                height: KosDockPlugin.thickness,
                child: DockSurface(
                  entries: entries,
                  pinnedAppCount: pinnedAppCount,
                  services: _FakeServices(),
                  monitorId: 0,
                  iconSize: KosDockPlugin.iconSize,
                  onItemReordered: onItemReordered,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The Positioned that hosts the 'DockGlass' ShellInputRegion.
/// Rendered rect of the 'DockGlass' ShellInputRegion (the glass Positioned
/// uses left+right, so width must be measured, not read).
Rect _glassRect(WidgetTester tester) {
  final region = find.byWidgetPredicate(
    (w) => w is ShellInputRegion && w.debugLabel == 'DockGlass',
  );
  expect(region, findsOneWidget);
  return tester.getRect(region);
}
/// Divider render boxes keyed by left offset inside the icons viewport.
List<Rect> _dividerRects(WidgetTester tester) => tester
    .widgetList<AnimatedPositioned>(
      find.byWidgetPredicate(
        (w) =>
            w is AnimatedPositioned &&
            w.width == 2 &&
            w.child is DecoratedBox,
      ),
    )
    .map(
      (w) => Rect.fromLTWH(w.left!, w.top!, w.width!, w.height!),
    )
    .toList();

void main() {
  group('KosDockPlugin.place', () {
    const plugin = KosDockPlugin();

    test('thickness = edgeOffset + restingThickness', () {
      // DockSurface.qml:65,121,621 — 8 + (iconSize + padding). Denial 默认
      // iconSize 36（源端 48）且玻璃内边距 13 = 4 + 9（源端 22，见
      // visual-deltas）→ 8 + (36 + 13) = 57；公式本身仍等于源端对等式。
      expect(KosDockPlugin.iconSize, 36);
      expect(KosDockPlugin.thickness, dockSurfaceThickness(36));
      expect(KosDockPlugin.thickness, 57);
      // 源端 iconSize 48 代入：8 + (48 + 13) = 69（源端内边距则为 78）。
      expect(dockSurfaceThickness(48), 69);
    });

    test('floats above application windows', () {
      // A dock that does not reserve work area must not sit under windows.
      expect(plugin.layer, ShellSurfaceLayer.aboveWindows);
    });

    test('bounds = edgeBounds bottom strip of the full output', () {
      final placement = plugin.place(_env());
      expect(placement, isNotNull);
      expect(
        placement!.bounds,
        Rect.fromLTWH(0, 600 - KosDockPlugin.thickness, 800, KosDockPlugin.thickness),
      );
      expect(placement.fade, ShellSurfaceFade.custom);
      expect(placement.occupiesDesktop, isFalse);
    });

    test('every output gets an instance (no main-output gate)', () {
      expect(
        plugin.place(_env(isMainOutput: false, monitorId: 1)),
        isNotNull,
      );
      expect(
        plugin
            .place(
              _env(
                output: const Rect.fromLTWH(800, 0, 1920, 1080),
                monitorId: 1,
                isMainOutput: false,
              ),
            )!
            .bounds,
        Rect.fromLTWH(800, 1080 - KosDockPlugin.thickness, 1920, KosDockPlugin.thickness),
      );
    });

    test('visible gate mirrors the taskbar', () {
      expect(plugin.place(_env())!.visible, isTrue);
      expect(plugin.place(_env(locked: true))!.visible, isFalse);
      expect(
        plugin.place(_env(wallpaperSelectorVisible: true))!.visible,
        isFalse,
      );
      expect(
        plugin
            .place(_env(fullscreen: true, desktopVisible: false))!
            .visible,
        isFalse,
      );
      expect(
        plugin.place(_env(fullscreen: true, overview: true))!.visible,
        isTrue,
      );
      // desktopVisible overrides fullscreen like the taskbar.
      expect(plugin.place(_env(fullscreen: true))!.visible, isTrue);
    });
  });

  group('DockSurface widget', () {
    testWidgets('empty dock renders glass base + safe empty row', (
      tester,
    ) async {
      await _pumpSurface(tester);
      await tester.pump();

      // Glass: Material + 20px radius inside a ShellInputRegion.
      expect(
        find.byWidgetPredicate(
          (w) => w is ShellInputRegion && w.debugLabel == 'DockGlass',
        ),
        findsOneWidget,
      );
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is ShellInputRegion && w.debugLabel == 'DockGlass',
          ),
          matching: find.byType(Material),
        ),
      );
      expect(
        (material.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(20),
      );

      // Glass geometry: width = bandLength 96 (empty layout.length = 24 →
      // clamped), height = restingThickness = iconSize + kDockGlassPadding.
      final glass = _glassRect(tester);
      expect(glass.width, 96);
      expect(glass.height, dockRestingThickness(KosDockPlugin.iconSize));

      // No icons, no dividers — safe empty row.
      expect(find.byType(DockItem), findsNothing);
      expect(_dividerRects(tester), isEmpty);
      // Empty-dock affordance icon (:1220-1227 replacement).
      expect(find.byIcon(Icons.apps_rounded), findsOneWidget);
    });

    testWidgets('band bottom inset is edgeOffset = 8', (tester) async {
      await _pumpSurface(tester);
      await tester.pump();
      final region = find.byWidgetPredicate(
        (w) => w is ShellInputRegion && w.debugLabel == 'DockGlass',
      );
      final glassBottom = tester.getBottomLeft(region).dy;
      final surfaceBottom = tester.getBottomLeft(
        find.byType(DockSurface),
      ).dy;
      expect(surfaceBottom - glassBottom, 8); // DockSurface.qml:65,769
    });

    testWidgets('resting icon is fully contained in the glass', (tester) async {
      // Coupling regression: the source glass padding `22 = 10 (top gap) + 12
      // (bottom inset)` is Denial `13 = 4 (top gap) + 9 (bottom inset)` — the
      // bottom inset widened to leave the indicator bar a lane below the icon.
      // Mismatching the terms leaves the icon poking above the glass top (and
      // out of the place() bounds).
      await _pumpSurface(
        tester,
        entries: [DockEntry(key: 'a', name: 'App', appId: 'app')],
      );
      await tester.pump();

      final glass = _glassRect(tester);
      final icon = tester.getRect(find.byType(DockItem));
      expect(icon.height, KosDockPlugin.iconSize);
      // Top gap >= 0: the icon top is not above the glass top.
      expect(icon.top, greaterThanOrEqualTo(glass.top - 0.5));
      // Bottom inset >= 0: the icon bottom is not below the glass bottom.
      expect(icon.bottom, lessThanOrEqualTo(glass.bottom + 0.5));
      // Both gaps match the structural constants exactly.
      expect(icon.top - glass.top, closeTo(kDockGlassTopGap, 0.5));
      expect(glass.bottom - icon.bottom, closeTo(kDockIconBottomInset, 0.5));
      // The two gaps + the icon fill the glass height (:121 coupling).
      expect(
        (icon.top - glass.top) + icon.height + (glass.bottom - icon.bottom),
        closeTo(glass.height, 0.5),
      );
    });

    testWidgets('indicator bar is contained in the glass, above the band bottom', (
      tester,
    ) async {
      // Combination-level regression for the user report: in the real surface
      // the running bar must stay inside the glass and in the bottom inset lane
      // (the glass bottom is the band bottom).
      await _pumpSurface(
        tester,
        entries: [
          DockEntry(
            key: 'a',
            name: 'App',
            appId: 'app',
            windowCount: 1,
            windowId: 7,
          ),
        ],
      );
      await tester.pump();

      final glass = _glassRect(tester);
      final bar = tester.getRect(
        find.descendant(
          of: find.byType(DockItem),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius ==
                    BorderRadius.circular(kDockIndicatorBarRadius),
          ),
        ),
      );

      // Bar ⊆ glass.
      expect(bar.left, greaterThanOrEqualTo(glass.left - 0.5));
      expect(bar.right, lessThanOrEqualTo(glass.right + 0.5));
      expect(bar.top, greaterThanOrEqualTo(glass.top - 0.5));
      expect(bar.bottom, lessThanOrEqualTo(glass.bottom + 0.5));
      // Bar bottom stays in the bottom inset lane
      // [bandBottom - kDockIconBottomInset, bandBottom].
      expect(
        bar.bottom,
        greaterThanOrEqualTo(glass.bottom - kDockIconBottomInset - 0.5),
      );
      // It is the bar, not the old circle.
      expect(bar.width, kDockIndicatorBarLength);
      expect(bar.height, kDockIndicatorBarThickness);
    });

    testWidgets('divider lands on layout().dividers ±1px', (tester) async {
      // pinned 2 + 1 unpinned → boundary at index 2 (DockLayout.js:62-71).
      final entries = [
        for (var i = 0; i < 3; ++i)
          DockEntry(key: 'k$i', name: 'App $i', appId: 'app$i'),
      ];
      await _pumpSurface(tester, entries: entries, pinnedAppCount: 2);
      await tester.pump();

      final truth = magnifier.layout(
        kinds: const ['app', 'app', 'app'],
        preferredSize: KosDockPlugin.iconSize,
        available: 768, // axis 800 - 32 (:64)
        magnification: 1.5,
        sectionSpacing: 16,
        pointer: double.nan,
        sectionBoundary: const [2],
      );
      expect(truth.dividers, hasLength(1));
      final resting = dockRestingThickness(KosDockPlugin.iconSize);
      final band = dockBandThickness(KosDockPlugin.iconSize, 1.5);

      final rects = _dividerRects(tester);
      expect(rects, hasLength(1));
      // x centered on the divider axis (:859); top = glass.y + 10 (:860),
      // height = resting - 20 (:858) inside bandThickness (:120).
      expect(
        rects.single.center.dx,
        closeTo(truth.dividers.single, 1),
      );
      expect(rects.single.width, 2);
      expect(rects.single.height, resting - 20);
      // bandThickness - resting = glass top; +10 = divider top.
      expect(rects.single.top, closeTo(band - resting + 10, 0.5));
    });

    testWidgets('small-spacer slot spans size * 0.5 + gap', (tester) async {
      final entries = [
        const DockEntry(
          key: 's',
          name: 'spacer',
          appId: 'none',
          kind: 'small-spacer',
        ),
        const DockEntry(key: 'a', name: 'App', appId: 'app'),
      ];
      await _pumpSurface(tester, entries: entries);
      await tester.pump();

      final truth = magnifier.layout(
        kinds: const ['small-spacer', 'app'],
        preferredSize: KosDockPlugin.iconSize,
        available: 768,
        magnification: 1.5,
        sectionSpacing: 16,
        pointer: double.nan,
      );
      // weight 0.5: span = iconSize*0.5*1 + 8 (DockLayout.js:22,47).
      expect(
        truth.slots.first.span,
        closeTo(KosDockPlugin.iconSize * 0.5 + 8, 1e-9),
      );

      // Slot AnimatedPositioneds live inside the 'DockIcons' region (the
      // band's own positioner is excluded by scoping the finder).
      final iconsRegion = find.byWidgetPredicate(
        (w) => w is ShellInputRegion && w.debugLabel == 'DockIcons',
      );
      final slots = tester
          .widgetList<AnimatedPositioned>(
            find.descendant(
              of: iconsRegion,
              matching: find.byWidgetPredicate(
                (w) => w is AnimatedPositioned && w.width != 2,
              ),
            ),
          )
          .toList();
      expect(slots.length, 2);
      // Spacer slot first: span = iconSize*0.5 + 8 gap.
      expect(slots.first.width, closeTo(truth.slots.first.span, 0.5));
      expect(slots.last.width, closeTo(truth.slots.last.span, 0.5));
    });

    testWidgets('icons row width = bandLength, centered in the surface', (
      tester,
    ) async {
      final entries = [
        for (var i = 0; i < 4; ++i)
          DockEntry(key: 'k$i', name: 'App $i', appId: 'app$i'),
      ];
      await _pumpSurface(tester, entries: entries);
      await tester.pump();

      final truth = magnifier.layout(
        kinds: const ['app', 'app', 'app', 'app'],
        preferredSize: KosDockPlugin.iconSize,
        available: 768,
        magnification: 1.5,
        sectionSpacing: 16,
        pointer: double.nan,
      );
      final bandLength = dockBandLength(768, truth.length);
      final icons = find.byWidgetPredicate(
        (w) => w is ShellInputRegion && w.debugLabel == 'DockIcons',
      );
      expect(tester.getSize(icons).width, closeTo(bandLength, 1));
      // Horizontally centered (:766).
      final left = tester.getTopLeft(icons).dx;
      expect(left, closeTo((800 - bandLength) / 2, 1));
    });

    testWidgets('hover magnifies the icon under the pointer (surface basis)', (
      tester,
    ) async {
      final entries = [
        for (var i = 0; i < 4; ++i)
          DockEntry(key: 'k$i', name: 'App $i', appId: 'app$i'),
      ];
      await _pumpSurface(tester, entries: entries);
      await tester.pump();

      final icons = find.byWidgetPredicate(
        (w) => w is ShellInputRegion && w.debugLabel == 'DockIcons',
      );
      final iconsRect = tester.getRect(icons);
      // Row-local centre of slot 2 from the resting layout. The band is
      // centered, so hovering the surface x of that slot must magnify slot 2;
      // before the surface-basis fix the band-local dx was handed to
      // `dockPointerInBase`, which subtracted the centering offset a second
      // time and killed the wave.
      final resting = magnifier.layout(
        kinds: const ['app', 'app', 'app', 'app'],
        preferredSize: KosDockPlugin.iconSize,
        available: 768,
        magnification: 1.5,
        sectionSpacing: 16,
        pointer: double.nan,
      );
      final rowPointer = resting.slots[2].center;
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(
        Offset(iconsRect.left + rowPointer, iconsRect.center.dy),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250)); // 220ms envelope

      final slots = tester
          .widgetList<AnimatedPositioned>(
            find.descendant(
              of: icons,
              matching: find.byWidgetPredicate(
                (w) => w is AnimatedPositioned && w.width != 2,
              ),
            ),
          )
          .toList();
      expect(slots, hasLength(4));
      // Slot geometry must match the pure layout truth for the row-local
      // pointer of slot 2's centre.
      final truth = magnifier.layout(
        kinds: const ['app', 'app', 'app', 'app'],
        preferredSize: KosDockPlugin.iconSize,
        available: 768,
        magnification: 1.5,
        sectionSpacing: 16,
        pointer: rowPointer,
      );
      expect(slots[2].width, closeTo(truth.slots[2].span, 0.5));
      expect(slots[0].width, closeTo(truth.slots[0].span, 0.5));
      // The hovered slot must actually have grown versus its resting span.
      expect(slots[2].width, greaterThan(resting.slots[2].span));
    });
  });

  group('pinned drag reorder (DockDragVisual.qml)', () {
    const entries = <DockEntry>[
      DockEntry(key: 'a', name: 'A', appId: 'a', pinned: true),
      DockEntry(key: 'b', name: 'B', appId: 'b', pinned: true),
      DockEntry(key: 'c', name: 'C', appId: 'c', pinned: true),
    ];

    DockItem itemByKey(WidgetTester tester, String key) =>
        tester.widget<DockItem>(
          find.byWidgetPredicate((w) => w is DockItem && w.entryKey == key),
        );

    testWidgets('dragging hides the row and shows ghost + placeholder', (
      tester,
    ) async {
      await _pumpSurface(tester, entries: entries, pinnedAppCount: 3);
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('a'))),
      );
      // Cross the 10px gate into B's left half (slot pitch 44 at iconSize 36).
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(itemByKey(tester, 'a').dragged, isTrue); // :61
      expect(find.byKey(const ValueKey('dock-drag-ghost')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('dock-drop-placeholder')),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump();
      expect(itemByKey(tester, 'a').dragged, isFalse);
      expect(find.byKey(const ValueKey('dock-drag-ghost')), findsNothing);
      expect(
        find.byKey(const ValueKey('dock-drop-placeholder')),
        findsNothing,
      );
    });

    testWidgets('release commits onItemReordered with the landing key', (
      tester,
    ) async {
      final reorders = <(String, String)>[];
      await _pumpSurface(
        tester,
        entries: entries,
        pinnedAppCount: 3,
        onItemReordered: (from, to) => reorders.add((from, to)),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('a'))),
      );
      await gesture.moveBy(const Offset(30, 0)); // into B's left half
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(reorders, <(String, String)>[('a', 'b')]);
    });

    testWidgets('pointer cancel resets the drag without committing', (
      tester,
    ) async {
      final reorders = <(String, String)>[];
      await _pumpSurface(
        tester,
        entries: entries,
        pinnedAppCount: 3,
        onItemReordered: (from, to) => reorders.add((from, to)),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('a'))),
      );
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(itemByKey(tester, 'a').dragged, isTrue);

      await gesture.cancel();
      await tester.pump();
      expect(itemByKey(tester, 'a').dragged, isFalse);
      expect(find.byKey(const ValueKey('dock-drag-ghost')), findsNothing);
      expect(reorders, isEmpty);
    });

    testWidgets('an unpinned row drag does not engage reorder', (tester) async {
      final reorders = <(String, String)>[];
      await _pumpSurface(
        tester,
        entries: const [
          DockEntry(key: 'run', name: 'Run', appId: 'run'),
          DockEntry(key: 'pin', name: 'Pin', appId: 'pin', pinned: true),
        ],
        pinnedAppCount: 1,
        onItemReordered: (from, to) => reorders.add((from, to)),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('run'))),
      );
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(itemByKey(tester, 'run').dragged, isFalse);
      expect(find.byKey(const ValueKey('dock-drag-ghost')), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(reorders, isEmpty);
    });
  });
}
