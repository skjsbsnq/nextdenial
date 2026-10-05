@Plugin()
library;

import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/theme/dock_tokens.dart' show DockMetrics, DockMetricsScope, kDockBaseHeight;
import 'src/widgets/dock_shell.dart';
import 'src/widgets/info_carousel.dart';

/// KOS Dock 表面（`ShellSurface`）：macOS-style 融合 Dock 容器（TASK-02）。
///
/// 布局对齐 NextKde `DockWindow.qml`（行号锚定
/// `/home/wwt/文档/NextKde/shell/desktop/modules/dock/`）：
/// - `layer: aboveWindows`：源 `WlrLayershell.layer: WlrLayer.Top`
///   （DockWindow.qml:32-34；fullscreen launcher 打开时升 Overlay 的特例
///   不在 Denial 层模型内，按常态 Top 映射）。dock 要浮在应用窗口之上，
///   `desktopControls` 会被普通窗口盖住（surfaces.dart:20-29）；
/// - `place()`：源 `DockHost` 每屏一个 PanelWindow——dock 绑定输出，故对
///   每个输出返回非 null，不做 isMainOutput 门控；bounds 为贴底边条带，
///   厚度 = dockHeight + edgeMargin + workspaceMargin（源
///   DockWindow.qml:93 `height: dockContainer.height + root.edgeMargin +
///   root.workspaceMargin`），edgeMargin/workspaceMargin 均取
///   `max(4, round(dockHeight*0.12))`（floating 模式，:63-64,:68-69）。
///   **pill 本体不贴屏幕底边**：条带底边仍是屏幕底边，pill 由
///   `dock_shell.dart` 的 `Align.bottomCenter` + 底部 [edgeMargin] 内边距
///   内缩——源 DockWindow.qml:177 `y: root.height - root.edgeMargin -
///   dockContainer.height`（回归见 `dock_container_test.dart` 的 pill 内缩
///   用例）；
/// - `occupiesDesktop: false`：源 `exclusionMode: Normal`（:27）保留的是
///   最大化的**工作区**（下方 [KosDockWorkArea] 负责预留），与「最小化窗口
///   预览不进条带」无关——SDK 语义见 surfaces.dart:137-138；
/// - `visible`：锁屏 / 壁纸选择器 / 全屏时隐藏，其余场景恒可见
///   （CONSTRAINTS §1：不启用 auto-hide/reveal handle/exclusiveZone）。
///   全屏门控是 compositor 层级语义：KOS dock 在 `WlrLayer.Top`
///   （DockWindow.qml:32-34）被全屏窗口盖住，DockAutoHideController 只在
///   mode!=="always" 才做显隐动画（DockAutoHideController.qml:50,254），
///   恒可见模式靠层级遮挡；Denial 无此遮挡，由本 surface 按
///   `environment.fullscreen` 降 visible。例外：overview 打开或
///   desktopVisible 时仍显示（KOS overview 里 dock 可用）。
@Provides(ShellSurface)
final class KosDockPlugin implements ShellSurface {
  const KosDockPlugin();

  @override
  String get id => 'kos_dock.dock';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.aboveWindows;

  /// 当前基准 dock 厚度（KOS `ConfigService.baseHeight` 默认 60，
  /// KOS: dock/DockConfigService.qml:37）。
  static const double dockHeight = kDockBaseHeight;

  /// 契约层条带厚度：由 [DockMetrics] 在基准配置下按输出宽反解。
  ///
  /// 方案 C（TASK-04b §6）：pill 高不再是常量——KOS `exclusiveZone =
  /// dockContainer.height + edgeMargin + workspaceMargin`（dock/
  /// DockWindow.qml:118-127）三项都绑运行时 dockContainer.height；本端
  /// 对应 `DockMetrics.stripThickness`。`place()`/`reserve()` 在插件装载
  /// 契约层，拿不到 `dockPreferencesProvider` 的会话态（place() 是环境的
  /// 纯函数，SDK 契约见 kos_deskcenter.dart:208 同式说明），故按**基准
  /// 配置**（launcher+trash 默认开、无运行窗、无 info/tray）对输出宽反解
  /// ——KOS 同构：DockWindow 的厚度同样由当帧 dock 内容决定，prefs 关闭
  /// launcher/trash 时条带只少 ~10px 高度差（见 dock_shell.dart 的
  /// 说明与 docs/visual-deltas.md）。
  ///
  /// 注意 KOS `availableLength` 传 `max(baseHeight, …)`（DockContainer.
  /// qml:130-137,167-170）；`DockMetrics.fromWidth` 内部已把
  /// `maxWidth = availableLength*0.98` 应用到极窄输出（MIN_ICON_SIZE=18
  /// 下限 → dockHeight≈25、edgeMargin=4、条带≈33，厚度仍正）。
  static double thicknessForWidth(double outputWidth) =>
      DockMetrics.fromWidth(outputWidth).stripThickness;

  /// 基准输出宽（1920 逻辑 px）下的条带厚度；`ShellWorkArea.reserve()` 的
  /// settings 不携带输出几何，按最大常规输出取上界（更宽的预留 = 更大
  /// 安全边际，真实条带厚度由 place() 的 [thicknessForWidth] 给）。
  ///
  /// KOS: dock/DockWindow.qml:92-93,124-127。
  static double get thickness => thicknessForWidth(1920);

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    return ShellSurfacePlacement(
      // `ShellBackdropBlur(separateChild: true)`（dock_shell.dart），SDK 不再
      // 对子树叠整体 FadeTransition——否则 opacity 被平方（SDK 契约见
      // PLUGIN_DEVELOPMENT.md；惯例对照 denial_taskbar.dart）。
      fade: ShellSurfaceFade.custom,
      // 条带底边 = 屏幕底边；pill 本体再由 `dock_shell.dart` 内缩
      // [edgeMargin]（源 DockWindow.qml:177），故不等价于 pill 贴底。
      bounds: ShellSurfacePlacement.edgeBounds(
        // 用 `output.logicalRect` 而非 `workArea`：dock 锚物理输出底边
        // （KOS DockWindow 锚 screen 底缘）；workArea 已扣预留条带，
        // 会把 dock 推上去错位。条带厚度按本输出宽反解（方案 C：
        // `DockMetrics.stripThickness`，KOS DockWindow.qml:92-93 的
        // `dockContainer.height + edgeMargin + workspaceMargin`）。
        environment.output.logicalRect,
        PanelEdge.bottom,
        thicknessForWidth(environment.output.logicalRect.width),
      ),
      // 只表示「不在本条带内排最小化窗口预览」（SDK 语义
      // surfaces.dart:137-138）；最大化窗口的工作区预留由 [KosDockWorkArea]
      // 的 `ShellWorkArea` 负责，与 `place()` 无关。
      occupiesDesktop: false,
      // 锁屏 / 壁纸选择器时隐藏（SDK 语义：保留状态淡出 + 抑制输入，
      // surfaces.dart:134-135）；全屏窗口经 compositor 升到高于 dock 的
      // 层（KOS WlrLayer.Top 被盖，恒可见模式无显隐动画、靠层级遮挡，
      // DockAutoHideController.qml:50,254），Denial 侧由 surface 按
      // `environment.fullscreen` 降 visible——除非 overview 打开或
      // desktopVisible（KOS overview 里 dock 可用）。除此三者外恒可见：
      // CONSTRAINTS §1 不启用 auto-hide/reveal handle。
      visible:
          !environment.locked &&
          !environment.wallpaperSelectorVisible &&
          (!environment.fullscreen ||
              environment.overview ||
              environment.desktopVisible),
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      KosDockShell(
        services: surface.services,
        monitorId: surface.environment.output.monitorId,
        // TASK-04：launcher/trash 由 KosDockShell 内建（受 showLauncher/
        // showTrash 偏好控制），不再从表面透传占位。
        // TASK-05：info 槽挂 `DockInfoCarousel`（4 卡共享槽 + 30s 轮换）——
        // `KosDockShell` 构建时把全 pill 唯一的 `DockPopupCoordinator`
        // 注入（详情 popup 与图标预览/菜单共享单例语义）。carousel 内部
        // 从 `DockMetricsScope` 读反解几何（此处 build 拿不到 Inherited
        // 上下文）。tray 仍为占位槽（TASK-06 接线）。
        infoCard: (coordinator) => DockInfoCarousel(
          services: surface.services,
          monitorId: surface.environment.output.monitorId,
          coordinator: coordinator,
        ),
        trayAccessory: const _TraySlot(),
      );
}

/// 托盘占位槽：尺寸 = metrics 的 icon slot 方槽（方案 C 起随
/// `DockMetricsScope` 反解缩放；kos_dock.dart 的 build() 拿不到
/// InheritedWidget 上下文，故透传一个读 scope 的件）。info 槽 TASK-05 起
/// 由 `DockInfoCarousel` 填充，不再需要占位。
class _TraySlot extends StatelessWidget {
  const _TraySlot();

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    return SizedBox(
      width: metrics.iconSlotSize,
      height: metrics.iconSlotSize,
    );
  }
}

/// 底部工作区预留（`ShellWorkArea`）：最大化窗口停在 dock 之上，永不被 dock
/// 覆盖。
///
/// 用户决定（2026-10-04）**覆盖** CONSTRAINTS §2「dock 悬浮不挤压工作区」：
/// 最大化窗口要浮在 dock 之上、且不要顶部栏（见
/// `docs/dock-port/CONSTRAINTS.md` §2 修正条目）。本 shell 的工作区条带只有
/// `ShellWorkArea` 一个扩展点（`denial_desktop` 侧
/// `lib/src/core/shell_runtime_bindings.dart:131-142` 把预留结果交给
/// `applyShellConfiguration(side:, systemBarThickness:, maximizePadding:)`），
/// 参照 denial_taskbar 的 `TaskbarWorkArea`
/// （`denial_taskbar.dart:49-60`）。
///
/// 厚度来源 KOS `dock/DockWindow.qml:118-127`：dock 恒显示时
/// `exclusiveZone = dockContainer.height + edgeMargin + workspaceMargin`
/// （= [KosDockPlugin.thickness]），再加用户 `maximizePadding` 呼吸空间
/// （预留：最大化窗口与 dock 上缘之间不贴边）。
///
/// 与 taskbar 的**差异**：taskbar 在 `systemBarSide == hidden`（栏被用户隐藏）
/// 时返回 `null` 不留条带；KOS dock 恒可见（CONSTRAINTS §1 不启用
/// auto-hide/reveal handle），只要 dock 在就占位，故这里**无条件**返回预留，
/// 不看 `settings.systemBarSide`（`top`/`hidden` 都不影响 dock 是否可见）。
@Provides(ShellWorkArea)
final class KosDockWorkArea implements ShellWorkArea {
  const KosDockWorkArea();

  /// 预留厚度 = 条带厚度 + [ShellLayoutSettings.maximizePadding]（非有限或
  /// 负值按 0 计，避免 `ShellWorkAreaReservation` 抛参数错误）。
  static double reservationThickness(ShellLayoutSettings settings) {
    final padding = settings.maximizePadding;
    return KosDockPlugin.thickness +
        (padding.isFinite && padding > 0 ? padding : 0.0);
  }

  @override
  ShellWorkAreaReservation? reserve(ShellLayoutSettings settings) =>
      ShellWorkAreaReservation(
        edge: PanelEdge.bottom,
        thickness: reservationThickness(settings),
        outputNames: settings.systemBarOutputNames,
      );
}
