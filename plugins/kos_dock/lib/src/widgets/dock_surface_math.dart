/// Pure geometry/constants for the DockSurface widget — no Flutter dependency
/// so the band math can be unit tested with `dart test`.
///
/// Source anchors are into quickshell `Modules/Dock/DockSurface.qml` unless
/// noted.
library;

import 'dart:math' as math;

import '../layout/dock_magnifier.dart' show DockSlot;

/// Axis margin subtracted from the surface axis (`axisLength - 32`, :64).
const double kDockEdgeMargin = 32;

/// Minimum `availableLength` (:64 `Math.max(80, …)`).
const double kDockMinAvailableLength = 80;

/// Band edge inset from the surface edge (`edgeOffset`, :65).
const double kDockEdgeOffset = 8;

/// Minimum band width (`Math.max(96, …)`, :119).
const double kDockMinBandLength = 96;

/// Top gap between the glass top and the resting icon top. The source value is
/// implied 10px: `restingThickness = size + 22` (DockSurface.qml:121) minus the
/// 12px `kDockIconBottomInset` (DockItem.qml:112). Denial narrows it (see
/// `kDockGlassPadding`).
const double kDockGlassTopGap = 4;

/// Band thickness above the magnified icon (`+ 36`, :120).
const double kDockBandPadding = 36;

/// Icon bottom inset inside the glass/band (DockItem.qml:112
/// `- height - 12`). Denial widens 12 → 9 so the running-indicator bar has a
/// clear lane *below* the resting icon: the source anchored its dot to the
/// taller delegate box, but the Denial [DockItem] box is the icon box, so a
/// narrower inset would put the bar on top of the artwork (user report; see
/// docs/visual-deltas.md). The paired `kDockGlassTopGap +
/// kDockIconBottomInset` (= `kDockGlassPadding`) = 13 keeps the resting icon
/// fully inside the glass.
const double kDockIconBottomInset = 9;

/// Glass height above the resting icon. Source `+ 22` (DockSurface.qml:121) is
/// structurally 10 (top gap) + 12 (bottom inset, DockItem.qml:112); Denial keeps
/// that coupling but narrows the top gap and widens the bottom inset to
/// `kDockGlassTopGap + kDockIconBottomInset` = 4 + 9 = 13 (glass 49 at iconSize
/// 36, down from the source-equivalent 58). Keeping the terms coupled is what
/// guarantees the resting icon is fully contained in the glass — recorded in
/// docs/visual-deltas.md.
const double kDockGlassPadding = kDockGlassTopGap + kDockIconBottomInset;

/// Glass corner radius (:822).
const double kDockGlassRadius = 20;

/// Section spacing passed to `layout()` (`16`, :74-76,:105-107).
const double kDockSectionSpacing = 16;

/// Reflow + envelope duration (`DockMotion.reflowDuration`, DockMotion.js:6).
const Duration kDockReflowDuration = Duration(milliseconds: 220);

/// Magnification-exit debounce (`magnificationExit` interval, :637-644).
const Duration kDockMagnificationExitDelay = Duration(milliseconds: 80);

/// Divider inset from the glass edge (:859-860 `glass.x/y + 10`); divider
/// cross-extent is `restingThickness - 20` (:857-858).
const double kDockDividerInset = 10;

/// Divider bar width (:857).
const double kDockDividerWidth = 2;

/// Default magnification strength (`magnificationScale` default 1.5,
/// DockModel.js:10; gated by `DockService.magnification`, :73).
const double kDockDefaultMagnification = 1.5;

/// `availableLength = max(80, axisLength - 32)` (:64).
double dockAvailableLength(double axisLength) =>
    math.max(kDockMinAvailableLength, axisLength - kDockEdgeMargin);

/// `bandLength = min(availableLength, max(96, layout.length))` (:119).
double dockBandLength(double availableLength, double layoutLength) => math.min(
  availableLength,
  math.max(kDockMinBandLength, layoutLength),
);

/// `bandThickness = baseLayout.size * magnification + 36` (:120).
double dockBandThickness(double baseSize, double magnification) =>
    baseSize * magnification + kDockBandPadding;

/// `restingThickness = baseLayout.size + kDockGlassPadding` (:121). Denial
/// padding is `kDockGlassTopGap + kDockIconBottomInset` = 4 + 9 = 13 (source
/// 22); keeping the two terms coupled keeps the resting icon inside the glass.
double dockRestingThickness(double baseSize) => baseSize + kDockGlassPadding;

/// Surface placement thickness = `edgeOffset + restingThickness` — the Dart
/// mirror of `exclusiveZone` (:621) since denial does not reserve work area.
double dockSurfaceThickness(double baseSize) =>
    kDockEdgeOffset + dockRestingThickness(baseSize);

/// `pointerInBase` (:79-81): converts a pointer coordinate in surface space
/// (where the band is centered) into the unmagnified base coordinate system
/// consumed by `layout()`. [scrollOffset] is the icons viewport scroll offset
/// (:77-78).
double dockPointerInBase({
  required double pointerAxis,
  required double axisLength,
  required double baseLength,
  required double availableLength,
  double scrollOffset = 0,
}) =>
    pointerAxis -
    (axisLength - math.min(baseLength, availableLength)) / 2 +
    scrollOffset;

/// `sectionBoundary(kinds, pinnedCount)` (DockLayout.js:62-71, no `order` —
/// preview reordering is a later card): index of the first unpinned row when
/// the pinned section contains at least one `app`, else `-1`.
int dockSectionBoundary(List<String> kinds, int pinnedCount) {
  var hasPinnedApp = false;
  for (var index = 0; index < kinds.length; ++index) {
    if (index >= pinnedCount) return hasPinnedApp ? index : -1;
    if (kinds[index] == 'app') hasPinnedApp = true;
  }
  return -1;
}

/// `insertionIndex(slots, position)` (DockLayout.js:74-80): index of the first
/// slot whose centre is past [position] — the gap the pointer precedes — or
/// `slots.length` when the pointer is past every centre.
///
/// Hit testing uses the **unmagnified** base slots so animated neighbours never
/// move their own thresholds (DockSurface.qml:412-413). [position] is already in
/// the icons-viewport coordinate system (content `x = 0` at the band's left
/// edge), i.e. `pointerLocalX + scrollOffset`.
int dockInsertionIndex(List<DockSlot> slots, double position) {
  for (var index = 0; index < slots.length; ++index) {
    if (position < slots[index].start + slots[index].span / 2) return index;
  }
  return slots.length;
}

/// Clamps a raw insertion gap [insertion] to the reorderable pinned block
/// `[start, end)` (`end` exclusive) and returns the **entry index** the drop
/// targets: the last pinned entry when the pointer is dragged past the block.
/// Returns `null` when the block is empty.
///
/// Only the pinned section is a persistent reorder target (Denial crop of the
/// source's cross-section pinning, `DockService.movePinned`; see
/// docs/visual-deltas.md).
int? dockPinDropIndex({
  required int insertion,
  required int start,
  required int end,
}) {
  if (end <= start) return null;
  final gap = insertion < start
      ? start
      : insertion > end
      ? end
      : insertion;
  return gap >= end ? end - 1 : gap;
}
