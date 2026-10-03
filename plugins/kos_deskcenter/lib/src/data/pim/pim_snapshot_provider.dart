/// 插件内 PIM 快照供给（TASK-11）：`PimSnapshotWatcher` 实现既有
/// `WidgetSnapshotWatcher` 接口供 `KosDeskCenterView(watcher:)` 直接接线，
/// Riverpod provider 供卡片 `ref.watch`。
///
/// 权威源是插件内 [PimStore]（`calendar.ics`/`metadata.json` 解析 +
/// `widget-snapshot.json` 生产均在插件内）；既有
/// `FileWidgetSnapshotWatcher` 仍可读外部写的 `widget-snapshot.json`
/// 做迁移兼容，但不再是生产端（任务卡 §4）。
///
/// 生命周期对齐 `PimWidgetService.qml`：loading → ready /
/// 5000ms 宽限期后 unavailable（:21-38）；store 每次产快照即推流。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widget_snapshot_watcher.dart';
import 'pim_store.dart';

/// 由插件内 [PimStore] 驱动的 [WidgetSnapshotWatcher]。
///
/// 与 `FileWidgetSnapshotWatcher` 同一接口，但数据不经文件：`start()`
/// 触发 `store.load()`（load 尾部自动产首份快照，对齐
/// PimStore.cpp:621 `singleShot(0, writeWidgetSnapshot)`）；之后
/// mutation/外部文件变更/5 分钟周期刷新都经 `store.snapshots` 推流。
final class PimSnapshotWatcher implements WidgetSnapshotWatcher {
  /// [store] 缺省时自建（拥有生命周期，`dispose` 连带释放）；
  /// 传入外部 store 时只订阅不释放。
  PimSnapshotWatcher({PimStore? store})
    : _store = store ?? PimStore(),
      _ownsStore = store == null;

  final PimStore _store;
  final bool _ownsStore;

  /// 可用性宽限期（PimWidgetService.qml:34-38 `5000ms`）。
  static const Duration _gracePeriod = Duration(seconds: 5);

  StreamSubscription<WidgetSnapshot>? _sub;
  Timer? _graceTimer;
  bool _started = false;
  bool _disposed = false;
  WidgetSnapshotState _state = WidgetSnapshotState.loading;

  final StreamController<WidgetSnapshot> _snapshots =
      StreamController<WidgetSnapshot>.broadcast();
  final StreamController<WidgetSnapshotState> _states =
      StreamController<WidgetSnapshotState>.broadcast();

  /// 底层 store（卡片需要 mutation/`eventsForRange` 时从这里拿）。
  PimStore get store => _store;

  @override
  Stream<WidgetSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<WidgetSnapshotState> get states => _states.stream;

  @override
  WidgetSnapshotState get state => _state;

  @override
  void start() {
    if (_started || _disposed) return; // 幂等（对齐 FileWidgetSnapshotWatcher）。
    _started = true;
    _emit(WidgetSnapshotState.loading);
    _graceTimer = Timer(_gracePeriod, () {
      if (_state == WidgetSnapshotState.loading) {
        _emit(WidgetSnapshotState.unavailable);
      }
    });
    _sub = _store.snapshots.listen((snapshot) {
      if (_disposed) return;
      if (!_snapshots.isClosed) _snapshots.add(snapshot);
      _emit(WidgetSnapshotState.ready);
    });
    unawaited(_store.load());
  }

  void _emit(WidgetSnapshotState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _graceTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_snapshots.close());
    unawaited(_states.close());
    if (_ownsStore) unawaited(_store.dispose());
  }
}

/// 全局 [PimStore] 实例 provider（容器接线收口处可 override 注入
/// 测试实例）。构造即 `load()`；autoDispose 时释放 store。
final pimStoreProvider = Provider<PimStore>(
  (ref) {
    final store = PimStore();
    unawaited(store.load());
    ref.onDispose(() => unawaited(store.dispose()));
    return store;
  },
  isAutoDispose: true,
);

/// `WidgetSnapshot` 流 provider：等价
/// `ref.watch(pimStoreProvider).snapshots` 的 StreamProvider 包装。
/// 卡片层亦可继续消费 `calendar_card.dart` 的 `widgetSnapshotProvider`
/// 占位（接线收口时让其 watch 本 provider）。
final pimSnapshotProvider = StreamProvider<WidgetSnapshot>(
  (ref) => ref.watch(pimStoreProvider).snapshots,
  isAutoDispose: true,
);
