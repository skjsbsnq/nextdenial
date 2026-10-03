/// Dock spacer entity + the fixed trailing trash row entry.
///
/// Sources:
/// - spacer slot (`DockItem.qml:28`, `DockLayout.js:22`): `spacer` is
///   weight 1, `small-spacer` weight 0.5 (the layout side already lives in
///   TASK-01); the drag ghost is a transparent rectangle with a 1px
///   `onSurface @ 0.4` border, `radius = width * 0.2`, width
///   `parent.width * (kind == "small-spacer" ? 0.5 : 1)` and full height
///   (`DockDragVisual.qml:127-136`);
/// - trash (`DockService.qml:232-243`): a fixed trailing row with
///   `key: "trash"`, `kind: "trash"`, `pinned: false`, `windowCount: 0`,
///   `available: true` and icon `user-trash-full` when `trashCount > 0` else
///   `user-trash`.
///
/// Denial difference (recorded in `docs/visual-deltas.md`): the trash click
/// opens `trash:///` in the file manager through `ApplicationService.openUrl`
/// (`DockService.qml:252-257`), but the SDK exposes no `openUrl`/spawn
/// channel (`ShellApplicationServices` only has `launchApplication`), so the
/// trash entry is display-only — activating it must not open anything.
library;

import 'package:flutter/material.dart';

import 'dock_item.dart' show kDockItemDefaultIconSize;
import 'dock_surface.dart' show DockEntry;

/// `key` of the fixed trailing trash row (`DockService.qml:233`).
const String kDockTrashKey = 'trash';

/// Trash icon names (`DockService.qml:237`).
const String kDockTrashIcon = 'user-trash';
const String kDockTrashFullIcon = 'user-trash-full';

/// `trashCount > 0 ? "user-trash-full" : "user-trash"`
/// (`DockService.qml:237`).
String dockTrashIconName(int trashCount) =>
    trashCount > 0 ? kDockTrashFullIcon : kDockTrashIcon;

/// The drag-ghost width for a spacer slot (`DockDragVisual.qml:129`):
/// half the slot for `small-spacer`, the whole slot otherwise.
double dockSpacerGhostWidth(double slotWidth, {required bool small}) =>
    slotWidth * (small ? 0.5 : 1);

/// The always-present trailing trash entry (`DockService.qml:232-243`).
///
/// `appId` carries the resolved icon name so the row renders
/// `user-trash`/`user-trash-full`; the entry is never pinned and never
/// reports a running window.
DockEntry dockTrashEntry({required int trashCount, String name = 'Trash'}) =>
    DockEntry(
      key: kDockTrashKey,
      kind: 'trash',
      name: name,
      appId: dockTrashIconName(trashCount),
      available: true, // :243
    );

/// A spacer row entry (`DockItem.qml:28`). Spacer rows come from `dock.json`
/// pins, so they sit in the pinned section (`pinned: true`,
/// `DockService.qml:191`).
DockEntry dockSpacerEntry({required String id, required bool small}) =>
    DockEntry(
      key: 'spacer:$id',
      kind: small ? 'small-spacer' : 'spacer',
      name: '',
      appId: '',
      pinned: true,
    );

/// Spacer placeholder slot (`DockItem.qml:28`,
/// `DockDragVisual.qml:127-136`).
///
/// Invisible at rest and only paints its 1px outline while [dragging] — the
/// host shows it as the drag ghost.
class DockSpacer extends StatelessWidget {
  const DockSpacer({
    super.key,
    this.small = false,
    this.dragging = false,
    this.size = kDockItemDefaultIconSize,
    this.outlineColor,
  });

  /// `small-spacer` — half-width ghost (`DockDragVisual.qml:129`).
  final bool small;

  /// Whether the drag ghost is currently visible.
  final bool dragging;

  /// Slot edge length the ghost is drawn into.
  final double size;

  /// Outline colour; defaults to `onSurface @ 0.4` (`:135`).
  final Color? outlineColor;

  @override
  Widget build(BuildContext context) {
    final color =
        outlineColor ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
    final ghostWidth = dockSpacerGhostWidth(size, small: small);
    return SizedBox(
      width: size,
      height: size,
      child: Opacity(
        opacity: dragging ? 1 : 0,
        child: Center(
          child: SizedBox(
            width: ghostWidth,
            height: size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.transparent, // :133
                borderRadius: BorderRadius.circular(ghostWidth * 0.2), // :132
                border: Border.all(color: color), // :134-135 (1px)
              ),
            ),
          ),
        ),
      ),
    );
  }
}
