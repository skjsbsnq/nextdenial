/// Pure math/constants for the DockItem widget — no Flutter dependency so the
/// geometry can be unit tested with `dart test`.
///
/// Source anchors are into quickshell `Modules/Dock/DockItem.qml`.
library;

import 'dart:math' as math;

/// Default icon edge (DockModel.js:7 `DockService.iconSize` default).
const double kDockItemDefaultIconSize = 48;

/// Product-set configurable range (brief §几何; not a source constant).
const double kDockItemMinIconSize = 32;
const double kDockItemMaxIconSize = 80;

/// Pointer displacement under which a press is still a click
/// (DockItem.qml:219 `Math.hypot(...) < 10`).
const double kDockItemDragThreshold = 10;

/// Icon opacity for unavailable apps with no window (DockItem.qml:126).
const double kDockItemUnavailableOpacity = 0.45;

/// Indicator alpha (DockItem.qml:188 `focused ? 1 : 0.8`).
const double kDockIndicatorActiveAlpha = 1.0;
const double kDockIndicatorInactiveAlpha = 0.8;

/// Running-indicator bar geometry. Denial replaces the source's circular dot
/// (`round(max(5, min(8, restingIconSize / 8)))`, DockItem.qml:183) with a small
/// rounded bar — an explicit product deviation recorded in
/// `docs/visual-deltas.md`. [kDockIndicatorBarRadius] is derived from the
/// thickness (`radius = width / 2`, :185).
const double kDockIndicatorBarLength = 10;
const double kDockIndicatorBarThickness = 3;
const double kDockIndicatorBarRadius = kDockIndicatorBarThickness / 2;

/// Band-bottom-relative offset of the bar's **top** edge — the Denial reading of
/// the source `y: height - 10` anchor (DockItem.qml:187). Primary geometry: the
/// bar spans `[kDockIndicatorBottomInset, kDockIndicatorTopOffset]` above the
/// band bottom.
const double kDockIndicatorTopOffset = 6;

/// Bar bottom edge inset from the band bottom, derived from the top offset and
/// the bar thickness. The Denial icon box is inset `kDockIconBottomInset` (9)
/// above the band bottom, so the bar (3..6) lands in the glass inset lane
/// *below* the resting icon with a 3px gap.
const double kDockIndicatorBottomInset =
    kDockIndicatorTopOffset - kDockIndicatorBarThickness;

/// Indicator alpha branch (DockItem.qml:188).
double dockIndicatorAlpha({required bool focused}) =>
    focused ? kDockIndicatorActiveAlpha : kDockIndicatorInactiveAlpha;

/// 10px displacement gate (DockItem.qml:219-222): a press only becomes a drag
/// once `hypot(dx, dy)` reaches the threshold — `< 10` stays a click.
bool dockDragGatePassed(double dx, double dy) =>
    math.sqrt(dx * dx + dy * dy) >= kDockItemDragThreshold;
