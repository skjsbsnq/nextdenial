/// KOS Dock pill 容器（TASK-02 容器布局；TASK-04 接入内建图标与整行指针
/// 广播；TASK-04b 方案 C 落地 KOS iconSize 反解）。
///
/// 布局：surface bounds 是贴屏幕底边的条带，厚度 = `dockHeight +
/// edgeMargin + workspaceMargin`（`kos_dock.dart` 的 `place()` 按输出宽
/// 反解，KOS: dock/DockWindow.qml:92-93）；pill 高 = `DockMetrics.
/// dockHeight`（不再是常量），由 `Align.bottomCenter` + **底部
/// `metrics.edgeMargin` 内边距**停浮空边距在条带底边之上——对应 KOS
/// `dockWrapper` 的排法（KOS: dock/DockWindow.qml:177 `y: root.height -
/// root.edgeMargin - dockContainer.height`）。`Align` 的贴边不提供这个
/// 内缩：早期版本把 pill 直接贴到条带底部（= 屏幕底边）是错的，回归见
/// `test/dock_container_test.dart` 的 pill 底边内缩用例。
///
/// 方案 C（KOS `AdaptiveMath.computeLayout`，dock/AdaptiveMath.mjs:
/// 62-166）：pill 内容尺寸全部由 `DockMetrics` 反解——`iconSize =
/// clamp(反解值, MIN_ICON_SIZE=18, maxIconSize)`，随后 `dockHeight/
/// itemSpacing/hPadding/vPadding/dividerMargin/pillRadius/
/// activeBackgroundGap` 都由 iconSize 派生（:140-150）。**不再有滚动
/// 兜底**：反解保证内容宽 ≤ `stripWidth × 0.98`（maxWidth），原先
/// 「超宽转 pinned 段内滚动 + 运行段 ClipRect 收缩」的 v1 兜底整段
/// 移除（旧实现会在窄条带下出现可滚行与 RawScrollbar 白条；差异记录
/// 见 docs/visual-deltas.md 方案 C 条款）。
///
/// pill 内容（KOS dock/DockContainer.qml:496-962 Row 顺序）：
/// `[launcher?][trash?][pinned段][divider1?][运行段][divider2?][info]
/// [divider3?][tray]`；launcher/trash 为内建件（TASK-04），受
/// `dockPreferencesProvider` 的 `showLauncher`/`showTrash` 控制（KOS
/// `ConfigService.showLauncher`/`showTrash`，DockContainer.qml:532,571），
/// `DockIconRow`，内部按 KOS 分段（方案 B → TASK-11 起改自绘槽位）：
/// leading(launcher/trash) + pinned 段 → divider1(launchers|windows，
/// launcher/trash 为内建件（TASK-04），受
/// `dockPreferencesProvider` 的 `showLauncher`/`showTrash` 控制（KOS
/// `ConfigService.showLauncher`/`showTrash`，DockContainer.qml:532,571），
/// false 即时从 Row/宽度推导中移除。「图标区」= `dock.pinned` 槽位里的
/// `DockIconRow`，内部按 KOS 分段（TASK-11 起改自绘槽位，弃
/// ReorderableListView）：leading(launcher/trash) → pinned 段 →
/// divider1(launchers|windows，仅两段都非空时出现，
/// DockContainer.qml:847-857 `visible:` :856) → 未 pin 运行段
/// （windowsRepeater，:859-862）。pill 宽 = `metrics.dockWidth`
/// （= `min(iconSize×scaleFactor + fixedOverhead, maxWidth)`，
/// AdaptiveMath.mjs:148-149），由反解公式直接给出，不再走
/// 「自然宽 vs 预算」的分支 clamp。
///
/// 指针广播：单一 MouseRegion 罩住整个 pill 内容区，把指针全局 x 经
/// `MagnificationPointer` 发给 launcher/trash/pinned 全体图标——
/// KOS `DockContainer.qml:220-228` 唯一 HoverHandler
/// （`magnificationPointer`）+ 各 DockIcon `magnificationRoot: container`
/// （DockContainer.qml:537-538,578-579）。
///
/// popup 单例：整 pill 共享一个 `DockPopupCoordinator`（KOS
/// `DockModelService.activeDockPopup`/`activeContextMenu`，
/// dock/DockModelService.qml:32-39），下发给 launcher、trash（含其菜单与
/// 清空确认弹窗）与 pinned 图标行：任一时刻只有一个 popup，
/// 新打开者立即收掉前一个。
library;

import 'package:denial_flutter_sdk/glass_configuration.dart'
    show ShellTransparencyMode;
import 'package:denial_flutter_sdk/input.dart' show ShellInputRegion;
import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellTheme, ShellThemeBuildContext;
import 'package:denial_flutter_sdk/state.dart'
    show networkConnectivityProvider;
import 'package:denial_flutter_sdk/surfaces.dart' show ShellSurfacePresentation;
import 'package:denial_flutter_sdk/wallpaper.dart' show shellAccentProvider;
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:math' as math;

import '../state/dock_row_entries.dart';
import '../state/dock_settings.dart';
import '../theme/dock_tokens.dart';
import 'dock_backdrop_blur.dart';
import 'dock_status_panels.dart';
import 'dock_divider.dart';
import 'dock_icons.dart';
import 'dock_preview_popup.dart';
import 'launcher_icon.dart';
import 'magnification.dart';
import 'trash_icon.dart';
import 'tray_accessory.dart';

/// Dock pill。主题/透明度全部接 `ShellTheme` 与
/// `ShellSurfacePresentation`，无硬编码颜色；几何全部接
/// [DockMetrics]（方案 C 反解）。
class KosDockShell extends ConsumerStatefulWidget {
  const KosDockShell({
    required this.services,
    required this.monitorId,
    this.infoCard,
    this.trayAccessory,
    super.key,
  });

  /// 宿主服务束（surface context 提供；launcher/trash 显式消费，
  /// DockIconRow 内部另建 `ShellServicesScope`）。
  final ShellServices services;
  final int monitorId;

  /// 信息卡区挂件构造器：`KosDockShell` 持有全 pill 唯一的
  /// [DockPopupCoordinator]，构建时注入给调用方（TASK-05 `DockInfoCarousel`
  /// 的详情 popup 走同一单例；KOS `DockModelService.activeDockPopup`）。
  /// trayAccessory 为尾部托盘挂件（TASK-06 `DockTrayAccessory`：槽宽 =
  /// `max(metrics.iconSlotSize, trayEstimateWidth)`，估算宽经
  /// `DockMetrics.fromWidth(trayWidth:)` 回流进 dockWidth，见该件类注释）。
  /// TASK-08 起与 `infoCard` 同式接收 popup 协调器——wifi/蓝牙状态格
  /// 面板与图标预览/菜单互斥，共享全 pill 唯一 `DockPopupCoordinator`。
  final Widget Function(DockPopupCoordinator coordinator)? infoCard;
  final Widget Function(DockPopupCoordinator coordinator)? trayAccessory;

  @override
  ConsumerState<KosDockShell> createState() => _KosDockShellState();
}

class _KosDockShellState extends ConsumerState<KosDockShell> {
  /// TASK-12 缺陷3：DockIconRow 每帧 postFrame 回报的当帧波形布局宽
  /// （Σspan，见 `dock_icons.dart` `layoutWidth` 参数）。pill 本体宽/底层
  /// 占位/带层 `dock.pinned` 宽都取 `max(静止反解宽, 本值)`——quickshell
  /// `DockSurface.qml:119-120` `bandLength = min(availableLength,
  /// max(96, layout.length))` 语义：pill 两端对称外扩跟随放大后的布局
  /// 长，放大图标不再向 pill 外溢出遮 divider/info/tray。初值 0 → 上报
  /// 前取静止宽（等价旧行为）。
  final _iconRowLayoutWidth = ValueNotifier<double>(0);
  /// KOS `magnificationPointer`（DockContainer.qml:220-228）：整个 pill
  /// 的单一 hover 源把指针全局 x 发给所有图标；null = 指针离开容器
  /// （等价 KOS `Qt.point(-10000,-10000)` 哨兵）。
  final _pointerX = ValueNotifier<double?>(null);

  /// 全 pill 唯一的 popup 协调器（KOS dock/DockModelService.qml:32-39,65-72
  /// `activeDockPopup`/`activeContextMenu` 单例）：pinned 预览/右键菜单、
  /// trash 菜单、清空确认弹窗共用同一份，新打开者立即收掉前一个；
  /// launcher tap 也先清场（DockContainer.qml:560-563）。
  final _popups = DockPopupCoordinator();

  /// 广播 MouseRegion 的 RenderBox（localToGlobal 坐标映射用）。
  final _pointerRegionKey = GlobalKey();

  /// TASK-12 图标带层（Stack 顶层）的广播 MouseRegion RenderBox——与玻璃层
  /// `_pointerRegionKey` 共喂同一 `_pointerX`（两条 hover 源等价 KOS
  /// `magnificationPointer` 单源语义：玻璃层罩 pill 本体、带层罩图标带
  /// [hPadding, hPadding+iconRowWidth)×dockHeight，谁在谁上由 hit test 决
  /// 定）。带层热区厚度恒 = dockHeight（缺陷3(a)：headroom 空白不吃
  /// hover，quickshell `DockItem.qml:190-199` pointerArea 排除 headroom
  /// 同语义）。
  final _bandPointerRegionKey = GlobalKey();

  /// 指针 x 广播到与槽中心同系的全局坐标：MouseRegion 事件给的是局部
  /// 坐标，经自身 RenderBox.localToGlobal 映射（DockIcon/内建图标的槽
  /// 中心同为 localToGlobal 全局系）。
  void _broadcastPointer(PointerHoverEvent event) {
    final box = _pointerRegionKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _pointerX.value = box.localToGlobal(event.localPosition).dx;
  }

  /// 图标带层同式（`_broadcastPointer` 的 RenderBox 换成带层 key）。
  void _broadcastBandPointer(PointerHoverEvent event) {
    final box = _bandPointerRegionKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _pointerX.value = box.localToGlobal(event.localPosition).dx;
  }

  @override
  void dispose() {
    _iconRowLayoutWidth.dispose();
    _pointerX.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    // surface 级可见性淡入淡出（锁屏/壁纸选择器时 SDK 动画驱动）。
    final opacity = ShellSurfacePresentation.opacityOf(context);
    // top_bar `_SystemBarCard` 顶部轻打光渐变（denial_top_bar
    // desktop_system_bar_components.dart:284-302）提升到 panel 语义：
    // cardFillTop→cardFill 两 stop 经 panelGradient 走面板透明度。
    final accent = ref.watch(shellAccentProvider);
    final prefsAsync = ref.watch(dockPreferencesProvider);
    // 首帧仍是 loading（异步 store 读文件）时退回默认四卡——沿用既有兜底；
    // 但 weather 快照流的订阅必须等偏好真正读到（见下）。
    final prefs = prefsAsync.value ?? const DockPreferences();
    // KOS ConfigService.showLauncher/showTrash（DockContainer.qml:532,571
    // `visible: ConfigService.show*`）：false 即时从 Row 与宽度推导中移除。
    final showLauncher = prefs.showLauncher;
    final showTrash = prefs.showTrash;
    // 条目序列由纯函数 `dockRowEntries` 推导（与 DockIconRow 渲染共用同一
    // 事实来源，state/dock_row_entries.dart）：pinned 段 + 未 pin 运行段
    // （KOS dock/DockModelService.qml:150-200 grouped，CONSTRAINTS §5 修正
    // 2026-10-05）。
    final entries = dockRowEntries(
      prefs: prefs,
      catalog: ref.watch(widget.services.applications),
      windows: ref.watch(widget.services.windows(widget.monitorId)),
    );
    final entryCount = entries.length;
    // 方案 B（KOS DockContainer.qml:847-862）：pinned 段与未 pin 运行段在
    // 图标区内部由 DockIconRow 分开渲染；divider 可见性需要两段各自计数。
    final pinnedCount = entries.where((entry) => entry.isPinned).length;
    final runningCount = entryCount - pinnedCount;
    final infoCard = widget.infoCard?.call(_popups);
    final trayAccessory = widget.trayAccessory?.call(_popups);
    // KOS `hasInfo = hasAvailableInfo && !hideInfoCarousel`
    // （DockContainer.qml:143）：`hasAvailableInfo` 由 `infoCardOrder` 与各卡
    // 数据可用性共同推导（`:46-58`）——clock/metrics 恒可用（metrics 无数据
    // 也常驻，`:54-56`）、music 需 `services.media.available`、weather 需
    // `dockWeatherSnapshotProvider` 的 ready 快照（与 `DockInfoCarousel` 同一
    // provider，保证同帧同源）。**零可用卡即整区隐藏**：order 非空但全是
    // 不可用卡（如 `['music']` 且无播放器、`['weather']` 首帧未 ready）时不能
    // 只靠「infoCard 非 null」判定，否则 pill 里会留下 4.2×iconSize 的空槽与
    // 一条多余 divider2。order 是会话态（`dockPreferencesProvider`），故在
    // shell 层推导（`place()` 契约层拿不到，保持纯函数）。
    //
    // music 可用性**与 order 同源门控**：order 不含 music 时该项恒不可用，并且
    // 不再订阅 `widget.services.media`（媒体流每次播放状态/进度 tick 都会通知，
    // 无门控时 order 不含 music 的会话仍会随媒体变化重建整 pill）。carousel
    // （`info_carousel.dart` build）用**同一表达式**，避免「shell 判
    // hasInfo=true 而 carousel 认为 music 不可用」的两侧漂移。
    final mediaAvailable = prefs.infoCardOrder.contains('music')
        ? ref.watch(widget.services.media.select(
            (state) => state.value?.available ?? false,
          ))
        : false;
    // weather 快照流**只在门控打开时才订阅**：门控 = 偏好已真正读到
    // （`prefsAsync.hasValue`）**且** order 需要天气数据——
    // [dockInfoCardNeedsWeather] = 「含 `weather` **或** 含 `clock`」
    // （clock 页的日出/日落行 `_SolarEventRow` 读同一份快照
    // `weather.sunrise/sunset`，故不能只按 含 `weather` 门控），shell 与
    // carousel 共用该判据（定义在 `data/dock_preferences.dart`）。
    //
    // 为什么必须门控（复审 round-3 缺陷 1：原先「只判 contains('weather')」+
    // carousel 无条件 watch，门控在生产路径不产生任何效果）：`dockWeather
    // SnapshotProvider` 一经 watch 就 `start()` 真实 provider
    // （state/dock_settings.dart:63-67：dart:io HttpClient + 真实状态文件 +
    // 1min 周期 Timer），且它是 keepAlive（非 autoDispose，
    // `dock_settings.dart:45-52`）——无条件订阅会让「order 里既没有天气卡也
    // 没有 clock」的会话照样起网络轮询，且此后不会自行停。`prefsAsync.
    // hasValue` 是必需的：loading 帧的 `prefs` 是默认四卡兜底（含 weather），
    // 只判 order 会让**每个**会话在启动帧就构造真实 provider（实测）。
    // **默认四卡（KOS 同构）恒订阅**，与 KOS `WeatherService` 常驻一致；
    // 「按卡片集合收敛订阅」是移植期收敛，记 docs/visual-deltas.md TASK-05 节。
    // 挂 `KosDockShell` 的测试因此必须 override `dockWeatherProviderProvider`。
    final weatherGate =
        prefsAsync.hasValue && dockInfoCardNeedsWeather(prefs.infoCardOrder);
    final weatherAvailable = weatherGate
        ? ref.watch(dockWeatherSnapshotProvider).value?.available ?? false
        : false;
    final hasAvailableInfo =
        infoCard != null &&
        prefs.infoCardOrder.any(
          (id) => switch (id) {
            // hasClock（`:52-53`，融合模式 showClock 恒真）/ hasTemperature
            // （`:54-56`，MetricsService 未就绪也常驻显 `--`）。
            'clock' || 'metrics' => true,
            'music' => mediaAvailable,
            'weather' => weatherAvailable,
            _ => false,
          },
        );
    // TASK-06 托盘估算宽（KOS `estimatedAccessoryWidth` 语义的回流，
    // TASK-06/08 托盘估算宽（KOS `estimatedAccessoryWidth` 语义的回流，
    // DockContainer.qml:111-133 预扣 + :954-959 `Loader.width =
    // item.implicitWidth`）：托盘项数 + 状态格（wifi/bt/battery，能力缺失
    // 隐藏）→ `dockTrayEstimateWidth`。只有 trayAccessory 挂载时才订阅这些
    // provider（托盘源 tick 不应重建无托盘的 pill）。
    final trayIdCount = trayAccessory != null
        ? ref.watch(widget.services.trayItemIds.select((ids) => ids.length))
        : 0;
    // 状态格计数与 `DockTrayAccessory` 内同源（KOS `trailingCells`，
    // BarStatusArea.qml:28-33 = network/battery/settings/controlcenter；
    // settings 无等价物隐藏、无独立蓝牙格）：wifi 看 `wifiDeviceAvailable`
    // （KOS NetworkStatus.qml `visible: NetworkService.available`）、battery 看
    // `capacity != null`、controlcenter（TASK-09）**恒显示 +1**。
    final statusCellCount = trayAccessory == null
        ? 0
        : (ref.watch(networkConnectivityProvider.select(
                  (state) => state.snapshot.wifiDeviceAvailable,
                ))
                  ? 1
                  : 0) +
              (ref.watch(widget.services.battery.select(
                  (battery) => battery.capacity != null,
                )) ? 1 : 0) +
              1;
    final trayItemCount = trayIdCount + statusCellCount;
    // chicken-and-egg：折行判定的 availableHeight=dockHeight 依赖反解后的
    // iconSize，而 iconSize 依赖含 trayWidth 的 dockWidth。先用基准 dock
    // 高（kDockBaseHeight=60）做两行判定；最终反解后按真实 dockHeight
    // 复算一次兜底（参考 hasInfo 探针范式——两行阈值翻转只发生在
    // dockHeight≈52 即 iconSize≈37 的窄带，复算保证收敛）。
    var trayTwoRows = dockTrayTwoRows(
      itemCount: trayItemCount,
      availableHeight: kDockBaseHeight,
    );
    var trayEstimateWidth = trayItemCount <= 0
        ? 0.0
        : dockTrayEstimateWidth(itemCount: trayIdCount, twoRows: trayTwoRows) +
              statusCellCount * (kDockTrayIconSpacing + kDockTrayItemSize);
    // hasTray 由估算宽推导：托盘 0 项且无状态格时 tray 槽与 divider3 整段
    // 不渲染（KOS `trailingAccessoryDividerVisible` 同语义，
    // DockContainer.qml:951）——不再留「trayAccessory 非 null 但内容空」的
    // 孤立 divider3。
    final hasTray = trayAccessory != null && trayEstimateWidth > 0;

    // ── 方案 C：KOS iconSize 反解（dock/AdaptiveMath.mjs:62-166 移植，
    //    DockMetrics.fromWidth 逐项对应）──
    // 可用宽 = 条带宽（KOS `availableLength`；tray 估算宽经 trayWidth 参数
    // 回流进 fromWidth 而非从 availableLength 预扣——KOS DockContainer.qml:
    // 170 的 `max(baseHeight, availableLength − estimatedAccessoryWidth)`
    // 是输出宽折让；本端把托盘宽计入 dockWidth 内部分，见 deltas）。cap
    // 上限与 KOS 一致走 `maxLengthRatio = 0.98`（AdaptiveMath.mjs:29-30）。
    final stripWidth = MediaQuery.sizeOf(context).width;
    // KOS `_infoProbeLayout`（DockContainer.qml:127-137）：**带上 carousel**
    // 先反解一次当探针；探针 iconSize 掉到绝对下限 MIN_ICON_SIZE=18 时摘掉整
    // 区（`hideInfoCarousel` :138-143——18px 图标下卡片连紧凑字形都放不下，
    // 摘掉同时把 4 个图标宽还给应用条目）。先探针再决定是为避免「摘掉 → 图标
    // 变大 → 又出现」的反馈环（KOS 注释 :127-129 同义）。
    final probeMetrics = DockMetrics.fromWidth(
      stripWidth,
      pinnedCount: pinnedCount,
      runningCount: runningCount,
      showLauncher: showLauncher,
      showTrash: showTrash,
      hasInfo: hasAvailableInfo,
      hasTray: hasTray,
      trayWidth: trayEstimateWidth,
    );
    final hasInfo =
        hasAvailableInfo && probeMetrics.iconSize > kDockMinIconSize.toDouble();
    // 摘掉时按最终 hasInfo 重新反解（KOS `_layout` 用的就是最终 hasInfo）；
    // 未摘掉时探针即最终几何，直接复用。
    var metrics = hasInfo == hasAvailableInfo
        ? probeMetrics
        : DockMetrics.fromWidth(
            stripWidth,
            pinnedCount: pinnedCount,
            runningCount: runningCount,
            showLauncher: showLauncher,
            showTrash: showTrash,
            hasInfo: hasInfo,
            hasTray: hasTray,
            trayWidth: trayEstimateWidth,
          );
    // 折行判定兜底：用最终 dockHeight 复算 twoRows（基准 60 的预判在
    // dockHeight≈52 的窄带可能翻转），翻转时用真实 trayWidth 再反解一次
    // metrics——只改 trayWidth 不动其余输入，收敛且最多多花一次 fromWidth。
    final finalTwoRows = dockTrayTwoRows(
      itemCount: trayItemCount,
      availableHeight: metrics.dockHeight,
    );
    if (hasTray && finalTwoRows != trayTwoRows) {
      trayTwoRows = finalTwoRows;
      trayEstimateWidth =
          dockTrayEstimateWidth(itemCount: trayIdCount, twoRows: trayTwoRows) +
          statusCellCount * (kDockTrayIconSpacing + kDockTrayItemSize);
      metrics = DockMetrics.fromWidth(
        stripWidth,
        pinnedCount: pinnedCount,
        runningCount: runningCount,
        showLauncher: showLauncher,
        showTrash: showTrash,
        hasInfo: hasInfo,
        hasTray: hasTray,
        trayWidth: trayEstimateWidth,
      );
    }

    // divider 可见性由 metrics 的同一组静态规则复算（KOS
    // DockContainer.qml:856,912,951 的 `visible:` 绑定；与 fromWidth 内部
    // dividerCount 保持同源）。**槽位 key 固定**：槽位显隐会改变 Row
    // 子元素下标，不给 key 会让 Flutter 按下标匹配后一位子树（Widget
    // 类型不同 → 旧子树销毁重建），图标行 `DockIconRow` 连同
    // `_DockEntrance`/ReorderableListView 状态一起重建 → pinned 图标
    // 重播入场动画、槽中心在重播期间短暂偏移（TASK-04 槽中心一致性回归
    // 暴露）。
    final divider2 = DockMetrics.divider2Visible(
      hasInfo: hasInfo,
      pinnedCount: pinnedCount,
      runningCount: runningCount,
    );
    final divider3 = DockMetrics.divider3Visible(
      hasTray: hasTray,
      hasInfo: hasInfo,
      showLauncher: showLauncher,
      showTrash: showTrash,
      pinnedCount: pinnedCount,
      runningCount: runningCount,
    );

    // KOS: dock/DockContainer.qml:195-196 `Math.round(computedDockHeight *
    // radiusRatio)`——半径绑运行时 dock 高（半径=高/2），非静态
    // baseHeight×0.5；radiusRatio 0.50 见 common/AppearanceTokens.qml:413。
    final borderRadius = BorderRadius.circular(metrics.pillRadius);

    // pill 宽 = `metrics.dockWidth`：KOS `contentWidth = iconSize*scaleFactor
    // + fixedOverhead`、`dockWidth = min(contentWidth, maxWidth)`
    // （AdaptiveMath.mjs:148-149），反解后恒 ≤ cap——不再需要方案 A/B 的
    // 「自然宽 vs 预算」clamp 与滚动兜底。pill 底部内缩
    // `metrics.edgeMargin`（`max(4, round(dockHeight*0.12))`，随反解后
    // dockHeight 变化；KOS: dock/DockWindow.qml:63-64,177）。
    // TASK-12（quickshell DockItem.qml:112 / DockSurface.qml:120-121）：
    // 放大图标底锚 pill 底向上「长」、可溢出 pill 顶缘（macOS 跳出水面）。
    // - glass pill 本体保持 dockHeight 底对齐不变；
    // - `ShellBackdropBlur` 的 ClipRRect 会裁掉溢出顶缘的内容，故给它包一层
    //   OverflowBox：clip 边界向上扩 headroom（= 放大探出需求 + bounce/lift
    //   余量，quickshell bandThickness 按 maxScale 预留带高的等价），blur/玻璃
    //   仍只作用在 tight dockHeight 盒上——溢出部分只
    //   是「不被裁」，backdrop-filter 的滤镜区不跟出去（quickshell 同构：
    //   glass.y = parent.height − height 钉在带底，band 上半段无玻璃）；
    // - 图标区（dock.pinned 槽位）单独提到 clip 之外的顶层层：底层玻璃盒内
    //   留同宽占位（Row 自然宽不变），顶层 OverflowBox 向上放
    //   DockIconRow——Row 的 crossAxisAlignment=center 按自身 maxChild 高
    //   （dockHeight+headroom）给图标区分配高度，图标带在
    //   dock_icons.dart 内底对齐，槽位盒贴带底。
    //
    // headroom 显式语义（quickshell `bandThickness = size·maxScale + 36` 的
    // 本端等价）：美术盒底锚 pill 底，顶缘 = iconSlotSize·maxScale——超出
    // pill 顶（dockHeight）的量 = iconSlotSize·maxScale − dockHeight。再加
    // TASK-10 bounce 顶点（19px 向上平移，bounce 叠在放大基线上）与 hover
    // lift（max(2, round(iconSize×0.08))≈4px）的余量，以及 2px 舍入保险，
    // 保证「满幅放大 + bounce 顶点 + lift」极端组合也不被 ClipRRect 切顶。
    // 底部 max(0,…) 兜底：dockHeight 足够大时 headroom 可为 bounce/lift 项。
    final iconRowHeadroom = math.max(
      0.0,
      metrics.iconSlotSize * kDockWaveMaxScale -
          metrics.dockHeight +
          kDockLaunchBounceHeight +
          kDockIconLiftHeadroomSlack,
    );

    // TASK-12 缺陷3（quickshell `DockSurface.qml:119-120` `bandLength =
    // min(availableLength, max(96, layout.length))`）：pill 宽跟随**当帧**
    // 波形布局宽 Σspan——图标带放大时 pill 两端对称外扩，放大图标始终留在
    // pill 内（不再向左右溢出遮 divider/info/tray）。Σspan 由 DockIconRow
    // 每帧 postFrame 回报到 `_iconRowLayoutWidth`；行重建/隐藏时本帧内用
    // 静止反解宽兜底（`restingIconRowWidth` 与 `DockIconRow` 内 weights
    // 构造逐项一致：leading+pinned+divider1(unscaled,dividerSlotWidth) +
    // running，全槽 scale=1）。pill 宽 = 静止 dockWidth + Δmax(0, Σspan −
    // resting)——外层 Align.bottomCenter 居中重排，外扩自然对称。
    final restingIconRowWidth = _iconRowWidth(
      metrics,
      entryCount: entryCount +
          (showLauncher ? 1 : 0) +
          (showTrash ? 1 : 0),
      divider1: DockMetrics.divider1Visible(
        pinnedCount: pinnedCount,
        runningCount: runningCount,
      ),
    );
    // Width changes only update geometry. Reuse the icon subtree so the
    // layout-width feedback doesn't rebuild every icon a second time.
    final iconRow = DockIconRow(
      monitorId: widget.monitorId,
      services: widget.services,
      coordinator: _popups,
      layoutWidth: _iconRowLayoutWidth,
      leading: [
        if (showLauncher)
          LauncherIcon(
            key: const ValueKey<String>(
              'dock.launcher',
            ),
            services: widget.services,
            coordinator: _popups,
          ),
        if (showTrash)
          TrashIcon(
            key: const ValueKey<String>('dock.trash'),
            services: widget.services,
            monitorId: widget.monitorId,
            coordinator: _popups,
          ),
      ],
    );
    return AnimatedBuilder(
      animation: _iconRowLayoutWidth,
      child: iconRow,
      builder: (context, child) {
        // Σspan 恒 ≥ resting（scale ≥ 1）；行首帧未上报（值 0）时退化为
        // 静止宽。行消失/条目骤减后上报滞后一帧 → max 取法保证不欠宽
        // （空行另经 `_reportLayoutWidth(0)` 主动清零，见 dock_icons.dart）。
        final reportedIconRowWidth =
            math.max(restingIconRowWidth, _iconRowLayoutWidth.value);
        // TASK-12 复审缺陷2：占位宽/带层宽必须与 pillWidth 走**同一预算**
        // ——底层 Row 的子项合计 = 占位宽 + 非图标区（divider2? + info? +
        // divider3? + tray?），pillWidth 被 stripWidth 截断时占位宽不跟着
        // 截会让 Row 溢出（debug 黄黑条 / release 右缘溢出），带层
        // `SizedBox(width: iconRowWidth)` 在 centerLeft 下同向溢出。
        // 非图标区宽 = Row 子项同式（divider 槽宽 `dividerSlotWidth`、info
        // 槽 `infoSlotWidth + iconSize·kDockInfoCardGapRatio`、tray 槽
        // `max(iconSlotSize, trayEstimateWidth)`——tray 在 fromWidth 的
        // `trayRenderedOverflow` 回流与 DockTrayAccessory 内部缺省重算都
        // 以「渲染宽」为准）。info 槽内 `ClipRect` + 页间 `pageX` 位移是
        // 槽内行为，槽位几何不受放大影响。
        final nonIconWidth =
            (divider2 ? metrics.dividerSlotWidth : 0.0) +
                (hasInfo
                    ? metrics.infoSlotWidth +
                        metrics.iconSize * kDockInfoCardGapRatio
                    : 0.0) +
                (divider3 ? metrics.dividerSlotWidth : 0.0) +
                (hasTray
                    ? math.max(metrics.iconSlotSize, trayEstimateWidth)
                    : 0.0);
        final iconRowWidth = math.min(
          reportedIconRowWidth,
          math.max(0.0, stripWidth - 2 * metrics.hPadding - nonIconWidth),
        );
        // pill 宽 = 内容宽（hpad×2 + 图标区 + 非图标区），自然封顶 stripWidth
        // ——放大外扩语义不变（Σspan 超静止时两端对称外扩），只是带层/占位与
        // pill 一起参与同一预算截断。
        final pillWidth = math.min(
          2 * metrics.hPadding + iconRowWidth + nonIconWidth,
          stripWidth,
        );
        return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: metrics.edgeMargin),
        child: OverflowBox(
          // TASK-12：clip 边界向上放 headroom（放大图标可溢出 pill 顶缘），
          // 自身仍是 tight dockWidth×dockHeight 的 pill 盒。
          maxHeight: metrics.dockHeight + iconRowHeadroom,
          alignment: Alignment.bottomCenter,
          child: MagnificationPointer(
            pointerX: _pointerX,
            child: DockMetricsScope(
              metrics: metrics,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // ── 底层：glass pill 本体（dockWidth×dockHeight，底对齐）──
                  // TASK-12 复审缺陷2：ShellBackdropBlur 末端 ClipRRect 跟
                  // 子树尺寸走——它的子树里只放 tight dockHeight 的 pill 本
                  // 体，图标带层移出 ClipRRect（溢出通路不再经过裁剪，与
                  // quickshell `glass` 恒定高、band 独立层同构）。
                  DockBackdropBlur(
                    blur: theme.backdropBlurEnabled,
                    // 前景不进 filter 层：glass 模式的 refraction/edge 光效
                    // 不污染内容。
                    opacity: opacity,
                    borderRadius: borderRadius,
                    child: ShellInputRegion(
                      debugLabel: 'KOS Dock pill',
                      // 矩形输入区罩住整个 pill；KOS squircle 输入形状以更
                      // 紧的非矩形区近似为矩形（偏差记 docs/visual-deltas.md）。
                      // minor②（不修，仅注记）：本区只罩 tight dockHeight
                      // ——放大美术盒向上探出的 headroom 区不在输入区内、命中
                      // 不上报；按 macOS/quickshell 语义（pointerArea 排除
                      // headroom，DockItem.qml:190-199）探出部分本就不可点击。
                      child: SizedBox(
                        width: pillWidth,
                        height: metrics.dockHeight,
                        // DecoratedBox 画在 tight SizedBox 内侧——若用带
                        // border 的 Container，hairline 边宽会把内容区再内推
                        // 2px 造成 Row 溢出。
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: borderRadius,
                            gradient: theme.panelGradient(
                              accent.cardFillTop(theme),
                              accent.cardFill(theme),
                            ),
                            // KOS: dock/DockDivider.qml:16 — divider 色走
                            // 语义 hairline，不在此硬编码；hairline 边线给
                            // 玻璃一个收敛边缘。
                            // Match Denial's glass tiles: the material owns
                            // its edge; another hairline doubles the contour.
                            border: theme.transparencyMode == ShellTransparencyMode.glass
                                ? null
                                : Border.all(color: colors.hairlineSoft),
                          ),
                          child: MouseRegion(
                            key: _pointerRegionKey,
                            // 缺陷3(b)：opaque 命中——容器含指针即连续几何判
                            // 定，槽间 itemSpacing 缝隙、pill 顶部死区
                            // （dockHeight−iconSlotSize≈8.6px）不再反复
                            // enter/exit。
                            hitTestBehavior: HitTestBehavior.opaque,
                            onHover: _broadcastPointer,
                            onExit: (_) => _pointerX.value = null,
                            child: Padding(
                              // hpad = round(iconSize*0.4)，随 iconSize 反解
                              // （KOS: AdaptiveMath.mjs:12,143）。
                              padding: EdgeInsets.symmetric(
                                horizontal: metrics.hPadding,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // 图标区占位：真实 DockIconRow 在 Stack
                                  // 顶层（溢出 pill 顶缘不被 ClipRRect
                                  // 裁）；占位保 Row 自然宽/槽位序不变，
                                  // 自身不吃 hit（IgnorePointer——顶层图标
                                  // 带才是交互面）。
                                  IgnorePointer(
                                    child: SizedBox(
                                      key: const ValueKey<String>(
                                        'dock.pinned.placeholder',
                                      ),
                                      // TASK-12 缺陷3：占位宽 = 当帧图标区
                                      // 宽（max(静止, Σspan)）——pill 外扩时
                                      // 它把 divider2/info/tray 同步右推。
                                      width: iconRowWidth,
                                    ),
                                  ),
                                  if (divider2)
                                    const DockDivider(
                                      key: ValueKey<String>(
                                        'dock.divider.info',
                                      ),
                                    ),
                                  if (hasInfo)
                                    KeyedSubtree(
                                      key: const ValueKey<String>(
                                        'dock.infoCard',
                                      ),
                                      child: infoCard,
                                    ),
                                  if (divider3)
                                    const DockDivider(
                                      key: ValueKey<String>(
                                        'dock.divider.tray',
                                      ),
                                    ),
                                  if (hasTray)
                                    // 托盘真实槽宽 = max(iconSlotSize, 估算内容
                                    // 宽)（KOS `Loader.width = item.
                                    // implicitWidth` 参与 Row 自然宽等价，
                                    // DockContainer.qml:954-959）；trayWidth 已
                                    // 回流进 dockWidth，内容右对齐排在槽内、不
                                    // 外延不遮相邻槽位。DockTrayAccessory 缺省
                                    // trayWidth 时内部同式重算槽宽，与本槽同宽
                                    // 不漂移。
                                    SizedBox(
                                      key: const ValueKey<String>('dock.tray'),
                                      width: math.max(
                                        metrics.iconSlotSize,
                                        trayEstimateWidth,
                                      ),
                                      height: metrics.dockHeight,
                                      child: DockStatusPanelBounds(child: trayAccessory),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ── 顶层：图标带（ClipRRect 之外的溢出通路）──
                  // KOS: dock/DockContainer.qml:496-962 Row 顺序：
                  // launcher → trash → pinned段 → divider1 → 运行段 ——
                  // launcher/trash 经 `DockIconRow.leading` 纳入同一
                  // `dockWaveLayout`（权重 1）。本层底对 pill 底、高度 =
                  // dockHeight + headroom（quickshell `DockSurface.qml:
                  // 120-121` `bandThickness = size·maxScale + 36` 按最大倍
                  // 率预留带高的等价）：波形槽位底对带底，放大美术盒向上探出
                  // pill 顶缘（带层已移出 ShellBackdropBlur 的 ClipRRect 子
                  // 树，缺陷2）。宽度与底层占位同式（反解自然宽，方案 C 起恒
                  // ≤ 预算），水平位置与底层 Row 同（同 hPadding 起排）。
                  //
                  // 缺陷3(a)：MouseRegion 热区厚度恒 = dockHeight——
                  // quickshell `DockSurface.qml:750-760` `dockInputArea` 恒
                  // `restingThickness+8`、`DockItem.qml:190-199` pointerArea
                  // `min(artwork.y, root.height−restingIconSize−22)` 显式排
                  // 除 headroom 语义：放大图标探出 pill 顶的部分**可命中**
                  // （OverflowBox 的 clip 边界外扩只是视觉通路，hit test 不
                  // 拦），但 headroom 空白区不吃 hover。hitTestBehavior:
                  // opaque 使含指针的判定是连续几何（缺陷3(b)：槽间缝隙不
                  // 再掉出 region）。
                  Positioned(
                    left: metrics.hPadding,
                    bottom: 0,
                    width: iconRowWidth,
                    height: metrics.dockHeight,
                    child: MouseRegion(
                      key: _bandPointerRegionKey,
                      hitTestBehavior: HitTestBehavior.opaque,
                      onHover: _broadcastBandPointer,
                      onExit: (_) => _pointerX.value = null,
                      child: OverflowBox(
                        // 带内容高 = dockHeight + headroom、底对齐——
                        // DockIconRow 内的 Align.bottomCenter 需要这个高度
                        // 才能让槽位列向上探出 pill 顶缘；hit 盒（外层
                        // Positioned）仍只有 dockHeight。
                        minHeight: metrics.dockHeight + iconRowHeadroom,
                        maxHeight: metrics.dockHeight + iconRowHeadroom,
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          key: const ValueKey<String>('dock.pinned'),
                          // TASK-12 缺陷3：带层宽 = 当帧 Σspan（与占位同源）
                          // ——图标带外扩始终留在 pill 内，不遮相邻槽位。
                          width: iconRowWidth,
                          height: metrics.dockHeight + iconRowHeadroom,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
        );
      },
    );
  }

  /// 图标区自然宽 = `n*(slot+spacing) − spacing` + divider1 槽位。
  ///
  /// [entryCount] 含 leading（launcher/trash）——TASK-11 起它们经
  /// `DockIconRow.leading` 进同一 `dockWaveLayout` 波形带，槽宽同规格
  /// iconSlotSize；divider1 仍以 `dividerSlotWidth` 占一个槽位（波形内
  /// unscaled）。与 `DockMetrics.fromWidth` 的 iconUnits/divider 计数
  /// 同式；反解后恒 ≤ dockWidth 扣掉固定槽位后的部分。
  static double _iconRowWidth(
    DockMetrics metrics, {
    required int entryCount,
    required bool divider1,
  }) => entryCount <= 0
      ? 0.0
      : entryCount * (metrics.iconSlotSize + metrics.itemSpacing) -
            metrics.itemSpacing +
            // divider1 槽在 pinned|running 之间、`dockWaveLayout` 给它
            // `span = dividerSlotWidth + itemSpacing`（非末槽仍带尾随
            // gap）——本函数须与之同式，否则图标区定宽比真实行宽窄一个
            // itemSpacing，running 末槽溢出图标区右缘。
            (divider1 ? metrics.dividerSlotWidth + metrics.itemSpacing : 0.0);
}
