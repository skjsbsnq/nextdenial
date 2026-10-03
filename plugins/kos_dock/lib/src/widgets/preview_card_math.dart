/// Pure geometry/constants for the dock window preview cards — no Flutter
/// dependency so the sizing math can be unit tested with `dart test` (same
/// split as `dock_item_math.dart` / `dock_surface_math.dart`).
///
/// Source anchors are into `denial_taskbar/lib/src/window_buttons.dart`.
library;

import 'dart:math' as math;

/// Per-card preview budget: `min(320, available)` / `min(216, maxHeight)`
/// (taskbar window_buttons.dart:767-777 — dock keeps the same 320×216 cap).
const double kDockPreviewMaxWidth = 320;
const double kDockPreviewMaxHeight = 216;

/// Fallback aspect ratio when a window has not supplied a usable
/// `previewSize` yet — empty or non-finite sources render as 3:2 cards
/// (taskbar `_previewSize`, window_buttons.dart:916).
const double kDockPreviewFallbackAspect = 1.5;

/// Card-to-card horizontal gap in the preview row (taskbar :828, :782).
const double kDockPreviewGap = 8;

/// Overlay margin: row width reserve (`output.width - 16`, :766) and the
/// anchor-center clamp inset inside the output rect (:784-787).
const double kDockPreviewMargin = 8;

/// Fit one card inside the preview budget without letterboxing its content —
/// the direct port of taskbar `_previewSize` (window_buttons.dart:914-919)
/// lifted onto raw doubles so `dart test` can cover it.
///
/// [sourceWidth]/[sourceHeight] are the window's `previewSize` components; an
/// empty (≤0 edge) or non-finite source falls back to
/// [kDockPreviewFallbackAspect]. The result keeps the source ratio and never
/// exceeds [maxWidth]×[maxHeight].
({double width, double height}) previewCardSize({
  required double sourceWidth,
  required double sourceHeight,
  required double maxWidth,
  required double maxHeight,
}) {
  final ratio =
      sourceWidth > 0 &&
          sourceHeight > 0 &&
          sourceWidth.isFinite &&
          sourceHeight.isFinite
      ? sourceWidth / sourceHeight
      : kDockPreviewFallbackAspect;
  final height = math.min(maxHeight, maxWidth / ratio);
  return (width: height * ratio, height: height);
}
