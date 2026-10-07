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
/// - `AnimatedPopupWindow` 独立 surface → `OverlayPortal`（同 preview 范式）；
/// - 详情是 hover tooltip 非 modal 菜单：`DockInfoOverlay` 无 fullScene
///   输入区/点外即关/Esc/Focus 捕获（KOS `DockInfoPopup` 无 dismissal 通道，
///   收场全靠 `pointerInside` + `infoPopupCloseDelay`，
///   DockInfoPopup.qml:219-221 + DockInfoCarousel.qml:304-312）。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

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
  static double heightFor(int rowCount) => rowCount <= 0
      ? 1
      : rowCount * kDockInfoPopupRowHeight + kDockInfoPopupBaseHeight;
}

/// 信息卡详情面板（玻璃，radius 18）：标题行 + 分隔线 + 键值行。
/// 视觉对齐 `DockMenuPanel` 的 panelGradient + hairlineSoft + BackdropBlur
/// 三段式（dock_menu.dart:49-74 同构）。
class DockInfoPanel extends StatelessWidget {
  const DockInfoPanel({required this.content, this.progress = 1, super.key});

  final DockInfoContent content;

  /// Fade the foreground only; keep backdrop sampling at full strength.
  final double progress;

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
                              fontSize:
                                  kDockInfoPopupValueSize, // KOS: :205-212
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
      ),
    );
  }
}

/// 详情浮层：`OverlayPortal.overlayChild` 内容，对齐 preview 的 **hover
/// popup 范式**（`dock_preview_popup.dart` `_buildPreview` :601-669）——
/// 详情是 tooltip 不是 modal 菜单：
/// - `ShellInputRegion` 默认 `childBounds`（包在 popup 的 `Positioned`
///   内，输入区 = 面板+桥带矩形）；**不**用 fullScene/`ShellKeyboardPolicy.
///   capture`/`Focus(autofocus)`；
/// - 无点外即关层、无 Esc（KOS `DockInfoPopup` 也没有 dismissal 通道：全件
///   只靠 `pointerInside` HoverHandler 与 `infoPopupCloseDelay` 收场，
///   DockInfoPopup.qml:22,219-221 + DockInfoCarousel.qml:304-312）；
/// - 容器高度含 `kDockInfoPopupGap`(12px) 桥带：`Positioned` `top =
///   anchor.top - gap - panelHeight`、`height = panelHeight + gap`，
///   `MouseRegion` 整覆含底部桥带的整个 Positioned（桥接卡槽→popup 的
///   12px 真空，等价 KOS `pointerInside` 跨 surface 桥接），面板
///   `Align(topCenter)`；
/// - 面板底边贴 anchor 顶 −12px（`anchor.margins.top: -12`，
///   DockInfoPopup.qml:34-39）+ 屏内 clamp + 150/140ms + scale 0.96→1 +
///   20px 位移（ACCEPTANCE popup 条款，调用方驱动 progress）。
class DockInfoOverlay extends StatelessWidget {
  const DockInfoOverlay({
    required this.anchor,
    required this.output,
    required this.progress,
    required this.content,
    this.onPointerInsideChanged,
    this.debugLabel = 'Dock info popup',
    super.key,
  });

  /// 锚点矩形（carousel 槽位，overlay 坐标系）。
  final Rect anchor;

  /// 屏内矩形（clamp 边界，overlay 坐标系）。
  final Rect output;

  /// 0..1 显隐进度（调用方 AnimationController）。
  final Animation<double> progress;

  final DockInfoContent content;

  /// KOS `pointerInside`（DockInfoPopup.qml:22,219-221）：popup（含桥带）
  /// 内 hover 状态回传，供 carousel 的 closeDelay 桥接。
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
    const gap = kDockInfoPopupGap;
    // 面板内容高（rowCount*26+62，DockInfoPopup.qml:28）经 maxHeight clamp。
    final panelHeight = math.min(
      DockInfoContent.heightFor(content.rows.length),
      maxHeight,
    );
    final left = (anchor.center.dx - width / 2).clamp(
      output.left + kDockPopupEdgeMargin,
      math.max(
        output.left + kDockPopupEdgeMargin,
        output.right - kDockPopupEdgeMargin - width,
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: left.toDouble(),
          // KOS: popup.bottom = anchor.top − 12（`anchor.margins.top: -12`，
          // DockInfoPopup.qml:34-39）；容器高 = 面板 + gap 桥带，底部桥带
          // 贴卡槽顶边（preview `_buildPreview` :598-607 同式）。
          top: anchor.top - gap - panelHeight,
          width: width,
          height: panelHeight + gap,
          child: ShellInputRegion(
            debugLabel: debugLabel,
            // 默认 childBounds + keyboardPolicy none（preview 同式）。
            child: MouseRegion(
              // KOS `pointerInside`：整个 Positioned（含底部 12px 桥带）
              // 都算 popup 内。
              onEnter: (_) => onPointerInsideChanged?.call(true),
              onExit: (_) => onPointerInsideChanged?.call(false),
              child: Align(
                alignment: Alignment.topCenter,
                child: AnimatedBuilder(
                  animation: progress,
                  builder: (context, child) {
                    final v = progress.value;
                    // ACCEPTANCE popup 条款：scale 0.96→1 + ~20px 位移
                    // （底锚向上长，KOS motionOrigin: Item.Bottom
                    // DockInfoPopup.qml:24）。
                    return Transform.translate(
                      offset: Offset(0, (1 - v) * kDockMenuEnterOffset),
                      child: Transform.scale(
                        scale:
                            kDockMenuEnterScale + (1 - kDockMenuEnterScale) * v,
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxHeight),
                          child: DockInfoPanel(content: content, progress: v),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
