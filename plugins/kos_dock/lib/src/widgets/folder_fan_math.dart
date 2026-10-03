/// Pure geometry for the folder fan popup — line-for-line port of
/// `Common/functions/DockLayout.js:125-256` (`bottomFanBounds`,
/// `bottomFolderFan`, `folderFan`, `folderFanSlot`) with no Flutter
/// dependency so it can be unit tested with `dart test`.
///
/// The scroll viewport uses uniform [FolderFanGeometry.step]s, while each
/// row's icon and label share a tangent to this arc. Longer fans bend
/// farther without tightening the gap between neighbours. Bounds include
/// the rotated labels and the trailing action tile.
library;

import 'dart:math' as math;

/// Dock edge the fan expands from — the `edge` string of
/// `DockLayout.folderFan` (:195). `top`/`hidden` share the bottom path
/// like the source's `edge === "bottom"` test (:200).
enum FolderFanEdge {
  bottom,
  left,
  right;

  /// `edge === "bottom"` (:200) — the vertical arc / bisected outset path.
  bool get isBottom => this == FolderFanEdge.bottom;
}

/// Fan bounds rect — `bottomFanBounds` return object (:133-139).
final class FolderFanBounds {
  const FolderFanBounds({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;
}

/// One tile's rect + rotation — `folderFanSlot` return object
/// (:242-245, :252-255). `x`/`y` are the tile's top-left inside the fan
/// surface; [rotation] is in degrees (QML `rotation` unit).
final class FolderFanSlot {
  const FolderFanSlot({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
}

/// The `geometry` object produced by `folderFan` (:195-232) /
/// `bottomFolderFan` (:142-193). Fields that exist on only one branch are
/// `null` on the other: [angle]/[radius]/[originX]/[originY] are
/// bottom-only, [outset]/[padding]/[distance] are left/right-only.
final class FolderFanGeometry {
  FolderFanGeometry({
    required this.width,
    required this.height,
    required this.count,
    required this.step,
    required this.header,
    required this.stackReserve,
    required this.iconSize,
    required this.iconInset,
    required this.tileWidth,
    required this.tileHeight,
    required this.slots,
    this.originX,
    this.originY,
    this.angle,
    this.radius,
    this.outset,
    this.padding,
    this.distance,
  });

  double width;
  double height;
  int count;
  double step;

  /// `header = height − shown*step` (:191) — bottom edge's logical
  /// viewport offset; `0` on the horizontal edges (:223).
  double header;
  double stackReserve;
  double iconSize;
  double iconInset;
  double tileWidth;
  double tileHeight;
  double? originX;
  double? originY;
  double? angle; // radians — bottom edge only (:154)
  double? radius; // bottom edge only (:171)
  double? outset; // left/right edges only (:218-219)
  double? padding; // left/right edges only (:209)
  double? distance; // left/right edges only (:217)

  final List<FolderFanSlot> slots;
}

/// `bottomFanBounds(geometry)` (DockLayout.js:125-140).
///
/// Bounds include the rotated labels and the action tile; the lower left
/// corner briefly swings left before following the arc (:131-132).
FolderFanBounds bottomFanBounds(FolderFanGeometry geometry) {
  final halfHeight = geometry.tileHeight / 2;
  final pivot = geometry.tileWidth - geometry.iconSize / 2 - 6;
  final right = geometry.iconSize / 2 + 6;
  final angle = geometry.angle!;
  final radius = geometry.radius!;
  // The lower left corner briefly swings left before following the arc.
  final leftAngle = math.min(angle, math.atan2(halfHeight, radius + pivot));
  return FolderFanBounds(
    left: radius -
        (radius + pivot) * math.cos(leftAngle) -
        halfHeight * math.sin(leftAngle),
    right: radius * (1 - math.cos(angle)) +
        right * math.cos(angle) +
        halfHeight * math.sin(angle),
    top: angle > 0
        ? -(radius + pivot) * math.sin(angle) - halfHeight * math.cos(angle)
        : -geometry.count * geometry.step -
            geometry.stackReserve -
            halfHeight,
    bottom: halfHeight,
  );
}

/// `bottomFolderFan(count, availableWidth, availableHeight,
/// requestedIconSize, maximumOutset)` (DockLayout.js:142-193).
FolderFanGeometry bottomFolderFan(
  int count,
  double availableWidth,
  double availableHeight,
  double requestedIconSize,
  double maximumOutset,
) {
  const padding = 8;
  final iconSize = math.max(
    1.0,
    math.min(
      requestedIconSize,
      math.min(
        availableWidth - padding * 2 - 18,
        availableHeight - padding * 2 - 8,
      ),
    ),
  );
  final step = iconSize + math.max(12, iconSize * 0.16);
  final preferredWidth =
      iconSize + 18 + math.max(260, math.min(440, iconSize * 4.5));
  final geometry = FolderFanGeometry(
    width: 0,
    height: 0,
    count: 0,
    step: step,
    header: 0,
    stackReserve: 0,
    iconSize: iconSize,
    iconInset: 0,
    tileWidth: 0,
    tileHeight: iconSize + 8,
    slots: [],
  );
  var shown = math
      .max(
        0,
        math.min(
          count,
          math.min(
            8,
            ((availableHeight - iconSize - 8 - padding * 2) / step).floor(),
          ),
        ),
      )
      .toInt();
  FolderFanBounds bounds;
  do {
    geometry.count = shown;
    geometry.stackReserve = count > shown && shown > 0 ? 24 : 0;
    geometry.angle = shown > 0
        ? math.min(16, 6 + shown) * math.pi / 180
        : 0;
    final distance = shown * step + geometry.stackReserve;
    // Near an output edge, straighten the same arc rather than shifting
    // its foot away from the folder. The label still faces inward.
    if (maximumOutset.isFinite && shown > 0) {
      var low = 0.0;
      var high = geometry.angle!;
      for (var i = 0; i < 16; ++i) {
        final angle = (low + high) / 2;
        final outset = distance / angle * (1 - math.cos(angle)) +
            (iconSize / 2 + 6) * math.cos(angle) +
            geometry.tileHeight / 2 * math.sin(angle) +
            padding;
        if (outset <= maximumOutset - 1) {
          low = angle;
        } else {
          high = angle;
        }
      }
      geometry.angle = low;
    }
    geometry.radius = geometry.angle! > 0 ? distance / geometry.angle! : 0;
    geometry.tileWidth = preferredWidth;
    bounds = bottomFanBounds(geometry);
    final overflow =
        bounds.right - bounds.left + padding * 2 - availableWidth;
    if (overflow > 0) {
      geometry.tileWidth = math.max(
        iconSize + 18,
        preferredWidth - overflow / math.cos(geometry.angle!),
      );
      bounds = bottomFanBounds(geometry);
    }
    if (bounds.right - bounds.left + padding * 2 <= availableWidth &&
            bounds.bottom - bounds.top + padding * 2 <= availableHeight ||
        shown == 0) {
      break;
    }
    --shown;
  } while (true);
  geometry.width = math.min(
    availableWidth,
    (bounds.right - bounds.left + padding * 2).ceilToDouble(),
  );
  geometry.height = math.min(
    availableHeight,
    (bounds.bottom - bounds.top + padding * 2).ceilToDouble(),
  );
  geometry.originX = padding - bounds.left;
  geometry.originY = geometry.height - padding - bounds.bottom;
  geometry.iconInset = geometry.width - geometry.originX!;
  // ListView's logical viewport stays rectangular. Its delegates map
  // their fractional scroll positions onto the same curve as the fixed
  // action tile.
  geometry.header = geometry.height - shown * step;
  return geometry;
}

/// `folderFan(edge, count, maximumWidth, maximumHeight, labelsLeft,
/// requestedIconSize, maximumOutset)` (DockLayout.js:195-232).
FolderFanGeometry folderFan({
  required FolderFanEdge edge,
  required int count,
  required double maximumWidth,
  required double maximumHeight,
  required bool labelsLeft,
  required double requestedIconSize,
  double maximumOutset = double.infinity,
}) {
  final availableWidth = math.max(0.0, maximumWidth);
  final availableHeight = math.max(0.0, maximumHeight);
  // :198 `Math.max(64, Math.round(requestedIconSize || 64))` — `||` swaps
  // falsy (0/NaN) requests for the 64 default.
  final requested =
      requestedIconSize == 0 || requestedIconSize.isNaN ? 64.0 : requestedIconSize;
  final iconSize = math.max(64, requested.round()).toDouble();
  final FolderFanGeometry geometry;
  if (edge.isBottom) {
    geometry = bottomFolderFan(
      count,
      availableWidth,
      math.min(
        availableHeight,
        math.max(iconSize + 24, availableHeight * 0.75),
      ),
      iconSize,
      maximumOutset,
    );
  } else {
    // Reserve a final tile for open/back on the same horizontal arc.
    // Keep labels close to their icons and include rotated corners in
    // the bounds.
    final size = math.max(
      1.0,
      math.min(
        iconSize.toDouble(),
        math.min(
          (availableWidth - 32) / 1.5,
          (availableHeight - 68) / 1.4,
        ),
      ),
    );
    final tileHeight = size + 38;
    final tilt = 10 * math.pi / 180;
    final padding = (tileHeight * math.sin(tilt) + 12).ceilToDouble();
    final tileWidth = math.max(
      1.0,
      math.min(math.max(100.0, size + 32), availableWidth - padding * 2),
    );
    final step = tileWidth + 12;
    var shown = math
        .max(
          0,
          math.min(
            count,
            math.min(
              8,
              ((availableWidth - padding * 2 - tileWidth) / step).floor(),
            ),
          ),
        )
        .toInt();
    if (count > shown &&
        shown * step + tileWidth + padding * 2 + 24 > availableWidth) {
      shown = math.max(0, shown - 1);
    }
    final stackReserve = count > shown && shown > 0 ? 24.0 : 0.0;
    final distance = shown * step + stackReserve;
    final outset = math.max(
      0.0,
      math.min(
        32.0,
        math.min(
          distance * math.tan(tilt) / 2,
          availableHeight - tileHeight - padding * 2,
        ),
      ),
    );
    geometry = FolderFanGeometry(
      width: math.min(availableWidth, distance + tileWidth + padding * 2),
      height: math.min(availableHeight, tileHeight + outset + padding * 2),
      count: shown,
      step: step,
      header: 0,
      stackReserve: stackReserve,
      iconSize: size,
      iconInset: padding + tileWidth / 2,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      outset: outset,
      padding: padding,
      distance: distance,
      slots: [],
    );
  }
  for (var i = 0; i < geometry.count; ++i) {
    geometry.slots.add(
      folderFanSlot(edge, i.toDouble(), geometry, labelsLeft),
    );
  }
  return geometry;
}

/// `folderFanSlot(edge, position, geometry, labelsLeft)`
/// (DockLayout.js:234-256). [position] may exceed `geometry.count` — the
/// action tile asks for `slot(count)` (`DockFolderFan.qml:146`) which
/// picks up the [FolderFanGeometry.stackReserve].
FolderFanSlot folderFanSlot(
  FolderFanEdge edge,
  double position,
  FolderFanGeometry geometry,
  bool labelsLeft,
) {
  if (edge.isBottom) {
    final distance = position * geometry.step +
        (position >= geometry.count ? geometry.stackReserve : 0);
    final radius = geometry.radius!;
    final angle = radius > 0 ? distance / radius : 0.0;
    final arcX = geometry.originX! + radius * (1 - math.cos(angle));
    final centerX = labelsLeft ? arcX : geometry.width - arcX;
    final iconOffset = geometry.iconSize / 2 + 6;
    final pivotX = labelsLeft ? geometry.tileWidth - iconOffset : iconOffset;
    return FolderFanSlot(
      x: centerX - pivotX,
      y: geometry.originY! -
          (radius > 0 ? radius * math.sin(angle) : distance) -
          geometry.tileHeight / 2,
      width: geometry.tileWidth,
      height: geometry.tileHeight,
      rotation: (labelsLeft ? 1 : -1) * angle * 180 / math.pi,
    );
  }
  final distance = position * geometry.step +
      (position >= geometry.count ? geometry.stackReserve : 0);
  final totalDistance = geometry.distance!;
  final fraction = totalDistance > 0 ? distance / totalDistance : 0.0;
  final x = geometry.padding! + distance;
  final angle = totalDistance > 0
      ? math.atan2(-2 * geometry.outset! * fraction, totalDistance) *
          180 /
          math.pi
      : 0.0;
  return FolderFanSlot(
    x: edge == FolderFanEdge.left
        ? x
        : geometry.width - x - geometry.tileWidth,
    y: geometry.padding! + geometry.outset! * (1 - fraction * fraction),
    width: geometry.tileWidth,
    height: geometry.tileHeight,
    rotation: edge == FolderFanEdge.left ? angle : -angle,
  );
}
