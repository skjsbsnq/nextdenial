/// DockFolderList — the list content view of a folder popup
/// (`DockFolderMenu.qml` as embedded by `DockFilePopup.qml:185-211`).
///
/// Semantics (line anchors into `DockFolderMenu.qml` unless noted):
/// - Rows are `StyledMenuItem`s: height 34, 22px icon at x=8, text left
///   padding 38 (:153-172). `isDirectory` rows get a `chevron_right` arrow
///   (:187-194) — under app-group clipping no entry is a directory, so the
///   chevron never renders (card 注意 :111).
/// - Panel height `min(480, maximumHeight, 16 + (max(1,count)+1)·34 + 12 +
///   (edge === "bottom" ? tail : 0))` (:28-29, also `DockFilePopup.qml
///   :61-62`); width 360 (:27); tail = 10px bottom only (:14-17).
/// - Empty group → one disabled "Folder is empty" row (:196-203).
/// - The source's footer separator + "Open in File Manager" row (:204-213)
///   is replaced by an optional back row — app groups have no browsing
///   history, so it renders only when [canGoBack] (card 数据源裁剪).
///
/// This is a standalone panel rather than a `DockContextMenu` wrapper: the
/// context menu always renders its sort/display/view option sections and the
/// generic open/remove rows (:362-415), which are dead UI for a list-view
/// popup. The row geometry and the shared `DockFanEntry` record shape mirror
/// the menu's `DockFolderEntry` — this file only re-implements the flat
/// (no-subdirectory) half. NOTE: being standalone it does NOT inherit the
/// context menu's outside-dismiss Listener/Escape/`ShellInputRegion`
/// (`context_menu.dart` ~:770-791); the host that mounts this panel owns the
/// dismiss protocol (see visual-deltas).
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';

import 'folder_fan.dart' show DockFanEntry, FolderFanEdge;
import 'folder_grid.dart' show kDockBubbleTailSize;

/// Row height — `implicitHeight: 34` (`DockFolderMenu.qml:157,175,202`).
const double kDockFolderListRowHeight = 34;

/// Row icon edge — `DockFileIcon` 22×22 (:160-163).
const double kDockFolderListIconSize = 22;

/// Row text left padding — `leftPadding: 38` (:158,176).
const double kDockFolderListLeftPadding = 38;

/// Menu height formula (:28-29 / `DockFilePopup.qml:61-62`):
/// `min(480, maximumHeight, 16 + (max(1,count)+1)·34 + 12 +
/// (edge === "bottom" ? tail : 0))`.
double dockFolderListHeight({
  required int count,
  required double maximumHeight,
  required FolderFanEdge edge,
  double tailSize = kDockBubbleTailSize,
}) => math.min(
  480.0,
  math.min(
    maximumHeight,
    16 +
        (math.max(1, count) + 1) * kDockFolderListRowHeight +
        12 +
        (edge == FolderFanEdge.bottom ? tailSize : 0),
  ),
);

/// The folder list panel — flat rows of the app group, `DockFolderMenu`
/// semantics without directory cascades.
class DockFolderList extends StatelessWidget {
  const DockFolderList({
    required this.entries,
    super.key,
    this.edge = FolderFanEdge.bottom,
    this.maximumHeight = 600,
    this.available = true,
    this.canGoBack = false,
    this.onActivated,
    this.onBack,
  });

  /// `contents.model` (:93-95) — app-group members in dock order.
  final List<DockFanEntry> entries;

  /// `edge` (:12) — only the bottom edge adds the 10px tail (:17).
  final FolderFanEdge edge;

  /// `maximumHeight` (:21).
  final double maximumHeight;

  /// `contents.available` (:199-201) — false swaps the empty text for
  /// "Folder is unavailable".
  final bool available;

  /// Footer back row gate — app-group replacement for the source's
  /// always-present "Open in File Manager" (:205-213).
  final bool canGoBack;

  /// `fileActivated(info)` (:167) — fires with the tapped entry index.
  final void Function(int index)? onActivated;

  /// Footer back action — `history` pop under app-group clipping.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    final height = dockFolderListHeight(
      count: entries.length,
      maximumHeight: maximumHeight,
      edge: edge,
    );
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return SizedBox(
      width: 360, // :27
      height: height,
      child: ShellBackdropBlur(
        // card material chain (DeskCard): blur/glass on, off → flat fill.
        blur: shell.backdropBlurEnabled,
        separateChild: true,
        borderRadius: BorderRadius.circular(12),
        child: Material(
          // cardColor shares the shell card opacity with the dock glass.
          color: shell.cardColor(colors.surfaceContainer),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              // DockBubbleSurface lineColor onSurface@0.18 (:43).
              color: colors.onSurface.withValues(alpha: 0.18),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            // :15-17 — 8px side paddings + 10px tail on the bottom edge.
            padding: EdgeInsets.only(
              top: 8,
              left: 8 + (edge == FolderFanEdge.left ? kDockBubbleTailSize : 0),
              right:
                  8 + (edge == FolderFanEdge.right ? kDockBubbleTailSize : 0),
              bottom:
                  8 +
                  (edge == FolderFanEdge.bottom ? kDockBubbleTailSize : 0),
            ),
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(), // StopAtBounds
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < entries.length; ++index)
                    _DockFolderListRow(
                      key: ValueKey('list:$index'),
                      entry: entries[index],
                      onTap: onActivated == null
                          ? null
                          : () => onActivated!(index),
                    ),
                  if (entries.isEmpty)
                    // :196-203 — disabled empty/unavailable row.
                    SizedBox(
                      height: kDockFolderListRowHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            available
                                ? (chinese ? '文件夹为空' : 'Folder is empty')
                                : (chinese
                                      ? '文件夹不可用'
                                      : 'Folder is unavailable'),
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                  if (canGoBack) ...[
                    Container(
                      // :204 MenuSeparator.
                      height: 1,
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      color: colors.onSurface.withValues(alpha: 0.16),
                    ),
                    // :205-213 slot — back under app-group clipping.
                    _DockFolderListActionRow(
                      icon: Icons.arrow_back,
                      label: chinese ? '返回' : 'Back',
                      onTap: onBack,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One app row — the `fileItem` component (:152-172): 34px, 22px icon at
/// x=8, text left-padded 38. No `DockFileDrag` (:168-171 — file drag is
/// clipped) and no subdirectory cascade.
class _DockFolderListRow extends StatelessWidget {
  const _DockFolderListRow({
    required this.entry,
    required this.onTap,
    super.key,
  });

  final DockFanEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    final foreground = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xffeeeeee)
        : const Color(0xff202020);
    return SizedBox(
      height: kDockFolderListRowHeight,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          alignment: Alignment.centerLeft,
          // :158 leftPadding 38 — 8px horizontal insets + 22px icon + 8 gap.
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        onPressed: onTap,
        child: Row(
          children: [
            // :159-166 — 22px artwork at x=8.
            SizedBox(
              width: kDockFolderListIconSize,
              height: kDockFolderListIconSize,
              child: services.buildApplicationIcon(context, entry.appId),
            ),
            // Icon 8 + 22 + gap 8 = text left edge at 38 (:158).
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The footer action row — same 34px menu-item geometry, icon + label.
class _DockFolderListActionRow extends StatelessWidget {
  const _DockFolderListActionRow({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xffeeeeee)
        : const Color(0xff202020);
    return SizedBox(
      height: kDockFolderListRowHeight,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        onPressed: onTap,
        child: Row(
          children: [
            SizedBox(
              width: kDockFolderListIconSize,
              height: kDockFolderListIconSize,
              child: Icon(icon, size: 18, color: foreground),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
