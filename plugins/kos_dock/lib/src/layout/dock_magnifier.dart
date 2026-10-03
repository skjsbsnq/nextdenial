/// Gaussian-magnification dock layout engine — pure Dart port.
///
/// Sources:
/// - `layout()` : quickshell/Common/functions/DockLayout.js:18-58
/// - `reconcile()`: quickshell/Common/functions/DockModel.js:226-243
///
/// No Flutter / `dart:ui` dependency; only `dart:math` is used, so the
/// layout can be computed synchronously on every animation frame and unit
/// tested with `dart test`.
library;

import 'dart:math' as math;

/// One laid-out dock entry, matching DockLayout.js:52
/// `{center, start, span, size}`.
final class DockSlot {
  const DockSlot({
    required this.center,
    required this.start,
    required this.span,
    required this.size,
  });

  /// Centre of the icon in the *unmagnified* base coordinate system.
  /// Magnification never feeds back into [center] (DockLayout.js:16-17,47-48).
  final double center;

  /// Leading edge in the magnified coordinate system (post-scale cursor).
  final double start;

  /// Magnified slot footprint including the trailing gap:
  /// `size * weight * scale + gap` (DockLayout.js:51).
  final double span;

  /// Magnified icon edge length: `size * scale` (DockLayout.js:52).
  final double size;
}

/// Return value of [layout], matching DockLayout.js:56-57.
final class DockLayoutResult {
  const DockLayoutResult({
    required this.size,
    required this.baseLength,
    required this.length,
    required this.slots,
    required this.divider,
    required this.dividers,
    required this.overflow,
  });

  /// Base (unmagnified) icon edge length chosen for this pass.
  final double size;

  /// Total row length with every icon at `scale = 1`.
  final double baseLength;

  /// Total magnified row length (`cursor + padding`, DockLayout.js:56).
  final double length;

  /// Slot geometry, one per input kind, in order.
  final List<DockSlot> slots;

  /// Axis position of the last section divider (`-1` when none).
  final double divider;

  /// Axis positions of all section dividers, in order.
  final List<double> dividers;

  /// `baseLength + reserve * size > available` (DockLayout.js:57) — uses the
  /// base length, not the magnified [length].
  final bool overflow;
}

/// Lays out one dock row with a Gaussian magnification wave.
///
/// Line-for-line port of DockLayout.js:18-58:
/// ```
/// scale = 1 + A*(M-1)*exp(-d²/2),  d = (pointer - center) / (size + gap)
/// ```
/// with `M = clamp(magnification, 1, 2)` and `A = clamp(strength, 0, 1)`.
///
/// - [kinds]: entry kind per slot; `"small-spacer"` gets weight 0.5, every
///   other kind weight 1 (DockLayout.js:22).
/// - [pointer]: pointer axis position already expressed in the *unmagnified
///   base coordinate system* — conversion (`pointerAxis - (axisLength -
///   min(baseLength, availableLength))/2 + scrollOffset`, DockSurface.qml:
///   77-81) is the caller's job. A non-finite [pointer] (NaN/±Infinity)
///   yields `scale = 1` for every slot (DockLayout.js:50).
/// - [sectionBoundary]: sorted-or-not list of slot indices that open a new
///   section; values are filtered to `v > 0 && v < count` and de-duplicated
///   preserving order (DockLayout.js:28-29). Callers with a scalar boundary
///   wrap it in a single-element list (JS accepts both via `Array.isArray`).
/// - [strength]: amplitude envelope `A`. The caller animates it with a 220 ms
///   `easeOutCubic` ramp (hover in 0→1, out 1→0) and calls [layout] again
///   every frame with the current `A`. Slot `start`/`span` must never be
///   interpolated — that feedback loop is what makes a dock chase the
///   pointer (DockLayout.js:16-17,25-27). This function holds no timers or
///   state; identical inputs always produce identical outputs.
DockLayoutResult layout({
  required List<String> kinds,
  required double preferredSize,
  required double available,
  required double magnification,
  required double sectionSpacing,
  required double pointer,
  List<int> sectionBoundary = const <int>[],
  double strength = 1,
}) {
  const gap = 8.0; // DockLayout.js:19
  const padding = 12.0; // DockLayout.js:20
  final count = kinds.length; // :21
  final weights = <double>[
    // :22 — "small-spacer" weighs half a slot.
    for (final kind in kinds) kind == 'small-spacer' ? 0.5 : 1.0,
  ];
  final apps = weights.fold<double>(0, (sum, weight) => sum + weight); // :23
  final maximum = math.max(1.0, math.min(2.0, magnification)); // :24
  // :25-27 — fade the wave by amplitude only; the reserved space and the
  // wave centre never animate, so the dock cannot chase the pointer.
  final amplitude = math.max(0.0, math.min(1.0, strength));
  // :28-29 — filter `v > 0 && v < count`, keep first occurrence order.
  final boundaries = <int>[];
  final seen = <int>{};
  for (final value in sectionBoundary) {
    if (value > 0 && value < count && seen.add(value)) {
      boundaries.add(value);
    }
  }
  final sectionGap = sectionSpacing + gap; // :30
  final fixed =
      count * gap + padding * 2 + sectionGap * boundaries.length; // :31
  final reserve = math.min(apps, 5.0) * (maximum - 1); // :32
  final size = math.max(
    32.0,
    math.min(preferredSize, (available - fixed) / math.max(1.0, apps + reserve)),
  ); // :33
  final baseLength = fixed + apps * size; // :34
  var baseCursor = padding; // :35
  var cursor = padding; // :36
  var divider = -1.0; // :37
  final dividers = <double>[]; // :38
  final slots = <DockSlot>[]; // :39
  for (var index = 0; index < count; ++index) {
    // :40
    if (boundaries.contains(index)) {
      // :41-46 — divider sits mid-section-gap, then both cursors step.
      divider = cursor + sectionGap / 2;
      dividers.add(divider);
      baseCursor += sectionGap;
      cursor += sectionGap;
    }
    final baseSpan = size * weights[index] + gap; // :47
    // :48 — centre is computed in the unmagnified base system so the wave
    // never feeds on its own displacement.
    final center = baseCursor + baseSpan / 2;
    final distance = (pointer - center) / (size + gap); // :49
    // :50 — non-finite pointer => no magnification at all.
    final scale = !pointer.isFinite
        ? 1.0
        : 1 + amplitude * (maximum - 1) * math.exp(-distance * distance / 2);
    final span = size * weights[index] * scale + gap; // :51
    slots.add(
      DockSlot(center: center, start: cursor, span: span, size: size * scale),
    ); // :52
    baseCursor += baseSpan; // :53
    cursor += span; // :54
  }
  // :56-57
  return DockLayoutResult(
    size: size,
    baseLength: baseLength,
    length: cursor + padding,
    slots: slots,
    divider: divider,
    dividers: dividers,
    overflow: baseLength + reserve * size > available,
  );
}

/// Mutable row list with the QML `ListModel` operation set that
/// `reconcile()` drives — `count`/`get`/`remove`/`insert`/`move`/
/// `setProperty` of DockModel.js:226-243. Implementations keep element
/// identity: [remove]/[move] relocate existing entries, [insert] adopts the
/// given row, and [setProperty] mutates an entry's role in place so the
/// widget layer can keep delegate identity.
abstract interface class DockReconcileModel<E> {
  /// Number of rows currently in the model (`model.count`).
  int get count;

  /// Row at [index] (`model.get(index)`).
  E get(int index);

  /// Removes the row at [index] (`model.remove(index)`).
  void remove(int index);

  /// Inserts [row] so it lands at [index] (`model.insert(index, row)`).
  void insert(int index, E row);

  /// Moves the row at [from] to [to] (`model.move(from, to, 1)`).
  void move(int from, int to);

  /// Sets [role] on the row at [index] to [value]
  /// (`model.setProperty(index, role, value)`).
  void setProperty(int index, String role, Object? value);
}

/// Minimal-diff reconciliation, ported from DockModel.js:226-243.
///
/// Two passes preserving element identity:
/// 1. Reverse scan removing every model entry whose key is not in [rows]
///    (`!wanted`).
/// 2. Forward scan aligning by key: missing key → `insert(index, row)`;
///    key found later → `move(current, index)`; then for each role of the
///    row, `setProperty(index, role, value)` when the kept entry differs.
///
/// [keyOf] extracts a row's identity key, [rolesOf] lists the roles stored
/// on a wanted row (mirroring `Object.keys(row)` — include the key role if
/// it is a stored role; the same-key comparison makes it a no-op), and
/// [roleOf] reads a role value for the `!==` comparison.
void reconcile<E>(
  DockReconcileModel<E> model,
  List<E> rows, {
  required Object? Function(E entry) keyOf,
  required Iterable<String> Function(E row) rolesOf,
  required Object? Function(E entry, String role) roleOf,
}) {
  // :227-230 — drop everything unwanted, back to front so indices stay valid.
  final wanted = <Object?>{for (final row in rows) keyOf(row)};
  for (var index = model.count - 1; index >= 0; index--) {
    if (!wanted.contains(keyOf(model.get(index)))) model.remove(index);
  }
  // :231-243 — align forward: insert, move, then per-role setProperty.
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    var current = index;
    while (current < model.count && keyOf(model.get(current)) != keyOf(row)) {
      current++;
    }
    if (current == model.count) {
      model.insert(index, row); // :235
    } else {
      if (current != index) model.move(current, index); // :237
      final previous = model.get(index);
      for (final role in rolesOf(row)) {
        // :239-240
        if (roleOf(previous, role) != roleOf(row, role)) {
          model.setProperty(index, role, roleOf(row, role));
        }
      }
    }
  }
}
