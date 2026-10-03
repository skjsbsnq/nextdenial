/// DockContextMenu — the right-click context menu for one dock entry.
///
/// Mechanism is a 1:1 port of the taskbar `_WindowButton` menu half
/// (`denial_taskbar/lib/src/window_buttons.dart:431-444,518-531,575,620-684`)
/// plus the `tray.dart:141-171` `ShellInputRegion` paradigm. The overlay is
/// rendered through the shared `OverlayPortal` of `DockPreviewCard`
/// (`_menu ? _buildMenu : _buildPreviews`, :520-521); the card owns
/// `_openMenu` (:431-439) and hands us `_closeMenu` (:441-444) as [onClose].
///
/// The item list mirrors `DockPreviewPopup.qml:208-410` in order and
/// visibility (per-item anchors inline). Folder/file/trash entries follow
/// `DockFilePopup.qml:343-415`; the recursive folder listing follows
/// `DockFolderMenu.qml` (`cascade: true` :31, `ancestorUrls` cycle guard
/// :95, nested portal per expandable row :137-151).
///
/// The SDK exposes no close/kill/DesktopActions/settings hosts — those items
/// take injected callbacks and render disabled when unimplemented (see
/// docs/visual-deltas.md).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Creates a one-shot [Timer] — the injectable seam behind which fake-clock
/// tests drive the confirm-state reset and cascade hover delays.
typedef DockMenuTimerFactory = Timer Function(Duration, void Function());

/// Builds the TASK-05 menu inside the shared preview/menu portal —
/// [layout] is the portal's `OverlayChildLayoutInfo`, [close] is the card's
/// `_closeMenu` (:441-444). The item's `contextRequested` path calls
/// `DockPreviewCardState.openMenu()`; this builder supplies the content.
typedef DockMenuBuilder =
    Widget Function(
      BuildContext context,
      OverlayChildLayoutInfo layout,
      VoidCallback close,
    );

/// The dock-panel foreground — `taskbarForeground` equivalent
/// (`denial_taskbar/lib/src/neutral_color.dart`), the shell token used at
/// window_buttons.dart:697,704 for menu text/icons.
Color dockMenuForeground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xffeeeeee)
    : const Color(0xff202020);

/// One `.desktop` "Desktop Action" row (DockPreviewPopup.qml:253-298).
///
/// The SDK has no `actionsForApplication`/action launcher — the parent
/// constructs this list from its own desktop-file data and supplies
/// [onLaunch] per action; `null` disables the row (`canLaunch` gate
/// :290-291).
class DockDesktopAction {
  const DockDesktopAction({required this.name, this.iconAppId, this.onLaunch});

  /// Action display name (`modelData.name`, :265).
  final String name;

  /// Icon identity for `services.buildApplicationIcon` — 20px ThemeIcon
  /// slot (:268-277); `null` renders no icon.
  final String? iconAppId;

  /// Injected launch callback (`launchApplicationAction`, :292); `null`
  /// disables the row.
  final VoidCallback? onLaunch;
}

/// One folder listing record (DockFolderMenu `contents` row, :93-95).
///
/// Children are supplied eagerly (injected model); a directory row cascades
/// only when `isDirectory && !isLink && !ancestorUrls.contains(url)` (:95).
class DockFolderEntry {
  const DockFolderEntry({
    required this.url,
    required this.name,
    this.isDirectory = false,
    this.isLink = false,
    this.children = const [],
    this.available = true,
  });

  /// Canonical file url — identity for the `ancestorUrls` cycle guard.
  final String url;

  /// Row label (`info.name`, :156).
  final String name;

  /// `info.isDirectory` (:95) — qualifies for a nested submenu.
  final bool isDirectory;

  /// `info.isLink` (:95) — symlinks never cascade (cycle guard).
  final bool isLink;

  /// Pre-resolved children for a cascading directory row.
  final List<DockFolderEntry> children;

  /// `contents.available` per-row equivalent (:199-201).
  final bool available;
}

/// The context menu overlay for one dock entry.
///
/// Constructed inside `DockPreviewCard`'s `overlayChildBuilder` through the
/// `menuBuilder` seam, which supplies [layout] (the shared portal's
/// `OverlayChildLayoutInfo`) and [onClose] (`_closeMenu` :441-444).
class DockContextMenu extends StatefulWidget {
  const DockContextMenu({
    required this.layout,
    required this.onClose,
    required this.monitorId,
    super.key,
    this.monitorBounds,
    this.kind = 'app',
    this.entryName = '',
    this.available = true,
    this.launchId,
    this.windows = const [],
    this.desktopActions = const [],
    this.pinned,
    this.onTogglePin,
    this.onCloseWindow,
    this.onForceQuit,
    this.onOpenSettings,
    this.folderUrl,
    this.folderEntries,
    this.folderEntriesAvailable = true,
    this.folderSort,
    this.folderView,
    this.onFolderSortChanged,
    this.onFolderViewChanged,
    this.onFileActivated,
    this.onOpen,
    this.onRemoveFromDock,
    this.onEmptyTrash,
    this.timerFactory = Timer.new,
  });

  /// The shared portal's layout info — geometry source for `_geometry`
  /// (:620-627).
  final OverlayChildLayoutInfo layout;

  /// `_closeMenu` (:441-444): `_hideImmediately` + anchor focus restore.
  final VoidCallback onClose;

  /// Output for `launchApplication(monitorId:)`.
  final int monitorId;

  /// Output rect the menu clamps into; `null` uses the whole overlay (:625).
  final Rect? monitorBounds;

  /// Entry kind: `app`, `folder`, `file`, `trash` (DockItem.qml:15).
  final String kind;

  /// Entry display name — title row when there are no windows (:208-220).
  final String entryName;

  /// `entry.available` (:309) — gates the "Application is unavailable" row.
  final bool available;

  /// Launch identity for `services.launchApplication`; `canLaunch`
  /// (:290, :325, :328) — `null` hides "Open application" and disables the
  /// Desktop Action rows.
  final String? launchId;

  /// This entry's windows — the checkable list (:228-245).
  final List<ApplicationWindow> windows;

  /// Desktop Action rows (:253-298); empty hides the section (:255).
  final List<DockDesktopAction> desktopActions;

  /// `entry.pinned` (:388) — `null` means `canChangePin` is false (:387).
  final bool? pinned;

  /// Injected pin/unpin (`DockService.pin/unpin`, :393-396) — no host API.
  final VoidCallback? onTogglePin;

  /// Injected per-window close (`DockService.closeWindow`, :345) — no host
  /// API; `null` renders "Close all windows" disabled.
  final void Function(int windowId)? onCloseWindow;

  /// Injected force quit (`processQuit.prepare→confirm`, :356-362) — no
  /// host API. Returns success; `false` keeps the menu open with the error
  /// row (:364-374). `null` disables the item.
  final FutureOr<bool> Function()? onForceQuit;

  /// Injected "Dock settings" handler (`ControlCenterService.openSearch`,
  /// :407) — no host service; `null` keeps the item as a disabled
  /// placeholder (visual-deltas.md).
  final VoidCallback? onOpenSettings;

  /// Folder url for the cascade root (`folderUrl`, :11) and the cycle
  /// guard's seed (`ancestorUrls` :22).
  final String? folderUrl;

  /// Eager folder listing for `folderView == 'list'`; `null` hides the
  /// cascade section entirely.
  final List<DockFolderEntry>? folderEntries;

  /// `contents.available` (:199) — false shows "Folder is unavailable".
  final bool folderEntriesAvailable;

  /// Current folder sort option (`sort` :18, choices :366-374).
  final String? folderSort;

  /// Current folder view (`fan`/`grid`/`list`, :391-396); `'list'` plus
  /// [folderEntries] renders the cascading directory section.
  final String? folderView;

  /// Injected sort option handler (`option: "sort"`, :372-374).
  final void Function(String sort)? onFolderSortChanged;

  /// Injected view option handler (`option: "view"` :392-396 and
  /// `option: "display"` :379-386 share this callback; display values pass
  /// through as-is).
  final void Function(String view)? onFolderViewChanged;

  /// Injected file activation (`fileActivated(info)`, :167, :209-211) —
  /// also used by "Open in File Manager" with the folder url.
  final void Function(String url)? onFileActivated;

  /// Injected generic open (`action: "open"`, :398-403) — trash/file/folder.
  final VoidCallback? onOpen;

  /// Injected remove (`action: "remove"`, :410-414) — folder/file entries.
  final VoidCallback? onRemoveFromDock;

  /// Injected empty-trash execution (`action: "empty"`, :354-357) — the row
  /// runs the same two-stage confirm as Force quit; `null` disables it.
  final FutureOr<bool> Function()? onEmptyTrash;

  /// Timer seam for the confirm-state reset and cascade hover delays —
  /// defaults to `Timer.new`; tests pass a fake-clock factory.
  final DockMenuTimerFactory timerFactory;

  @override
  State<DockContextMenu> createState() => _DockContextMenuState();
}

class _DockContextMenuState extends State<DockContextMenu> {
  /// Two-stage confirm arm flags — first tap enters the destructive confirm
  /// state, second executes, [timerFactory] resets (processQuit
  /// prepare→confirm model, DockFilePopup.qml:344-358 confirmEmpty pair).
  bool _forceQuitArmed = false;
  bool _emptyTrashArmed = false;
  bool _quitFailed = false;
  Timer? _confirmTimer;

  static const _confirmTimeout = Duration(seconds: 3);

  bool get _chinese => Localizations.localeOf(context).languageCode == 'zh';

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  // ---- two-stage confirm ---------------------------------------------------

  void _arm(VoidCallback disarm) {
    _confirmTimer?.cancel();
    _confirmTimer = widget.timerFactory(_confirmTimeout, () {
      if (mounted) setState(disarm);
    });
  }

  void _forceQuit() {
    if (!_forceQuitArmed) {
      // First tap → destructive confirm state (:356 prepare).
      setState(() {
        _forceQuitArmed = true;
        _emptyTrashArmed = false;
        _quitFailed = false;
      });
      _arm(() => _forceQuitArmed = false);
      return;
    }
    _confirmTimer?.cancel();
    final result = widget.onForceQuit!();
    if (result is Future<bool>) {
      unawaited(result.then(_finishForceQuit, onError: (_) => false));
    } else {
      _finishForceQuit(result);
    }
  }

  void _finishForceQuit(bool success) {
    if (!mounted) return;
    if (success) {
      widget.onClose(); // :360-362 — dismissed only on success
    } else {
      setState(() {
        _forceQuitArmed = false;
        _quitFailed = true; // :357-361 quitFailed → error row
      });
    }
  }

  void _emptyTrash() {
    if (!_emptyTrashArmed) {
      // First tap → destructive confirm (confirmEmpty pair :344-358).
      setState(() {
        _emptyTrashArmed = true;
        _forceQuitArmed = false;
      });
      _arm(() => _emptyTrashArmed = false);
      return;
    }
    _confirmTimer?.cancel();
    final result = widget.onEmptyTrash!();
    if (result is Future<bool>) {
      unawaited(result.then(_finishEmptyTrash, onError: (_) => false));
    } else {
      _finishEmptyTrash(result);
    }
  }

  void _finishEmptyTrash(bool success) {
    if (!mounted) return;
    if (success) {
      widget.onClose();
    } else {
      setState(() => _emptyTrashArmed = false);
    }
  }

  // ---- actions --------------------------------------------------------------

  void _openApplication() {
    final launchId = widget.launchId;
    if (launchId == null) return;
    widget.onClose(); // :331 root.dismissed()
    unawaited(
      ShellServicesScope.of(
        context,
      ).launchApplication(launchId, monitorId: widget.monitorId).then(
        (_) {},
        onError: (_) {},
      ),
    );
  }

  void _closeAll() {
    final closeWindow = widget.onCloseWindow;
    if (closeWindow == null) return;
    // Snapshot ids before close events can change the group (:342-346).
    final ids = [for (final window in widget.windows) window.id];
    widget.onClose();
    for (final id in ids) {
      closeWindow(id);
    }
  }

  // ---- item builders ---------------------------------------------------------

  Widget _separator() => Container(
    // :247-252 — onSurface@0.16 1px rule with the column's 4px rhythm.
    height: 1,
    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.16),
  );

  Widget _titleRow() => Padding(
    // :208-220 — entry name, 32px, onSurfaceVariant, only when no windows.
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: SizedBox(
      height: 32,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          widget.entryName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  Widget _unavailableRow() => Padding(
    // :306-316 — app kind unavailable + no windows.
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Text(
      _chinese ? '应用不可用' : 'Application is unavailable',
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _quitFailedRow() => Padding(
    // :364-374 — error text in colError.
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Text(
      _chinese
          ? '无法强制退出此应用。'
          : 'Unable to force quit this application.',
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.error, // :743
      ),
    ),
  );

  Widget _heading(String text) => Padding(
    // "Sort by"/"Display as"/"View content as" headings (:364-390).
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _menuItem({
    required String label,
    VoidCallback? onPressed,
    bool? checked,
    bool destructive = false,
    Widget? icon,
    Widget? trailing,
  }) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructive
        ? colors.error // destructive rows use colors.error (:743)
        : dockMenuForeground(context);
    return SizedBox(
      height: 32, // implicitHeight 32 (:233)
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          disabledForegroundColor: foreground.withValues(alpha: 0.38),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8), // :234-235
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        onPressed: onPressed,
        child: Row(
          children: [
            if (checked != null)
              SizedBox(
                // checkable indicator slot (:237-238).
                width: 18,
                child: checked
                    ? Icon(Icons.check, size: 18, color: foreground)
                    : null,
              ),
            if (icon != null) ...[
              SizedBox(width: 20, height: 20, child: icon), // :269-270
              const SizedBox(width: 8), // :267 spacing
            ],
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// Items in exact `DockPreviewPopup.qml:208-410` order/visibility.
  List<Widget> _appItems(BuildContext context) {
    final services = ShellServicesScope.of(context);
    return [
      // 1. :208-220 — app-name title row, no windows only.
      if (widget.windows.isEmpty && widget.entryName.isNotEmpty) _titleRow(),
      // 2. :221-245 — window block, checkable, checked = isFocused.
      if (widget.windows.isNotEmpty)
        for (final window in widget.windows)
          _menuItem(
            label: window.title.isEmpty ? widget.entryName : window.title,
            checked: window.active, // :238 checked = isFocused
            onPressed: () {
              widget.onClose(); // :241 dismissed
              services.activateWindow(window.id); // :240 focusWindow
            },
          ),
      // 3. :247-252 — separator, always rendered.
      _separator(),
      // 4. :253-298 — Desktop Actions, section hidden when empty (:255).
      for (final action in widget.desktopActions)
        _menuItem(
          label: action.name,
          icon: action.iconAppId == null
              ? null
              : services.buildApplicationIcon(context, action.iconAppId!),
          onPressed: action.onLaunch == null
              ? null
              : () {
                  widget.onClose(); // :294 dismissed
                  action.onLaunch!();
                },
        ),
      // 5. :299-305 — actions separator, only when actions non-empty.
      if (widget.desktopActions.isNotEmpty) _separator(),
      // 6. :306-316 — unavailable hint (app kind, !available, no windows).
      if (!widget.available && widget.windows.isEmpty) _unavailableRow(),
      // 7. :320-333 — Open application, canLaunch visible.
      if (widget.launchId != null)
        _menuItem(
          label: _chinese ? '打开应用' : 'Open application',
          onPressed: _openApplication,
        ),
      // 8. :334-348 — Close all windows; injected, disabled without impl.
      if (widget.windows.isNotEmpty)
        _menuItem(
          label: _chinese ? '关闭所有窗口' : 'Close all windows',
          onPressed: widget.onCloseWindow == null ? null : _closeAll,
        ),
      // 9. :349-363 — Force quit, two-stage destructive confirm.
      if (widget.windows.isNotEmpty)
        _menuItem(
          label: _forceQuitArmed
              ? (_chinese ? '确认强制退出？' : 'Confirm force quit?')
              : (_chinese ? '强制退出' : 'Force quit'),
          destructive: _forceQuitArmed,
          onPressed: widget.onForceQuit == null ? null : _forceQuit,
        ),
      // :364-374 — failure row.
      if (_quitFailed) _quitFailedRow(),
      // 10. :375-381 — separator, windows only.
      if (widget.windows.isNotEmpty) _separator(),
      // 11. :382-399 — Pin to Dock / Remove from Dock, canChangePin.
      if (widget.pinned != null)
        _menuItem(
          label: widget.pinned!
              ? (_chinese ? '从 Dock 移除' : 'Remove from Dock')
              : (_chinese ? '固定到 Dock' : 'Pin to Dock'),
          onPressed: widget.onTogglePin == null
              ? null
              : () {
                  widget.onClose(); // :397 dismissed
                  widget.onTogglePin!();
                },
        ),
      // 12. :400-410 — Dock settings; no host service → disabled placeholder.
      _menuItem(
        label: _chinese ? 'Dock 设置' : 'Dock settings',
        onPressed: widget.onOpenSettings == null
            ? null
            : () {
                widget.onClose();
                widget.onOpenSettings!();
              },
      ),
    ];
  }

  /// `DockFilePopup.qml:343-415` choices for folder/file/trash entries.
  List<Widget> _fileItems(BuildContext context) {
    final chinese = _chinese;
    final kind = widget.kind;
    return [
      if (widget.windows.isEmpty && widget.entryName.isNotEmpty) _titleRow(),
      if (widget.windows.isNotEmpty)
        for (final window in widget.windows)
          _menuItem(
            label: window.title.isEmpty ? widget.entryName : window.title,
            checked: window.active,
            onPressed: () {
              widget.onClose();
              ShellServicesScope.of(context).activateWindow(window.id);
            },
          ),
      // Folder list view → recursive cascade (DockFolderMenu.qml).
      if (kind == 'folder' &&
          widget.folderView == 'list' &&
          widget.folderEntries != null) ...[
        for (final entry in widget.folderEntries!)
          _folderRow(entry, ancestorUrls: {if (widget.folderUrl != null) widget.folderUrl!}),
        if (widget.folderEntries!.isEmpty)
          _menuItem(
            // :196-203 — empty/unavailable, disabled.
            label: widget.folderEntriesAvailable
                ? (chinese ? '文件夹为空' : 'Folder is empty')
                : (chinese ? '文件夹不可用' : 'Folder is unavailable'),
          ),
        _separator(), // :204 MenuSeparator
        _menuItem(
          // :205-213 — Open in File Manager → fileActivated(folderUrl).
          label: chinese ? '在文件管理器中打开' : 'Open in File Manager',
          onPressed: widget.onFileActivated == null
              ? null
              : () {
                  widget.onClose();
                  widget.onFileActivated!(widget.folderUrl ?? '');
                },
        ),
        _separator(),
      ] else
        _separator(),
      // :362-374 — Sort by heading + 5 options (folder only).
      if (kind == 'folder') ...[
        _heading(chinese ? '排序方式' : 'Sort by'),
        for (final (value, label) in [
          ('name', chinese ? '名称' : 'Name'),
          ('modified', chinese ? '修改日期' : 'Date Modified'),
          ('created', chinese ? '创建日期' : 'Date Created'),
          ('kind', chinese ? '类型' : 'Kind'),
          ('size', chinese ? '大小' : 'Size'),
        ])
          _menuItem(
            label: label,
            checked: widget.folderSort == value,
            onPressed: widget.onFolderSortChanged == null
                ? null
                : () => widget.onFolderSortChanged!(value),
          ),
        // :375-388 — Display as heading + Folder/Stack.
        _heading(chinese ? '显示为' : 'Display as'),
        for (final (value, label) in [
          ('folder', chinese ? '文件夹' : 'Folder'),
          ('stack', chinese ? '堆叠' : 'Stack'),
        ])
          _menuItem(
            label: label,
            checked: widget.folderView == value,
            onPressed: widget.onFolderViewChanged == null
                ? null
                : () => widget.onFolderViewChanged!(value),
          ),
        // :389-396 — View content as heading + Fan/Grid/List.
        _heading(chinese ? '内容视图' : 'View content as'),
        for (final (value, label) in [
          ('fan', chinese ? '扇形' : 'Fan'),
          ('grid', chinese ? '网格' : 'Grid'),
          ('list', chinese ? '列表' : 'List'),
        ])
          _menuItem(
            label: label,
            checked: widget.folderView == value,
            onPressed: widget.onFolderViewChanged == null
                ? null
                : () => widget.onFolderViewChanged!(value),
          ),
        _separator(),
      ],
      // :398-403 — Open label by kind.
      _menuItem(
        label: kind == 'trash'
            ? (chinese ? '打开回收站' : 'Open Trash')
            : kind == 'file'
            ? (chinese ? '打开' : 'Open')
            : (chinese ? '在文件管理器中打开' : 'Open in File Manager'),
        onPressed: widget.onOpen == null
            ? null
            : () {
                widget.onClose();
                widget.onOpen!();
              },
      ),
      // :404-409 — trash: Empty Trash… two-stage destructive confirm.
      if (kind == 'trash')
        _menuItem(
          label: _emptyTrashArmed
              ? (chinese ? '永久删除回收站中的所有项目？' : 'Permanently delete all items in Trash?')
              : (chinese ? '清空回收站…' : 'Empty Trash…'),
          destructive: true, // :408 destructive flag
          onPressed: widget.onEmptyTrash == null ? null : _emptyTrash,
        )
      else
        // :410-414 — folder/file: Remove from Dock.
        _menuItem(
          label: chinese ? '从 Dock 移除' : 'Remove from Dock',
          onPressed: widget.onRemoveFromDock == null
              ? null
              : () {
                  widget.onClose();
                  widget.onRemoveFromDock!();
                },
        ),
    ];
  }

  /// One folder listing row — cascade for guarded directories, plain
  /// `fileActivated` row otherwise (:93-107).
  Widget _folderRow(DockFolderEntry entry, {required Set<String> ancestorUrls}) {
    // :95 — nested ⇔ isDirectory && !isLink && url ∉ ancestorUrls.
    final nested =
        entry.isDirectory &&
        !entry.isLink &&
        !ancestorUrls.contains(entry.url);
    if (nested) {
      return _CascadeFolderItem(
        key: ValueKey('folder:${entry.url}'),
        entry: entry,
        monitorBounds: widget.monitorBounds,
        ancestorUrls: {...ancestorUrls, entry.url},
        onFileActivated: widget.onFileActivated,
        dismiss: widget.onClose,
        timerFactory: widget.timerFactory,
      );
    }
    return _menuItem(
      label: entry.name,
      onPressed: widget.onFileActivated == null
          ? null
          : () {
              widget.onClose();
              widget.onFileActivated!(entry.url); // :167 fileActivated
            },
    );
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    // :620-627 — anchor rect + output = monitorBounds ∩ overlaySize.
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final output =
        (widget.monitorBounds ?? (Offset.zero & layout.overlaySize))
            .intersect(Offset.zero & layout.overlaySize);
    // :631-636 — width/maxHeight budgets; zero → shrink, no overlay.
    final width = math.min(244.0, math.max(0.0, output.width - 16));
    final maxHeight = math.max(0.0, anchor.top - output.top - 16);
    if (width == 0 || maxHeight == 0) {
      return const SizedBox.shrink();
    }
    // :637-640 — centred on the anchor, clamped inside output − 8.
    final left = (anchor.center.dx - width / 2).clamp(
      output.left + 8,
      output.right - width - 8,
    );
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    // Menu radius 8 scaled by the shell roundness (was hardcoded).
    final radius = BorderRadius.circular(shell.scaledRadius(8));
    return ShellInputRegion(
      debugLabel: 'Dock context menu',
      // :646-647 / tray.dart:142-144 — scene-wide pointer + key capture.
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: CallbackShortcuts(
        bindings: {
          // :650 — Escape closes the menu.
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Focus(
          autofocus: true, // :652-653
          child: Stack(
            children: [
              Positioned.fill(
                // :656-662 / tray.dart:162-171 — dismiss on the down phase,
                // before desktop gestures or clients can claim the release.
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => widget.onClose(),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                // :665 — panel bottom sits 8px above the anchor top.
                bottom: layout.overlaySize.height - anchor.top + 8,
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  // The source popup is a plain `visible` toggle — the app
                  // context menu appears instantly with no entrance fade
                  // (taskbar menu: same, window_buttons.dart:668+). Showing
                  // the menu fully opaque keeps a right-click over a live
                  // preview a single-step switch instead of preview-out →
                  // fade-in.
                  child: ShellBackdropBlur(
                      // blur under every translucent panel (blur/glass on);
                      // off mode paints flat — same gate as the tray glass.
                      blur: shell.backdropBlurEnabled,
                      separateChild: true,
                      borderRadius: radius,
                      child: Material(
                        // cardColor: matches the desktop widget surface so
                        // menus and the tray share the shell card opacity.
                        color: shell.cardColor(
                          colors.surfaceContainer,
                        ),
                        surfaceTintColor: Colors.transparent, // :677
                        shape: RoundedRectangleBorder(
                          side: BorderSide(color: colors.outlineVariant),
                          borderRadius: radius,
                        ),
                        clipBehavior: Clip.antiAlias, // :682
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(6), // :683-684
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: widget.kind == 'app'
                                ? _appItems(context)
                                : _fileItems(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One cascading directory row — nested `OverlayPortal` equivalent of
/// `DockFolderMenu.qml`'s `insertMenu`/`createSubmenu` (:100, :137-151).
/// Opens right of the parent row and flips left when the output is too
/// narrow; `ancestorUrls` breaks recursive-directory cycles (:95).
class _CascadeFolderItem extends StatefulWidget {
  const _CascadeFolderItem({
    required this.entry,
    required this.monitorBounds,
    required this.ancestorUrls,
    required this.onFileActivated,
    required this.dismiss,
    required this.timerFactory,
    super.key,
  });

  final DockFolderEntry entry;
  final Rect? monitorBounds;
  final Set<String> ancestorUrls;
  final void Function(String url)? onFileActivated;
  final VoidCallback dismiss;
  final DockMenuTimerFactory timerFactory;

  @override
  State<_CascadeFolderItem> createState() => _CascadeFolderItemState();
}

class _CascadeFolderItemState extends State<_CascadeFolderItem> {
  final _portal = OverlayPortalController();
  Timer? _hoverTimer;
  bool _inside = false;
  bool _insideSubmenu = false;

  static const _openDelay = Duration(milliseconds: 200);
  static const _closeDelay = Duration(milliseconds: 180);

  void _open() {
    _hoverTimer?.cancel();
    _portal.show();
  }

  /// Pointer left both the row and the open submenu → close after the dock
  /// close delay (hover bridge: moving onto the submenu cancels this).
  void _scheduleClose() {
    _hoverTimer?.cancel();
    _hoverTimer = widget.timerFactory(_closeDelay, () {
      if (!_inside && !_insideSubmenu) _portal.hide();
    });
  }

  void _scheduleOpen() {
    _inside = true;
    _hoverTimer?.cancel();
    if (_portal.isShowing) return;
    _hoverTimer = widget.timerFactory(_openDelay, _open);
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese =
        Localizations.localeOf(context).languageCode == 'zh';
    final colors = Theme.of(context).colorScheme;
    final foreground = dockMenuForeground(context);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) {
        // Row rect in overlay coordinates; output = bounds ∩ overlay.
        final row = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        final output =
            (widget.monitorBounds ?? (Offset.zero & info.overlaySize))
                .intersect(Offset.zero & info.overlaySize);
        // DockFolderMenu width 360 (:27) clamped into the output.
        final width = math.min(360.0, math.max(0.0, output.width - 16));
        if (width == 0) return const SizedBox.shrink();
        // Expand right of the row; flip left when it would overflow.
        final openRight = row.right + 4 + width <= output.right - 8;
        final left = (openRight ? row.right + 4 : row.left - 4 - width)
            .clamp(output.left + 8, output.right - width - 8);
        final maxHeight = math.max(0.0, output.bottom - 8 - row.top + 6);
        if (maxHeight == 0) return const SizedBox.shrink();
        final cascadeRadius = BorderRadius.circular(
          context.shellTheme.scaledRadius(8),
        );
        return Stack(
          children: [
            Positioned(
              left: left.toDouble(),
              top: math.max(output.top + 8, row.top - 6),
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                // Hover bridge: pointer inside the submenu keeps it alive
                // (preview-card MouseRegion 续命 :798-800 equivalent).
                child: MouseRegion(
                  onEnter: (_) {
                    _insideSubmenu = true;
                    _hoverTimer?.cancel();
                  },
                  onExit: (_) {
                    _insideSubmenu = false;
                    _scheduleClose();
                  },
                  child: ShellBackdropBlur(
                    blur: context.shellTheme.backdropBlurEnabled,
                    separateChild: true,
                    borderRadius: cascadeRadius,
                    child: Material(
                      color: context.shellTheme.cardColor(
                        colors.surfaceContainer,
                      ),
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: colors.outlineVariant),
                        borderRadius: cascadeRadius,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(6),
                        child: _FolderRows(
                          entries: widget.entry.children,
                          ancestorUrls: widget.ancestorUrls,
                          available: widget.entry.available,
                          chinese: chinese,
                          onFileActivated: widget.onFileActivated,
                          folderUrl: widget.entry.url,
                          dismiss: widget.dismiss,
                          monitorBounds: widget.monitorBounds,
                          timerFactory: widget.timerFactory,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: MouseRegion(
        onEnter: (_) => _scheduleOpen(),
        onExit: (_) {
          _inside = false;
          _scheduleClose();
        },
        child: SizedBox(
          height: 34, // DockFolderMenu delegate implicitHeight (:177)
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
            onPressed: _open,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // arrow chevron_right (:188-194).
                Icon(Icons.chevron_right, size: 18, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The recursive folder rows shared by the root list view and every nested
/// cascade portal — the `ancestorUrls` guard (:95) is carried in
/// [ancestorUrls] so cyclic directory graphs cannot recurse forever.
class _FolderRows extends StatelessWidget {
  const _FolderRows({
    required this.entries,
    required this.ancestorUrls,
    required this.available,
    required this.chinese,
    required this.onFileActivated,
    required this.folderUrl,
    required this.dismiss,
    required this.monitorBounds,
    required this.timerFactory,
  });

  final List<DockFolderEntry> entries;
  final Set<String> ancestorUrls;
  final bool available;
  final bool chinese;
  final void Function(String url)? onFileActivated;
  final String folderUrl;
  final VoidCallback dismiss;
  final Rect? monitorBounds;
  final DockMenuTimerFactory timerFactory;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = dockMenuForeground(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          if (entry.isDirectory &&
              !entry.isLink &&
              !ancestorUrls.contains(entry.url)) // :95 nested guard
            _CascadeFolderItem(
              key: ValueKey('folder:${entry.url}'),
              entry: entry,
              monitorBounds: monitorBounds,
              ancestorUrls: {...ancestorUrls, entry.url},
              onFileActivated: onFileActivated,
              dismiss: dismiss,
              timerFactory: timerFactory,
            )
          else
            // Non-nested rows activate the file (:167 fileActivated).
            SizedBox(
              height: 34,
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
                onPressed: onFileActivated == null
                    ? null
                    : () {
                        dismiss();
                        onFileActivated!(entry.url);
                      },
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        if (entries.isEmpty)
          // :196-203 — empty/unavailable disabled row.
          SizedBox(
            height: 34,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  available
                      ? (chinese ? '文件夹为空' : 'Folder is empty')
                      : (chinese ? '文件夹不可用' : 'Folder is unavailable'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        Container(
          // :204 MenuSeparator.
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: colors.onSurface.withValues(alpha: 0.16),
        ),
        // :205-213 — Open in File Manager → fileActivated(folderUrl).
        SizedBox(
          height: 34,
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
            onPressed: available && onFileActivated != null
                ? () {
                    dismiss();
                    onFileActivated!(folderUrl);
                  }
                : null,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                chinese ? '在文件管理器中打开' : 'Open in File Manager',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
