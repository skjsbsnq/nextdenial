/// KOS Dock 偏好 provider（串行写队列 + 可注入 store）与垃圾桶 provider。
///
/// 搬自 denial_taskbar `taskbar_settings.dart` 整文件改 Dock 命名：
/// `AsyncNotifierProvider` + `_writes` 串行队列保证写不交错；store 经
/// [dockPreferencesStoreProvider] 注入，测试可 override 为内存假实现
/// （CONSTRAINTS §10）。垃圾桶服务同款注入点（[trashServiceProvider]）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dock_preferences.dart';
import '../data/dock_preferences_io.dart';
import '../data/trash_service.dart';
import '../data/trash_service_io.dart';

export '../data/dock_preferences.dart';
export '../data/trash_service.dart';

/// store 注入点：生产环境为文件实现；测试 override 为内存假实现。
final dockPreferencesStoreProvider = Provider<DockPreferencesStore>(
  (_) => FileDockPreferencesStore(FileDockPreferencesStore.defaultFile()),
);

/// 垃圾桶服务注入点：生产环境为 dart:io freedesktop 实现；测试 override
/// 为假实现（CONSTRAINTS §10）。
final trashServiceProvider = Provider<TrashService>((_) => FileTrashService());

/// 垃圾桶状态流：订阅即 `watch()`（先 emit 当前状态，随后变化重发）。
final trashStateProvider = StreamProvider<TrashState>(
  (ref) => ref.watch(trashServiceProvider).watch(),
);

final dockPreferencesProvider =
    AsyncNotifierProvider<DockPreferencesController, DockPreferences>(
      DockPreferencesController.new,
    );

/// 搬自 denial_taskbar `taskbar_settings.dart:12-47`（去 leftAligned 字段，
/// 加 showLauncher/showTrash 可见性写路径）。
class DockPreferencesController extends AsyncNotifier<DockPreferences> {
  late DockPreferencesStore _store;
  Future<void> _writes = Future.value();

  @override
  Future<DockPreferences> build() {
    _store = ref.watch(dockPreferencesStoreProvider);
    return _store.read();
  }

  Future<void> updatePins(
    List<PinnedApplication> Function(List<PinnedApplication>) update,
  ) => _enqueue(() async {
    final current = state.requireValue;
    final snapshot = List<PinnedApplication>.unmodifiable(
      update(current.pinned),
    );
    await _store.writePins(snapshot);
    if (!ref.mounted) return;
    // 写回后保留可见性 flag（原实现重置为默认 true，TASK-04 修复）。
    state = AsyncData(
      DockPreferences(
        pinned: snapshot,
        showLauncher: current.showLauncher,
        showTrash: current.showTrash,
      ),
    );
  });

  Future<void> updateShowLauncher(bool showLauncher) =>
      _updateVisibility(showLauncher: showLauncher);

  Future<void> updateShowTrash(bool showTrash) =>
      _updateVisibility(showTrash: showTrash);

  /// 两个可见性写走同一 `_writes` 队列；成功后 state 保留 pinned 与另一
  /// flag（只改指定项）。
  Future<void> _updateVisibility({bool? showLauncher, bool? showTrash}) =>
      _enqueue(() async {
        final current = state.requireValue;
        await _store.writeVisibility(
          showLauncher: showLauncher,
          showTrash: showTrash,
        );
        if (!ref.mounted) return;
        state = AsyncData(
          DockPreferences(
            pinned: current.pinned,
            showLauncher: showLauncher ?? current.showLauncher,
            showTrash: showTrash ?? current.showTrash,
          ),
        );
      });

  /// 串行队列：按调用顺序执行；单次失败上报给调用方，但不毒化后续写
  /// （搬自 taskbar_settings.dart 的 `_writes` 语义）。
  Future<void> _enqueue(Future<void> Function() operation) {
    final queued = _writes.then((_) async {
      if (!ref.mounted) return;
      await operation();
    });
    // A failed write is reported to the invoking UI but must not poison later saves.
    _writes = queued.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return queued;
  }
}
