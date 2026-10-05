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
/// false 即时从 Row/宽度推导中移除。「图标区」= `dock.pinned` 槽位里的
/// `DockIconRow`，内部按 KOS 分段（方案 B）：pinned 段
/// ReorderableListView → divider1(launchers|windows，仅两段都非空时
/// 出现，DockContainer.qml:847-857 `visible:` :856) → 未 pin 运行段
/// Row（windowsRepeater，:859-862）。pill 宽 = `metrics.dockWidth`
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

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart' show ShellInputRegion;
import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellTheme, ShellThemeBuildContext;
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:denial_flutter_sdk/wallpaper.dart' show shellAccentProvider;
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dock_row_entries.dart';
import '../state/dock_settings.dart';
import '../theme/dock_tokens.dart';
import 'dock_divider.dart';
import 'dock_icons.dart';
import 'dock_preview_popup.dart';
import 'launcher_icon.dart';
import 'magnification.dart';
import 'trash_icon.dart';

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

  /// 后续任务挂件：infoCard（music/weather 信息卡，槽宽 =
  /// `metrics.infoSlotWidth`）、trayAccessory（尾部托盘挂件，槽宽 =
  /// `metrics.iconSlotSize`）。
  final Widget? infoCard;
  final Widget? trayAccessory;

  @override
  ConsumerState<KosDockShell> createState() => _KosDockShellState();
}

class _KosDockShellState extends ConsumerState<KosDockShell> {
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

  /// 指针 x 广播到与槽中心同系的全局坐标：MouseRegion 事件给的是局部
  /// 坐标，经自身 RenderBox.localToGlobal 映射（DockIcon/内建图标的槽
  /// 中心同为 localToGlobal 全局系）。
  void _broadcastPointer(PointerHoverEvent event) {
    final box = _pointerRegionKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _pointerX.value = box.localToGlobal(event.localPosition).dx;
  }

  @override
  void dispose() {
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
    final prefs =
        ref.watch(dockPreferencesProvider).value ?? const DockPreferences();
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
    final infoCard = widget.infoCard;
    final trayAccessory = widget.trayAccessory;
    final hasInfo = infoCard != null;
    final hasTray = trayAccessory != null;

    // ── 方案 C：KOS iconSize 反解（dock/AdaptiveMath.mjs:62-166 移植，
    //    DockMetrics.fromWidth 逐项对应）──
    // 可用宽 = 条带宽（KOS `availableLength`；本端无动态 accessory 预留，
    // DockContainer.qml:170 的 `max(baseHeight, availableLength −
    // estimatedAccessoryWidth)` 只剩下限保护——fromWidth 内部
    // maxWidth=width×0.98 已覆盖极窄输出）。cap 上限与 KOS 一致走
    // `maxLengthRatio = 0.98`（AdaptiveMath.mjs:29-30）。
    final stripWidth = MediaQuery.sizeOf(context).width;
    final metrics = DockMetrics.fromWidth(
      stripWidth,
      pinnedCount: pinnedCount,
      runningCount: runningCount,
      showLauncher: showLauncher,
      showTrash: showTrash,
      hasInfo: hasInfo,
      hasTray: hasTray,
    );

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
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: metrics.edgeMargin),
        child: ShellBackdropBlur(
        blur: theme.backdropBlurEnabled,
        // 前景不进 filter 层：glass 模式的 refraction/edge 光效不污染内容。
        separateChild: true,
        opacity: opacity,
        borderRadius: borderRadius,
        child: ShellInputRegion(
          debugLabel: 'KOS Dock pill',
          // 矩形输入区罩住整个 pill；KOS squircle 输入形状以更紧的非矩形
          // 区近似为矩形（偏差记 docs/visual-deltas.md）。
          child: SizedBox(
            width: metrics.dockWidth,
            height: metrics.dockHeight,
            // DecoratedBox 画在 tight SizedBox 内侧——若用带 border 的
            // Container，hairline 边宽会把内容区再内推 2px 造成 Row 溢出。
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: theme.panelGradient(
                  accent.cardFillTop(theme),
                  accent.cardFill(theme),
                ),
                // KOS: dock/DockDivider.qml:16 — divider 色走语义 hairline，
                // 不在此硬编码；hairline 边线给玻璃一个收敛边缘。
                border: Border.all(color: colors.hairlineSoft),
              ),
              child: MouseRegion(
                key: _pointerRegionKey,
                onHover: _broadcastPointer,
                onExit: (_) => _pointerX.value = null,
                child: MagnificationPointer(
                  pointerX: _pointerX,
                  child: DockMetricsScope(
                    metrics: metrics,
                    child: Padding(
                      // hpad = round(iconSize*0.4)，随 iconSize 反解
                      // （KOS: AdaptiveMath.mjs:12,143）。
                      padding: EdgeInsets.symmetric(
                        horizontal: metrics.hPadding,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        // 每个槽位固定 key（见上方注释）：槽位显隐变化时按
                        // key 匹配 Element，避免后一位子树被重建（入场动画
                        // 重播 / 状态丢失）。
                        children: [
                          // KOS: dock/DockContainer.qml:496-962 Row 顺序：
                          // launcher → trash → pinned段 → divider1 → 运行段 →
                          // divider2 → info → divider3 → trailingAccessory。
                          // divider1(launchers|windows) 与运行段都在图标区
                          // 内部（DockIconRow 的 rowChildren），此处只见
                          // `dock.pinned` 一个图标区槽位。
                          if (showLauncher)
                            LauncherIcon(
                              key: const ValueKey<String>('dock.launcher'),
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
                          // 图标区槽位取反解后的自然宽（方案 C 起恒 ≤
                          // 预算，不再 clamp/滚动）：n*(slot+spacing)−spacing
                          // + （两段都非空时 +divider1 槽宽）——与
                          // `DockMetrics.fromWidth` 的 iconUnits/divider
                          // 计数同式；DockIconRow 内部 Center 撑满约束。
                          SizedBox(
                            key: const ValueKey<String>('dock.pinned'),
                            width: _iconRowWidth(
                              metrics,
                              entryCount: entryCount,
                              divider1: DockMetrics.divider1Visible(
                                pinnedCount: pinnedCount,
                                runningCount: runningCount,
                              ),
                            ),
                            child: DockIconRow(
                              monitorId: widget.monitorId,
                              services: widget.services,
                              coordinator: _popups,
                            ),
                          ),
                          if (divider2)
                            const DockDivider(
                              key: ValueKey<String>('dock.divider.info'),
                            ),
                          if (hasInfo)
                            KeyedSubtree(
                              key: const ValueKey<String>('dock.infoCard'),
                              child: infoCard,
                            ),
                          if (divider3)
                            const DockDivider(
                              key: ValueKey<String>('dock.divider.tray'),
                            ),
                          if (hasTray)
                            KeyedSubtree(
                              key: const ValueKey<String>('dock.tray'),
                              child: trayAccessory,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  /// 图标区自然宽 = `n*(slot+spacing) − spacing` + divider1 槽位。
  ///
  /// 与 `DockMetrics.fromWidth` 的 iconUnits/divider 计数同式（pinned 段 +
  /// 运行段 + 段间 divider1，KOS DockContainer.qml:847-862）；反解后恒 ≤
  /// dockWidth 扣掉固定槽位后的部分——方案 A/B 的「图标区预算 clamp +
  /// 滚动兜底」随方案 C 移除。
  static double _iconRowWidth(
    DockMetrics metrics, {
    required int entryCount,
    required bool divider1,
  }) =>
      entryCount <= 0
          ? 0.0
          : entryCount * (metrics.iconSlotSize + metrics.itemSpacing) -
              metrics.itemSpacing +
              (divider1 ? metrics.dividerSlotWidth : 0.0);
}
