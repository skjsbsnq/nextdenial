/// DockFolderFan — the fan (弧形展开) content view of a folder popup.
///
/// Semantics port (line anchors are into quickshell
/// `Modules/Dock/DockFolderFan.qml` unless noted):
/// - tiles interpolate from [sourceCenter] to their arc slot
///   (`finalX/finalY` :105-116); rotation is `slot.rotation · progress`
///   (:124), scale `(0.7 + 0.3·progress) · 0.94^stackDepth` (:126-131).
/// - `opacity = min(1, 2·progress) · min(1, position+1) ·
///   (1 − stackDepth/4)` three-factor product (:117-118); rows are
///   `visible ⇔ position > −1 && stackDepth < 4` (:91) and only
///   `stackDepth < 0.001` accepts input (:100, :74).
/// - `labelReveal = max(0, (progress−0.4)/0.6) · 0.42^stackDepth` — labels
///   lag the unfold by 40 % (:119).
/// - overflow stack offsets split by edge: bottom edge shifts x by
///   `stackDepth·(labelsLeft ? 3 : −3)` and y by `−7·stackDepth`; left /
///   right shift x by `±7·stackDepth` with no y change (:105-111).
/// - the trailing action tile (open/back) sits at `slot(count)` (:146).
/// - opening 260 ms / closing 180 ms `easeOutCubic`
///   (`DockFilePopup.qml:136-143`).
///
/// Scrolling replaces the QML `ListView` delegation trick (card 注意):
/// tiles live in a scroll-content strip of `count·step` and are mapped
/// back to the arc by their fractional `position = index − scrollOffset`
/// — the exact position→slot mapping of :82-90.
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';

import 'folder_fan_math.dart';

export 'folder_fan_math.dart';

/// Fan open duration (`DockFilePopup.qml:141` — fan branch 260ms).
const Duration kDockFolderFanOpenDuration = Duration(milliseconds: 260);

/// Fan close duration (`DockFilePopup.qml:140` — `to:0` 180ms).
const Duration kDockFolderFanCloseDuration = Duration(milliseconds: 180);

/// One entry in a folder popup — the app-group equivalent of a
/// `fileInfo` record (`{name, icon}`; directories don't exist under the
/// app-group semantics, card 数据源裁剪).
final class DockFanEntry {
  const DockFanEntry({required this.name, required this.appId});

  /// Row label (`info.name`).
  final String name;

  /// Icon identity for `services.buildApplicationIcon`.
  final String appId;
}

/// `stackDepth = max(0, position − count + 1)` (:87).
double dockFanStackDepth(double position, int count) =>
    math.max(0, position - count + 1);

/// Three-factor opacity product (:117-118).
double dockFanTileOpacity({
  required double progress,
  required double position,
  required double stackDepth,
}) =>
    math.min(1, progress * 2) *
    math.min(1, position + 1) *
    (1 - stackDepth / 4);

/// `labelReveal = max(0, (progress − 0.4) / 0.6) · 0.42^stackDepth` (:119).
double dockFanLabelReveal({
  required double progress,
  required double stackDepth,
}) =>
    math.max(0, (progress - 0.4) / 0.6) * math.pow(0.42, stackDepth).toDouble();

/// `(0.7 + 0.3·progress) · 0.94^stackDepth` (:126-131).
double dockFanTileScale({
  required double progress,
  required double stackDepth,
}) => (0.7 + 0.3 * progress) * math.pow(0.94, stackDepth).toDouble();

/// Per-layer stack offset on the tile's x (:105-111): bottom edge
/// `±3·depth` by [labelsLeft], horizontal edges `±7·depth` by edge.
double dockFanStackShiftX({
  required FolderFanEdge edge,
  required bool labelsLeft,
  required double stackDepth,
}) {
  if (edge == FolderFanEdge.bottom) {
    return stackDepth * (labelsLeft ? 3 : -3);
  }
  return stackDepth * (edge == FolderFanEdge.left ? 7 : -7);
}

/// Per-layer stack offset on the tile's y (:111): bottom edge only,
/// `−7·depth` (the subtraction of :111 is folded in by the caller).
double dockFanStackShiftY({
  required FolderFanEdge edge,
  required double stackDepth,
}) => edge == FolderFanEdge.bottom ? stackDepth * 7 : 0;

/// One folder-app tile — the `DockFileTile` port in `fan` /
/// `verticalLabel` modes (`DockFileTile.qml:30-100`): a 28px glass label
/// pill facing the arc's label side, the app icon 6px inside the opposite
/// tile edge, and an optional circular action badge over the icon.
class DockFanTile extends StatelessWidget {
  const DockFanTile({
    required this.iconSize,
    super.key,
    this.name = '',
    this.appId,
    this.verticalLabel = false,
    this.labelsLeft = true,
    this.labelReveal = 1,
    this.actionIcon,
    this.onTap,
  });

  /// `fileInfo.name` (:89) — label text.
  final String name;

  /// App icon identity for `services.buildApplicationIcon`; `null`
  /// renders an empty icon box.
  final String? appId;

  /// `verticalLabel` (:13) — label under the icon on horizontal fans.
  final bool verticalLabel;

  /// `labelsLeft` (:14) — which side the label pill faces on the bottom
  /// fan.
  final bool labelsLeft;

  /// `labelReveal` (:15) — pill/text opacity (:38, :99).
  final double labelReveal;

  /// Icon edge (`tileIconSize`, :17).
  final double iconSize;

  /// `actionIcon` (:16) — badge glyph over the icon (open_in_new /
  /// arrow_back); `null` hides the badge and shows [appId]'s icon (:52).
  final IconData? actionIcon;

  /// `activated(fileInfo)` (:113).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    final services = ShellServicesScope.of(context);
    // DockFileIcon artwork (:46-60); actionBackground (:61-80) is a
    // circular badge centred on the artwork (x/y + 7, edge iconSize−14).
    final artworkStack = SizedBox(
      width: iconSize,
      height: iconSize,
      child: Stack(
        children: [
          if (actionIcon == null)
            Positioned.fill(
              child: appId == null
                  ? const SizedBox.shrink()
                  : services.buildApplicationIcon(context, appId!),
            )
          else
            Positioned(
              left: 7,
              top: 7,
              width: iconSize - 14,
              height: iconSize - 14,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle, // :68
                  color: shell.cardColor(colors.surfaceContainer), // :70
                ),
                child: Icon(
                  actionIcon,
                  // :77 — max(22, badge*0.55).
                  size: math.max(22, (iconSize - 14) * 0.55),
                  color: colors.onSurface,
                ),
              ),
            ),
        ],
      ),
    );
    final label = Text(
      name,
      maxLines: 1,
      softWrap: false, // :97 NoWrap
      overflow: TextOverflow.fade, // :96 ElideMiddle
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: colors.onSurface),
    );
    final content = verticalLabel
        ? Stack(
            children: [
              const SizedBox.expand(),
              // :53-59 — icon centred horizontally at the tile top.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(child: artworkStack),
              ),
              // :83-95 — 28px label row pinned to the tile bottom.
              Positioned(
                left: 10,
                right: 10,
                bottom: 0,
                height: 28,
                child: Opacity(
                  opacity: labelReveal,
                  child: Center(child: label),
                ),
              ),
            ],
          )
        : Stack(
            clipBehavior: Clip.none,
            children: [
              const SizedBox.expand(),
              // :33-44 — 28px glass pill on the label side, its inner
              // edge 12px off the artwork (artwork.x ± width + 12 :36-37),
              // text inset 10px (:83-88).
              Positioned(
                left: labelsLeft ? 0 : iconSize + 6 + 12,
                right: labelsLeft ? iconSize + 6 + 12 : 0,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: labelsLeft
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Opacity(
                    opacity: labelReveal,
                    child: Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7), // :39
                        color: shell.cardColor(
                          colors.surfaceContainer,
                        ), // :40 BlurService.backgroundColor
                        border: Border.all(
                          // :43-44 — onSurface @ 0.16.
                          color: colors.onSurface.withValues(alpha: 0.16),
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        child: label,
                      ),
                    ),
                  ),
                ),
              ),
              // :53-56 — icon 6px from the arc-foot edge (right when
              // labelsLeft, left otherwise), vertically centred (:59).
              Positioned(
                left: labelsLeft ? null : 6,
                right: labelsLeft ? 6 : null,
                top: 0,
                bottom: 0,
                child: Center(child: artworkStack),
              ),
            ],
          );
    return MouseRegion(
      cursor: services.linkCursor, // :102-104 PointingHandCursor
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// The arc fan for one folder entry (`DockFolderFan.qml:7-183`).
///
/// [sourceCenter] is the dock icon's centre in this widget's coordinate
/// space (`sourceCenter`, :17); [progress] drives the unfold exactly like
/// the source `progress` property (:18) — callers animate it 260ms open /
/// 180ms close easeOutCubic (`DockFilePopup.qml:136-143`).
class DockFolderFan extends StatefulWidget {
  const DockFolderFan({
    required this.entries,
    super.key,
    this.count,
    this.edge = FolderFanEdge.bottom,
    this.labelsLeft = true,
    this.maximumWidth = 600,
    this.maximumHeight = 800,
    this.iconSize = 64,
    this.maximumOutset = double.infinity,
    this.sourceCenter = Offset.zero,
    this.progress = 0,
    this.actionText = '',
    this.canOpen = true,
    this.canGoBack = false,
    this.onActivated,
    this.onAction,
  });

  /// `model` (:9) — the folder's entries (app group members).
  final List<DockFanEntry> entries;

  /// Logical item count (`count`, :10) — may exceed `entries.length`
  /// while a live listing catches up; defaults to `entries.length`.
  final int? count;

  /// Dock edge (:11); `bottom` fans vertically, `left`/`right`
  /// horizontally (:25).
  final FolderFanEdge edge;

  /// `labelsLeft` (:12) — bottom-edge label side.
  final bool labelsLeft;

  /// `maximumWidth`/`maximumHeight` (:13-14) — surface bounds budget.
  final double maximumWidth;
  final double maximumHeight;

  /// `iconSize` request (:15) — floored at 64 inside `folderFan` (:198).
  final double iconSize;

  /// `maximumOutset` (:16) — dock-to-screen-edge distance; finite only
  /// on the bottom edge where it triggers the 16-step bisection (:158).
  final double maximumOutset;

  /// `sourceCenter` (:17) — dock icon centre in widget coordinates.
  final Offset sourceCenter;

  /// `progress` (:18) — 0 closed … 1 fully unfolded.
  final double progress;

  /// `actionText` (:19) — action tile label.
  final String actionText;

  /// `canOpen`/`canGoBack` (:20-21) — action tile enable gate (:166).
  final bool canOpen;
  final bool canGoBack;

  /// `activated(info)` (:133) — fires with the tapped entry index.
  final void Function(int index)? onActivated;

  /// `openRequested`/`backRequested` (:23-24, :172) — selected by
  /// [canGoBack] exactly like the source.
  final void Function(bool back)? onAction;

  /// `horizontal` (:25) — horizontal-arc edges.
  bool get horizontal => edge != FolderFanEdge.bottom;

  /// `geometry` (:26-27) — the pure-Dart `folderFan()` pass.
  FolderFanGeometry get geometry => folderFan(
    edge: edge,
    count: count ?? entries.length,
    maximumWidth: maximumWidth,
    maximumHeight: maximumHeight,
    labelsLeft: labelsLeft,
    requestedIconSize: iconSize,
    maximumOutset: maximumOutset,
  );

  /// Icon centre inside a tile of this geometry — `tile.center`
  /// (:103-104 + DockFileTile.qml:53-59).
  Offset get iconCenter => horizontal
      ? Offset(geometry.tileWidth / 2, geometry.iconSize / 2)
      : Offset(
          labelsLeft
              ? geometry.tileWidth - geometry.iconSize / 2 - 6
              : geometry.iconSize / 2 + 6,
          geometry.tileHeight / 2,
        );

  @override
  State<DockFolderFan> createState() => _DockFolderFanState();
}

class _DockFolderFanState extends State<DockFolderFan> {
  final _scroll = ScrollController();

  /// Fractional scroll offset in item units — `view.contentX/contentY`
  /// divided by the row step (:82-86).
  double get _offset =>
      _scroll.hasClients ? _scroll.offset / widget.geometry.step : 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final geometry = widget.geometry;
    final horizontal = widget.horizontal;
    final itemCount = widget.entries.length;
    // Viewport strip: `geometry.count` (shown ≤ 8) slots on the scroll axis
    // (:61-62) — the viewport is exactly the shown arc length, NOT
    // `itemCount` (using it would pin maxScrollExtent at 0 so overflow
    // entries could never scroll into view, and would leak an invisible
    // hit surface `(itemCount−shown)·step` beyond the fan surface).
    final strip = horizontal
        ? Size(geometry.count * geometry.step, geometry.height)
        : Size(geometry.width, geometry.count * geometry.step);
    // `view.x/y` (:59-60): right edge right-aligns the viewport;
    // bottom edge sits at `header`.
    final viewOrigin = horizontal
        ? Offset(
            widget.edge == FolderFanEdge.right
                ? geometry.width - strip.width
                : 0,
            0,
          )
        : Offset(0, geometry.header);
    // Content-space offset of the row that currently carries fractional
    // `position` — `index·step − scroll` for left/bottom (items grow
    // away from the edge), `(itemCount−1−index)·step − scroll` for the
    // RightToLeft right edge (:65) — equivalent: `position·step` on the
    // row's leading axis either way.
    final tiles = <Widget>[
      for (var index = 0; index < itemCount; ++index)
        _FanItem(
          key: ValueKey('fan:$index'),
          entry: widget.entries[index],
          position: index - _offset,
          geometry: geometry,
          edge: widget.edge,
          labelsLeft: widget.labelsLeft,
          sourceCenter: widget.sourceCenter,
          progress: widget.progress,
          onActivated: widget.onActivated == null
              ? null
              : () => widget.onActivated!(index),
        ),
    ];
    // Action tile (open/back) at slot(count) (:144-172).
    final actionSlot = folderFanSlot(
      widget.edge,
      geometry.count.toDouble(),
      geometry,
      widget.labelsLeft,
    );
    return SizedBox(
      width: geometry.width, // :43-44 implicit size
      height: geometry.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Scroll viewport (:57-74) — carries input only; tiles are
          // painted by the sibling overlay so their arc positions are in
          // fan-surface space regardless of scroll offset. The viewport
          // shows `geometry.count` slots (:61-62); the scrollable CONTENT is
          // `itemCount` slots so overflowing entries scroll into view
          // (maxScrollExtent = (itemCount−count)·step > 0) — using
          // `itemCount` for the viewport itself would pin maxScrollExtent
          // at 0 and leak a hit surface beyond the fan surface.
          Positioned(
            left: viewOrigin.dx,
            top: viewOrigin.dy,
            width: strip.width,
            height: strip.height,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
              // :64-65 — BottomToTop for bottom edge, RightToLeft for
              // the right edge.
              reverse: !horizontal || widget.edge == FolderFanEdge.right,
              // :72,74 — bounds-clamped, and only interactive once the
              // fan is fully unfolded.
              physics: widget.progress == 1
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: horizontal
                    ? itemCount * geometry.step
                    : strip.width,
                height: horizontal
                    ? strip.height
                    : itemCount * geometry.step,
                // Invisible hit surface spanning the narrow gaps between
                // rows (:45-48 — traversing the curve must not leave the
                // popup or click through).
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // :92 — `z: -position` paints higher positions underneath; Stack
          // paints later children on top, so reverse the index order.
          ...tiles.reversed,
          // Action tile (:144-172).
          Positioned(
            left: _actionX(actionSlot),
            top: _actionY(actionSlot),
            width: geometry.tileWidth,
            height: geometry.tileHeight,
            child: _ActionTile(
              slot: actionSlot,
              geometry: geometry,
              horizontal: horizontal,
              iconCenter: widget.iconCenter,
              sourceCenter: widget.sourceCenter,
              progress: widget.progress,
              actionText: widget.actionText,
              canGoBack: widget.canGoBack,
              // :166 — enabled on `canGoBack || canOpen` alone; the source
              // does not gate the action tile on full progress.
              enabled: widget.canGoBack || widget.canOpen,
              onTap: widget.onAction == null
                  ? null
                  : () => widget.onAction!(widget.canGoBack),
            ),
          ),
        ],
      ),
    );
  }

  // openItem x/y (:162-163): slot rect interpolated from sourceCenter.
  double _actionX(FolderFanSlot slot) =>
      slot.x +
      (widget.sourceCenter.dx - slot.x - widget.iconCenter.dx) *
          (1 - widget.progress);

  double _actionY(FolderFanSlot slot) =>
      slot.y +
      (widget.sourceCenter.dy - slot.y - widget.iconCenter.dy) *
          (1 - widget.progress);
}

/// One scrollable fan item — the `delegate` half of :75-142.
///
/// Painted as a sibling of the scroll viewport (not inside it): the
/// tile's rect is `slot + stack offset` in fan-surface space, exactly
/// `finalX/finalY` (:105-112) with the `row/view/contentX` terms already
/// cancelled — the row rect moves the hit strip, the slot rect moves the
/// pixels.
class _FanItem extends StatelessWidget {
  const _FanItem({
    required this.entry,
    required this.position,
    required this.geometry,
    required this.edge,
    required this.labelsLeft,
    required this.sourceCenter,
    required this.progress,
    this.onActivated,
    super.key,
  });

  final DockFanEntry entry;

  /// `position` (:82-86) — fractional slot index after scrolling.
  final double position;
  final FolderFanGeometry geometry;
  final FolderFanEdge edge;
  final bool labelsLeft;
  final Offset sourceCenter;
  final double progress;
  final VoidCallback? onActivated;

  bool get _horizontal => edge != FolderFanEdge.bottom;

  @override
  Widget build(BuildContext context) {
    final stackDepth = dockFanStackDepth(position, geometry.count); // :87
    // :91 — outside the render window → gone entirely.
    if (geometry.count <= 0 || position <= -1 || stackDepth >= 4) {
      return const SizedBox.shrink();
    }
    // :88-90 — slot under the fractional `position`, clamped to count−1.
    final slot = folderFanSlot(
      edge,
      math.min(position, geometry.count - 1),
      geometry,
      labelsLeft,
    );
    // finalX/finalY (:105-112) — slot rect + stack offset in
    // fan-surface space (view/row/contentX cancel for a painted-sibling
    // implementation).
    final finalX =
        slot.x +
        dockFanStackShiftX(
          edge: edge,
          labelsLeft: labelsLeft,
          stackDepth: stackDepth,
        );
    final finalY =
        slot.y - dockFanStackShiftY(edge: edge, stackDepth: stackDepth);
    // x/y (:113-116) — each tile interpolates from the dock icon centre
    // (sourceCenter, in tile space) toward finalX/finalY.
    final center = _iconCenter();
    final tileX =
        finalX + (sourceCenter.dx - finalX - center.dx) * (1 - progress);
    final tileY =
        finalY + (sourceCenter.dy - finalY - center.dy) * (1 - progress);
    final opacity = dockFanTileOpacity(
      progress: progress,
      position: position,
      stackDepth: stackDepth,
    );
    final labelReveal = dockFanLabelReveal(
      progress: progress,
      stackDepth: stackDepth,
    );
    final scale = dockFanTileScale(
      progress: progress,
      stackDepth: stackDepth,
    );
    return Positioned(
      left: tileX,
      top: tileY,
      width: geometry.tileWidth,
      height: geometry.tileHeight,
      child: Transform(
        transform: Matrix4.identity()
          ..translateByDouble(center.dx, center.dy, 0, 1)
          ..rotateZ(slot.rotation * math.pi / 180 * progress) // :124
          ..scaleByDouble(scale, scale, 1, 1) // :126-131
          ..translateByDouble(-center.dx, -center.dy, 0, 1),
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: IgnorePointer(
            // :100 — only stackDepth < 0.001 accepts input.
            ignoring: stackDepth >= 0.001,
            child: DockFanTile(
              name: entry.name,
              appId: entry.appId,
              verticalLabel: _horizontal, // :97
              labelsLeft: labelsLeft,
              labelReveal: labelReveal,
              iconSize: geometry.iconSize,
              onTap: onActivated,
            ),
          ),
        ),
      ),
    );
  }

  /// `tile.center` (:103-104): icon centre inside the tile —
  /// `(tileWidth−icon/2−6, tileHeight/2)` when labelsLeft,
  /// `(icon/2+6, tileHeight/2)` otherwise; `(tileWidth/2, iconSize/2)`
  /// for vertical labels (artwork centred at the top :53-59).
  Offset _iconCenter() => _horizontal
      ? Offset(geometry.tileWidth / 2, geometry.iconSize / 2)
      : Offset(
          labelsLeft
              ? geometry.tileWidth - geometry.iconSize / 2 - 6
              : geometry.iconSize / 2 + 6,
          geometry.tileHeight / 2,
        );
}

/// The fixed action tile — `openItem` (:144-172): `arrow_back` while
/// history exists, `open_in_new` otherwise; opacity is plain `progress`
/// (:164), no stack factor.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.slot,
    required this.geometry,
    required this.horizontal,
    required this.iconCenter,
    required this.sourceCenter,
    required this.progress,
    required this.actionText,
    required this.canGoBack,
    required this.enabled,
    this.onTap,
  });

  final FolderFanSlot slot;
  final FolderFanGeometry geometry;
  final bool horizontal;
  final Offset iconCenter;
  final Offset sourceCenter;
  final double progress;
  final String actionText;
  final bool canGoBack;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Transform(
      transform: Matrix4.identity()
        ..translateByDouble(iconCenter.dx, iconCenter.dy, 0, 1)
        ..rotateZ(slot.rotation * math.pi / 180 * progress) // :167-171
        ..translateByDouble(-iconCenter.dx, -iconCenter.dy, 0, 1),
      child: Opacity(
        opacity: progress, // :164
        child: IgnorePointer(
          ignoring: !enabled, // :166 (+ :74 — callers gate on progress)
          child: DockFanTile(
            name: actionText,
            verticalLabel: horizontal,
            labelsLeft: true,
            labelReveal: math.max(0, (progress - 0.4) / 0.6), // :165
            iconSize: geometry.iconSize,
            actionIcon: canGoBack ? Icons.arrow_back : Icons.open_in_new, // :151
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}
