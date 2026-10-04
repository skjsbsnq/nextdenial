@Plugin()
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/theme/dock_tokens.dart';
import 'src/widgets/dock_view.dart';

/// KOS Dock 表面（`ShellSurface`）：macOS-style 融合 Dock 的骨架实现。
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
///   `max(4, round(dockHeight*0.12))`（floating 模式，:63-64,:68-69）；
/// - `occupiesDesktop: false`：源 `exclusionMode: Normal`（:27）为 dock
///   预留空间是 KOS 行为，但 Denial 移植约定 dock 悬浮不挤压工作区
///   （不实现 ShellWorkArea），仅不把最小化预览推进条带；
/// - `visible`：对齐 kos_deskcenter 惯例，锁屏/壁纸选择器时隐藏；
///   fullscreen/overview 不隐藏（macOS dock 全屏时仍可由 reveal 唤出，
///   自动隐藏本身不在本任务范围）。
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

  /// 玻璃与屏幕边的浮空距（KOS: dock/DockWindow.qml:63-64）。
  static int get edgeMargin => _floatMargin;

  /// pill 上缘与最大化窗口间的留白（KOS: dock/DockWindow.qml:68-69）。
  static int get workspaceMargin => _floatMargin;

  /// floating 模式浮空边距：`max(4, round(dockHeight*0.12))`。
  static int get _floatMargin => math.max(
    kDockMinEdgeMargin.toInt(),
    (dockHeight * kDockEdgeMarginRatio).round(),
  );

  /// 条带总厚度（KOS: dock/DockWindow.qml:93）。
  static double get thickness =>
      dockHeight + edgeMargin + workspaceMargin;

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    return ShellSurfacePlacement(
      // `custom`：插件自己把 `ShellSurfacePresentation.opacityOf` 喂给
      // `ShellBackdropBlur(separateChild: true)`（dock_view.dart），SDK 不再
      // 对子树叠整体 FadeTransition——否则 opacity 被平方（SDK 契约见
      // PLUGIN_DEVELOPMENT.md；惯例对照 denial_taskbar.dart）。
      fade: ShellSurfaceFade.custom,
      bounds: ShellSurfacePlacement.edgeBounds(
        // 用 `output.logicalRect` 而非 `workArea`：dock 锚物理输出底边
        // （KOS DockWindow 锚 screen 底缘）；workArea 已扣 top_bar 独占，
        // 会把 dock 推上去错位。
        environment.output.logicalRect,
        PanelEdge.bottom,
        thickness,
      ),
      // 悬浮 dock：不推开最小化窗口预览，不预留工作区。
      occupiesDesktop: false,
      // 锁屏与壁纸选择器时隐藏（SDK 语义：保留状态淡出 + 抑制输入，
      // surfaces.dart:134-135）。
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      const KosDockView();
}
