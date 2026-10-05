/// KOS Dock 信息卡详情 popup（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/dock/DockInfoPopup.qml`（222 行，行号
/// 在各段标注）：288 宽、`rowCount*26 + 62` 高、radius 18、padding 16/12、
/// spacing 6、标题 14px DemiBold + 分隔线 + 行 `label 12px@0.62 / value
/// 13px DemiBold`；锚 carousel 槽顶 −12px。
///
/// 与 KOS 的偏差（记 docs/visual-deltas.md）：
/// - KOS 只服务 clock/weather 页（music 走 DockMusicPopup、metrics 走
///   TemperatureSensorPopups，DockInfoCarousel.qml:253-277）；本端四页统一
///   走本面板（无那两个组件）；
/// - `LiquidGlassPanel`（:129-138）→ `ShellBackdropBlur` + `panelGradient` +
///   hairlineSoft 边；
/// - popup 开/关动画沿用 ACCEPTANCE 菜单条款（150ms OutCubic / 140ms
///   InCubic + scale 0.96→1 + 20px 位移，`DockMenuOverlay` 同式）；
/// - `AnimatedPopupWindow` 独立 surface → `OverlayPortal`（同 preview 范式）。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/dock_tokens.dart';

/// DockInfoPopup 的一行键值对（KOS `detailRows()` 的 `{label, value}`，
/// DockInfoPopup.qml:77-120）。
final class DockInfoRow {
  const DockInfoRow({required this.label, required this.value});

  final String label;
  final String value;
}

/// 详情面板内容模型（KOS `rows`/`title` 投影）。
final class DockInfoContent {
  const DockInfoContent({required this.title, required this.rows, this.scope});

  /// 标题（KOS `title`：时钟/天气/资源占用；DockInfoPopup.qml:53-61）。
  final String title;

  /// 标题右侧 scope 文本（仅天气页显示 cityName，:163-174；其它页 null）。
  final String? scope;

  final List<DockInfoRow> rows;

  /// KOS 高度公式：`rowCount*26 + 62`（DockInfoPopup.qml:28）。
  static double heightFor(int rowCount) =>
      rowCount <= 0 ? 1 : rowCount * kDockInfoPopupRowHeight + kDockInfoPopupBaseHeight;
}

/// 信息卡详情面板（玻璃，radius 18）：标题行 + 分隔线 + 键值行。
/// 视觉对齐 `DockMenuPanel` 的 panelGradient + hairlineSoft + BackdropBlur
/// 三段式（dock_menu.dart:49-74 同构）。
class DockInfoPanel extends StatelessWidget {
  const DockInfoPanel({required this.content, super.key});

  final DockInfoContent content;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    const radius = BorderRadius.all(
      Radius.circular(kDockInfoPopupRadius),
    ); // KOS: DockInfoPopup.qml:132 `radius: 18`
    return ShellBackdropBlur(
      blur: theme.backdropBlurEnabled,
      separateChild: true,
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: theme.panelGradient(
            colors.panelBackground,
            colors.panelBackgroundBottom,
          ),
          border: Border.all(color: colors.hairlineSoft),
        ),
        child: SizedBox(
          width: kDockInfoPopupWidth, // KOS: :27 `implicitWidth: 288`
          height: DockInfoContent.heightFor(content.rows.length),
          child: Padding(
            // KOS: :140-147 anchors 四边 margin 16/16/12/12。
            padding: const EdgeInsets.fromLTRB(
              kDockInfoPopupPaddingH,
              kDockInfoPopupPaddingV,
              kDockInfoPopupPaddingH,
              kDockInfoPopupPaddingV,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      content.title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        // KOS: :154-161 14px DemiBold。
                        fontSize: kDockInfoPopupTitleSize,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                    if (content.scope != null) ...[
                      const SizedBox(width: 8), // KOS: :152 `spacing: 8`
                      Text(
                        content.scope!,
                        style: TextStyle(
                          // KOS: :163-173 opacity 0.62、11px Medium。
                          color: colors.textPrimary.withValues(
                            alpha: kDockInfoPopupLabelAlpha,
                          ),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          height: 1.0,
                        ),
                      ),
                    ],
                  ],
                ),
                // KOS: :148 — 标题块与分隔线的间距走 Column spacing 6。
                const SizedBox(height: kDockInfoPopupRowSpacing),
                Container(
                  height: 1,
                  // KOS: :178-183 `foregroundColor` opacity 0.12。
                  color: colors.textPrimary.withValues(alpha: 0.12),
                ),
                const SizedBox(height: kDockInfoPopupRowSpacing),
                for (final row in content.rows)
                  SizedBox(
                    // KOS: :191 `Layout.preferredHeight: 20`（行高 26 =
                    // 20 + spacing 6 由 SizedBox+padding 等效——此处直接
                    // 26 行高记 deltas）。
                    height: kDockInfoPopupRowHeight,
                    child: Row(
                      children: [
                        Text(
                          row.label,
                          style: TextStyle(
                            color: colors.textPrimary.withValues(
                              alpha: kDockInfoPopupLabelAlpha,
                            ), // KOS: :194-202 12px@0.62
                            fontSize: kDockInfoPopupLabelSize,
                            fontWeight: FontWeight.w500,
                            height: 1.0,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          row.value,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: kDockInfoPopupValueSize, // KOS: :205-212
                            fontWeight: FontWeight.w600,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情浮层骨架：`OverlayPortal.overlayChild` 内容（`DockMenuOverlay`
/// 同构，dock_menu.dart:91-194）：fullScene 输入区 + 点外即关 + Esc +
/// 面板底边贴 anchor 顶 −`kDockInfoPopupGap`(12px，KOS
/// DockInfoPopup.qml:34-39 `anchor.margins.top: -12`)
/// + 屏内 clamp + 150/140ms + scale 0.96→1 + 20px 位移（ACCEPTANCE
/// popup 条款，调用方驱动 progress）。
class DockInfoOverlay extends StatelessWidget {
  const DockInfoOverlay({
    required this.anchor,
    required this.output,
    required this.overlaySize,
    required this.progress,
    required this.content,
    required this.onDismiss,
    this.onPointerInsideChanged,
    this.debugLabel = 'Dock info popup',
    super.key,
  });

  /// 锚点矩形（carousel 槽位，overlay 坐标系）。
  final Rect anchor;

  /// 屏内矩形（clamp 边界，overlay 坐标系）。
  final Rect output;

  /// overlay 尺寸（bottom 定位用）。
  final Size overlaySize;

  /// 0..1 显隐进度（调用方 AnimationController）。
  final Animation<double> progress;

  final DockInfoContent content;

  /// 点外/Esc 关闭回调（KOS `requestClose`）。
  final VoidCallback onDismiss;

  /// KOS `pointerInside`（DockInfoPopup.qml:22,219-221）：popup 内 hover
  /// 状态回传，供 carousel 的 closeDelay 桥接。
  final ValueChanged<bool>? onPointerInsideChanged;

  final String debugLabel;

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.max(
      0.0,
      anchor.top - output.top - kDockPopupEdgeMargin - kDockInfoPopupGap,
    );
    if (maxHeight <= 0) return const SizedBox.shrink();
    const width = kDockInfoPopupWidth;
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
              // 点外即关（dock_menu.dart:150-155 同式）。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => onDismiss(),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                // KOS: popup.bottom = anchor.top − 12
                // （DockInfoPopup.qml:34-39 `anchor.margins.top: -12`；
                // DockMenuOverlay bottom 定位同式）。
                bottom: overlaySize.height - anchor.top + kDockInfoPopupGap,
                width: width,
                child: MouseRegion(
                  onEnter: (_) => onPointerInsideChanged?.call(true),
                  onExit: (_) => onPointerInsideChanged?.call(false),
                  child: AnimatedBuilder(
                    animation: progress,
                    builder: (context, child) {
                      final v = progress.value;
                      // ACCEPTANCE popup 条款：scale 0.96→1 + ~20px
                      // 位移（底锚向上长，KOS motionOrigin: Item.Bottom
                      // DockInfoPopup.qml:24）。
                      return Transform.translate(
                        offset: Offset(0, (1 - v) * kDockMenuEnterOffset),
                        child: Transform.scale(
                          scale:
                              kDockMenuEnterScale +
                              (1 - kDockMenuEnterScale) * v,
                          alignment: Alignment.bottomCenter,
                          child: Opacity(opacity: v, child: child),
                        ),
                      );
                    },
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxHeight),
                      child: DockInfoPanel(content: content),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
