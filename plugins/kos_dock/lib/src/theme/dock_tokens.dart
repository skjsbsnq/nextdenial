/// KOS Dock 尺寸 tokens（纯几何常量，无 IO）。
///
/// 所有数值移植自 NextKde（KOS）源，注释以 `KOS: <file>:<lines>` 标注行号，
/// 源根为 `/home/wwt/文档/NextKde/shell/desktop/modules/`：
/// - dock：DockWindow.qml / DockContainer.qml / DockDivider.qml /
///   AdaptiveMath.mjs / DockConfigService.qml
/// - common：AppearanceTokens.qml
library;

/// Dock 基准厚度（floating 模式 pill 高）。
///
/// KOS: dock/DockConfigService.qml:37 — `property real baseHeight: 60`
/// （macOS 外观基准高；AdaptiveMath 以 iconSize 为自变量反解高度，但
/// `baseHeight` 默认值固定 60，作为 place() 厚度与 pill 高的基准）。
const double kDockBaseHeight = 60;

/// 基准图标边长：`baseHeight / (1 + 2*vpad)`，vpad=0.20 → 60/1.4 ≈ 42.857。
///
/// KOS: dock/AdaptiveMath.mjs:126 — `baseIconSize = baseHeight/(1+2*p.vpad)`；
/// vpad 取自 AppearanceTokens macOS 行的 `verticalPaddingRatio: 0.20`。
/// KOS: common/AppearanceTokens.qml:416 — `verticalPaddingRatio: 0.20`
/// （isWindows12 0.12 / isMaterial 0.16 / 否则 0.20，macOS 走 0.20 分支）。
const double kDockIconSize = kDockBaseHeight / (1 + 2 * 0.20);

/// 竖向内边距比（iconSize 的 0.20），见 [kDockIconSize]。
///
/// KOS: common/AppearanceTokens.qml:416 / dock/AdaptiveMath.mjs:11 (`vpad: 0.20`)。
const double kDockVerticalPaddingRatio = 0.20;

/// Pill 圆角比：圆角 = dockHeight × 0.50（半圆胶囊端帽）。
///
/// KOS: common/AppearanceTokens.qml:413 —
/// `radiusRatio: isWindows12 ? 0.20 : 0.50`，macOS/Material 均钉在 0.50
/// （"the cap becomes a half circle" 的上限）。当前视图以
/// `BorderRadius.circular(pillHeight / 2)` 表达（半径=高/2，见
/// dock_view.dart）；源端为 squircle，退化见 docs/visual-deltas.md。
const double kDockPillRadiusRatio = 0.50;

/// 浮空边距比：edgeMargin/workspaceMargin = dockHeight × 0.12（下限 4px）。
///
/// KOS: dock/DockWindow.qml:63-64 —
/// `edgeMargin: taskbar ? 0 : max(4, round(dockContainer.height * 0.12))`；
/// KOS: dock/DockWindow.qml:68-69 — `workspaceMargin` 同式。
const double kDockEdgeMarginRatio = 0.12;

/// 浮空边距下限（px）：`Math.max(4, …)` 的 4。
///
/// KOS: dock/DockWindow.qml:63-64,68-69。
const double kDockMinEdgeMargin = 4;

/// Divider 线宽（px）。
///
/// KOS: dock/DockContainer.qml:521,851,910,949 — 各 divider 实例
/// `dividerWidth: 2`（AdaptiveMath.mjs:20 的 DEFAULT 1px 被实例覆盖为 2）。
const double kDockDividerWidth = 2;

/// Divider 线高占 dock 高度比。
///
/// KOS: dock/DockDivider.qml:15 — `lineHeightRatio: 0.45`。
const double kDockDividerHeightRatio = 0.45;

/// 竖向 dock 时的横向内边距比（图标行 TASK-01 使用，先记常量）。
///
/// KOS: common/AppearanceTokens.qml:414-415 —
/// `horizontalPaddingRatio: 0.40`（macOS 分支）。
const double kDockHorizontalPaddingRatio = 0.40;

/// 图标间距比（itemSpacing = iconSize × 0.09，macOS 分支）。
///
/// KOS: common/AppearanceTokens.qml:418-419 — `itemSpacingRatio: 0.09`。
const double kDockItemSpacingRatio = 0.09;
