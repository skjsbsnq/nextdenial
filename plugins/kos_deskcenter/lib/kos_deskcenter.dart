@Plugin()
library;

import 'dart:async';

import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/kos_data_client_io.dart';
import 'src/data/activity_ledger.dart';
import 'src/data/pim/pim_snapshot_provider.dart';
import 'src/data/system_metrics_collector.dart';
import 'src/data/weather_provider.dart';
import 'src/state/desk_center_config_io.dart';
import 'src/widgets/desk_center_view.dart';
import 'src/widgets/desk_panel_shell.dart' show deskPanelSessionProvider;
import 'src/widgets/desk_panel_surface.dart';
import 'src/widgets/desk_panels.dart' show registerDeskPanels;

/// KOS DeskCenter 桌面容器表面（`ShellSurface`）。
///
/// 布局对齐 NextKde `DeskCenterWindow.qml`（行号锚定
/// `/home/wwt/文档/NextKde/shell/desktop/modules/deskcenter/`）：
/// - `layer: desktop`：源 `WlrLayershell.layer: Bottom`（:29），在应用
///   窗口之下、不占 exclusive zone（`exclusionMode: Ignore` :27-28 →
///   `occupiesDesktop: true` 仅推开最小化预览，不预留工作区）；
/// - `place()`：源 `widgetColumns = min(4, 10)`（:41-42）把网格左 4/10
///   分配给部件、`sideMargin: 20`（:43）四边留白；bounds 取
///   workArea 内缩 20 后的左 40%（4 列占 10 列之比），卡片网格在
///   bounds 内从 (0,0) 起排（容器内 inset 语义见 desk_center_view.dart）；
/// - `visible`：源 PanelWindow 常驻；锁屏/壁纸选择时隐藏对齐
///   taskbar/clock 惯例（`!locked && !wallpaperSelectorVisible`）。
///
/// `build()` 内的数据通道（`SocketKosDataClient`/
/// `FileWidgetSnapshotWatcher`，均为 dart:io 实现）由
/// `_KosDeskCenterSurface` 在 surface 实例生命周期内持有并 dispose
/// （SDK 文档：surface 实例随 place() 出入而创建/销毁，
/// shell_surface_plane.dart `_SurfaceInstance`）。
@Provides(ShellSurface)
final class KosDeskCenterPlugin implements ShellSurface {
  const KosDeskCenterPlugin();

  @override
  String get id => 'kos_deskcenter.container';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.desktop;

  /// `sideMargin`（DeskCenterWindow.qml:43）在 bounds 层的内缩量。
  static const double sideMargin = 20;

  /// `widgetColumns / columns = 4 / 10`（:41-42）的宽占比。
  static const double widthFraction = 4 / 10;

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    // 只在主输出落一个容器实例（源 `root.screen?.name ===
    // ScreenLifecycle.activeScreen?.name` 才出 widgetDefinitions，:454）；
    // 其余输出返回 null 不放置。
    if (!environment.isMainOutput) return null;
    final area = environment.workArea.deflate(sideMargin);
    if (area.isEmpty) return null;
    return ShellSurfacePlacement(
      // 左侧区域：宽 = 内缩后宽 × 4/10（widgetColumns/columns），
      // 贴 workArea 左缘（:476 `x: root.leftInset + column·(cell+gap)`
      // 的列从 0 起）。topInset/bottomInset（:54-56）由 workArea 承载。
      bounds: Rect.fromLTWH(
        area.left,
        area.top,
        area.width * widthFraction,
        area.height,
      ),
      // 占据桌面区域：minimized 窗口预览避开此范围（对应源注释
      // "reserves no usable desktop area" + Bottom 层，:21-22）。
      occupiesDesktop: true,
      // 锁屏与壁纸选择器时隐藏（SDK 语义：保留状态淡出 + 抑制输入，
      // surfaces.dart:134-135）。
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) {
    // 数据通道为 dart:io 实现，生命周期跟随 surface 实例（dispose 于
    // `_KosDeskCenterSurfaceState.dispose`）。
    return _KosDeskCenterSurface(surface: surface);
  }
}

/// 持有数据通道与配置存储的 surface 实例 widget。
class _KosDeskCenterSurface extends StatefulWidget {
  const _KosDeskCenterSurface({required this.surface});

  final ShellSurfaceContext surface;

  @override
  State<_KosDeskCenterSurface> createState() =>
      _KosDeskCenterSurfaceState();
}

class _KosDeskCenterSurfaceState extends State<_KosDeskCenterSurface> {
  /// kos-data.sock JSONL 客户端；Denial 会话无该服务，连接失败自动降级。
  /// 仍保留以承载 activity 通道（socket 在时活动榜可走服务端结算）。
  late final SocketKosDataClient _dataClient = SocketKosDataClient();

  /// 内嵌 metrics 采集器（TASK-10）：/proc+/sys+df 采 CPU/内存/磁盘/频率/温度。
  late final SystemMetricsCollector _metricsCollector =
      SystemMetricsCollector();

  /// 内嵌 Open-Meteo 天气 provider（TASK-10）。
  late final WeatherProvider _weatherProvider = WeatherProvider();

  /// 插件内 PIM 快照 watcher（TASK-11）：`PimStore` 产 `widget-snapshot.json`
  /// 替代外部 `FileWidgetSnapshotWatcher`（PIM 服务不跑）。
  late final PimSnapshotWatcher _watcher = PimSnapshotWatcher();

  /// 部件配置持久化（`$XDG_STATE_HOME/denial/kos_deskcenter/config.json`）。
  late final DeskCenterConfigStore _configStore = DeskCenterConfigStore();

  /// activity/uptime 持久化 ledger（TASK-18，
  /// `$XDG_STATE_HOME/denial/kos_deskcenter/activity-ledger.json`）。
  late final ActivityLedger _activityLedger = ActivityLedger();

  /// 宿主 `ProviderScope` 容器（写入跨 surface 面板会话用）；无 scope 的
  /// 预览形态为 null。
  ProviderContainer? _container;

  /// 本 surface 的环境事件订阅：锁屏/壁纸选择器时关闭面板会话（见
  /// [_onEnvironment]）。
  StreamSubscription<ShellSurfaceEnvironment>? _environmentSub;

  @override
  void initState() {
    super.initState();
    // 面板路由注册（TASK-13/14/15…）：幂等，首帧前装配一次。
    registerDeskPanels();
    // 瞬态面板语义：锁屏/进入壁纸选择器时关闭面板会话。旧实现走
    // `ShellPopupHost`（SDK 在锁屏时调 `dismissAllImmediately()` 清空）；
    // 改为会话 provider 后需在此显式关闭，否则锁屏只让面板 surface
    // `visible:false`、会话残留，解锁后原样恢复（编辑器 `TextField` 会跨锁屏保留）。
    _environmentSub = widget.surface.events.listen(_onEnvironment);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _container = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      _container = null; // 无 ProviderScope 的预览形态
    }
  }

  /// 环境变更：锁屏或壁纸选择器可见 → 关闭面板会话（对齐旧 popup 的
  /// 锁屏 `dismissAllImmediately()` 瞬态语义）。
  void _onEnvironment(ShellSurfaceEnvironment environment) {
    if (environment.locked || environment.wallpaperSelectorVisible) {
      _container?.read(deskPanelSessionProvider.notifier).close();
    }
  }

  @override
  void dispose() {
    unawaited(_environmentSub?.cancel());
    _environmentSub = null;
    _dataClient.dispose();
    _metricsCollector.dispose();
    _weatherProvider.dispose();
    _watcher.dispose();
    _activityLedger.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KosDeskCenterView(
      services: widget.surface.services,
      dataClient: _dataClient,
      // activity 卡前台应用跟踪的 `windows(monitorId)` 目标输出
      // （本 surface 只放主输出，:50-53 isMainOutput 门控）。
      monitorId: widget.surface.environment.output.monitorId,
      watcher: _watcher,
      configStore: _configStore,
      metricsCollector: _metricsCollector,
      weatherProvider: _weatherProvider,
      pimStore: _watcher.store,
      activityLedger: _activityLedger,
    );
  }
}

/// KOS DeskCenter 详情面板宿主表面（TASK-12 §9.4 方案 (B)）。
///
/// 面板由容器卡片点击驱动（`KosDeskCenterView._openPanel` 写入会话 provider），
/// 但渲染发生在本表面：落在 [ShellSurfaceLayer.desktopControls] 层，而非旧
/// 实现的 SDK `ShellPopupHost`（画在整个 shell 场景之上）。Denial 场景层序
/// （`denial_desktop/src/desktop/desktop_scene.dart` 内层 Stack）为
/// `desktop → 最小化窗口 → desktopControls(本层) → 普通应用窗口 →
/// DesktopPanelOverlay → 输入法候选 popup → aboveWindows`：本层位于候选窗
/// **之下**，故输入法候选窗可显示在面板之上（这正是要修的问题）。
///
/// `place()`：仅主输出贡献一个**铺满 workArea** 的 bounds，不占桌面
/// （`occupiesDesktop:false`，不推开最小化预览）；锁屏/壁纸选择器时
/// `visible:false`（保留状态淡出 + 抑制输入）。「无面板时」的隐藏由
/// `DeskPanelSurfaceHost` 渲染空 widget + `ShellInputRegion` 失活承担——
/// `place()` 是环境的纯函数（SDK 契约），读不到会话 provider 的运行时态。
@Provides(ShellSurface)
final class KosDeskCenterPanelSurface implements ShellSurface {
  const KosDeskCenterPanelSurface();

  @override
  String get id => 'kos_deskcenter.panel';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.desktopControls;

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    // 只在主输出落一个面板实例（与容器 surface 同门控，避免多输出重复弹层）。
    if (!environment.isMainOutput) return null;
    final area = environment.workArea;
    if (area.isEmpty) return null;
    return ShellSurfacePlacement(
      // 铺满工作区：遮罩覆盖整个可交互区，面板居中（DeskPanelShell 自管）。
      bounds: area,
      // 不占桌面区域（面板是瞬态弹层，不推开最小化窗口预览）。
      occupiesDesktop: false,
      // 锁屏/壁纸选择器时隐藏（SDK 语义：保留状态淡出 + 抑制输入）。
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      DeskPanelSurfaceHost(services: surface.services);
}
