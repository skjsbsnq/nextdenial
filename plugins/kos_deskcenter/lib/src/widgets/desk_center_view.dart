/// KOS DeskCenter 桌面容器（`KosDeskCenterView`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml`（行号锚定
/// `/home/wwt/文档/NextKde/shell/desktop/modules/deskcenter/`）：
///
/// - 网格几何（:41-75）：全屏 10 列方格，部件只占左 `widgetColumns=4` 列
///   （:42）；`cellSize` 由容器宽推导——`sideMargin 20`（:43）对应
///   ShellSurface bounds 语义（place() 已把 bounds 内缩到左区），布局基数
///   取 `layoutBaseSideMargin 8` + `layoutBaseGap 10`（:47-48）：
///   `cellSize = max(1, (w − 8·2 − 10·9) / 10)`；行数
///   `usableRows = max(0, floor((h + gap) / (cellSize + gap)))`（:74-75），
///   `gap` 取 `widget.gap` = 10（:70）；
/// - 部件摆放（:451-483）：`packWidgets`（widget_layout.dart）按
///   priority 降序 first-fit，`x/y/width/height` 的 `Behavior` 隐式动画
///   （:480-483，`normalDuration` + `standardEasing`）→
///   `AnimatedPositioned`/`AnimatedContainer` 220ms OutQuart（material 档
///   默认值，AppearanceTokens.qml:501-505）；
/// - 编辑模式（:81-94、:299-319、:486-527、:551-591）：
///   长按空白/右键卡片进入（`enterWidgetEditMode`），工具栏「+ 组件/完成」
///   （:332-371）、部件库面板七项开关（:373-449）、卡片角标
///   `cycleSize`/`setVisible(false)`（:563-566、:588-590）、
///   拖拽最近邻换序 `moveWidget`（DragHandler :492-527）；编辑态无桌面
///   文件网格可清，对应 `clearDesktopSelection`（:85）为空操作；
/// - 持久化：所有编辑动作经 [DeskCenterConfig] 产出新值并写
///   `DeskCenterConfigStore`（对应 `_settings.sync()` + `revision++`，
///   DeskCenterConfigService.qml:64-65、:83-84）。
///
/// 已知收窄（详见 docs/visual-deltas.md §8-§9）：
/// - 拖拽视觉为「松手即换序重排」（DragHandler onActiveChanged 语义），
///   无跟手 offset/1.035 缩放；
/// - Flutter `GestureDetector` 无「仅无修饰键」条件，源
///   `modifiers === Qt.NoModifier`（:316）不可表达；
/// - 悬停尺寸提示（:531-549）仅在鼠标环境下由 MouseRegion 驱动；
/// - activity 卡前台应用榜为插件侧轮询近似（TASK-06，§9）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_sdk/system.dart' show LoadSeries;
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/kos_data_client.dart';
import '../data/system_metrics_collector.dart';
import '../data/weather_provider.dart';
import '../data/widget_snapshot_watcher.dart';
import '../layout/widget_layout.dart';
import '../state/desk_center_config.dart';
import '../state/desk_center_config_io.dart';
import '../data/activity_ledger.dart';
import 'activity_card.dart';
import 'calendar_card.dart';
import 'clock_card.dart';
import 'desk_card.dart';
import 'desk_panel_shell.dart';
import 'music_card.dart';
import 'system_card.dart';
import 'todo_card.dart';
import 'weather_card.dart';

/// 网格常数（DeskCenterWindow.qml:41-48）。
abstract final class _Grid {
  /// `columns: 10`（:41）——cellSize 的全宽推导基数。
  static const columns = 10;

  /// `widgetColumns: min(4, columns)`（:42）——部件装箱列数。
  static const widgetColumns = 4;

  /// `layoutBaseSideMargin: 8`（:47）。
  static const baseSideMargin = 8.0;

  /// `layoutBaseGap: 10`（:48）→ `gap = widget.gap`（:70）。
  static const gap = 10.0;
}

/// 卡片隐式动画时长：`AppearanceTokens.motion.normalDuration` 的
/// material 档 220ms（AppearanceTokens.qml:501-502）；源 Behavior 挂
/// `standardEasing` = material `Easing.OutQuart`（:505-506）。
const Duration _kMotionNormal = Duration(milliseconds: 220);
const Curve _kMotionStandard = Curves.easeOutQuart;

/// 工具栏淡入时长 `fastDuration` material 档 100ms（:499-500、:328）。
const Duration _kMotionFast = Duration(milliseconds: 100);

/// 部件库面板淡入 `normalDuration` + OutCubic（:382）。
const Duration _kLibraryFade = _kMotionNormal;
const Curve _kLibraryCurve = Curves.easeOutCubic;

/// metrics/activity 快照轮询间隔（MetricsService.qml:44 /
/// ActivityUsageService.qml:90 `interval: 10000`）。
const Duration _kMetricsPoll = Duration(seconds: 10);

/// 把 [SystemMetricsCollector.cpuUpdates]（`Stream<LoadSeries>`）包成
/// `ProviderListenable<LoadSeries>`，供 `KosSystemCard.cpu` 注入（SDK
/// `services.cpu` 缺席时的内嵌 CPU 源）。`cpuUpdates` 每次采样推一份
/// `LoadSeries` 快照；notifier 监听该流并转写为状态。
final _cpuStreamProvider = NotifierProvider.autoDispose
    .family<_CpuSeriesNotifier, LoadSeries, SystemMetricsCollector>(
      _CpuSeriesNotifier.new,
    );

/// 监听 [SystemMetricsCollector.cpuUpdates] 并暴露 `LoadSeries` 状态的
/// notifier（SDK `services.cpu` 的 `LoadSeries` 型态对齐）。dispose 时
/// 退订流。
final class _CpuSeriesNotifier extends Notifier<LoadSeries> {
  _CpuSeriesNotifier(this._collector);

  final SystemMetricsCollector _collector;
  StreamSubscription<LoadSeries>? _sub;

  @override
  LoadSeries build() {
    _sub = _collector.cpuUpdates.listen((series) => state = series);
    ref.onDispose(() => unawaited(_sub?.cancel()));
    return _collector.cpuSeries;
  }
}

/// 前台应用跟踪轮询周期（TASK-06 任务卡约定 5s；源端为
/// WindowService.onRevisionChanged 事件驱动，ActivityUsageService.qml:84-87）。
const Duration _kActivityTick = Duration(seconds: 5);

/// DeskCenter 容器：卡片网格 + 编辑模式 + 数据通道装配。
///
/// [dataClient]/[watcher] 为可空注入（无 kos-data.sock / PIM 服务时降级
/// 空态，对齐源端服务不可用的读取回退）；[configStore] 为 null 时编辑动作
/// 只更新内存态不落盘（预览/测试形态）。
class KosDeskCenterView extends StatefulWidget {
  const KosDeskCenterView({
    super.key,
    this.services,
    this.dataClient,
    this.monitorId,
    this.activityTracker,
    this.watcher,
    this.configStore,
    this.metricsCollector,
    this.weatherProvider,
    this.pimStore,
    this.activityLedger,
  });

  /// 宿主 `ShellServices`（`surface.services`）；卡片内各数据源经
  /// `ShellServicesScope` 下钻（clock/cpu/media/imageBytes），launch 回调
  /// 适配 `launchApplication`（DeskCenterWindow.qml 的
  /// `AppActionService.launchById`，:1161、:1721、:2048、:2196）。
  final ShellServices? services;

  /// kos-data.sock 客户端（metrics/weather/activity 通道）；null 时
  /// system/weather/activity 卡保持空态（对齐源端 `available=false` 分支）。
  final KosDataClient? dataClient;

  /// 主输出 monitorId（`ShellSurfaceEnvironment.output.monitorId`，
  /// surfaces.dart:81）；供 `services.windows(monitorId)` 轮询前台窗口。
  /// null 且 services 存在时退化为窗口表恒空（活动榜仅热力图）。
  final int? monitorId;

  /// 前台应用跟踪器注入（测试）；null 时容器按 [services]+[monitorId]
  /// 自建 [ActivityTracker]。
  final ActivityTracker? activityTracker;

  /// widget-snapshot.json 监听器（calendar/todo 通道）。
  final WidgetSnapshotWatcher? watcher;

  /// 配置持久化；null 时不落盘。
  final DeskCenterConfigStore? configStore;

  /// 内嵌 metrics 采集器（TASK-10）：非 null 时 system 卡改吃本地流，
  /// 替代 socket `metrics.snapshot`（`dataClient` 仍用于 activity 通道）。
  final SystemMetricsCollector? metricsCollector;

  /// 内嵌 Open-Meteo provider（TASK-10）：非 null 时 weather 卡改吃本地流，
  /// 替代 socket `weather.snapshot`。
  final WeatherProvider? weatherProvider;

  /// 插件内 PIM store（TASK-11）：calendar/todo 面板的读写数据源；由
  /// surface 层把 `PimSnapshotWatcher.store` 传入，面板经
  /// `DeskPanelData.pimStore` 取读写入口。
  final Object? pimStore;

  /// activity/uptime 持久化 ledger（TASK-18）：`uptimeByDay` + 当日
  /// `ActivityTracker.entries` 周期 debounce 落盘、启动读回恢复；null 时
  /// 不持久化（预览/测试形态）。
  final ActivityLedger? activityLedger;

  @override
  State<KosDeskCenterView> createState() => KosDeskCenterViewState();
}

/// 状态暴露为公开类供 widget 测试断言编辑态/换序。
class KosDeskCenterViewState extends State<KosDeskCenterView> {
  /// `root.editMode`（DeskCenterWindow.qml:81）。
  bool _editMode = false;

  /// `root.widgetLibraryOpen`（:82）。
  bool _libraryOpen = false;

  /// 悬停卡的尺寸提示（:531-549 的 hovered 条件），非编辑态生效。
  String? _hoveredId;

  /// 拖拽中的卡 id 与跟手位移（对应 `card.dragOffsetX/Y`，:459-460）。
  String? _dragId;
  Offset _dragTranslation = Offset.zero;

  /// 最近一次 build 算出的 placements 与 cellSize（拖拽距离比较用）。
  Map<String, WidgetPlacement> _placements = const {};
  double _lastCellSize = 1.0;
  DeskCenterConfig _config = DeskCenterConfig.defaults();

  // ---- 数据通道 ----
  StreamSubscription<WidgetSnapshot>? _snapshotSub;
  StreamSubscription<WidgetSnapshotState>? _stateSub;
  WidgetSnapshot? _snapshot;
  WidgetSnapshotState _snapshotState = WidgetSnapshotState.loading;
  KosSystemMetrics? _metrics;
  WeatherSnapshot? _weather;
  ActivitySnapshot? _activity;
  Timer? _metricsTimer;
  StreamSubscription<KosSystemMetrics>? _metricsSub;
  StreamSubscription<WeatherSnapshot>? _weatherSub;

  /// 前台应用时长跟踪器（插件侧轮询近似，TASK-06；widget 生命周期内有效）。
  ActivityTracker? _activityTracker;
  Timer? _activityTimer;

  /// TASK-18：`_activity` 是否来自 socket（false = 无 socket 时由 ledger/
  /// tracker 合成的本地快照——每个 tick 重建以反映当日累计）。
  bool _activityFromSocket = false;

  /// TASK-18：activity ledger 恢复完成闸——socket `activity.snapshot`
  /// 到达时按「当日键 max(socket, tracker 累计)，历史键 socket 为准」
  /// 合并进 tracker（socket 数据权威于持久化历史）。
  bool _activityLedgerRestored = false;

  ProviderContainer? _providerContainer;

  /// 当前编辑态（测试可断言）。
  bool get editMode => _editMode;

  /// 当前配置（测试可断言）。
  DeskCenterConfig get config => _config;

  @override
  void initState() {
    super.initState();
    _attachData();
    unawaited(_restoreConfig());
    // 前台应用跟踪随 widget 生命周期启动（修复前漏调导致 `_activityTracker`
    // 恒 null、应用榜恒空）；didUpdateWidget :199-204 的换装路径同样走
    // _stopActivityTracking + _startActivityTracking。
    _startActivityTracking();
    unawaited(_restoreActivityLedger());
  }

  @override
  void didUpdateWidget(KosDeskCenterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.dataClient, oldWidget.dataClient) ||
        !identical(widget.watcher, oldWidget.watcher) ||
        !identical(widget.metricsCollector, oldWidget.metricsCollector) ||
        !identical(widget.weatherProvider, oldWidget.weatherProvider)) {
      _detachData();
      _attachData();
    }
    if (!identical(widget.services, oldWidget.services) ||
        widget.monitorId != oldWidget.monitorId ||
        !identical(widget.activityTracker, oldWidget.activityTracker)) {
      // TASK-18：换装重建 tracker 前先取旧累计——_startActivityTracking 里把
      // 旧 tracker 的 uptime/apps 迁入新 tracker，避免每次 services/monitorId
      // 换装都会话内归零（surface 环境频繁变化时 uptime/榜单曾反复清零）。
      final previous = _activityTracker;
      _stopActivityTracking();
      _startActivityTracking(carryFrom: previous);
      // 新 tracker 恢复旧累计后仍要与 ledger 对齐（ledger 可能更新更全），
      // 重跑一次 restore（幂等：uptime 当日键取 max、apps 覆盖式灌回）。
      unawaited(_restoreActivityLedger());
    }
  }

  @override
  void dispose() {
    _detachData();
    _stopActivityTracking();
    super.dispose();
  }

  void _attachData() {
    final watcher = widget.watcher;
    if (watcher != null) {
      _snapshotState = watcher.state;
      _snapshotSub = watcher.snapshots.listen((snapshot) {
        if (mounted) setState(() => _snapshot = snapshot);
      });
      _stateSub = watcher.states.listen((state) {
        if (mounted) setState(() => _snapshotState = state);
      });
      watcher.start();
    }
    // 内嵌 collector/provider（TASK-10）：替代 socket metrics/weather 通道。
    // dataClient 仍驱动 activity 通道（socket）与降级兜底。
    final collector = widget.metricsCollector;
    if (collector != null) {
      _metrics = collector.latest;
      _metricsSub = collector.metrics.listen((m) {
        if (mounted) setState(() => _metrics = m);
      });
      collector.start();
    }
    final weather = widget.weatherProvider;
    if (weather != null) {
      _weather = weather.latest;
      _weatherSub = weather.snapshots.listen((s) {
        if (mounted) setState(() => _weather = s);
      });
      unawaited(weather.start());
    }
    final client = widget.dataClient;
    if (client != null) {
      unawaited(client.connect());
      // socket 仍存在时只轮询 activity（metrics/weather 已由本地源覆盖）；
      // 无本地源时退回 socket 全量轮询（dataClient 注入测试形态）。
      _metricsTimer = Timer.periodic(
        _kMetricsPoll,
        (_) => _pollSnapshots(
          client,
          metrics: collector == null,
          weather: weather == null,
        ),
      );
      _pollSnapshots(
        client,
        metrics: collector == null,
        weather: weather == null,
      ); // triggeredOnStart（MetricsService.qml:46）
    }
  }

  void _detachData() {
    unawaited(_snapshotSub?.cancel());
    unawaited(_stateSub?.cancel());
    unawaited(_metricsSub?.cancel());
    unawaited(_weatherSub?.cancel());
    _snapshotSub = null;
    _stateSub = null;
    _metricsSub = null;
    _weatherSub = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
  }

  void _stopActivityTracking() {
    _activityTimer?.cancel();
    _activityTimer = null;
    // 注入的 tracker 由调用方持有生命周期，只停本地自建的。
    if (!identical(_activityTracker, widget.activityTracker)) {
      _activityTracker?.stop();
    }
    _activityTracker = null;
  }

  /// 拉取 metrics/weather 快照；失败保留上一份（MetricsService.qml:67-70
  /// `else` 分支「keep the previous values」语义）。`metrics`/`weather` 为
  /// false 时跳过对应通道（已被内嵌 collector/provider 覆盖）。
  void _pollSnapshots(
    KosDataClient client, {
    bool metrics = true,
    bool weather = true,
  }) {
    if (metrics) {
      unawaited(() async {
        try {
          final result = await client
              .request(KosDataOperations.metricsSnapshot)
              .first;
          final metrics = result['metrics'];
          if (metrics is Map && mounted) {
            setState(
              () => _metrics = KosSystemMetrics.fromJson(
                metrics.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        } on Object {
          // 断线/超时/服务错误：保留上一份（对应源端 else 空分支）。
        }
      }());
    }
    if (weather) {
      unawaited(() async {
        try {
          final result = await client
              .request(KosDataOperations.weatherSnapshot)
              .first;
          final weather = result['weather'];
          if (weather is Map && mounted) {
            setState(
              () => _weather = WeatherSnapshot.fromJson(
                weather.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        } on Object {
          // 同上。
        }
      }());
    }
    unawaited(() async {
      // activity.snapshot（ActivityUsageService.qml:30-39 `reload`）：
      // 与 metrics/weather 同周期（refreshTimer interval 10000，:90）。
      try {
        final result = await client
            .request(KosDataOperations.activitySnapshot)
            .first;
        final activity = result['activity'];
        if (activity is Map && mounted) {
          setState(() {
            _activity = ActivitySnapshot.fromJson(
              activity.map((k, v) => MapEntry(k.toString(), v)),
            );
            _activityFromSocket = true;
          });
          // TASK-18：socket 数据到达后以 socket 为准合并 uptimeByDay——
          // 历史键 socket 覆盖（服务端 journald 跨进程结算更权威），
          // 当日键取 max(socket, tracker 已累计) 不回退插件存活期的
          // 本地累计；随后 tracker 续计的时段仍写入当日桶。
          _mergeActivitySocket(_activity);
        }
      } on Object {
        // 服务未写首份快照 / 断线：保留上一份（:37-38 else 空分支）。
      }
    }());
  }

  /// 前台应用跟踪（TASK-06）：SDK 无窗口事件流，插件侧每
  /// [_kActivityTick] 读 `services.windows(monitorId)` 当前快照，把周期
  /// 时长记给 `active && !minimized` 窗口的 appId（近似源端
  /// `updateActiveApp` + `activity.active-app` 上报的服务端结算，
  /// ActivityUsageService.qml:63-83；差异见 docs/visual-deltas §9）。
  /// `services`/`monitorId`/`ProviderScope` 任一缺失时窗口表恒空（
  /// 降级形态：榜空态、热力图照常）。注意 [build] 在 initState 之后才
  /// 能取到 ProviderContainer——tracker 首帧用空表建立基准时刻，首个
  /// 5s 周期读取的是 build 时缓存的 container，语义不变。
  void _startActivityTracking({ActivityTracker? carryFrom}) {
    final services = widget.services;
    final monitorId = widget.monitorId;
    _activityTracker =
        widget.activityTracker ??
        ActivityTracker(
          tickPeriod: _kActivityTick,
          // windows(monitorId) 是 ProviderListenable（services.dart:66）：
          // 读 build 缓存的 ProviderContainer 的当前值（不走 watch——
          // 轮询本身即订阅的降级近似，且无订阅意味着不触发逐帧重建）。
          windows: () {
            final container = _providerContainer;
            if (services == null || monitorId == null || container == null) {
              return const [];
            }
            return [
              for (final w in container.read(services.windows(monitorId)))
                ActivityWindowRow(
                  id: w.id,
                  appId: w.appId,
                  title: w.title,
                  active: w.active,
                  minimized: w.minimized,
                ),
            ];
          },
          // `name` 对齐源 `identity.name`（ActivityUsageService.qml:66）：
          // SDK 无窗口级显示名，用 LaunchableApplication.name 近似
          // （services.dart:44-55），未匹配回退 appId（:1635 `name||id`）。
          resolveName: (appId) {
            final container = _providerContainer;
            if (services == null || container == null) return null;
            for (final app in container.read(services.applications)) {
              if (app.appId == appId || app.windowAppIds.contains(appId)) {
                return app.name;
              }
            }
            return null;
          },
        );
    // TASK-18：换装重建时迁移旧 tracker 的会话内累计（uptime 分桶 + 当日
    // app 秒数），防止 services/monitorId 换装把插件存活期的累计清零。
    // 注入的 widget.activityTracker 由调用方持有，不迁（其生命周期独立）。
    if (carryFrom != null && !identical(_activityTracker, carryFrom)) {
      _activityTracker?.seedUptimeByDay(carryFrom.uptimeByDay);
      _activityTracker?.seedFromEntries(carryFrom.entries);
    }
    _activityTimer = Timer.periodic(_kActivityTick, (_) {
      _activityTracker?.tick();
      _recordActivityLedger();
      if (mounted) {
        setState(() {
          // 无 socket 时本地快照随 tick 重建（uptimeByDay/todayApps 反映
          // tracker 最新累计）；socket 快照到达后不再本地重建。
          if (!_activityFromSocket) {
            _activity = ActivitySnapshot(
              uptimeByDay:
                  _activityTracker?.uptimeByDay ?? const {},
              todayApps: _activityTracker?.entries ?? const [],
            );
          }
        });
      }
    });
    _activityTracker?.tick(); // 建立基准时刻（首个周期不计时）。
  }

  /// TASK-18：启动读回 `activity-ledger.json` 恢复历史。load 后：
  /// - `uptimeByDay` 经 `seedUptimeByDay` 灌入 tracker（当日键取较大值，
  ///   tracker 自 tick 起已续计的本地累计不回退）；
  /// - 当日 `day==today` 的 app 秒数经 `seedFromEntries` 灌回榜单；
  /// - 无 socket（`_activity == null`）时用 ledger 合成 `ActivitySnapshot`
  ///   供卡片/面板热力图（socket 到达后以 socket 为准合并，见
  ///   `_mergeActivitySocket`）。
  Future<void> _restoreActivityLedger() async {
    final ledger = widget.activityLedger;
    if (ledger == null) return;
    await ledger.load();
    _activityLedgerRestored = true;
    if (!mounted) return;
    final tracker = _activityTracker;
    final todayKey = kosDayKey(DateTime.now());
    if (ledger.hasData) {
      tracker?.seedUptimeByDay(ledger.uptimeByDay);
      final todayApps = [
        for (final app in ledger.apps)
          if (app.day == todayKey)
            ActivityAppEntry(
              id: app.id,
              name: app.name,
              icon: app.icon,
              seconds: app.seconds,
            ),
      ];
      tracker?.seedFromEntries(todayApps);
      _activity ??= ActivitySnapshot(
        uptimeByDay: tracker?.uptimeByDay ?? ledger.uptimeByDay,
        todayApps: tracker?.entries ?? const [],
      );
      _activityFromSocket = false; // 合成快照：socket 到达前本地权威
      setState(() {});
    }
  }

  /// TASK-18：每次活动 tick 后把最新内存态提交 ledger（debounce 合并
  /// 落盘，`saveDebounce` ~1.2s）。tracker 缺省/no-op。
  void _recordActivityLedger() {
    final ledger = widget.activityLedger;
    final tracker = _activityTracker;
    if (ledger == null || tracker == null) return;
    final todayKey = kosDayKey(DateTime.now());
    ledger.update(
      uptimeByDay: tracker.uptimeByDay,
      apps: [
        for (final entry in tracker.entries)
          ActivityLedgerAppEntry(
            id: entry.id,
            name: entry.name,
            icon: entry.icon,
            day: todayKey,
            seconds: entry.seconds,
          ),
      ],
    );
  }

  /// TASK-18：socket `activity.snapshot` 到达后以 socket 为准合并
  /// uptimeByDay——历史键 socket 覆盖（服务端结算更权威），当日键取
  /// max(socket, tracker 已累计) 防回退插件存活期的本地累计。
  void _mergeActivitySocket(ActivitySnapshot? snapshot) {
    final tracker = _activityTracker;
    if (tracker == null || snapshot == null || !_activityLedgerRestored) {
      return;
    }
    final todayKey = kosDayKey(DateTime.now());
    final merged = <String, double>{
      for (final entry in snapshot.uptimeByDay.entries)
        entry.key: entry.key == todayKey
            ? math.max(entry.value, tracker.uptimeByDay[entry.key] ?? 0)
            : entry.value,
    };
    // tracker 当日桶若大于 socket（插件侧本地续计），回填使 socket 键
    // 不丢本地累计段。
    if ((tracker.uptimeByDay[todayKey] ?? 0) >
        (snapshot.uptimeByDay[todayKey] ?? 0)) {
      merged[todayKey] = tracker.uptimeByDay[todayKey]!;
    }
    tracker.seedUptimeByDay(merged);
  }
  Future<void> _restoreConfig() async {
    final store = widget.configStore;
    if (store == null) return;
    final initial = _config;
    final loaded = await store.load();
    if (!mounted || loaded == _config) return;
    // load 在途期间用户已编辑（内存态 ≠ load 前快照）：不回滚内存态，
    // 把当前配置写回盘上，避免 UI 与磁盘分裂。
    if (_config != initial) {
      unawaited(store.save(_config));
      return;
    }
    setState(() => _config = loaded);
  }

  /// 编辑动作统一入口：更新内存态 + 原子落盘（`_settings.sync()` +
  /// `revision++` 语义，DeskCenterConfigService.qml:64-65）。
  void _apply(DeskCenterConfig next) {
    if (next == _config) return;
    setState(() => _config = next);
    unawaited(widget.configStore?.save(next));
  }

  /// `enterWidgetEditMode`（:84-89）：进入编辑态（含可选开库）。
  /// 源端无条件重置 `widgetLibraryOpen`——已在编辑态时再次触发
  /// （空白长按/右键）等价「关库」，不做无条件 early-return。
  void enterEditMode({bool openLibrary = false}) {
    if (_editMode && _libraryOpen == openLibrary) return;
    setState(() {
      _editMode = true;
      _libraryOpen = openLibrary;
    });
  }

  /// `leaveWidgetEditMode`（:91-94）。
  void leaveEditMode() {
    if (!_editMode) return;
    setState(() {
      _editMode = false;
      _libraryOpen = false;
    });
  }

  /// `cycleSize`（DeskCenterConfigService.qml:88-93）。
  void cycleSize(String id) => _apply(_config.cycleSize(id));

  /// `setDeskCenterWidgetVisible`（DeskCenterWindow.qml:564-566、443-445）。
  void setWidgetVisible(String id, bool visible) =>
      _apply(_config.setVisible(id, visible));

  /// `moveWidget`（DeskCenterConfigService.qml:56-67）：移动到 order 中
  /// [targetId] 所在索引（DragHandler :522-523 的最近邻语义）。
  void moveWidget(String id, String targetId) {
    final target = _config.order.indexOf(targetId);
    if (target < 0) return;
    _apply(_config.moveWidget(id, target));
  }

  /// 不再走 SDK `ShellPopupHost`（那会盖住输入法候选窗）。重复打开同卡即覆盖
  /// 同一会话（不堆叠）。argv 语义经 [DeskPanelRequest] 透传面板初始 state
  /// （weather `--location`、calendar `--date`、todo `--view`/`--item`；
  /// clock/system/activity/music 无参——对应 :612、:1156-1164、:2193-2199、
  /// :2045-2050/:2144-2147、:1718-1722 的 launchById 调用点）。
  /// 面板路由未覆盖的 appId 回退 `launchApplication` 外开（:1161 等的
  /// launchById 语义——面板未实现的应用仍外开，见 TASK-12 §改动范围）。
  void _openPanel(String appId, List<String> argv) {
    // 编辑态不弹面板：非编辑态整卡 tap 才触发（TASK-12 §约束）。
    if (_editMode) return;
    final cardId = kosDeskPanelAppIds.entries
        .firstWhere(
          (entry) => entry.value == appId,
          orElse: () => const MapEntry('', ''),
        )
        .key;
    if (cardId.isEmpty) {
      unawaited(widget.services?.launchApplication(appId));
      return;
    }
    final container = _providerContainer;
    final data = DeskPanelData(
      weather: _weather,
      snapshot: _snapshot,
      metrics: _metrics,
      activity: _activity,
      // media 当帧值（面板 builder 无卡片级 watch 上下文，用
      activityTracker: _activityTracker,
      // build 缓存的 container 读一次；services/容器缺失恒 null，
      // 占位体只显示「无」）。
      media: container != null && widget.services != null
          ? container.read(widget.services!.media).value
          : null,
      // 面板读写数据源（TASK-13~17）：容器 surface 持有的同一实例原样透传
      // （面板 surface 与容器 surface 共享同一份），面板经 `DeskPanelData`
      // 的 Object? 字段向下转型取用。
      pimStore: widget.pimStore,
      weatherProvider: widget.weatherProvider,
      metricsCollector: widget.metricsCollector,
    );
    // 单一入口：`showDeskPanel` 写入会话 provider（容器是否为空由其内部判空，
    // 无 `ProviderScope` 的预览形态静默 no-op）。
    showDeskPanel(
      container,
      request: DeskPanelRequest(appId: appId, argv: argv),
      data: data,
    );
  }

  @override
  Widget build(BuildContext context) {
    // windows/applications 是 ProviderListenable（services.dart:66、81）：
    // 缓存 ProviderContainer 供轮询回调 `read` 当前值。
    try {
      _providerContainer = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      _providerContainer = null; // 无 ProviderScope 的预览形态
    }
    // ShellServicesScope 下钻：卡片内 clock/cpu/media/imageBytes 数据源
    // 均经 scope 取 services（clock_card.dart:280-284 等）。
    Widget child = _buildBody(context);
    final services = widget.services;
    if (services != null) {
      child = ShellServicesScope(services: services, child: child);
    }
    return child;
  }

  Widget _buildBody(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 0.0;
        // :71-73 cellSize 由「全屏宽」推导（源注释 "Ten square units are
        // derived exclusively from screen width"）。bounds 已被 place() 缩到
        // 左 4/10 区，故回推虚拟全宽 = w / (widgetColumns/columns) =
        // w / 0.4，使卡片恢复源码尺寸并恰好铺满左区 4 列。
        final fullWidth = w / (_Grid.widgetColumns / _Grid.columns);
        final cellSize = math.max(
          1.0,
          (fullWidth -
                  _Grid.baseSideMargin * 2 -
                  _Grid.gap * (_Grid.columns - 1)) /
              _Grid.columns,
        );
        // :74-75 usableRows = max(0, floor((h + gap)/(cellSize + gap)))；
        // topInset/bottomInset 已由 place() 的 workArea 内缩吸收（
        // 桌面层 surface bounds 即可视区，见 kos_deskcenter.dart）。
        final usableRows = math
            .max(0, ((h + _Grid.gap) / (cellSize + _Grid.gap)).floor())
            .clamp(0, 64); // 防御：异常高度不生成超大行数矩阵。
        // widgetDefinitions（:214-239）：orderedIds 序 + hidden 过滤 +
        // spanFor(size) 展开 columns/rows。
        final definitions = <WidgetDefinition>[
          for (final id in _config.order)
            if (_config.isVisible(id)) _definitionFor(id),
        ];
        final placements = {
          for (final p in packWidgets(
            definitions,
            columnCount: _Grid.widgetColumns,
            rowCount: usableRows,
          ))
            p.id: p,
        };
        // 拖拽换序的距离比较用当帧 placements/cellSize（DragHandler
        // onActiveChanged 在 build 间触发）。
        _placements = placements;
        _lastCellSize = cellSize;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // :315-318 onPressAndHold（左键长按）进入编辑态；右键已由卡片
          // TapHandler 承担（:486-490），空白右键源端弹桌面文件菜单——
          // desktopFileGrid 不在本插件范围，不实现。
          onLongPress: () => enterEditMode(),
          onSecondaryTap: () => enterEditMode(),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 卡片层（widgetRepeater，:451-483）。
              for (final def in definitions)
                if (placements[def.id] case final placement?)
                  _positionedCard(placement, cellSize),
              // 编辑工具栏（widgetEditToolbar，:321-371）。
              _EditToolbar(
                visible: _editMode,
                onToggleLibrary: () =>
                    setState(() => _libraryOpen = !_libraryOpen),
                onDone: leaveEditMode,
              ),
              // 部件库面板（widgetLibrary，:373-449）。
              _WidgetLibrary(
                visible: _editMode && _libraryOpen,
                isActive: _config.isVisible,
                onToggle: (id) => setWidgetVisible(id, !_config.isVisible(id)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// `configuredWidget`（:208-212）：id + priority + spanFor(id) 展开。
  WidgetDefinition _definitionFor(String id) {
    final catalog = kosWidgetCatalog.firstWhere(
      (entry) => entry.id == id,
      orElse: () => kosWidgetCatalog.first,
    );
    final span = spanFor(id, _config.sizeFor(id));
    return WidgetDefinition(
      id: id,
      priority: catalog.priority,
      columns: span.columns,
      rows: span.rows,
    );
  }

  /// 卡片定位：x/y/w/h = `leftInset + col·(cell+gap)` /
  /// `topInset + row·(cell+gap)` / `spanSize(columns)` / `spanSize(rows)`
  /// （:476-479）；inset 项已被 bounds 吸收，局部坐标从 0 起。
  Widget _positionedCard(WidgetPlacement placement, double cellSize) {
    final left = placement.column * (cellSize + _Grid.gap);
    final top = placement.row * (cellSize + _Grid.gap);
    final width =
        placement.columns * cellSize +
        (placement.columns - 1) * _Grid.gap; // spanSize（:253）
    final height = placement.rows * cellSize + (placement.rows - 1) * _Grid.gap;
    final id = placement.id;
    final size = _config.sizeFor(id);
    final dragging = _dragId == id;
    return AnimatedPositioned(
      key: ValueKey('kos-desk-card-$id'),
      // 拖拽中的卡用 translation 跟手，基准位不动（对应源
      // `transform: Translate{x:dragOffsetX}` + dragOffset 直接赋值，
      // :459-464）——跳过隐式动画避免回追。
      duration: dragging ? Duration.zero : _kMotionNormal,
      left: left,
      top: top,
      width: width,
      height: height,
      curve: _kMotionStandard, // :480-483 Behavior standardEasing（OutQuart）
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hoveredId = id),
              onExit: (_) {
                if (_hoveredId == id) setState(() => _hoveredId = null);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                // TASK-12：非编辑态整卡 tap → 内嵌面板（替代源端
                // launchById 外开应用）。仅非编辑态注册：同竞技场挂
                // Tap+Pan 时 Pan 恒输（单指针 tap 先到截止）会破坏
                // 拖拽换序——手势对称方案不可用，改为显式
                // `!_editMode` 门控。weather/calendar/todo/music 卡内
                // 已挂带 argv 的 onTap（命中路径更深，tap 竞技由内层
                // 赢得），此回调实际只承接无内层 detector 的
                // clock/system/activity 卡（:612 邻域、:1718-1722 同
                // 语义的无参入口）。
                onTap: _editMode
                    ? null
                    : () =>
                        _openPanel(kosDeskPanelAppIds[id] ?? id, const []),
                // TapHandler acceptedButtons:RightButton（:486-490）→
                // 右键进编辑。
                onSecondaryTap: () => enterEditMode(),
                // 卡片长按不进编辑态：源端 onPressAndHold 只挂在背景
                // DragHandler（:492-527 `enabled: root.editMode`）：仅编辑
                // 态注册；跟手位移 → 松手找最近邻换序。dragStartBehavior
                // 取 down：默认 start 会把「过 slop 那一帧」的位移吞掉
                // （_checkDrag 里 localUpdateDelta 置零），一次到位的拖动
                // 丢首个 delta——源端 `dragOffset = translation` 自按下
                // 点累计，down 语义一致。
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: _editMode ? _onDragStart(id) : null,
                onPanUpdate: _editMode ? _onDragUpdate : null,
                onPanEnd: _editMode ? (_) => _endDrag(id) : null,
                onPanCancel: _editMode ? _cancelDrag : null,
                child: Transform.translate(
                  // :459-464 Translate{dragOffsetX/Y} 跟手。
                  offset: dragging ? _dragTranslation : Offset.zero,
                  child: AnimatedScale(
                    // :465 `scale: widgetDrag.active ? 1.035 : 1` +
                    // :484 Behavior 120ms OutCubic。
                    scale: dragging ? 1.035 : 1.0,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    child: _cardFor(id, size),
                  ),
                ),
              ),
            ),
          ),
          // 悬停尺寸提示（:531-549）：非编辑态悬停时右下角胶囊
          // 「小/中/大 · 右键编辑」，高 24、radius 12、层 4 @0.52。
          if (_hoveredId == id && !_editMode)
            Positioned(
              right: 8, // :534 margins:8
              bottom: 8,
              child: IgnorePointer(
                child: Container(
                  height: 24, // :536
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7, // :535 implicitWidth+14 → 两侧 7
                  ),
                  decoration: BoxDecoration(
                    // :538 黑@0.52 scrim——玻璃卡上半透明叠加，明暗壳通用，
                    // 保留源端深色档。文字白与 scrim 为固定语义对。
                    color: const Color(0x85000000),
                    borderRadius: BorderRadius.circular(12), // :537
                    border: Border.all(
                      // :540 白@0.18 → shell 白系 hairline。
                      color: context.shellColors.hairlineWindow,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${kosWidgetSizeLabels[size] ?? ''} · 右键编辑', // :544-545
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF), // :546 \"white\"（白-on-scrim 固定）
                      fontSize: 9, // :547
                      fontWeight: FontWeight.w600, // :547 DemiBold
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// DragHandler `enabled: root.editMode` 按下分支（:494-498）：记录拖拽
  /// 卡 id，跟手位移归零（dragOffsetX/Y 起点 0）。
  GestureDragStartCallback _onDragStart(String id) => (_) {
    setState(() {
      _dragId = id;
      _dragTranslation = Offset.zero;
    });
  };

  /// DragHandler 跟手位移（:501-502 `dragOffset = translation`）：累加
  /// pan delta 驱动 `Transform.translate`。
  void _onDragUpdate(DragUpdateDetails details) {
    if (_dragId == null) return;
    setState(() => _dragTranslation += details.delta);
  }

  /// DragHandler `onActiveChanged` 松开分支（:503-526）：以「卡中心 +
  /// 跟手位移」为落点，在所有 placement 中找最近邻（含自身，距离平方
  /// 比较），再 `moveWidget(id, orderedIds().indexOf(nearestId))`。
  void _endDrag(String id) {
    final placement = _placements[id];
    if (placement == null) {
      _cancelDrag();
      return;
    }
    // :506-507 centerX/Y = x + w/2 + dragOffset；w/h = spanSize。
    final base = _cardOrigin(placement);
    final center = Offset(
      base.dx + _spanSize(placement.columns) / 2 + _dragTranslation.dx,
      base.dy + _spanSize(placement.rows) / 2 + _dragTranslation.dy,
    );
    var nearestId = id; // :508 默认自身
    var nearestDistance = double.infinity; // :509
    for (final candidate in _placements.values) {
      final origin = _cardOrigin(candidate);
      // :514-517 dx/dy 对各卡中心（x+w/2、y+h/2）取距离平方。
      final dx = center.dx - (origin.dx + _spanSize(candidate.columns) / 2);
      final dy = center.dy - (origin.dy + _spanSize(candidate.rows) / 2);
      final distance = dx * dx + dy * dy;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestId = candidate.id; // :518-521
      }
    }
    setState(() {
      _dragId = null;
      _dragTranslation = Offset.zero; // :524-525 归零
    });
    moveWidget(id, nearestId); // :522-523
  }

  void _cancelDrag() {
    if (_dragId == null) return;
    setState(() {
      _dragId = null;
      _dragTranslation = Offset.zero;
    });
  }

  /// `spanSize`（:253）：`span * cellSize + (span - 1) * gap`（当帧
  /// cellSize）。供卡片定位与拖拽中心比较共用。
  double _spanSize(int span) => span * _lastCellSize + (span - 1) * _Grid.gap;

  /// 卡片格点原点（:476-477 的 x/y 公式局部化，inset 已被 bounds 吸收）；
  /// 读取 [_lastCellSize]（当帧 cellSize）+ gap。
  Offset _cardOrigin(WidgetPlacement placement) {
    final step = _lastCellSize + _Grid.gap;
    return Offset(placement.column * step, placement.row * step);
  }
  /// 分卡装配（widgetContentLayer 的 Loader 分派，:608-1986）。
  /// 七卡按 id 分派（activity 实卡归 TASK-06，本轮询近似方案见 §9）。
  Widget _cardFor(String id, WidgetSize size) {
    final edit = _editMode;
    void onRemove() => setWidgetVisible(id, false); // :563-566
    void onCycle() => cycleSize(id); // :588-590
    return switch (id) {
      'clock' => KosClockCard(
        size: size,
        editMode: edit,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'weather' => KosWeatherCard(
        snapshot: _weather,
        size: size,
        editMode: edit,
        onLaunchApp: _openPanel,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'calendar' => KosCalendarCard(
        snapshot: _snapshot,
        state: _snapshotState,
        size: size,
        editMode: edit,
        onLaunchApp: _openPanel,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'todo' => KosTodoCard(
        snapshot: _snapshot,
        state: _snapshotState,
        size: size,
        editMode: edit,
        onLaunchApp: _openPanel,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'system' => KosSystemCard(
        // CPU 环：SDK `services.cpu` 优先（telemetry 源），缺席时退化
        // 内嵌 collector 的 /proc/stat 差分流（StreamProvider 包装成
        // ProviderListenable，对齐 KosSystemCard.cpu 接口）。
        cpu: widget.services != null
            ? widget.services!.cpu
            : widget.metricsCollector != null
            ? _cpuStreamProvider(widget.metricsCollector!)
            : null,
        metrics: _metrics,
        size: size,
        editMode: edit,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'activity' => KosActivityCard(
        snapshot: _activity,
        apps: _activityTracker?.entries ?? const [],
        size: size,
        editMode: edit,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      'music' => KosMusicCard(
        size: size,
        editMode: edit,
        onLaunchApp: _openPanel,
        onRemove: onRemove,
        onCycleSize: onCycle,
      ),
      _ => DeskCard(
        size: size,
        editMode: edit,
        onRemove: onRemove,
        onCycleSize: onCycle,
        child: const SizedBox.expand(),
      ),
    };
  }
}

/// 编辑工具栏（widgetEditToolbar，:321-371）：右上「+ 组件」「完成」两钮，
/// 32 高胶囊、间距 8、topInset/rightMargin 由容器内边距近似（源锚定窗口
/// 右上角；本容器 bounds 即左区，贴容器右上）。
class _EditToolbar extends StatelessWidget {
  const _EditToolbar({
    required this.visible,
    required this.onToggleLibrary,
    required this.onDone,
  });

  final bool visible;
  final VoidCallback onToggleLibrary;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      top: 0, // anchors.top: parent.top + topInset → 容器顶
      right: 24, // :329 rightMargin: 24
      height: 32, // :340
      duration: _kMotionFast,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0, // :325 opacity 绑 editMode
        duration: _kMotionFast, // :328 Behavior fastDuration
        child: IgnorePointer(
          ignoring: !visible, // :327 enabled: root.editMode
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ToolbarButton(label: '+ 组件', onTap: onToggleLibrary), // :334
              const SizedBox(width: 8), // :330 spacing
              _ToolbarButton(
                label: '完成', // :335
                primary: true, // :342-345 primaryContainer 分支
                onTap: onDone,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12), // :339 +24 总宽
        decoration: BoxDecoration(
          // :342-347 surface.pick(primaryContainer / surfaceContainerHigh,
          // 暗 0.90 / 亮 0.92)：primary → accent 容器、其余 → surfaceContainerHigh。
          color: primary
              ? theme.accentPalette.container
              : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16), // :341 material 16
          border: Border.all(
            // :349-353 outlineVariant / foreground@0.16 → shell hairline。
            color: colors.hairline,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            // primary 钮文字压 accent 容器 → onContainer；其余 → textPrimary。
            color: primary
                ? theme.accentPalette.onContainer
                : colors.textPrimary,
            fontSize: 11, // :359
            fontWeight: FontWeight.w600, // :359 DemiBold
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// 部件库面板（widgetLibrary，:373-449）：右上弹出，430×116、radius 24
/// （material 档），七项 54×82 条目（symbol + label + −/+ 开关）。
class _WidgetLibrary extends StatelessWidget {
  const _WidgetLibrary({
    required this.visible,
    required this.isActive,
    required this.onToggle,
  });

  final bool visible;
  final bool Function(String id) isActive;
  final void Function(String id) onToggle;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      top: 42, // :383 anchors.top: toolbar.bottom + topMargin:10
      right: 24,
      width: 430, // :384
      height: 116, // :385
      duration: _kLibraryFade,
      curve: _kLibraryCurve,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0, // :377
        duration: _kLibraryFade,
        curve: _kLibraryCurve, // :382 OutCubic
        // :380 scale 0.96+0.04·opacity、transformOrigin TopRight：
        // 用对齐右上角的缩放近似。
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.96,
          duration: _kLibraryFade,
          curve: _kLibraryCurve,
          alignment: Alignment.topRight,
          child: IgnorePointer(
            ignoring: !visible, // :379 enabled 门控
            child: Container(
              decoration: BoxDecoration(
                // :387-390 surfaceContainer → shell surfaceContainer 角色。
                color: context.shellColors.surfaceContainer,
                borderRadius: BorderRadius.circular(24), // :386 material 24
                // :391-396 outlineVariant → shell hairline。
                border: Border.all(color: context.shellColors.hairline),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final entry in kosWidgetCatalog)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3, // :400 spacing 6 → 两侧各 3
                      ),
                      child: _LibraryEntry(
                        entry: entry,
                        active: isActive(entry.id),
                        onTap: () => onToggle(entry.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 库条目（:403-447 delegate）：54×82、symbol 20px + label 9px DemiBold +
/// −/+ 14px Bold（active 红 #ff453a / inactive accent）；active 底色
/// secondaryContainer + primary 描边，inactive 透明 + outlineVariant。
class _LibraryEntry extends StatelessWidget {
  const _LibraryEntry({
    required this.entry,
    required this.active,
    required this.onTap,
  });

  final KosWidgetCatalogEntry entry;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap, // :442-445 setDeskCenterWidgetVisible(id, !active)
      child: Container(
        width: 54, // :408
        height: 82, // :408
        decoration: BoxDecoration(
          // :410-416 active → secondaryContainer 近似 → accent container；
          // inactive → transparent。
          color: active
              ? theme.accentPalette.container
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(16), // :409 material 16
          border: Border.all(
            // :417-419 active → primary → accent outline；inactive →
            // outlineVariant → shell hairline。
            color: active ? theme.accentPalette.outline : colors.hairline,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              entry.symbol, // :424-427 widgetSymbols 20px
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 20,
                height: 1,
              ),
            ),
            const SizedBox(height: 5), // :421 spacing
            Text(
              entry.label, // :430-433 widgetLabels 9px DemiBold
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
            Text(
              active ? '−' : '+', // :436-439
              style: TextStyle(
                color: active
                    ? const Color(0xFFFF453A) // :438 "#ff453a" 语义红（固定）
                    : theme.accent, // accentColor → shell accent
                fontSize: 14,
                fontWeight: FontWeight.bold, // :439 Font.Bold
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
