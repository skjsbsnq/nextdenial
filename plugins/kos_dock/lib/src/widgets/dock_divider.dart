/// KOS Dock 分隔线（2px 竖线 + 两侧留白槽位）。
///
/// 布局对齐 NextKde `DockDivider.qml`（行号锚定
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 槽位宽 `dividerWidth + sideMargin*2`、高撑满 dock（DockDivider.qml:
///   20-22；本端为 `DockMetrics.dockHeight`——方案 C 起随 iconSize 反解变）；
/// - 可见线宽 2px、高 = dockHeight×0.45、槽内居中（DockDivider.qml:26-34
///   `anchors.centerIn`，dividerWidth:2 见 DockContainer.qml:851,910,949，
///   线高比 0.45 见 DockDivider.qml:15）；
/// - 线帽全圆：`lineRadius: 999`（DockContainer.qml:855 实例覆盖值，覆盖
///   DockDivider.qml:13 默认 `dividerWidth/2`）；
/// - 线色：KOS 为白 0.46（DockContainer.qml:853-854 `lineColor:
///   Qt.rgba(1,1,1,1)` + `lineOpacity: 0.46`），本端按 CONSTRAINTS §3 映射
///   shellTheme `hairline` 语义色（偏差记 docs/visual-deltas.md）。
///
/// 可见性由父级条件插入决定（KOS `visible:` 绑定，DockContainer.qml:
/// 912,951）；KOS 的 `Behavior on width` 显隐动画（DockDivider.qml:38-44）
/// 不移植。
library;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/widgets.dart';

import '../theme/dock_tokens.dart';

/// Dock 分区竖线。自身只画静态线形；是否渲染由父级 Row 的条件插入控制。
class DockDivider extends StatelessWidget {
  const DockDivider({super.key});

  @override
  Widget build(BuildContext context) {
    // 方案 C：槽位宽（dividerMargin）与线高（dockHeight）都由 DockMetrics
    // 反解（KOS: dock/DockDivider.qml:20-22,26-34；sideMargin =
    // container.dividerMargin，DockContainer.qml:851-855）。
    final metrics = DockMetricsScope.of(context);
    return SizedBox(
      // KOS: dock/DockDivider.qml:20-21 — width: dividerWidth + sideMargin*2。
      width: metrics.dividerSlotWidth,
      height: metrics.dockHeight,
      child: Center(
        child: Container(
          // KOS: dock/DockDivider.qml:27-29 — width: divider.dividerWidth,
          // height: divider.dockHeight * divider.lineHeightRatio。
          width: kDockDividerWidth,
          height: metrics.dockHeight * kDockDividerHeightRatio,
          decoration: BoxDecoration(
            // KOS: dock/DockContainer.qml:853-854 — 白@0.46 → hairline
            // 语义色（CONSTRAINTS §3，不在此硬编码颜色）。
            color: context.shellColors.hairline,
            // KOS: dock/DockContainer.qml:855 — lineRadius: 999（胶囊端帽）。
            borderRadius: BorderRadius.circular(kDockDividerCapRadius),
          ),
        ),
      ),
    );
  }
}
