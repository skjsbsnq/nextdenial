@Plugin()
library;

import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/widgets/dock_host.dart';
import 'src/widgets/dock_surface.dart';

/// KOS Dock 悬浮坞表面（`ShellSurface`）。
///
/// 移植自 quickshell 的 Dock（几何参数 DockSurface.qml:64-121）：
///
/// - `layer: aboveWindows`：dock 是**浮在应用窗口之上**的托盘（源端 Dock 面板
///   位于 overlay/top 层）。taskbar 用 `desktopControls` 是因为它通过
///   `TaskbarWorkArea`（`denial_taskbar/lib/denial_taskbar.dart:49-60`）独占
///   bottom 工作区预留、窗口永远不覆盖它；dock **不预留工作区**
///   （`occupiesDesktop:false`），留在 `desktopControls` 会被普通窗口盖住
///   （surfaces.dart:24-25 vs :27-28），故取 `aboveWindows`；
/// - `place()`：`edgeBounds` 吸**整屏**底边（最大化窗口用不到工作区以下的
///   预留条带，dock 正好占用那段空隙），`thickness = edgeOffset(8) +
///   restingThickness(iconSize+13)`（DockSurface.qml:65,121 —— `exclusiveZone
///   = restingThickness + edgeOffset` :621 的对等式；玻璃内边距源端 22，Denial
///   收窄到 13 = 顶隙 4 + 底距 9，见 visual-deltas.md）；对全部输出返回非
///   null（源端 DockHost.qml:9-16 每屏一 surface）；`visible` 门控对齐
///   taskbar（`denial_taskbar.dart:32-38`）；
/// - `build()`：返回接线宿主 `DockHost`（dock.json 配置 + 宿主应用/窗口投影
///   → `DockSurface`，内部包 `ShellServicesScope`/`Localizations.override`/
///   `Theme`，taskbar 范式）。
///
/// 预览卡/右键菜单走 `OverlayPortal`（同 taskbar），故本插件只声明一个
/// `ShellSurface`（`provides.count: 1`）。
@Provides(ShellSurface)
final class KosDockPlugin implements ShellSurface {
  const KosDockPlugin();

  @override
  String get id => 'kos_dock.dock';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.aboveWindows;

  /// Resting icon edge. 源端 `DockModel.js:7` 默认 48（clamp 32–80 :37），
  /// Denial 侧默认 **36**（用户目检决定）：宿主常见 1.25–1.5 缩放下 48 逻辑
  /// 像素的坞偏大、会盖住最大化窗口底部更多内容。记 `docs/visual-deltas.md`。
  static const double iconSize = 36;

  /// 吸底条带厚度 = `edgeOffset + restingThickness`
  /// （DockSurface.qml:65,121,621）：`8 + (iconSize + kDockGlassPadding)`，
  /// 默认 `8 + (36 + 13) = 57`（玻璃内边距源端 22，Denial 收窄到 13 =
  /// 顶隙 4 + 底距 9：底距加宽以给图标下方让出指示条车道，见
  /// `docs/visual-deltas.md`）。thickness 只按 resting 几何，不含放大余量——
  /// 放大绘制靠溢出 bounds（卡片 §1）。
  static double get thickness => dockSurfaceThickness(iconSize);

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    // 每个输出一个 dock 实例（DockHost.qml:9-16 Variants 每屏一 surface；
    // 模型不按屏过滤）。edgeBounds 对非有限或空 rect 抛 ArgumentError
    // （surfaces.dart:146-152），isEmpty 拦不住 ±inf/NaN，须先查 isFinite。
    final output = environment.output.logicalRect;
    if (!output.isFinite || output.isEmpty) return null;
    return ShellSurfacePlacement(
      fade: ShellSurfaceFade.custom, // taskbar denial_taskbar.dart:26
      // 吸附**整屏底边**（不是可用区底边）：最大化窗口只用到工作区，底部
      // 预留条带是它没占用的空隙，dock 正好落在那里（用户目检要求）。
      // `ShellWorkArea` 是 zeroOrOne 契约（surfaces.dart:229-235），dock 不能
      // 自己预留该条带，只能占用它。
      bounds: ShellSurfacePlacement.edgeBounds(
        output,
        PanelEdge.bottom,
        thickness,
      ),
      // taskbar 同款门控（denial_taskbar.dart:32-38）。
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
      DockHost(
        services: surface.services,
        monitorId: surface.environment.output.monitorId,
        iconSize: iconSize,
        statusBarBuilder: (context) => buildDockStatusBar(
          context,
          monitorId: surface.environment.output.monitorId,
        ),
      );
}

/// Dock 底条工作区预留（`ShellWorkArea`，zeroOrOne）。
///
/// 合并顶栏后底条承载 dock 图标 + 工作区胶囊 + 状态簇，必须让最大化窗口
/// 避开整段底条（用户诉求「最大化空出底部 dock」）。照抄官方
/// `TaskbarWorkArea`/`TopBarWorkArea` 模式：bottom 边、厚度 =
/// `KosDockPlugin.thickness`（resting 条带高，放大镜 head-room 溢出 bounds
/// 绘制不占工作区）。`systemBarSide` 语义不适用于 dock（dock 固定 bottom），
/// 永远返回非 null——dock 关掉=插件禁用，而非 side==hidden。
@Provides(ShellWorkArea)
final class KosDockWorkArea implements ShellWorkArea {
  const KosDockWorkArea();

  @override
  ShellWorkAreaReservation? reserve(ShellLayoutSettings settings) =>
      ShellWorkAreaReservation(
        edge: PanelEdge.bottom,
        thickness: KosDockPlugin.thickness,
      );
}
