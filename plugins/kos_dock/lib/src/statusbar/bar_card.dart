import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';

/// 悬浮毛玻璃胶囊卡片——每个顶栏模块的外壳。
///
/// 复刻官方 `_SystemBarCard`（denial_top_bar
/// `desktop_system_bar_components.dart:265-320`）的结构与参数，但视觉走
/// dock/deskcenter 的平填链（CONSTRAINTS.md §4 / ROADMAP 决策 6）：
///
/// - `ShellBackdropBlur(separateChild: true)`：前景内容不进 backdrop
///   filter 层（desk_card.dart 注释：液态玻璃 refraction/edge 光效不污染
///   内容）。`separateChild` 要求 `blendMode == src`（SDK assert），因此
///   不传官方卡的 `blendMode: srcOver`；
/// - 填充 `theme.cardColor(colors.surfaceContainer)` 平填——glass 模式
///   `cardColor` 自动换 `_glassBacking` × `effectiveCardOpacity`，不用
///   `WallpaperAccent` 渐变；
/// - 边框常态 `outlineVariant @ 0.65`，`focused` 换 `accent @ 0.78`
///   （官方卡 focused 语义）；
/// - `highlighted` 时填充向 `theme.accent` lerp 0.12；
/// - `AnimatedContainer` 以 `Motion.wallpaperReveal`/`Motion.standard`
///   过渡换肤，与壁纸揭示同节奏（官方同参数）。
class TopBarCard extends StatelessWidget {
  const TopBarCard({
    required this.child,
    this.highlighted = false,
    this.focused = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.bare = false,
    super.key,
  });

  /// 卡片内容（文本/图标行），由模块方提供。
  final Widget child;

  /// 悬停/按压高亮：填充向 accent lerp 0.12。
  final bool highlighted;

  /// 焦点态：边框换 accent @ 0.78。
  final bool focused;

  /// 内容内边距，默认 `horizontal: 12`（官方同默认；工作区胶囊等模块
  /// 可覆盖为 `horizontal: 4`/`all: 4`）。
  final EdgeInsetsGeometry padding;

  /// 裸排模式（kos_dock 整条玻璃）：true 时跳过 blur/填充/边框，只渲染
  /// `padding + child`——模块共享外层 `_DockStripGlass` 整根玻璃条，不再
  /// 各自浮空胶囊（用户要求「连成一条」）。hover/focus 高亮改由模块自身
  /// InkWell 圆角承担（无独立底板）。false 保持原悬浮胶囊行为。
  final bool bare;

  @override
  Widget build(BuildContext context) {
    if (bare) {
      return Padding(padding: padding, child: child);
    }
    final theme = context.shellTheme;
    final colors = Theme.of(context).colorScheme;
    final radius = theme.borderRadius(999);
    final fill = theme.cardColor(colors.surfaceContainer);
    return ShellBackdropBlur(
      // 条带整体透明度随 surface 显隐动画（dock_surface.dart:766 同款）。
      opacity: ShellSurfacePresentation.opacityOf(context),
      // blur/glass 模式开模糊；off 模式退化为不透明平填。
      blur: theme.backdropBlurEnabled,
      separateChild: true,
      borderRadius: radius,
      child: AnimatedContainer(
        duration: Motion.wallpaperReveal,
        curve: Motion.standard,
        padding: padding,
        decoration: BoxDecoration(
          color: highlighted ? Color.lerp(fill, theme.accent, 0.12) : fill,
          borderRadius: radius,
          border: Border.all(
            color: focused
                ? theme.accent.withValues(alpha: 0.78)
                : colors.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
