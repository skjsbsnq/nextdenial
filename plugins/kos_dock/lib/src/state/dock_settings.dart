/// KOS Dock 偏好 provider（串行写队列 + 可注入 store）与垃圾桶 provider，
/// 以及信息卡区数据 provider（天气/metrics，TASK-05）。
///
/// 搬自 denial_taskbar `taskbar_settings.dart` 整文件改 Dock 命名：
/// `AsyncNotifierProvider` + `_writes` 串行队列保证写不交错；store 经
/// [dockPreferencesStoreProvider] 注入，测试可 override 为内存假实现
/// （CONSTRAINTS §10）。垃圾桶服务同款注入点（[trashServiceProvider]）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dock_metrics.dart';
import '../data/dock_metrics_io.dart';
import '../data/dock_preferences.dart';
import '../data/dock_preferences_io.dart';
import '../data/dock_weather.dart';
import '../data/dock_weather_io.dart';
import '../data/trash_service.dart';
import '../data/trash_service_io.dart';

export '../data/dock_metrics.dart';
export '../data/dock_preferences.dart';
export '../data/dock_weather.dart';
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

/// 天气数据 provider 注入点：生产为 Open-Meteo + 状态文件实现；测试
/// override 为假 [DockWeatherProvider]（CONSTRAINTS §10）。
///
/// keepAlive（非 autoDispose）：info 卡槽是 `hasInfo` 门控的按需子树，
/// autoDispose 会在槽短暂卸载时重启刷新节奏/丢 ready 快照（记
/// docs/visual-deltas.md）。
final dockWeatherProviderProvider = Provider<DockWeatherProvider>((ref) {
  final provider = OpenMeteoDockWeatherProvider();
  ref.onDispose(provider.dispose);
  return provider;
});

/// metrics 采集器注入点：生产为 procfs/df 实现；测试 override 为假
/// [DockMetricsCollector]。
final dockMetricsCollectorProvider = Provider<DockMetricsCollector>((ref) {
  final collector = ProcfsDockMetricsCollector();
  ref.onDispose(collector.dispose);
  return collector;
});

/// 天气快照流（订阅即 `start()`）。
final dockWeatherSnapshotProvider = StreamProvider<DockWeatherSnapshot>((ref) {
  final provider = ref.watch(dockWeatherProviderProvider);
  unawaited(provider.start());
  return provider.snapshots;
});

/// metrics 快照流（订阅即 `start()`）。
final dockMetricsSnapshotProvider = StreamProvider<DockMetricsSnapshot>((ref) {
  final collector = ref.watch(dockMetricsCollectorProvider);
  collector.start();
  return collector.snapshots;
});

final dockPreferencesProvider =
    AsyncNotifierProvider<DockPreferencesController, DockPreferences>(
      DockPreferencesController.new,
    );

/// 搬自 denial_taskbar `taskbar_settings.dart:12-47`（去 leftAligned 字段，
/// 加 showLauncher/showTrash 可见性写路径；TASK-05 加 infoCard 写路径）。
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
    // 写回后保留可见性 flag 与信息卡字段（原实现重置为默认，TASK-04 修复；
    // TASK-05 同样不能丢 infoCard*）。
    state = AsyncData(
      DockPreferences(
        pinned: snapshot,
        showLauncher: current.showLauncher,
        showTrash: current.showTrash,
        infoCardOrder: current.infoCardOrder,
        infoCardAutoRotate: current.infoCardAutoRotate,
        infoCardMode: current.infoCardMode,
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
            infoCardOrder: current.infoCardOrder,
            infoCardAutoRotate: current.infoCardAutoRotate,
            infoCardMode: current.infoCardMode,
          ),
        );
      });

  /// KOS DockConfigService `moveInfoCard`/`addInfoCard`/`removeInfoCard`
  /// （dock/DockConfigService.qml:283-352）：order 先经
  /// [normalizeDockInfoCardOrder] 归一化再落盘；state 保留 pinned/可见性。
  Future<void> updateInfoCardOrder(
    List<String> Function(List<String>) update,
  ) => _enqueue(() async {
    final current = state.requireValue;
    final order = normalizeDockInfoCardOrder(update(current.infoCardOrder));
    await _store.writeInfoCards(order: order);
    if (!ref.mounted) return;
    state = AsyncData(
      DockPreferences(
        pinned: current.pinned,
        showLauncher: current.showLauncher,
        showTrash: current.showTrash,
        infoCardOrder: order,
        infoCardAutoRotate: current.infoCardAutoRotate,
        infoCardMode: current.infoCardMode,
      ),
    );
  });

  /// `infoCardAutoRotate` 开关（`!== false` 同式，默认 true；
  /// dock/DockConfigService.qml:259-273）。
  Future<void> updateInfoCardAutoRotate(bool autoRotate) => _enqueue(() async {
    final current = state.requireValue;
    await _store.writeInfoCards(autoRotate: autoRotate);
    if (!ref.mounted) return;
    state = AsyncData(
      DockPreferences(
        pinned: current.pinned,
        showLauncher: current.showLauncher,
        showTrash: current.showTrash,
        infoCardOrder: current.infoCardOrder,
        infoCardAutoRotate: autoRotate,
        infoCardMode: current.infoCardMode,
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
