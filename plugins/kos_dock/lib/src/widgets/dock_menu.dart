/// KOS Dock 共享自绘右键菜单（TASK-03 从 `dock_preview_popup.dart` 提取，
/// TASK-04 launcher/trash 复用同一玻璃菜单与浮层骨架）。
///
/// KOS 侧三类 shell 控件（Dock app / launcher / trash）都走同一
/// 「self-drawn liquid-glass ContextMenu」（DockContainer.qml:371-376,
/// 404-410 注释），因此移植版把菜单面板/菜单项/浮层几何提取成公共件：
/// - [DockMenuPanel]/[DockMenuItem]：玻璃面板 + 菜单行；
/// - [DockMenuOverlay]：OverlayPortal 内的 fullScene 输入区 + 点外即关 +
///   Esc + 150ms OutCubic 开 / 140ms InCubic 关 + scale 0.96→1 + ~20px
///   位移 + 屏内 clamp（ACCEPTANCE 菜单条款；
///   taskbar `window_buttons.dart:629-758` 几何范式）。
///
/// TASK-03 行为/数值在提取时逐字保留：`dock_preview_popup.dart` 只改
/// 调用点，回归由 `test/dock_preview_test.dart` 覆盖。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/dock_tokens.dart';

/// 菜单项模型（label + 图标 + 动作；null onTap = 禁用）。
class DockMenuItem {
  const DockMenuItem({required this.label, required this.icon, this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
}

/// 右键菜单面板：ShellBackdropBlur 玻璃；150ms OutCubic 开 / 140ms
/// InCubic 关 + scale 0.96→1 + 20px 位移由调用方动画驱动
/// （ACCEPTANCE 菜单条款；变换见 [DockMenuOverlay]）。
///
/// [progress]（0..1 显隐进度）只作用于**前景**（渐变+边框+菜单行），
/// `ShellBackdropBlur` 的 backdrop 层从第一帧就满强度——外层 Opacity 套
/// 整只面板会把模糊层一起淡化（模糊采样的是半透明桌面，出现「先透明
/// 再模糊」的延迟观感），故淡入移到面板内部、backdrop 不吃进度。
class DockMenuPanel extends StatelessWidget {
  const DockMenuPanel({
    required this.items,
    this.progress = 1.0,
    super.key,
  });

  final List<DockMenuItem> items;

  /// 显隐进度（0=全隐，1=完全展开）；默认 1（无淡入，如直接挂载/测试）。
  final double progress;
  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    const radius = BorderRadius.all(Radius.circular(kDockMenuRadius));
    return ShellBackdropBlur(
      blur: theme.backdropBlurEnabled,
      separateChild: true,
      borderRadius: radius,
      // backdrop 层不吃 [progress]——模糊从第一帧就满强度；Opacity 只套前景
      // （渐变+边框+菜单行），避免「先透明再模糊」。
      child: Opacity(
        opacity: progress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: theme.panelGradient(
              colors.panelBackground,
              colors.panelBackgroundBottom,
            ),
            border: Border.all(color: colors.hairlineSoft),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(kDockMenuPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final item in items) _DockMenuRow(item: item)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单浮层骨架：OverlayPortal 的 overlayChild 内容。
///
/// 由调用方持有 `OverlayPortalController` 与 `progress`（0=隐藏/关闭中、
/// 1=完全展开），本件只负责：
/// - fullScene `ShellInputRegion` + 透明 barrier（点外即关）；
/// - Esc 关闭（keyboardPolicy capture）；
/// - 面板底边贴 anchor 顶部 −6px（`kDockPreviewGap`，KOS
///   DockWindowPreview.qml:175-180 的 anchor margin）并做屏内 clamp；
/// - 入场/退场变换：translate (1−v)·20px、scale 0.96+(1−0.96)·v、opacity v
///   （150ms OutCubic / 140ms InCubic 由调用方动画驱动）。
///
/// [anchor]/[output] 为 overlay 坐标系矩形（output 已与 overlay 求交），
/// [overlaySize] 用于把面板底边锚到 anchor 上方。
class DockMenuOverlay extends StatelessWidget {
  const DockMenuOverlay({
    required this.anchor,
    required this.output,
    required this.overlaySize,
    required this.progress,
    required this.items,
    required this.onDismiss,
    this.debugLabel = 'Dock context menu',
    super.key,
  });

  /// 菜单锚点矩形（通常是被右键的图标槽位，overlay 坐标系）。
  final Rect anchor;

  /// 屏内矩形（clamp 边界，overlay 坐标系）。
  final Rect output;

  /// overlay 尺寸（用于 bottom 定位）。
  final Size overlaySize;

  /// 0..1 显隐进度（调用方 AnimationController）。
  final Animation<double> progress;

  final List<DockMenuItem> items;

  /// 点外/Esc 关闭回调（调用方播放 140ms 退场后收 portal）。
  final VoidCallback onDismiss;

  final String debugLabel;

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.max(
      0.0,
      anchor.top - output.top - kDockPopupEdgeMargin - kDockPreviewGap,
    );
    if (maxHeight <= 0) return const SizedBox.shrink();
    const width = kDockMenuMinWidth;
    final left = (anchor.center.dx - width / 2).clamp(
      output.left + kDockPopupEdgeMargin,
      math.max(
        output.left + kDockPopupEdgeMargin,
        output.right - kDockPopupEdgeMargin - width,
      ),
    );
    return ShellInputRegion(
      debugLabel: debugLabel,
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // 点外即关（taskbar `_buildMenu` barrier 范式）。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => onDismiss(),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                // 菜单底边贴图标顶 −gap（taskbar `_buildMenu`
                // `bottom: overlayHeight − anchor.top + 8` 范式）。
                bottom:
                    overlaySize.height - anchor.top + kDockPreviewGap,
                width: width,
                child: AnimatedBuilder(
                  animation: progress,
                  builder: (context, _) {
                    final v = progress.value;
                    // ACCEPTANCE 菜单条款：scale 0.96→1 + ~20px 位移
                    // （底锚向上长）；开 150ms OutCubic / 关 140ms
                    // InCubic 由调用方动画驱动。
                    // opacity 不套整只面板——backdrop 模糊会随透明度弱化
                    // （「先透明再模糊」）；淡入改由 DockMenuPanel 内部
                    // 只作用于前景（backdrop 第一帧即满强度）。
                    return Transform.translate(
                      offset: Offset(0, (1 - v) * kDockMenuEnterOffset),
                      child: Transform.scale(
                        scale:
                            kDockMenuEnterScale +
                            (1 - kDockMenuEnterScale) * v,
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxHeight),
                          child: DockMenuPanel(items: items, progress: v),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 菜单行：hover textPrimary@0.08、禁用 textTertiary、32px 高。
class _DockMenuRow extends StatefulWidget {
  const _DockMenuRow({required this.item});

  final DockMenuItem item;

  @override
  State<_DockMenuRow> createState() => _DockMenuRowState();
}

class _DockMenuRowState extends State<_DockMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final enabled = widget.item.onTap != null;
    final fg = enabled ? colors.textPrimary : colors.textTertiary;
    return MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.item.onTap,
        child: Container(
          height: kDockMenuItemHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: kDockMenuItemHPadding,
          ),
          decoration: BoxDecoration(
            // Denial-invented: 行圆角/行高/hover alpha 见
            // `kDockMenuItemRadius`/`kDockMenuItemHoverAlpha`。
            borderRadius: BorderRadius.circular(kDockMenuItemRadius),
            color: _hovered && enabled
                ? colors.textPrimary.withValues(
                    alpha: kDockMenuItemHoverAlpha,
                  )
                : Colors.transparent,
          ),
          child: Row(
            children: [
              // Denial-invented: `kDockMenuItemIconSize`（无 KOS 对应值）。
              Icon(widget.item.icon, size: kDockMenuItemIconSize, color: fg),
              const SizedBox(width: kDockMenuItemIconGap),
              Expanded(
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Denial-invented: `kDockMenuItemFontSize`（同上）。
                  style: TextStyle(fontSize: kDockMenuItemFontSize, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
