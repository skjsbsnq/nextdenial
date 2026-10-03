// Unit tests for the pure geometry in
// plugins/kos_dock/lib/src/widgets/dock_surface_math.dart.
//
// Golden values against DockSurface.qml:64-65,79-81,119-121 and
// DockLayout.js:62-71.

import 'package:kos_dock/src/layout/dock_magnifier.dart';
import 'package:kos_dock/src/widgets/dock_surface_math.dart';
import 'package:test/test.dart';

void main() {
  group('dockAvailableLength (:64)', () {
    test('axisLength - 32', () {
      expect(dockAvailableLength(1920), 1888);
      expect(dockAvailableLength(800), 768);
    });
    test('floors at 80', () {
      expect(dockAvailableLength(100), 80);
      expect(dockAvailableLength(0), 80);
    });
  });

  group('dockBandLength (:119)', () {
    test('clamps to min 96', () {
      expect(dockBandLength(800, 24), 96); // empty dock layout.length = 24
      expect(dockBandLength(800, 96), 96);
    });
    test('passes the layout length through', () {
      expect(dockBandLength(800, 336), 336);
    });
    test('caps at availableLength', () {
      expect(dockBandLength(200, 433.3), 200);
    });
  });

  group('thickness formulas (:120-121, :65, :621)', () {
    test('restingThickness = size + kDockGlassPadding', () {
      // Source padding `22 = 10 (top gap) + 12 (bottom inset, :121 +
      // DockItem.qml:112); Denial trades a wider bottom inset (`13 = 4 + 9`) for
      // a clear indicator-bar lane below the icon, but must keep the terms
      // coupled, otherwise the resting icon pokes out of the glass (see
      // docs/visual-deltas.md).
      expect(kDockGlassTopGap, 4);
      expect(kDockIconBottomInset, 9);
      expect(kDockGlassPadding, kDockGlassTopGap + kDockIconBottomInset);
      expect(kDockGlassPadding, 13);
      expect(dockRestingThickness(48), 48 + kDockGlassPadding); // 61
      expect(dockRestingThickness(32), 32 + kDockGlassPadding); // 45
      expect(dockRestingThickness(80), 80 + kDockGlassPadding); // 93
    });
    test('bandThickness = size * M + 36', () {
      // Band head-room keeps the source `+ 36` (kDockBandPadding).
      expect(dockBandThickness(48, 1.5), 108);
      expect(dockBandThickness(48, 1), 84);
    });
    test('surface thickness = edgeOffset + restingThickness', () {
      // 8 + (size + 13): Denial padding 13 = 4 + 9 (source 22).
      expect(dockSurfaceThickness(48), kDockEdgeOffset + 48 + kDockGlassPadding);
      expect(dockSurfaceThickness(32), kDockEdgeOffset + 32 + kDockGlassPadding);
      expect(dockSurfaceThickness(80), kDockEdgeOffset + 80 + kDockGlassPadding);
    });
    test('matches layout().size at the default iconSize', () {
      // The real resting size comes from TASK-01 layout(); with 3 icons and
      // plenty of room size == preferredSize == 48.
      final result = layout(
        kinds: const ['app', 'app', 'app'],
        preferredSize: 48,
        available: 1888,
        magnification: 1.5,
        sectionSpacing: kDockSectionSpacing,
        pointer: double.nan,
      );
      expect(result.size, 48);
      expect(
        dockSurfaceThickness(result.size),
        kDockEdgeOffset + result.size + kDockGlassPadding,
      );
    });
  });

  group('dockPointerInBase (:79-81)', () {
    test('centered band, no scroll', () {
      // axis 800, baseLength 336 < available 768 → row centered:
      // pointerInBase = x - (800 - 336)/2 = x - 232.
      expect(
        dockPointerInBase(
          pointerAxis: 400,
          axisLength: 800,
          baseLength: 336,
          availableLength: 768,
        ),
        168,
      );
    });
    test('caps at availableLength when the row overflows', () {
      // baseLength 1200 > available 768 → min() picks 768:
      // pointerInBase = x - (800 - 768)/2 = x - 16.
      expect(
        dockPointerInBase(
          pointerAxis: 400,
          axisLength: 800,
          baseLength: 1200,
          availableLength: 768,
        ),
        384,
      );
    });
    test('scrollOffset shifts the base origin', () {
      expect(
        dockPointerInBase(
          pointerAxis: 400,
          axisLength: 800,
          baseLength: 1200,
          availableLength: 768,
          scrollOffset: 37,
        ),
        421,
      );
    });
    test('non-finite pointer stays non-finite', () {
      expect(
        dockPointerInBase(
          pointerAxis: double.nan,
          axisLength: 800,
          baseLength: 336,
          availableLength: 768,
        ).isNaN,
        isTrue,
      );
    });
  });

  group('dockSectionBoundary (DockLayout.js:62-71)', () {
    test('no pinned rows → -1', () {
      expect(dockSectionBoundary(const ['app', 'app'], 0), -1);
    });
    test('pinned apps then unpinned → first unpinned index', () {
      expect(
        dockSectionBoundary(const ['app', 'app', 'app'], 2),
        2,
      );
    });
    test('all pinned → -1', () {
      expect(dockSectionBoundary(const ['app', 'app'], 2), -1);
    });
    test('pinned section without an app → -1', () {
      // A pinned spacer alone does not open the boundary (:63-70).
      expect(
        dockSectionBoundary(const ['spacer', 'app'], 1),
        -1,
      );
    });
    test('first unpinned row is not an app still bounds the section', () {
      expect(
        dockSectionBoundary(const ['app', 'small-spacer'], 1),
        1,
      );
    });
    test('empty kinds → -1', () {
      expect(dockSectionBoundary(const [], 0), -1);
    });
  });

  group('dockInsertionIndex (DockLayout.js:74-80)', () {
    // Three 36px slots: start 12/56/100, span 44, centre 34/78/122.
    const slots = <DockSlot>[
      DockSlot(center: 34, start: 12, span: 44, size: 36),
      DockSlot(center: 78, start: 56, span: 44, size: 36),
      DockSlot(center: 122, start: 100, span: 44, size: 36),
    ];
    test('first slot whose centre is past the pointer', () {
      expect(dockInsertionIndex(slots, 0), 0);
      expect(dockInsertionIndex(slots, 33), 0); // before slot 0 centre
      expect(dockInsertionIndex(slots, 34), 1); // on the centre → next gap
      expect(dockInsertionIndex(slots, 100), 2);
    });
    test('past the last centre → slots.length (append gap)', () {
      expect(dockInsertionIndex(slots, 999), 3);
    });
    test('empty row → 0 (the only gap)', () {
      expect(dockInsertionIndex(const <DockSlot>[], 42), 0);
    });
  });

  group('dockPinDropIndex', () {
    test('clamps to the pinned block and returns the target entry', () {
      // Block [1, 4): launcher at 0, pins at 1..3.
      expect(dockPinDropIndex(insertion: 0, start: 1, end: 4), 1);
      expect(dockPinDropIndex(insertion: 2, start: 1, end: 4), 2);
    });
    test('dropping past the block targets the last pinned entry', () {
      expect(dockPinDropIndex(insertion: 4, start: 1, end: 4), 3);
      expect(dockPinDropIndex(insertion: 99, start: 1, end: 4), 3);
    });
    test('empty block → null', () {
      expect(dockPinDropIndex(insertion: 2, start: 2, end: 2), isNull);
      expect(dockPinDropIndex(insertion: 0, start: 5, end: 3), isNull);
    });
  });
}
