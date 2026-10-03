/// Dock integration host.
///
/// Wires the TASK-07 `dock.json` store and the host's application / window
/// projections into [DockSurface], and owns the two behaviours that live above
/// the widget layer:
///
/// - row composition, ported from `Services/DockService.qml:158-248`:
///   pinned rows → running window groups not already pinned → trash; Denial has
///   no "recent apps" history channel, so the source's `showRecent` block
///   (:217-223) has no equivalent and a leading `launcher` row is used instead
///   so the dock always offers a way to pick an application (the taskbar's
///   start button is the other entry point). Recorded in visual-deltas.md;
/// - pin/unpin through the TASK-05 menu, persisted with [DockStore].
library;

import 'package:denial_flutter_sdk/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/dock_store.dart';
import 'dock_spacer.dart';
import 'dock_surface.dart';

/// `key` of the leading application-launcher row.
const String kDockLauncherKey = 'launcher';

/// Groups [windows] by `dockDesktopId(appId)` (`DockModel.groupWindows`
/// key semantics `:122-126`), focused windows first then by id.
Map<String, List<ApplicationWindow>> groupDockWindows(
  List<ApplicationWindow> windows,
) {
  final groups = <String, List<ApplicationWindow>>{};
  for (final window in windows) {
    final id = dockDesktopId(window.appId);
    final key = id.isEmpty ? 'window:${window.id}' : 'app:$id';
    (groups[key] ??= <ApplicationWindow>[]).add(window);
  }
  for (final list in groups.values) {
    list.sort((left, right) {
      if (left.active != right.active) return left.active ? -1 : 1;
      return left.id.compareTo(right.id);
    });
  }
  return groups;
}

/// Finds the catalog entry behind [desktopId] by launch id, icon appId or the
/// window app-ids the host maps onto it (`DockModel.applicationForWindow`
/// :103-120 equivalent).
LaunchableApplication? findDockApplication(
  List<LaunchableApplication> applications,
  String desktopId,
) {
  if (desktopId.isEmpty) return null;
  for (final application in applications) {
    if (dockDesktopId(application.id) == desktopId ||
        dockDesktopId(application.appId) == desktopId) {
      return application;
    }
  }
  for (final application in applications) {
    if (application.windowAppIds.any(
      (appId) => dockDesktopId(appId) == desktopId,
    )) {
      return application;
    }
  }
  return null;
}

/// Builds the dock rows from the persisted config plus the host projections
/// (`DockService.qml:173-244` with the file/recent blocks cut).
List<DockEntry> buildDockEntries({
  required DockConfig config,
  required List<LaunchableApplication> applications,
  required List<ApplicationWindow> windows,
  required int trashCount,
  bool showLauncher = true,
}) {
  final groups = groupDockWindows(windows);
  final entries = <DockEntry>[];
  if (showLauncher) {
    entries.add(
      const DockEntry(
        key: kDockLauncherKey,
        kind: 'launcher',
        name: 'Applications',
        appId: '',
        available: true,
      ),
    );
  }
  final used = <String>{};
  for (final pin in config.pinned) {
    if (pin is DockAppPin) {
      final key = 'app:${pin.desktopId}';
      used.add(key);
      entries.add(
        _appEntry(
          key: key,
          desktopId: pin.desktopId,
          applications: applications,
          windows: groups[key] ?? const <ApplicationWindow>[],
          pinned: true,
        ),
      );
    } else if (pin is DockSpacerPin) {
      entries.add(dockSpacerEntry(id: pin.id, small: pin.small));
    }
    // Folder pins are out of scope (file rows were cut with external drags).
  }
  for (final key in groups.keys) {
    if (used.contains(key)) continue;
    entries.add(
      _appEntry(
        key: key,
        desktopId: key.startsWith('app:') ? key.substring(4) : '',
        applications: applications,
        windows: groups[key]!,
        pinned: false,
      ),
    );
  }
  entries.add(dockTrashEntry(trashCount: trashCount)); // :232-244
  return entries;
}

/// Number of leading rows that sit *before* the first unpinned running app —
/// the `sectionBoundary` seed (`DockLayout.sectionBoundaries`).
int dockPinnedRowCount(List<DockEntry> entries) {
  var count = 0;
  for (final entry in entries) {
    if (entry.kind == 'launcher' || entry.pinned) {
      count++;
    } else {
      break;
    }
  }
  return count;
}

/// Adds or removes the `app:<desktopId>` pin behind [key]
/// (`DockService.pin/unpin` :382-399). Non-app keys are returned unchanged;
/// a full pin list is left as-is.
DockConfig toggleDockPin(DockConfig config, String key) {
  if (!key.startsWith('app:')) return config;
  final pinned = <DockPin>[...config.pinned];
  final index = pinned.indexWhere((pin) => pin.pinnedKey == key);
  if (index >= 0) {
    pinned.removeAt(index);
  } else {
    if (pinned.length >= kDockMaxPinned) return config;
    pinned.add(DockAppPin(desktopId: key.substring(4)));
  }
  return DockConfig(options: config.options, pinned: pinned);
}

/// Moves the pinned entry behind [fromKey] onto the position held by [toKey] and
/// returns a new `DockConfig`.
///
/// Semantics (pinned by tests):
/// - keys are `DockPin.pinnedKey` values (`app:<desktopId>` / `spacer:<id>`);
/// - the moved entry lands at [toKey]'s *original* list index, so dragging past
///   a target places it after that target and dragging back places it before;
/// - same key, an unknown key, or an out-of-range pair returns the **same**
///   config instance (`identical`), so callers can no-op without persisting.
///
/// Denial crop (docs/visual-deltas.md): only the `pinned` list is reorderable —
/// launcher, running and trash rows never enter `config.pinned`, and there is no
/// cross-section pinning / external file drop from the source
/// (`DockService.movePinned`, DockModel.js:191-201).
DockConfig reorderDockPins(DockConfig config, String fromKey, String toKey) {
  if (fromKey == toKey) return config;
  final pinned = <DockPin>[...config.pinned];
  final fromIndex = pinned.indexWhere((pin) => pin.pinnedKey == fromKey);
  final toIndex = pinned.indexWhere((pin) => pin.pinnedKey == toKey);
  if (fromIndex < 0 || toIndex < 0) return config;
  final moved = pinned.removeAt(fromIndex);
  pinned.insert(toIndex, moved);
  return DockConfig(options: config.options, pinned: pinned);
}

DockEntry _appEntry({
  required String key,
  required String desktopId,
  required List<LaunchableApplication> applications,
  required List<ApplicationWindow> windows,
  required bool pinned,
}) {
  final application = findDockApplication(applications, desktopId);
  final first = windows.isEmpty ? null : windows.first;
  return DockEntry(
    key: key,
    kind: 'app',
    name: application?.name ?? first?.title ?? desktopId,
    appId: application?.appId ?? first?.appId ?? desktopId,
    launchId: application?.id ?? (desktopId.isEmpty ? null : desktopId),
    windowId: first?.id,
    windowCount: windows.length,
    focused: windows.any((window) => window.active),
    available: application != null || windows.isNotEmpty, // :154
    windows: windows,
    pinned: pinned,
  );
}

/// Reacts to the host's application/window projections and owns the dock
/// config, rendering a fully wired [DockSurface].
class DockHost extends ConsumerStatefulWidget {
  const DockHost({
    required this.services,
    required this.monitorId,
    super.key,
    this.iconSize = 48,
    this.showLauncher = true,
    this.store,
    this.trashCount,
    this.statusBarBuilder,
  });

  /// Host bundle (`surface.services`).
  final ShellServices services;

  /// Target output.
  final int monitorId;

  /// Resting icon edge (`DockService.iconSize`).
  final double iconSize;

  /// Render the leading launcher row (Denial addition, see library doc).
  final bool showLauncher;

  /// Config store; `null` resolves [DockStore.defaultPath] (falls back to
  /// in-memory defaults when no config directory exists).
  final DockStore? store;

  /// Trash item count; `null` probes the XDG trash directory
  /// ([dockTrashCount]).
  final int? trashCount;

  /// 左右状态槽构建器（kos_topbar 合并迁入），透传给 [DockSurface]；
  /// `null` 不渲染（widget 测试不传）。真实装配 `kos_dock.dart` 传
  /// [buildDockStatusBar]。
  final WidgetBuilder? statusBarBuilder;

  @override
  ConsumerState<DockHost> createState() => _DockHostState();
}

class _DockHostState extends ConsumerState<DockHost> {
  DockStore? _store;
  DockConfig _config = DockConfig.defaults;
  int _trashCount = 0;

  @override
  void initState() {
    super.initState();
    // No config directory (no XDG_CONFIG_HOME/HOME) is not fatal: fall back to
    // the defaults without persistence.
    final store = widget.store;
    if (store != null) {
      _store = store;
      _config = store.read();
    } else {
      try {
        _store = DockStore();
        _config = _store!.read();
      } on Object {
        _store = null;
      }
    }
    _trashCount = widget.trashCount ?? dockTrashCount();
  }

  void _togglePin(String key) {
    final config = toggleDockPin(_config, key);
    if (identical(config, _config)) return;
    setState(() => _config = config);
    try {
      _store?.write(config);
    } on Object {
      // Persistence failure keeps the in-memory state; the file is untouched.
    }
  }

  void _onActivated(String key) {
    if (key == kDockLauncherKey) {
      widget.services.toggleLauncher();
    }
    // `trash` is display-only: the SDK exposes no `openUrl`/spawn channel.
  }

  /// Commits a pinned-row reorder from the dock drag (`DockService.movePinned`).
  void _onReorder(String fromKey, String toKey) {
    final config = reorderDockPins(_config, fromKey, toKey);
    if (identical(config, _config)) return;
    setState(() => _config = config);
    try {
      _store?.write(config);
    } on Object {
      // Persistence failure keeps the in-memory order.
    }
  }

  @override
  Widget build(BuildContext context) {
    final ProviderListenable<List<LaunchableApplication>> applications =
        widget.services.applications;
    final ProviderListenable<List<ApplicationWindow>> windows = widget.services
        .windows(widget.monitorId);
    final entries = buildDockEntries(
      config: _config,
      applications: ref.watch(applications),
      windows: ref.watch(windows),
      trashCount: _trashCount,
      showLauncher: widget.showLauncher,
    );
    return DockSurface(
      entries: entries,
      services: widget.services,
      monitorId: widget.monitorId,
      iconSize: widget.iconSize,
      pinnedAppCount: dockPinnedRowCount(entries),
      onItemActivated: _onActivated,
      onItemReordered: _onReorder,
      onTogglePin: _togglePin,
      statusBarBuilder: widget.statusBarBuilder,
    );
  }
}
