/// KOS DeskCenter 卡片容器（`DeskCard`）。
///
/// 对齐 NextKde `DeskWidgetCard.qml` 的卡片表面契约：一张卡 = 一个表面 +
/// 内容 + 编辑态角标（源端可选标题槽在所有 configuredWidget 中均为空串，
/// 本端不留该参数）。源端表面材质（KWin 磨砂 blurRegion /
/// blurRegion / LiquidGlassPanel liquid 折射）不可逐项移植；本端改吃
/// Denial 原生材质——`ShellBackdropBlur` + `Material` 由
/// `context.shellTheme` 供色（与底部 taskbar `_TaskbarSurface`/
/// `_TaskbarBackdrop` 同一套 ShellTheme 材质，glass 模式下引擎层自带
/// refraction/dispersion/edge 光效），不再手写 scrim/描边/高光/阴影。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对路径。
library;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/glass_configuration.dart'
    show ShellTransparencyMode;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';

import '../layout/widget_layout.dart' show WidgetSize;
import '../theme/kos_card_tokens.dart';

/// 编辑态角标点击回调类型（对应 DeskCenterWindow.qml:563-566、588-590 的
/// TapHandler 动作）。公开供 TASK-05 容器接线 `onRemove`/`onCycleSize` 用，
/// 当前仅挂接静态视觉。
typedef DeskCardBadgeCallback = void Function();

/// 尺寸档位 → 角标中文标签（DeskCenterWindow.qml:544-545、582-583：
/// `{small:"小", medium:"中", large:"大"}`）。公开供 TASK-05 悬停尺寸
/// 提示（DeskCenterWindow.qml:531-549 "小 · 右键编辑"）复用；
/// 当前仅编辑态尺寸角标（build 内尺寸角标 Text）引用。
const Map<WidgetSize, String> kosWidgetSizeLabels = {
  WidgetSize.small: '小',
  WidgetSize.medium: '中',
  WidgetSize.large: '大',
};

/// Only a settled, non-overlapping grid can share its backdrop snapshot.
/// Keep the scope in the tree during editing so card state is not recreated.
class DeskCardBackdropScope extends InheritedWidget {
  const DeskCardBackdropScope({
    required this.grouped,
    required super.child,
    super.key,
  });

  final bool grouped;

  static bool groupedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DeskCardBackdropScope>()
          ?.grouped ??
      false;

  @override
  bool updateShouldNotify(DeskCardBackdropScope oldWidget) =>
      grouped != oldWidget.grouped;
}

/// DeskCenter 小部件卡片。
class DeskCard extends StatelessWidget {
  const DeskCard({
    super.key,
    required this.child,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.cornerRadius,
    this.badgeColor,
    this.badgeForeground,
    this.onRemove,
    this.onCycleSize,
  });

  /// 卡内容（对应 `DeskWidgetCard` 内嵌 Loader 的内容层，
  /// DeskCenterWindow.qml:596-610）。
  final Widget child;

  /// 尺寸档位，驱动编辑态尺寸角标标签。
  final WidgetSize size;

  /// 编辑模式：显示移除（左上 −）与尺寸循环（右下）角标
  /// （DeskCenterWindow.qml:551-591）。
  final bool editMode;

  /// 卡片圆角，对应 `AppearanceTokens.widget.radius`
  /// （AppearanceTokens.qml:465-466）。null（默认）取 Denial 统一卡片圆角
  /// `context.shellTheme.tileRadius`（对齐 Denial 自身卡片）。
  final double? cornerRadius;

  /// 尺寸角标底色/文字色覆盖；null 时取 shell 色板
  /// （底色 `surfaceContainerHigh`、前景 `textPrimary`）。
  final Color? badgeColor;
  final Color? badgeForeground;

  /// 移除角标点击回调（对应 `setDeskCenterWidgetVisible(id,false)`，
  /// DeskCenterWindow.qml:563-566；实现归 TASK-05）。
  final DeskCardBadgeCallback? onRemove;

  /// 尺寸循环角标点击回调（对应 `DeskCenterConfigService.cycleSize`，
  /// DeskCenterWindow.qml:588-590）。
  final DeskCardBadgeCallback? onCycleSize;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final borderRadius = BorderRadius.circular(
      cornerRadius ?? theme.tileRadius,
    );

    return ShellBackdropBlur(
      // Opaque foregrounds completely cover the filtered backdrop.
      blur: theme.backdropBlurEnabled && theme.effectiveCardOpacity < 1,
      // Glass grouping forces a shared backdrop cache and prevents the
      // engine's direct-composition path. Keep glass filters independent;
      // non-overlapping plain blur cards can still share their blur input.
      grouped:
          theme.transparencyMode == ShellTransparencyMode.blur &&
          DeskCardBackdropScope.groupedOf(context),
      // 前景不进 filter 层（液态玻璃的 refraction/edge 光效不污染内容）。
      separateChild: true,
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Material(
              // 填充随 ShellTheme：glass 模式取 _glassBacking（黑/白随
              // appearance）× glass.opacity；blur/off 模式退化为
              // surfaceContainer 不透明（与 taskbar 同一 cardColor 链）。
              color: theme.cardColor(colors.surfaceContainer),
              borderRadius: borderRadius,
              clipBehavior: Clip.antiAlias,
              // Draw controls directly without a per-card compositing/cache
              // layer, and keep their subtree stable across material changes.
              child: child,
            ),
          ),
          if (editMode) ...[
            // 移除角标：左上 26px 圆 #ff453a + 白 "−"
            // （DeskCenterWindow.qml:551-567）。红底白字为固定语义警示对
            // （明暗壳下通用），保留源端原值不走 shell 色板。
            Positioned(
              top: KosCardTokens.badgeMargin,
              left: KosCardTokens.badgeMargin,
              child: _Badge(
                onTap: onRemove,
                child: Container(
                  width: KosCardTokens.removeBadgeSize,
                  height: KosCardTokens.removeBadgeSize,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: KosCardTokens.removeBadgeColor,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '−', // U+2212，源 `text: "−"`（:559）
                    style: TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: KosCardTokens.removeBadgeFontSize,
                      fontWeight: FontWeight.bold, // Font.Bold（:561）
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
            // 尺寸循环角标：右下胶囊（DeskCenterWindow.qml:569-591）。
            Positioned(
              right: KosCardTokens.badgeMargin,
              bottom: KosCardTokens.badgeMargin,
              child: _Badge(
                onTap: onCycleSize,
                child: Container(
                  height: KosCardTokens.sizeBadgeHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: KosCardTokens.sizeBadgePaddingH,
                  ),
                  decoration: BoxDecoration(
                    // :575 `isMaterial ? 13 : 9` 双档合并为 Denial chip 圆角。
                    borderRadius: BorderRadius.circular(theme.chipRadius),
                    color: badgeColor ?? colors.surfaceContainerHigh,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    kosWidgetSizeLabels[size] ?? '',
                    style: TextStyle(
                      color: badgeForeground ?? colors.textPrimary,
                      fontSize: KosCardTokens.sizeBadgeFontSize,
                      fontWeight: FontWeight.w600, // Font.DemiBold（:586）
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 角标手势包装：有回调才挂 GestureDetector，静态布局与源一致。
class _Badge extends StatelessWidget {
  const _Badge({required this.child, this.onTap});

  final Widget child;
  final DeskCardBadgeCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    );
  }
}
