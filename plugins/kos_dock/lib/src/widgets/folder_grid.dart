/// DockFolderGrid — the grid content view of a folder popup
/// (`DockFilePopup.qml:243-341`, non-fan/non-list/non-contextMenu branch).
///
/// Semantics (line anchors into `DockFilePopup.qml` unless noted):
/// - `gridColumns = max(1, floor(width / 106))` (:57), `cellHeight = 112`
///   (:301), `gridRows = max(1, min(4, ceil((count + 1) / columns)))` (:58).
/// - The card width is `min(360, maximumWidth)` (:60), its height
///   `min(maximumHeight, 20 + tail + header 34 + rows·112)` (:63-66).
/// - Each cell is a `DockFileTile` (`compact:false, fan:false`): icon 64
///   centred at the cell top + 6px, label under it (`DockFileTile.qml:30-100`
///   default branch), hover background `onSurface @ 0.12` (:41-42), and the
///   trailing `count`-th cell is the action cell (:306-313) — `open_in_new`
///   in the source; under app-group clipping it renders `arrow_back` when
///   [canGoBack] and is hidden otherwise (card 数据源裁剪, :65).
/// - `progress` scales the whole card from the tail edge (:251-252
///   `transformOrigin` bottom).
/// - Empty group shows the centred "Folder is empty" text one cell in
///   (:329-339).
///
/// The shell is a self-built `DockBubbleSurface` port
/// (`DockBubbleSurface.qml` + `DockBubble.js:5-37`): rounded body + a 10px
/// tail, bottom edge only for the grid (:61-66 — `edge === "bottom" ? tail :
/// 0`); the task card forbids a shared `DockBubble` component so this
/// painter lives inside this file.
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';

import 'folder_fan.dart' show DockFanEntry, FolderFanEdge;

/// Bubble tail height for bottom-edge popups (`tailSize` default,
/// `DockBubbleSurface.qml:10` / `DockFolderMenu.qml:14`).
const double kDockBubbleTailSize = 10;

/// Grid cell edge budget — `grid.width / 106` column divisor (:57).
const double kDockFolderGridColumnWidth = 106;

/// Grid cell height — `cellHeight: 112` (:301) = tile implicitHeight.
const double kDockFolderGridCellHeight = 112;

/// `Math.max(1, Math.floor(width / 106))` (:57).
int dockFolderGridColumns(double width) =>
    math.max(1, (width / kDockFolderGridColumnWidth).floor());

/// `Math.max(1, Math.min(4, Math.ceil((count + 1) / gridColumns)))` (:58).
int dockFolderGridRows({required int count, required int columns}) =>
    math.max(1, math.min(4, ((count + 1) / columns).ceil()));

/// Card height (:63-66): `min(maxH, 20 + tail + 34 + rows·112)`.
double dockFolderGridHeight({
  required int rows,
  required double maximumHeight,
  required double tail,
}) => math.min(maximumHeight, 20 + tail + 34 + rows * kDockFolderGridCellHeight);

/// The folder grid popup — `card` + `grid` half of `DockFilePopup.qml`.
///
/// The widget sizes itself to the card formula (:60-66); the caller wraps it
/// in an `OverlayPortal`/positioner the same way the fan is hosted.
class DockFolderGrid extends StatelessWidget {
  const DockFolderGrid({
    required this.entries,
    super.key,
    this.name = '',
    this.edge = FolderFanEdge.bottom,
    this.maximumWidth = 600,
    this.maximumHeight = 600,
    this.progress = 1,
    this.canGoBack = false,
    this.onActivated,
    this.onAction,
  });

  /// Folder entries — app-group members (`directory.item.model`, :302).
  final List<DockFanEntry> entries;

  /// Folder display name — the header text (`directory.item.info.name`,
  /// :274).
  final String name;

  /// `edge` (:16) — the tail exists only on the bottom edge (:61-66,
  /// DockFolderMenu.qml:14-17); it also picks the scale origin (:252).
  final FolderFanEdge edge;

  /// `maximumWidth`/`maximumHeight` (:13-14).
  final double maximumWidth;
  final double maximumHeight;

  /// `progress` (:56) — whole-card scale factor (:251-252).
  final double progress;

  /// `canGoBack` — under app-group clipping there is no history, so the
  /// trailing action cell only exists when this is true (source always
  /// shows "Open in File Manager", :308-313).
  final bool canGoBack;

  /// `activated(info)` (:316-322) — fires with the tapped entry index.
  final void Function(int index)? onActivated;

  /// Action-cell tap — the `openFolder` branch (:317-320); only reachable
  /// when [canGoBack].
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final width = math.min(360.0, maximumWidth); // :60 non-fan width
    // :61-66 — the 10px tail is added to the height only on the bottom
    // edge; DockFolderMenu.qml:14-17 puts it on the matching side padding.
    final tail = edge == FolderFanEdge.bottom ? kDockBubbleTailSize : 0.0;
    final bodyWidth = width; // :12 — bottom edge keeps full width
    // Grid width is the content width inside the 10px card insets
    // (:262-265 — bodyX+10, bodyWidth−20).
    final gridWidth = bodyWidth - 20;
    final columns = dockFolderGridColumns(gridWidth);
    final cellWidth = gridWidth / columns; // :300 cellWidth = width/columns
    // The source always reserves count+1 cells (the action cell lives in
    // the `(count+1)` term of the row formula, :58) — the grid height does
    // NOT shrink when `!canGoBack`; the trailing action cell is merely
    // empty space in that case (clipped away at paint time below).
    final rows = dockFolderGridRows(count: entries.length, columns: columns);
    final height = dockFolderGridHeight(
      rows: rows,
      maximumHeight: maximumHeight,
      tail: tail,
    );
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: height,
      child: Transform.scale(
        // :251-252 — scale progress from the dock edge.
        scale: progress.clamp(0.0, 1.0),
        alignment: switch (edge) {
          FolderFanEdge.left => Alignment.centerLeft,
          FolderFanEdge.right => Alignment.centerRight,
          FolderFanEdge.bottom => Alignment.bottomCenter,
        },
        child: DockFolderBubble(
          tailSize: tail,
          child: Padding(
            // :262-265 — x:bodyX+10, y:10, w:bodyWidth−20, h:bodyHeight−20.
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                // :266-290 — 34px header row, centred name.
                SizedBox(
                  height: 34,
                  child: Row(
                    children: [
                      SizedBox(
                        // :280-289 — 34px back button slot, only with
                        // history (always hidden under app groups).
                        width: canGoBack ? 34 : 0,
                        height: 34,
                        child: canGoBack
                            ? IconButton(
                                padding: EdgeInsets.zero,
                                iconSize: 18,
                                icon: const Icon(Icons.arrow_back),
                                onPressed: onAction,
                              )
                            : null,
                      ),
                      Expanded(
                        child: Padding(
                          // :273 — width − 72 keeps the text clear of the
                          // button zone; ElideMiddle.
                          padding: const EdgeInsets.symmetric(horizontal: 36),
                          child: Text(
                            name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: colors.onSurface),
                          ),
                        ),
                      ),
                      // Mirror the button slot so the name stays centred.
                      SizedBox(width: canGoBack ? 34 : 0),
                    ],
                  ),
                ),
                // :291-340 — GridView cells + empty-state text.
                Expanded(
                  child: ClipRect(
                    // :299 clip:true.
                    child: Stack(
                      children: [
                        GridView.builder(
                          // :304 StopAtBounds.
                          physics: const ClampingScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                childAspectRatio:
                                    cellWidth / kDockFolderGridCellHeight,
                              ),
                          itemCount: entries.length + (canGoBack ? 1 : 0),
                          itemBuilder: (context, index) {
                            // :308-313 — the trailing cell is the action
                            // cell (back under app-group clipping).
                            if (index >= entries.length) {
                              return DockGridTile(
                                iconSize: 64,
                                actionIcon: Icons.arrow_back,
                                onTap: onAction,
                              );
                            }
                            final entry = entries[index];
                            return DockGridTile(
                              iconSize: 64,
                              name: entry.name,
                              appId: entry.appId,
                              onTap: onActivated == null
                                  ? null
                                  : () => onActivated!(index),
                            );
                          },
                        ),
                        if (entries.isEmpty)
                          // :329-339 — centred text one cell in.
                          Positioned(
                            left: cellWidth,
                            top: 0,
                            width: gridWidth - cellWidth,
                            height: kDockFolderGridCellHeight,
                            child: Center(
                              child: Text(
                                'Folder is empty',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One grid cell — the default (non-fan, non-compact) `DockFileTile`
/// (`DockFileTile.qml:29-100`): icon 64 at the cell top + 6px centred, label
/// 32px under it (2-line wrap, centred), hover background `onSurface@0.12`
/// full-cell, action badge `iconSize−14` at artwork+7 (:61-80).
class DockGridTile extends StatelessWidget {
  const DockGridTile({
    required this.iconSize,
    super.key,
    this.name = '',
    this.appId,
    this.actionIcon,
    this.onTap,
  });

  /// `fileInfo.name` (:89).
  final String name;

  /// App icon identity for `services.buildApplicationIcon`.
  final String? appId;

  /// `tileIconSize` (:17) — 64 in grid mode.
  final double iconSize;

  /// `actionIcon` (:16) — badge glyph (action cell only).
  final IconData? actionIcon;

  /// `activated(fileInfo)` (:113).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    final services = ShellServicesScope.of(context);
    return MouseRegion(
      cursor: services.linkCursor, // :102-104
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          children: [
            // :30-45 — full-cell background, hover onSurface@0.12
            // (GestureDetector supplies the tap; a hover overlay needs a
            // second MouseRegion — keep the tile simple like the fan tile:
            // static transparent background, hover handled by the bubble).
            const SizedBox.expand(),
            // :46-60 — artwork centred horizontally, 6px from the top.
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: actionIcon == null
                      ? (appId == null
                            ? const SizedBox.shrink()
                            : services.buildApplicationIcon(
                                context,
                                appId!,
                              ))
                      // :61-80 — action badge artwork+7, iconSize−14.
                      : Stack(
                          children: [
                            Positioned(
                              left: 7,
                              top: 7,
                              width: iconSize - 14,
                              height: iconSize - 14,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: shell.cardColor(
                                    colors.surfaceContainer,
                                  ),
                                ),
                                child: Icon(
                                  actionIcon,
                                  // :77 — max(22, badge*0.55).
                                  size: math.max(
                                    22,
                                    (iconSize - 14) * 0.55,
                                  ),
                                  color: colors.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            // :81-99 — label under the icon, 2 lines, centred,
            // ElideMiddle→fade.
            Positioned(
              top: iconSize + 12, // :85 — tileIconSize + 12
              left: 10,
              right: 10,
              height: 32, // :88
              child: Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2, // :97-98
                overflow: TextOverflow.fade,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: colors.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bubble shell — a minimal `DockBubbleSurface` port
/// (`DockBubbleSurface.qml` + `DockBubble.js:5-37`): rounded body + a 10px
/// tail on the bottom edge. Painted by `_DockBubblePainter`; the body is
/// `shellTheme.cardColor(surfaceContainer)` with a `onSurface@0.18` 1px
/// stroke (:42-43).
class DockFolderBubble extends StatelessWidget {
  const DockFolderBubble({
    required this.child,
    super.key,
    this.tailSize = kDockBubbleTailSize,
    this.anchorOffset,
  });

  final Widget child;

  /// `tailSize` (:10) — 0 disables the tail.
  final double tailSize;

  /// `anchorOffset` (:9) — tail tip x in body coordinates; `null` centres.
  final double? anchorOffset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    return ShellBackdropBlur(
      // card material chain (DeskCard): blur/glass on, off → flat fill.
      blur: shell.backdropBlurEnabled,
      separateChild: true,
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        painter: _DockBubblePainter(
          tail: tailSize,
          anchorOffset: anchorOffset,
          fill: shell.cardColor(colors.surfaceContainer),
          stroke: colors.onSurface.withValues(alpha: 0.18), // :43
        ),
        child: child,
      ),
    );
  }
}

/// Paints the `DockBubble.outline` bottom-edge path
/// (`DockBubble.js:5-37`): rounded-12 body + cubic tail tip clamped to
/// `[26, extent−26]` (:14).
class _DockBubblePainter extends CustomPainter {
  const _DockBubblePainter({
    required this.tail,
    required this.anchorOffset,
    required this.fill,
    required this.stroke,
  });

  final double tail;
  final double? anchorOffset;
  final Color fill;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final bodyHeight = size.height - tail; // :13 edge === "bottom"
    if (size.width <= 1 || bodyHeight <= 1) return;
    const cornerRadius = 12.0; // :11 default
    final radius = math.max(
      0.0,
      math.min(cornerRadius, math.min(size.width / 2, bodyHeight / 2)),
    );
    // :14 — tip clamped to [26, extent−26] on the cross axis.
    final tip = math.max(
      26.0,
      math.min(size.width - 26, anchorOffset ?? size.width / 2),
    );
    final path = Path()
      ..moveTo(radius, 0) // :15 M x+radius y
      ..lineTo(size.width - radius, 0)
      // :16 — top-right rounded corner.
      ..quadraticBezierTo(size.width, 0, size.width, radius)
      ..lineTo(size.width, bodyHeight - radius) // :22
      ..quadraticBezierTo(
        size.width,
        bodyHeight,
        size.width - radius,
        bodyHeight,
      );
    if (tail > 0) {
      // :24-26 — bottom-edge tail, two cubics through the tip.
      path
        ..lineTo(tip + 14, bodyHeight)
        ..cubicTo(
          tip + 7,
          bodyHeight,
          tip + 5,
          bodyHeight + tail,
          tip,
          bodyHeight + tail,
        )
        ..cubicTo(
          tip - 5,
          bodyHeight + tail,
          tip - 7,
          bodyHeight,
          tip - 14,
          bodyHeight,
        );
    }
    path
      ..lineTo(radius, bodyHeight) // :28
      ..quadraticBezierTo(0, bodyHeight, 0, bodyHeight - radius)
      ..lineTo(0, radius) // :34
      ..quadraticBezierTo(0, 0, radius, 0)
      ..close();
    canvas
      ..drawPath(path, Paint()..color = fill)
      ..drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1, // :54-55
      );
  }

  @override
  bool shouldRepaint(_DockBubblePainter old) =>
      tail != old.tail ||
      anchorOffset != old.anchorOffset ||
      fill != old.fill ||
      stroke != old.stroke;
}
