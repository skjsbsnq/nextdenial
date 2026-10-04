/// KOS Dock 占位 pill 视图（TASK-00 骨架）。
///
/// 业务内容（图标行、信息卡、托盘分隔等）归后续任务；这里只渲染
/// macOS floatingDock 形态的玻璃胶囊本体，验证 surface 接入与材质链。
///
/// 布局：surface bounds 已含 `edgeMargin + workspaceMargin`（见
/// `kos_dock.dart` 的 `place()`），pill 高 `kDockBaseHeight` 并由
/// `Align.bottomCenter` 贴到条带底部——对应 KOS 源里 `dockContainer` 在
/// `dockWrapper` 内 `edgeMargin` 内缩的排法（KOS:
/// dock/DockWindow.qml:177 `y: root.height - root.edgeMargin -
/// dockContainer.height`）。
library;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellTheme, ShellThemeBuildContext;
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:flutter/widgets.dart';

import '../theme/dock_tokens.dart';

/// Dock 占位 pill。主题/透明度全部接 `ShellTheme` 与
/// `ShellSurfacePresentation`，无硬编码颜色。
class KosDockView extends StatelessWidget {
  const KosDockView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    // surface 级可见性淡入淡出（锁屏/壁纸选择器时 SDK 动画驱动）。
    final opacity = ShellSurfacePresentation.opacityOf(context);
    // pill 高 = 当前 dock 高；TASK-01 换成 computedDockHeight 后半径自动跟随。
    const pillHeight = kDockBaseHeight;
    // KOS: dock/DockContainer.qml:195-196 `Math.round(computedDockHeight *
    // radiusRatio)`——半径绑运行时 dock 高（半径=高/2），非静态 baseHeight×0.5；
    // radiusRatio 0.50 见 common/AppearanceTokens.qml:413（半圆端帽）。
    final borderRadius = BorderRadius.circular(pillHeight / 2);

    // pill 贴条带底部：bounds 底部 edgeMargin 即玻璃与屏幕边的浮空。
    return Align(
      alignment: Alignment.bottomCenter,
      child: ShellBackdropBlur(
        blur: theme.backdropBlurEnabled,
        // 前景不进 filter 层：glass 模式的 refraction/edge 光效不污染内容。
        separateChild: true,
        opacity: opacity,
        borderRadius: borderRadius,
        child: Container(
          height: kDockBaseHeight,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            // 与 deskcenter 卡同一 cardColor 链：glass 模式取玻璃衬底，
            // blur/off 模式退化为 surfaceContainer。
            color: theme.cardColor(colors.surfaceContainer),
            // KOS: dock/DockDivider.qml:16 — divider 色走语义 hairline，
            // 不在此硬编码；hairline 边线给玻璃一个收敛边缘。
            border: Border.all(color: colors.hairlineSoft),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Center(
            child: Text(
              'KOS Dock',
              style: theme.text.base.copyWith(color: colors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
