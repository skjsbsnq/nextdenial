/// KOS Dock 尺寸 tokens：几何比例常量 + 运行时尺寸对象 [DockMetrics]。
///
/// 所有数值移植自 NextKde（KOS）源，注释以 `KOS: <file>:<lines>` 标注行号，
/// 源根为 `/home/wwt/文档/NextKde/shell/desktop/modules/`：
/// - dock：DockWindow.qml / DockContainer.qml / DockDivider.qml /
///   AdaptiveMath.mjs / DockConfigService.qml
/// - common：AppearanceTokens.qml
///
/// 方案 C（TASK-04b §6）：原编译期尺寸常量（kDockIconSlotSize 等）已收敛进
/// 运行时对象 [DockMetrics]——KOS `AdaptiveMath.computeLayout` 以 iconSize
/// 为单一自变量反解、再由它派生全部间距/内边距/pill 高（AdaptiveMath.mjs:
/// 129-150）；本文件保留的是**不随宽度变化**的比例/固定像素常量与公式。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// ══════════════════════════════════════════════════════════════════
// 一、DockMetrics 反解输入（KOS AdaptiveMath.mjs 常量段）
// ══════════════════════════════════════════════════════════════════

/// Dock 基准厚度（floating 模式 pill 高基准）。
///
/// KOS: dock/DockConfigService.qml:37 — `property real baseHeight: 60`
/// （macOS 外观基准高；AdaptiveMath 以 iconSize 为自变量反解高度，
/// `baseHeight` 经 `baseIconSize = baseHeight/(1+2*vpad)` 参与反解，
/// AdaptiveMath.mjs:126）。
const double kDockBaseHeight = 60;

/// 基准图标边长：`baseHeight / (1 + 2*vpad)`，vpad=0.20 → 60/1.4 ≈ 42.857。
///
/// KOS: dock/AdaptiveMath.mjs:126 — `baseIconSize = baseHeight/(1+2*p.vpad)`；
/// vpad 取自 AppearanceTokens macOS 行的 `verticalPaddingRatio: 0.20`。
/// KOS: common/AppearanceTokens.qml:416 — `verticalPaddingRatio: 0.20`
/// （isWindows12 0.12 / isMaterial 0.16 / 否则 0.20，macOS 走 0.20 分支）。
const double kDockIconSize = kDockBaseHeight / (1 + 2 * 0.20);

/// iconSize 绝对下限：compact 极限 18px。
///
/// KOS: dock/AdaptiveMath.mjs:25 — `MIN_ICON_SIZE = 18`。
const int kDockMinIconSize = 18;

/// 竖向内边距比（iconSize 的 0.20）。
///
/// KOS: common/AppearanceTokens.qml:416 / dock/AdaptiveMath.mjs:11
/// (`vpad: 0.20`)。
const double kDockVerticalPaddingRatio = 0.20;

/// 横向内边距比（hPadding = iconSize × 0.40，macOS 分支）。
///
/// KOS: common/AppearanceTokens.qml:414-415 — `horizontalPaddingRatio: 0.40`；
/// dock/AdaptiveMath.mjs:12（`hpad: 0.4`）,143（`hPadding` 导出式）。
const double kDockHorizontalPaddingRatio = 0.40;

/// 图标间距比（itemSpacing = iconSize × 0.09，macOS 分支）。
///
/// KOS: common/AppearanceTokens.qml:418-419 — `itemSpacingRatio: 0.09`；
/// dock/AdaptiveMath.mjs:13（`spacing: 0.09`）,142。
const double kDockItemSpacingRatio = 0.09;

/// Divider 两侧留白比（dividerMargin = iconSize × 0.20，macOS 分支）。
///
/// KOS: common/AppearanceTokens.qml:420-421 — `dividerMarginRatio: 0.20`；
/// dock/AdaptiveMath.mjs:14（`divmargin: 0.20`）,145。
const double kDockDividerMarginRatio = 0.20;

/// Pill 圆角比：圆角 = dockHeight × 0.50（半圆胶囊端帽）。
///
/// KOS: common/AppearanceTokens.qml:413 —
/// `radiusRatio: isWindows12 ? 0.20 : 0.50`，macOS/Material 均钉在 0.50
/// （"the cap becomes a half circle" 的上限）；DockContainer.qml:195-196
/// `Math.round(computedDockHeight * radiusRatio)`——半径绑运行时 dock 高。
/// 源端为 squircle，退化为 `BorderRadius.circular(height/2)`，见
/// docs/visual-deltas.md。
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

/// Divider 可见线宽（px）：唯一固定像素值。
///
/// KOS: dock/DockContainer.qml:521,851,910,949 — 各 divider 实例
/// `dividerWidth: 2`（AdaptiveMath.mjs:20 的 DEFAULT 1px 被实例覆盖为 2；
/// AdaptiveMath.mjs:122 的 fixedOverhead 用 DEFAULT 1px，我方统一按
/// 实例值 2 计入，偏差记 docs/visual-deltas.md）。
const double kDockDividerWidth = 2;

/// Divider 线高占 dock 高度比。
///
/// KOS: dock/DockDivider.qml:15 — `lineHeightRatio: 0.45`。
const double kDockDividerHeightRatio = 0.45;

/// 信息卡槽位宽单位：`INFO_UNITS = 4`（共享 music/weather 槽宽 ≡ 4 个图标
/// 方格）。
///
/// KOS: dock/AdaptiveMath.mjs:22（`INFO_UNITS = 4`）；消费端
/// dock/DockContainer.qml:201（`infoUnits: _layout.infoUnits`）,920,937。
const int kDockInfoUnits = 4;

/// [kDockInfoUnits] 的 double 字面量（`fromWidth` 默认参数需要 const
/// double，int→double 的 `.toDouble()` 不是 const 表达式）。
const double kDockInfoUnitsValue = 4.0;

/// 横向宽度上限比：bottom dock 最多占屏宽 98%。
///
/// KOS: dock/AdaptiveMath.mjs:29-30 — `MAX_WIDTH_RATIO = 0.98`；消费端
/// `maxWidth = availableLength * maxLengthRatio`（:80）。
const double kDockMaxWidthRatio = 0.98;

/// 图标槽位/激活底斑外延比：activeBackgroundGap = iconSize × 0.1。
/// KOS: dock/AdaptiveMath.mjs:36（`ACTIVE_BG_GAP_RATIO = 0.1`）,150；
/// dock/DockIcon.qml:93-96（槽宽 = iconSize + gap×2）。
const double kDockActiveBackgroundGapRatio = 0.10;

/// 激活底斑圆角比：radius = iconSize × 0.30（macOS 分支）。
///
/// KOS: common/AppearanceTokens.qml:434-435 — `activeRadiusRatio: 0.30`；
/// 消费端 dock/DockIcon.qml:114-115。
const double kDockActiveRadiusRatio = 0.30;

/// 激活底斑透明度（subtle 上限）：KOS macOS 分支走 glass/subtle 语义
/// `min(0.22, configured)`；取 0.22。
///
/// KOS: dock/DockIcon.qml:129-137（activeBackgroundAlpha：subtle→≤0.22、
/// tonal→≤0.34）,138（`showActiveBackground: isRunning && isActivated`）。
const double kDockActiveBackgroundAlpha = 0.22;

/// TASK-11 高斯波峰值 scale `M`（quickshell `clamp(magnification,1,2)`，
/// 默认 1.5）。
///
/// quickshell: `Common/functions/DockLayout.js:24` — `maximum =
/// max(1, min(2, magnification))` + DockService.magnificationScale 默认 1.5；
/// KOS 旧 smoothstep 峰值 1.19（AppearanceTokens.qml:445）与影响半径
/// 140/lift 0.04 随固定槽位路径整段移除（docs/visual-deltas.md TASK-11）。
const double kDockWaveMaxScale = 1.5;

/// TASK-12 抬起净空的**余量项**（不是比例）：headroom = `iconSlotSize ×
/// kDockWaveMaxScale − dockHeight + kDockLaunchBounceHeight + 本值`。
///
/// 美术盒底锚 pill 底、顶缘 = `iconSlotSize·maxScale`——超出 pill 顶
/// （`dockHeight`）的几何需求是 `iconSlotSize·maxScale − dockHeight`；
/// `kDockLaunchBounceHeight`（19px）盖住 bounce 顶点向上平移；本值再叠加
/// hover lift（`max(2, round(iconSize×kDockHoverLiftRatio))`≈4px）+ ~2px
/// 舍入保险 → `6`。
///
/// quickshell `Modules/Dock/DockSurface.qml:120-121`：`bandThickness =
/// size·maxScale + 36`，玻璃托盘高之外按最大倍率预留整段带高——放大图标
/// 底锚向上「长」出玻璃面（macOS「跳出水面」）。本端 pill 本体保持
/// `dockHeight` 底对齐不变，本值只给 `ShellBackdropBlur` 的 ClipRRect 与
/// 波形槽位向上 overflow 的余量（`dock_shell.dart` OverflowBox +
/// `dock_icons.dart` 槽位 OverflowBox）。
const double kDockIconLiftHeadroomSlack = 6.0;

/// 波形振幅包络时长（指针进/出容器的唯一缓动）：220ms `easeOutCubic`。
///
/// quickshell: `Common/functions/DockMotion.js:6` `reflowDuration = 220`
/// + `DockSurface.qml:96-101` `Behavior on magnificationProgress`
/// （NumberAnimation 220ms OutCubic）。
const Duration kDockWaveAmplitudeDuration = Duration(milliseconds: 220);

/// 指针离开容器的防抖（ms）：region 抖动期内不立即把包络打到 0。
///
/// quickshell: `DockSurface.qml:637-644` `magnificationExit` Timer
/// `interval: 80`。
const Duration kDockWaveExitDebounce = Duration(milliseconds: 80);

/// 手写重排的拖拽启动阈值（px 水平位移）：长按下超过阈值即进 reorder 态
/// （对齐 ReorderableListView 长按拖拽手势与 quickshell `DockItem.qml`
/// MouseArea 拖拽语义）。
const double kDockReorderDragThreshold = 10;

/// 独立 hover 缩放（magnification 指针缺席时）：scale 1.20。
///
/// KOS: common/AppearanceTokens.qml:439 — `hoverScale: 1.20`；
/// dock/DockIcon.qml:291-293。
const double kDockHoverScale = 1.20;

/// 独立 hover 抬升比：lift = −max(2, round(iconSize×0.08))。
///
/// KOS: common/AppearanceTokens.qml:440 — `hoverLiftRatio: 0.08`；
/// dock/DockIcon.qml:297-300。
const double kDockHoverLiftRatio = 0.08;

/// hover 高亮圆斑透明度：KOS 为白 0.12，映射 shellTheme 前景色同 alpha。
///
/// KOS: dock/DockIcon.qml:647 `Qt.rgba(1,1,1,0.12)`；时长/easing 见
/// :653-657 → DockAnimation.qml:30-32（fastDuration≈135ms OutCubic）。
const double kDockHoverHighlightAlpha = 0.12;

/// hover 高亮淡入淡出时长（ms，字面 OutCubic）。
///
/// KOS: dock/DockAnimation.qml:30 → common/AppearanceTokens.qml
/// `motion.fastDuration`（135ms）；曲线 standardEasing=OutCubic。
const Duration kDockHoverHighlightDuration = Duration(milliseconds: 135);

/// dot 指示行透明度动画时长（ms，字面 OutCubic）。
///
/// KOS: dock/DockIcon.qml:809-811（`duration: 140; easing.type: OutCubic`）。
const Duration kDockDotFadeDuration = Duration(milliseconds: 140);

/// 运行指示多点上限/下限：dotCount = min(3, max(1, windowCount))。
///
/// KOS: dock/DockIcon.qml:790-791。
const int kDockDotMaxCount = 3;

/// dot 边长（px）：count≥3 → 4；否则 5。
///
/// KOS: dock/DockIcon.qml:792 `dotCount >= 3 ? 4 : 5`。
const double kDockDotSizeCompact = 4;
const double kDockDotSizeWide = 5;

/// dot 间距（px）。
///
/// KOS: dock/DockIcon.qml:793 `dotSpacing: 2`。
const double kDockDotSpacing = 2;

/// dot 颜色 alpha（KOS 前景 0.95 → shellTheme textPrimary 同 alpha）。
///
/// KOS: dock/DockIcon.qml:824-826 `Qt.rgba(foreground…, 0.95)`。
const double kDockDotAlpha = 0.95;

/// 入场交错延迟（每图标 60ms，_SystemBarEntrance 范式）。
///
/// 移植自 denial_top_bar `desktop_system_bar_components.dart:344`
/// （`_stagger = Duration(milliseconds: 60)`）。
const Duration kDockEntranceStagger = Duration(milliseconds: 60);

/// Divider 线帽圆角：`lineRadius: 999`（2px 细线上即全圆胶囊端帽）。
///
/// KOS: dock/DockContainer.qml:855（`lineRadius: 999`）；DockDivider.qml:13
/// 默认 `dividerWidth / 2`，DockContainer 各实例均覆盖为 999。
const double kDockDividerCapRadius = 999;

// ── TASK-10/11 图标弹跳反馈与波形 ────────────────────────────────────────
//
// TASK-10 的 `kDockHoverSpring`（Motion.bouncy hover 过冲弹簧）已随 TASK-11
// 移除：高斯波下各槽 scale 由 `dockWaveLayout` 每帧直算，不再经逐图标
// spring 跟手（硬性约束①：唯一缓动是振幅包络）。

/// 无容器指针时的独立 hover 进度缓动（指针缺席的兜底路径，
/// `_progress` bounded tween）：quickshell `DockItem.qml` 无指针 hover 的
/// iconSize Behavior 100ms OutCubic，本端对齐同一量级。
const Duration kDockHoverEaseDuration = Duration(milliseconds: 100);

/// 点击启动单次弹跳（launch bounce）峰值位移（px）：图标向上跳起
/// 19px 后落地回弹。
///
/// quickshell: `Modules/Dock/DockItem.qml:86-104` — `SequentialAnimation`
/// `bounce: 0 → 19`（DockItem.qml:89-96 `to: 19`），水平 dock 下
/// `artwork.y = … − root.bounce`（:112 上推）。曲线构成参考 KOS
/// `dock/DockIcon.qml:320-338` `attentionPulse`（trash 收文件的
/// scale/lift/glow 脉冲），但 KOS 普通图标点击启动无任何弹跳 → 本效果为
/// **新增**，参数取 quickshell。取固定像素而非 iconSize 比例：quickshell
/// 的 19px 同样是常量（不随其 iconSize 缩放），且对小 iconSize（18px 下限
/// 时 0.4×iconSize=7.2px）保持同一视觉强度、避免亚像素舍入分叉。
const double kDockLaunchBounceHeight = 19;

/// launch bounce 上升段时长：`bounce 0 → 19`，220ms。
///
/// quickshell: `DockItem.qml:89-96` — `duration: 220`，
/// `easing.type: Easing.OutQuad`（→ `Curves.easeOutQuad`）。
const Duration kDockLaunchBounceRiseDuration = Duration(milliseconds: 220);

/// launch bounce 落地段时长：`bounce → 0`，340ms 回弹。
///
/// quickshell: `DockItem.qml:97-102` — `duration: 340`，
/// `easing.type: Easing.OutBounce`（→ `Curves.bounceOut`，等价 Qt
/// `Easing.OutBounce`）；KOS `attentionPulse` 的回落段同用 OutBounce
/// （dock/DockIcon.qml:335）。总时长 ≈560ms，单次 forward 不循环。
const Duration kDockLaunchBounceFallDuration = Duration(milliseconds: 340);

// ══════════════════════════════════════════════════════════════════
// 二、DockMetrics：KOS AdaptiveMath.computeLayout 的运行时移植
// ══════════════════════════════════════════════════════════════════

/// Dock 运行时尺寸对象：以 iconSize 为单一自变量反解并派生全部几何。
///
/// 逐项移植 KOS `dock/AdaptiveMath.mjs` 的 `computeLayout`（:62-166）：
///
/// ```text
/// scaleFactor = iconUnits                                  // :115-120
///             + (appIconCount + (hasInfo?1:0)) * 2*0.1
///             + max(0, itemCount-1) * spacing(0.09)
///             + 2*dividerCount * divmargin(0.20)
///             + 2*hpad(0.40)
/// fixedOverhead = dividerCount * dividerWidth              // :122
/// iconSize = baseIconSize*scaleFactor + fixedOverhead <= maxWidth
///     ? floor(baseIconSize)                                // :130-132
///     : floor((maxWidth - fixedOverhead) / scaleFactor)    // :134-135
/// iconSize = clamp(iconSize, MIN_ICON_SIZE, maxIconSize)   // :138
/// dockHeight    = round(iconSize * (1+2*0.20))             // :141
/// itemSpacing   = round(iconSize * 0.09)                   // :142
/// hPadding      = round(iconSize * 0.40)                   // :143
/// dividerMargin = round(iconSize * 0.20)                   // :145
/// pillRadius    = round(dockHeight * 0.50)                 // :146
/// dockWidth     = min(iconSize*scaleFactor+fixedOverhead,  // :148-149
///                     maxWidth)
/// activeBackgroundGap = iconSize * 0.1                     // :150
/// ```
///
/// **我方槽位映射（如实说明，非 KOS 公式）**：KOS 的 appIconCount 只含
/// pinned+window 两类 DockIcon；我方 pill 里 launcher/trash 是**同规格**的
/// `DockControlIcon`（同 slot/gap 几何），KOS 中它们由 pinnedRepeater 之外
/// 的固定 DockIcon 实例承担、同样计入 Row 链与 itemSpacing——故在反解里按
/// app icon 处理（计入 appIconCount 与 iconUnits）。tray 槽位是
/// `trailingAccessory`：KOS 经 `estimatedAccessoryWidth` 从可用宽预扣
/// （DockContainer.qml:124-133 `accessoryCount * baseHeight * 0.60`）且
/// `Loader.width = item.implicitWidth` 参与 Row 自然宽（:954-959）；我方
/// 等价回流——槽位按 1 个 icon unit 计入（保底 iconSlotSize），`trayWidth`
/// 估算宽超出槽宽的部分以固定 px 计入 dockWidth（见 [fromWidth]）。
/// info 槽宽 = infoUnits(4) × iconSize，无 activeBackgroundGap（KOS
/// DockInfoCarousel 非 DockIcon、无激活底斑槽——但 :117 的
/// `(hasInfoSlot?1:0)` 项为它额外计了 1 个 gap 对，照原式移植）。
@immutable
final class DockMetrics {
  const DockMetrics._({
    required this.iconSize,
    required this.dockHeight,
    required this.dockWidth,
    required this.itemSpacing,
    required this.hPadding,
    required this.vPadding,
    required this.dividerMargin,
    required this.pillRadius,
    required this.activeBackgroundGap,
    required this.iconUnits,
    required this.infoUnits,
    required this.dividerCount,
  });

  /// 反解后的图标边长（px，已 clamp 到 [kDockMinIconSize, maxIconSize]）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:129-138,154。
  final double iconSize;

  /// pill/dock 高：`round(iconSize * (1+2*vpad))`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:141。
  final double dockHeight;

  /// pill 内容宽（含 hpad×2 与 divider 槽位）：`min(contentWidth, maxWidth)`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:148-149 — `contentWidth = iconSize*scaleFactor
  /// + fixedOverhead；dockWidth = min(contentWidth, maxWidth)`。
  final double dockWidth;

  /// 图标间距：`round(iconSize * 0.09)`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:142。
  final double itemSpacing;

  /// pill 左右内边距：`round(iconSize * 0.40)`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:143。
  final double hPadding;

  /// pill 竖向内边距：`round(iconSize * 0.20)`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:144。
  final double vPadding;

  /// divider 单侧留白：`round(iconSize * 0.20)`。
  ///
  /// KOS: dock/AdaptiveMath.mjs:145。
  final double dividerMargin;

  /// pill 圆角半径：`round(dockHeight * 0.50)` = 高/2 半圆端帽。
  ///
  /// KOS: dock/AdaptiveMath.mjs:146 ← common/AppearanceTokens.qml:413
  /// `radiusRatio: 0.50`（DockContainer.qml:195-196 绑运行时 dockHeight）。
  final double pillRadius;

  /// 激活底斑相对图标的外延：`iconSize * 0.1`（亚像素，不取整）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:36,150；DockIcon.qml:93-96（槽宽 =
  /// iconSize + gap×2，DockIcon.qml:116,234-235）。
  final double activeBackgroundGap;

  /// 图标方格总数：appIconCount + infoUnits（含 launcher/trash/tray，见类
  /// 注释的槽位映射）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:92-93。
  final double iconUnits;

  /// info 槽占用方格数（hasInfo ? 4 : 0）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:22,83-85。
  final double infoUnits;

  /// 可见 divider 数（反解输入）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:88-89。
  final int dividerCount;

  /// 图标槽位边长：`iconSize + activeBackgroundGap*2`。
  ///
  /// KOS: dock/DockIcon.qml:116（`iconSize + activeBackgroundGap * 2`），
  /// 槽位即布局尺寸 :234-235。
  double get iconSlotSize => iconSize + activeBackgroundGap * 2;

  /// divider 槽位总宽：`dividerWidth + dividerMargin*2`。
  ///
  /// KOS: dock/DockDivider.qml:20-22（width: dividerWidth + sideMargin*2，
  /// sideMargin = container.dividerMargin，DockContainer.qml:851-855）。
  double get dividerSlotWidth => kDockDividerWidth + dividerMargin * 2;

  /// info 槽宽：`infoUnits * iconSize`（无 gap 外延）。
  ///
  /// KOS: dock/AdaptiveMath.mjs:22（槽宽 = 方格数 × iconSize）。
  double get infoSlotWidth => infoUnits * iconSize;

  /// 浮空边距：`max(4, round(dockHeight*0.12))`；workspaceMargin 同式。
  ///
  /// KOS: dock/DockWindow.qml:63-64（edgeMargin）,68-69（workspaceMargin）
  /// ——两者都绑**运行时** dockContainer.height，pill 高随反解变化时
  /// 边距跟随（方案 C：原 74 常量条带厚度随之变为运行时值）。
  double get edgeMargin => math.max(
    kDockMinEdgeMargin,
    (dockHeight * kDockEdgeMarginRatio).roundToDouble(),
  );

  /// 贴底条带厚度：`dockHeight + edgeMargin + workspaceMargin`。
  ///
  /// KOS: dock/DockWindow.qml:92-93（implicitHeight）；同式用于
  /// `exclusiveZone`（:124-127）→ `ShellWorkArea` 预留。
  double get stripThickness => dockHeight + edgeMargin * 2;

  /// iconSize 上限：`MAX_DOCK_HEIGHT/(1+2*vpad)` = 100/1.4 ≈ 71.4。
  ///
  /// KOS: dock/AdaptiveMath.mjs:125 — `maxIconSize = MAX_DOCK_HEIGHT /
  /// (1 + 2 * p.vpad)`；MAX_DOCK_HEIGHT = 100（:28）。
  static const double maxIconSize = 100 / (1 + 2 * kDockVerticalPaddingRatio);

  /// KOS `computeLayout` 移植：由可用宽与槽位计数反解全部几何。
  ///
  /// - [availableWidth]：输出逻辑宽（KOS `availableLength`，DockContainer
  ///   传 `max(baseHeight, availableLength - estimatedAccessoryWidth)`；
  ///   我方无动态配件预留，直接传条带宽）；
  /// - [pinnedCount]/[runningCount]：KOS `pinnedCount`/`windowCount`
  ///   （DockContainer.qml:167-169；windowCount = 未 pin 运行段条目数，
  ///   DockModelService.qml:150-200 grouped）；
  /// - [showLauncher]/[showTrash]：固定图标槽位（KOS `ConfigService.
  ///   showLauncher/showTrash`，DockContainer.qml:532,571 `visible:`）；
  /// - [hasInfo]/[hasTray]：info/tray 槽位出现（divider2/3 可见性由此与
  ///   条目数推导，见 [divider1Visible]/[divider2Visible]/[divider3Visible]）；
  /// - [trayWidth]：tray 槽估算内容宽（px，KOS `estimatedAccessoryWidth`
  ///   的等价回流，DockContainer.qml:111-133 预扣 + :954-959
  ///   `Loader.width = item.implicitWidth`）。槽位仍按 1 个 icon unit 计入
  ///   （保底 iconSlotSize），估算宽超出 iconSlotSize 的部分当固定
  ///   overhead 加进 `contentWidth`/`renderedWidth`/`dockWidth`——托盘内容
  ///   在 pill 内占真实槽宽，不再向左外延遮 divider3/info；
  /// - [infoUnits]：info 槽方格数（KOS `infoUnitsOverride`，
  ///   DockContainer.qml:159-160 非 expanded 取 4）。
  ///
  /// KOS 的 dividerCount 只数「段内」分割线（pinned|windows 与
  /// windows|info，AdaptiveMath.mjs:88-89）；我方把 divider3(tray 前) 同样
  /// 计入 itemCount/scaleFactor/fixedOverhead——它同样占 Row 槽位与
  /// spacing，漏计会让内容宽低估（偏差记 docs/visual-deltas.md）。
  factory DockMetrics.fromWidth(
    double availableWidth, {
    int pinnedCount = 0,
    int runningCount = 0,
    bool showLauncher = true,
    bool showTrash = true,
    bool hasInfo = false,
    bool hasTray = false,
    double trayWidth = 0,
    double infoUnits = kDockInfoUnitsValue,
    double maxLengthRatio = kDockMaxWidthRatio,
  }) {
    final maxWidth = availableWidth * maxLengthRatio;

    // KOS: dock/AdaptiveMath.mjs:82-94 — infoUnits/dividerCount/itemCount。
    final effInfoUnits = hasInfo && infoUnits.isFinite
        ? math.max(0.0, infoUnits)
        : 0.0;
    // divider1(pinned|windows) + divider2(windows|info)（KOS :88-89）+
    // divider3(info|tray)（我方扩展，规则同 DockContainer.qml:951）。
    final dividerCount =
        (divider1Visible(pinnedCount: pinnedCount, runningCount: runningCount)
            ? 1
            : 0) +
        (divider2Visible(
              hasInfo: hasInfo,
              pinnedCount: pinnedCount,
              runningCount: runningCount,
            )
            ? 1
            : 0) +
        (divider3Visible(
              hasTray: hasTray,
              hasInfo: hasInfo,
              showLauncher: showLauncher,
              showTrash: showTrash,
              pinnedCount: pinnedCount,
              runningCount: runningCount,
            )
            ? 1
            : 0);

    // appIconCount：KOS = pinnedCount + windowCount；我方加 launcher/trash/
    // tray（同规格图标槽位，见类注释映射）。
    final appIconCount =
        pinnedCount +
        runningCount +
        (showLauncher ? 1 : 0) +
        (showTrash ? 1 : 0) +
        (hasTray ? 1 : 0);
    // KOS: dock/AdaptiveMath.mjs:92-94 — iconUnits = appIconCount +
    // infoUnits；itemCount = 全部 Row 槽位（app 图标 + info + divider）。
    final iconUnitsAll = appIconCount + effInfoUnits;
    final itemCount = appIconCount + (hasInfo ? 1 : 0) + dividerCount;

    // KOS: dock/AdaptiveMath.mjs:97-104 — 空 dock 防御（我方恒有
    // launcher/trash 默认，仍保留同式守卫）。
    if (iconUnitsAll <= 0) {
      return const DockMetrics._(
        iconSize: 0,
        dockHeight: 0,
        dockWidth: 0,
        itemSpacing: 0,
        hPadding: 0,
        vPadding: 0,
        dividerMargin: 0,
        pillRadius: 0,
        activeBackgroundGap: 0,
        iconUnits: 0,
        infoUnits: 0,
        dividerCount: 0,
      );
    }

    // KOS: dock/AdaptiveMath.mjs:106-122 — scaleFactor/fixedOverhead。
    final scaleFactor =
        iconUnitsAll +
        (appIconCount + (hasInfo ? 1 : 0)) * 2 * kDockActiveBackgroundGapRatio +
        math.max(0, itemCount - 1) * kDockItemSpacingRatio +
        2 * dividerCount * kDockDividerMarginRatio +
        2 * kDockHorizontalPaddingRatio;
    // KOS :122 用 DEFAULT dividerWidth=1；我方实例恒 2（DockContainer.qml:
    // 851,910,949 `dividerWidth: 2`），按 2 计入（+dividerCount px 的偏差
    // 记 docs/visual-deltas.md）。
    final fixedOverhead = dividerCount * kDockDividerWidth;
    // tray 槽回流（KOS `estimatedAccessoryWidth` 预扣 + `Loader.width =
    // item.implicitWidth` 的等价，DockContainer.qml:111-133,954-959）：槽位
    // 已按 1 个 icon unit 计入 appIconCount（保底 iconSlotSize），估算内容
    // 宽超出槽宽的部分以固定 px 计入——tray 真实宽参与 dockWidth，托盘内容
    // 不向左外延遮相邻槽位。iconSize 未知时用基准槽宽（iconSize+gap×2，
    // DockIcon.qml:116 按 baseIconSize 代值）保守折算。
    final traySlotBase =
        kDockIconSize + 2 * (kDockIconSize * kDockActiveBackgroundGapRatio);
    final trayOverflowPx = hasTray
        ? math.max(0.0, trayWidth - traySlotBase)
        : 0.0;

    // KOS: dock/AdaptiveMath.mjs:124-138 — 反解 + clamp。
    const baseIconSize = kDockIconSize;
    var iconSize =
        (baseIconSize * scaleFactor + fixedOverhead + trayOverflowPx <= maxWidth
                ? baseIconSize.floor()
                : ((maxWidth - fixedOverhead - trayOverflowPx) / scaleFactor)
                      .floor())
            .toDouble();
    iconSize = iconSize.clamp(kDockMinIconSize.toDouble(), maxIconSize);

    // KOS: dock/AdaptiveMath.mjs:140-150 — 一切由 iconSize 派生。
    final dockHeight = (iconSize * (1 + 2 * kDockVerticalPaddingRatio))
        .roundToDouble();
    final itemSpacing = (iconSize * kDockItemSpacingRatio).roundToDouble();
    final hPadding = (iconSize * kDockHorizontalPaddingRatio).roundToDouble();
    final vPadding = (iconSize * kDockVerticalPaddingRatio).roundToDouble();
    final dividerMargin = (iconSize * kDockDividerMarginRatio).roundToDouble();
    final pillRadius = (dockHeight * kDockPillRadiusRatio).roundToDouble();
    final contentWidth =
        iconSize * scaleFactor + fixedOverhead + trayOverflowPx;
    final activeBackgroundGap = iconSize * kDockActiveBackgroundGapRatio;
    // 渲染时 tray 槽真实宽 = max(iconSlotSize, trayWidth)；dockWidth 必须
    // 至少包住它——按真实槽宽再折算一次超出部分（iconSize 已知，比反解段
    // 的 traySlotBase 基准折算更准）。
    final trayRenderedOverflow = hasTray
        ? math.max(0.0, trayWidth - (iconSize + activeBackgroundGap * 2))
        : 0.0;
    // dockWidth 必须包住**真实渲染宽**：:148-149 的 contentWidth 用未取整
    // 比例估计，而布局实际用 round 过的 itemSpacing/hPadding/dividerMargin
    // （上方 :141-145 同式取整）——取整方向上界使渲染宽最多比估计宽出 ~1px
    // （800 宽 2 pinned 实测溢出 0.62px → RenderFlex overflow 硬失败）。
    // 按真实几何取 max 再 clamp 到 maxWidth（KOS 同处差异 <1px，记
    // docs/visual-deltas.md）。渲染宽 = 2*hpad + 全 app 图标槽 + 图标区
    // 全槽位间距 + divider 槽 + info 槽 + tray 真实宽超出 1 icon unit
    // 的部分。TASK-11：间距烘进波形带**每槽尾随 gap**（含 launcher/
    // trash/divider1/running 同一 dockWaveLayout），即「图标区槽数−1」
    // 个 gap——不再是旧 Row 的 (pinned−1)+(running−1) 段内间距（tray/
    // info 在 outer Row 槽位、无 itemSpacing）。
    final iconRowSlots = pinnedCount +
        runningCount +
        (showLauncher ? 1 : 0) +
        (showTrash ? 1 : 0) +
        (divider1Visible(pinnedCount: pinnedCount, runningCount: runningCount)
            ? 1
            : 0);
    final renderedWidth =
        hPadding * 2 +
        appIconCount * (iconSize + activeBackgroundGap * 2) +
        math.max(0, iconRowSlots - 1) * itemSpacing +
        dividerCount * (kDockDividerWidth + dividerMargin * 2) +
        effInfoUnits * iconSize +
        trayRenderedOverflow;
    final dockWidth = math.min(math.max(contentWidth, renderedWidth), maxWidth);

    return DockMetrics._(
      iconSize: iconSize,
      dockHeight: dockHeight,
      dockWidth: dockWidth,
      itemSpacing: itemSpacing,
      hPadding: hPadding,
      vPadding: vPadding,
      dividerMargin: dividerMargin,
      pillRadius: pillRadius,
      activeBackgroundGap: activeBackgroundGap,
      iconUnits: iconUnitsAll,
      infoUnits: effInfoUnits,
      dividerCount: dividerCount,
    );
  }

  // ── divider 可见性规则（KOS DockContainer.qml 的 `visible:` 绑定）──

  /// divider1(launchers|windows)：pinned 与未 pin 运行段同时非空才插。
  ///
  /// KOS: dock/DockContainer.qml:847-857 — `visible: pinnedCount > 0 &&
  /// windowCount > 0`（:856）；launcher/trash 不计入（是 pinned 段之前的
  /// 固定槽位）。与 AdaptiveMath.mjs:88 同式。
  static bool divider1Visible({
    required int pinnedCount,
    required int runningCount,
  }) => pinnedCount > 0 && runningCount > 0;

  /// divider2(windows|info)：有 info 槽且 pinned+window 计数非空才插。
  ///
  /// KOS: dock/DockContainer.qml:907-913 — `visible: hasInfo &&
  /// (pinnedCount + windowCount > 0)`（:912）；与 AdaptiveMath.mjs:89 同式。
  static bool divider2Visible({
    required bool hasInfo,
    required int pinnedCount,
    required int runningCount,
  }) => hasInfo && pinnedCount + runningCount > 0;

  /// divider3(info|tray)：trailing accessory 与「图标组或 info 任一非空」。
  ///
  /// KOS: dock/DockContainer.qml:951 `trailingAccessoryDividerVisible`
  /// （沿用既有 hasIcons = launcher/trash/条目任一非空的语义）。
  static bool divider3Visible({
    required bool hasTray,
    required bool hasInfo,
    required bool showLauncher,
    required bool showTrash,
    required int pinnedCount,
    required int runningCount,
  }) =>
      hasTray &&
      (hasInfo || showLauncher || showTrash || pinnedCount + runningCount > 0);

  // KosDockShell.build 每次新建 metrics——值相等时不能让
  // DockMetricsScope.updateShouldNotify 引用比较恒为 true 而全量重建
  // dependents，故按全部字段逐字段相等（字段均为 double/int，可 ==）。
  @override
  bool operator ==(Object other) =>
      other is DockMetrics &&
      other.iconSize == iconSize &&
      other.dockHeight == dockHeight &&
      other.dockWidth == dockWidth &&
      other.itemSpacing == itemSpacing &&
      other.hPadding == hPadding &&
      other.vPadding == vPadding &&
      other.dividerMargin == dividerMargin &&
      other.pillRadius == pillRadius &&
      other.activeBackgroundGap == activeBackgroundGap &&
      other.iconUnits == iconUnits &&
      other.infoUnits == infoUnits &&
      other.dividerCount == dividerCount;

  @override
  int get hashCode => Object.hash(
    iconSize,
    dockHeight,
    dockWidth,
    itemSpacing,
    hPadding,
    vPadding,
    dividerMargin,
    pillRadius,
    activeBackgroundGap,
    iconUnits,
    infoUnits,
    dividerCount,
  );
}

/// [DockMetrics] 的 InheritedWidget 下发：KosDockShell 顶层构造后经
/// [DockMetricsScope] 供给 DockIcon/DockControlIcon/divider/整行。
///
/// 独立宿主（单测直接挂 DockIconRow/DockIcon/DockControlIcon，不经
/// KosDockShell）无祖先 scope 时退回 [fallback]——用基准几何
/// （kDockBaseHeight/kDockIconSize）构造，与方案 C 之前的编译期常量
/// 等价，避免单测全体改写。
class DockMetricsScope extends InheritedWidget {
  const DockMetricsScope({
    required this.metrics,
    required super.child,
    super.key,
  });

  final DockMetrics metrics;

  /// 当前 metrics；无 scope 时返回基准 fallback（见类注释）。
  static DockMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockMetricsScope>()?.metrics ??
      fallback;

  /// 最近 scope；无祖先时 null（`dependOn` 语义同上）。
  static DockMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockMetricsScope>()?.metrics;

  /// 独立宿主回退：基准 metrics（iconSize=floor(42.857)=42、dockHeight=59
  /// ……），与旧编译期常量同量级。
  static final DockMetrics fallback = DockMetrics.fromWidth(
    // 不受宽度钳制的基准：给一个必然走「舒适」分支的可用宽。
    4096,
  );

  @override
  bool updateShouldNotify(DockMetricsScope oldWidget) =>
      oldWidget.metrics != metrics;
}

// ── TASK-03 窗口预览 popup + 右键菜单 ──────────────────────────────

/// 预览开启驻留延迟（ms）：hover 进图标 300ms 后才弹预览。
///
/// KOS: dock/DockAnimation.qml:93 `windowPreviewDelay: 300`；消费端
/// dock/DockIcon.qml:485-511（`previewDelay` Timer，`onEntered` restart）。
const Duration kDockPreviewDelay = Duration(milliseconds: 300);

/// 预览关闭防抖（ms）：指针离开图标→进入 popup 的交接窗口。
///
/// KOS: dock/DockAnimation.qml:96 `windowPreviewCloseDelay: 130`；
/// dock/DockIcon.qml:514-520（`previewCloseDelay` Timer）。
const Duration kDockPreviewCloseDelay = Duration(milliseconds: 130);

/// 预览入场前 1 帧预滚延迟（ms）：防快速 hover 产生 blur 闪帧。
///
/// KOS: dock/DockWindowPreview.qml:130-138 `previewRevealStart interval: 16`。
const Duration kDockPreviewRevealStart = Duration(milliseconds: 16);

/// 预览入场时长（ms）：revealProgress 0→1，OutCubic（elementEnterEasing）。
///
/// KOS: dock/DockWindowPreview.qml:140-147 `previewEntrance duration: 120`；
/// easing 见 dock/DockAnimation.qml:71（standardEasing=OutCubic）。
const Duration kDockPreviewEntranceDuration = Duration(milliseconds: 120);

/// 预览退场时长（ms）：revealProgress→0，InCubic（elementExitEasing）。
///
/// KOS: dock/DockAnimation.qml:98 `windowPreviewExitDuration: 110`；
/// dock/DockWindowPreview.qml:158-173 `previewExit` + DockAnimation.qml:72。
const Duration kDockPreviewExitDuration = Duration(milliseconds: 110);

/// 关闭中重入的交接时长（ms）：exit 停掉后 30ms 回到 reveal 1。
///
/// KOS: dock/DockAnimation.qml:97 `windowPreviewHandoffDuration: 30`；
/// dock/DockWindowPreview.qml:149-156,533-539。
const Duration kDockPreviewHandoffDuration = Duration(milliseconds: 30);

/// 预览退场缩放下限：scale = 0.94 + 0.06×revealProgress（transformOrigin
/// 底部）。
///
/// KOS: dock/DockAnimation.qml:99 `windowPreviewExitScale: 0.94`；
/// dock/DockWindowPreview.qml:188-191。
const double kDockPreviewExitScale = 0.94;

/// 预览退场/入场下沉位移（px）：y = (1 − revealProgress) × 7。
///
/// KOS: dock/DockWindowPreview.qml:192-194 `Translate.y`。
const double kDockPreviewSink = 7;

/// popup 距图标顶部的间隙（px）：KOS anchor margins.top = −6。
///
/// KOS: dock/DockWindowPreview.qml:175-180（edges/gravity Top + margin −6）。
const double kDockPreviewGap = 6;

/// 预览卡宽（px）。
///
/// KOS: dock/DockWindowPreview.qml:50 `cardWidth: 174`。
const double kDockPreviewCardWidth = 174;

/// 预览卡高（px）。
///
/// KOS: dock/DockWindowPreview.qml:51 `cardHeight: 124`。
const double kDockPreviewCardHeight = 124;

/// popup 内边距（px，Column anchors.margins）。
///
/// KOS: dock/DockWindowPreview.qml:52 `rowPadding: 7`,215。
const double kDockPreviewRowPadding = 7;

/// 卡间距（px）。
///
/// KOS: dock/DockWindowPreview.qml:53 `rowSpacing: 6`。
const double kDockPreviewRowSpacing = 6;

/// popup 总高（px）：166 = padding14 + toolbar26 + spacing2 + card124。
///
/// KOS: dock/DockWindowPreview.qml:67 `implicitHeight: 166`。
const double kDockPreviewPopupHeight = 166;

/// popup 圆角（px；KOS 为 squircle 半径 14，退化为 circular）。
///
/// KOS: dock/DockWindowPreview.qml:195 `radius: 14`。
const double kDockPreviewPopupRadius = 14;

/// popup 最小宽下限 / 屏宽上限比：max(300, screenW×0.88)。
///
/// KOS: dock/DockWindowPreview.qml:60-63 `maxAllowedWidth`。
const double kDockPreviewMinPopupWidth = 300;
const double kDockPreviewMaxWidthRatio = 0.88;

/// 预览卡圆角（px）。
///
/// KOS: dock/DockWindowPreview.qml:327 `radius: 8`。
const double kDockPreviewCardRadius = 8;

/// 工具条行高（px）。
///
/// KOS: dock/DockWindowPreview.qml:221 `height: 26`。
const double kDockPreviewToolbarHeight = 26;

/// 预览工具条与卡行间距（px）。
///
/// KOS: dock/DockWindowPreview.qml:216 — `Column { spacing: 2 }`。
const double kDockPreviewToolbarGap = 2;

/// 「+」新建窗口按钮尺寸（px）。
///
/// KOS: dock/DockWindowPreview.qml:241-242 `width:34 height:26`。
const double kDockPreviewPlusWidth = 34;
const double kDockPreviewPlusHeight = 26;

/// 「+」按钮圆角（px）。
///
/// KOS: dock/DockWindowPreview.qml:244 `radius: 8`。
const double kDockPreviewPlusRadius = 8;

/// 缩略图区外边距（px）：top/left/right 6。
///
/// KOS: dock/DockWindowPreview.qml:352-354。
const double kDockPreviewThumbMargin = 6;

/// 缩略图区与标题间距（px）。
///
/// KOS: dock/DockWindowPreview.qml:359 `bottomMargin: 5`。
const double kDockPreviewThumbBottomGap = 5;

/// 预览内容圆角（px，thumbCrop radius）。
///
/// KOS: dock/DockWindowPreview.qml:383 `radius: 4`。
const double kDockPreviewThumbRadius = 4;

/// 卡标题外边距（px）。
///
/// KOS: dock/DockWindowPreview.qml:446 `anchors.margins: 7`。
const double kDockPreviewCardTitleMargin = 7;

/// hover 卡底色 alpha：KOS 白 0.10/黑 0.06 → textPrimary @0.08（语义折中）。
///
/// KOS: dock/DockWindowPreview.qml:332-333。
const double kDockPreviewCardHoverAlpha = 0.08;

/// 激活窗卡底色 alpha（accent tint，未 hover 时）。
///
/// KOS: dock/DockWindowPreview.qml:334-338 `accent…,0.16`。
const double kDockPreviewCardActiveAlpha = 0.16;

/// 「+」按钮 hover 底色/边线 alpha（accent @0.35/@0.65）；正常底色
/// textPrimary @0.08（KOS 白0.10/黑0.07 折中）、正常边线 hairline。
///
/// KOS: dock/DockWindowPreview.qml:245-251。
const double kDockPreviewPlusHoverAlpha = 0.35;
const double kDockPreviewPlusHoverBorderAlpha = 0.65;
const double kDockPreviewPlusBgAlpha = 0.08;

/// 菜单/预览 popup 的开/关时长与入场几何（ACCEPTANCE 视觉对齐：150ms
/// OutCubic 开 / 140ms InCubic 关 + scale 0.96→1 + ~20px 位移）。
///
/// KOS: common/AppearanceTokens.qml:514-517 — `popupOpenDuration: 150`、
/// `popupCloseDuration: 140`、`popupStartScale: 0.96`、
/// `popupAnchorOffset: 20`；KOS: common/PopupMotion.qml:11-12（两个时长即
/// `openDuration`/`closeDuration`）、:45-50（开 OutCubic / 关 InCubic）。
const Duration kDockMenuOpenDuration = Duration(milliseconds: 150);
const Duration kDockMenuCloseDuration = Duration(milliseconds: 140);
const double kDockMenuEnterScale = 0.96;
const double kDockMenuEnterOffset = 20;

/// 菜单面板圆角/内边距/项高（px）。
// Denial-invented: KOS 右键菜单是 Plasma 原生 ContextMenu（无独立几何
// 常量）；数值取 taskbar `_buildMenu` 同量级玻璃菜单风格。
const double kDockMenuRadius = 10;
// Denial-invented: 同上，KOS 无菜单内边距 token。
const double kDockMenuPadding = 6;
// Denial-invented: 同上（32px 项高，与 taskbar 菜单行一致）。
const double kDockMenuItemHeight = 32;
// Denial-invented: 同上（图标/文字左右留白 10px）。
const double kDockMenuItemHPadding = 10;
// Denial-invented: 同上（最短标签下菜单仍 ≥160px 才不显窄条）。
const double kDockMenuMinWidth = 160;
// Denial-invented: 菜单行几何（KOS Plasma 菜单无对应常量）：行圆角 6、
// 行内图标 16、图标与文字间距 8、字号 13、hover 底 textPrimary@0.08。
const double kDockMenuItemRadius = 6;
const double kDockMenuItemIconSize = 16;
const double kDockMenuItemIconGap = 8;
const double kDockMenuItemFontSize = 13;
const double kDockMenuItemHoverAlpha = 0.08;

// Denial-invented: KOS popup 是独立 PopupWindow（无屏内 clamp 概念）；
/// 菜单/预览距屏幕边安全边距（px）。
const double kDockPopupEdgeMargin = 8;

// ── TASK-04 启动器 / 垃圾桶 / 清空确认弹窗 ───────────────────────────

/// 启动器/垃圾桶菜单项文案（KOS DockContainer.qml:383-386
/// `setItems([{folder-open, "打开回收站", open}, {user-trash, "清空回收站",
/// empty}])`；launcher 无菜单，display-mode 菜单砍掉）。
const String kDockTrashMenuOpenLabel = '打开回收站';
const String kDockTrashMenuEmptyLabel = '清空回收站';

/// 确认弹窗几何（KOS: common/DesktopConfirmDialog.qml:37-44 —— 内容宽
/// `min(340, popup.width - 44)`；DockTrashConfirmPopup.qml:4-9 只覆写
/// busy/enabled/onAccepted）。
const double kDockConfirmWidth = 340;
const double kDockConfirmScreenInset = 44;

/// 确认弹窗面板圆角（KOS `KosFloatPanel` 玻璃面板半径；Dock 预览/菜单
/// 同量级 14，squircle 退化为 circular）。
const double kDockConfirmRadius = 14;

/// 顶部 icon 圆底：58px 圆、底 textPrimary@0.08、边 @0.34、中心 28px 图标
/// （KOS: DesktopConfirmDialog.qml:52-77）。
const double kDockConfirmCircleSize = 58;
const double kDockConfirmCircleFillAlpha = 0.08;
const double kDockConfirmCircleBorderAlpha = 0.34;
const double kDockConfirmIconSize = 28;

/// 内容节奏（px）：顶部 20 → 圆 58 → 12 → 标题 → 4 → 正文 → 22 → 按钮行
/// → 底部 16（KOS: DesktopConfirmDialog.qml:50,80,87,104,177）。
const double kDockConfirmTopPadding = 20;
const double kDockConfirmGapAfterCircle = 12;
const double kDockConfirmGapAfterTitle = 4;
const double kDockConfirmGapBeforeButtons = 22;
const double kDockConfirmBottomPadding = 16;

/// 标题/正文字号（px，KOS: DesktopConfirmDialog.qml:82-102：
/// `17 Bold` + `13` 次级色）。
const double kDockConfirmTitleSize = 17;
const double kDockConfirmBodySize = 13;

/// 标题/正文左右内边距（px）：KOS `dialogContent.sidePadding`（标题
/// DesktopConfirmDialog.qml:80-87、正文 :94-95）。
///
/// KOS: common/DesktopConfirmDialog.qml:42（`sidePadding: 24`）。
const double kDockConfirmSidePadding = 24;

/// 正文行高倍数（KOS: common/DesktopConfirmDialog.qml:101
/// `lineHeight: 1.16`）。
const double kDockConfirmBodyLineHeight = 1.16;

/// 按钮行：34 高、radius 17、左右 margin 16、间距 8、各半宽；按钮底色
/// textPrimary@0.08（KOS `contentControlFill`），字号 13 DemiBold
/// （KOS: DesktopConfirmDialog.qml:108-173）。
const double kDockConfirmButtonHeight = 34;
const double kDockConfirmButtonMargin = 16;
const double kDockConfirmButtonSpacing = 8;
const double kDockConfirmButtonFillAlpha = 0.08;
const double kDockConfirmButtonFontSize = 13;

/// busy 态确认色 alpha（KOS: DesktopConfirmDialog.qml:158-159
/// `Qt.rgba(1.0,0.23,0.19,0.55)` → performanceBad@0.55）。
const double kDockConfirmBusyAlpha = 0.55;

/// 确认弹窗文案（KOS: DesktopConfirmDialog.qml:9-12 + DockTrashConfirmPopup.qml）。
const String kDockConfirmTitle = '确定要清空回收站吗？';
const String kDockConfirmBody = '所有项目都将被永久删除。\n此操作无法撤销。';
const String kDockConfirmCancelLabel = '取消';
const String kDockConfirmEmptyLabel = '清空回收站';
const String kDockConfirmBusyLabel = '正在处理…';

// ── TASK-05 信息卡区（carousel：clock/weather/metrics/music） ────────────

/// 自动轮播间隔：KOS `carouselTimer` 30s（autoRotate && !expanded &&
/// availablePageCount>1；KOS 的 `running:` **无 hover 项**——hover 暂停是
/// 本端按任务卡要求新增的偏差，记 docs/visual-deltas.md）。
///
/// KOS: dock/DockInfoCarousel.qml:205-213。
const Duration kDockInfoCarouselInterval = Duration(seconds: 30);

/// 切页横向滑动时长（x 位移 ±cardWidth）。
///
/// KOS: dock/DockInfoCarousel.qml:332（`x` Behavior 260ms OutCubic）。
const Duration kDockInfoPageSlideDuration = Duration(milliseconds: 260);

/// 切页透明度时长。
///
/// KOS: dock/DockInfoCarousel.qml:333（`opacity` Behavior 220ms OutCubic）。
const Duration kDockInfoPageFadeDuration = Duration(milliseconds: 220);

/// 滚轮切页冷却（wheel handler debounce）。
///
/// KOS: dock/DockInfoCarousel.qml:215-235（wheelCooldown 180ms + MouseArea
/// onWheel）；KOS 方向 `delta>=0?-1:1`（:231）本端取反（deltaY>0 → 下一页，
/// 记 docs/visual-deltas.md）。
const Duration kDockInfoWheelCooldown = Duration(milliseconds: 180);

/// hover 打开详情 popup 的 dwell 延迟 / 指针移出后的关闭延迟。
///
/// KOS: dock/DockInfoCarousel.qml:279-312（openTimer 420ms / closeTimer
/// 260ms；DockMusicPlayer.qml:88-107 同节奏经 DockMusicPopup）。
const Duration kDockInfoPopupOpenDelay = Duration(milliseconds: 420);
const Duration kDockInfoPopupCloseDelay = Duration(milliseconds: 260);

/// DockInfoPopup 面板宽/行高/圆角（px）。
///
/// KOS: dock/DockInfoPopup.qml:27-28（width 288 / rowHeight 26）、
/// :132（radius 18）、:140-148（padding 16/12、spacing 6）、:150-215
/// （标题 14 DemiBold + 分隔线 + 行 label 12@0.62 / value 13 DemiBold）。
const double kDockInfoPopupWidth = 288;
const double kDockInfoPopupRowHeight = 26;
const double kDockInfoPopupRadius = 18;
const double kDockInfoPopupPaddingH = 16;
const double kDockInfoPopupPaddingV = 12;
const double kDockInfoPopupRowSpacing = 6;
const double kDockInfoPopupTitleSize = 14;
const double kDockInfoPopupLabelSize = 12;
const double kDockInfoPopupValueSize = 13;
const double kDockInfoPopupLabelAlpha = 0.62;

/// DockInfoPopup 锚定偏移：面板底边贴 carousel 槽顶 −12px。
///
/// KOS: dock/DockInfoPopup.qml:34-39（`anchor.margins.top: -12`；
/// DockWindowPreview.qml:215 用 `anchors.margins: preview.rowPadding`
/// 同式，取值由面板 padding 决定）。
const double kDockInfoPopupGap = 12;

/// DockInfoPopup 高公式：标题 + 分隔线 + rows*rowHeight + 上下 padding。
///
/// KOS: dock/DockInfoPopup.qml:28 + :140-148 — `height = rowCount*26 + 62`
/// （62 = title 18 + divider 1 + 2*12 padding + spacing 6 + 尾部 13）。
const double kDockInfoPopupBaseHeight = 62;

/// carousel 槽宽相对 iconSize 的外延比：`widthUnits*iconSize + iconSize*0.2`
/// 中 cardGap=iconSize*0.2 是卡背相对内容的左右外延。
///
/// KOS: dock/DockInfoCarousel.qml:56（`iconSize*widthUnits + iconSize*0.2`）。
const double kDockInfoCardGapRatio = 0.2;

/// carousel 槽高比：`iconSize*1.2` 容纳卡背上下外延。
///
/// KOS: dock/DockInfoCarousel.qml:57（`height: iconSize * 1.2`）。
const double kDockInfoSlotHeightRatio = 1.2;

/// 卡背圆角比：squircle → `BorderRadius.circular(iconSize*0.35)` 退化
/// （记 docs/visual-deltas.md）。
///
/// KOS: 四张卡背的 `radius: iconSize * 0.35`（dock/DockClockWidget.qml:102、
/// DockWeatherWidget.qml:50、DockTemperatureWidget.qml:53、
/// DockMusicPlayer.qml:135）。
const double kDockInfoCardRadiusRatio = 0.35;

/// 时钟卡紧凑阈值：iconSize<32 单行 `HH:mm · 日落`。
///
/// KOS: dock/DockClockWidget.qml（`compact: iconSize < 32` :22、compact 行
/// :272-306）。
const double kDockClockCompactThreshold = 32;

/// 时钟主行字号比 / 日期行字号比 / 最低主字号。
///
/// KOS: dock/DockClockWidget.qml — HH:mm:ss `iconSize*0.43` DemiBold 下限 16；
/// `yyyy年M月d日 周X` `iconSize*0.21` Medium @0.82。
const double kDockClockTimeFontRatio = 0.43;
const double kDockClockDateFontRatio = 0.21;
const double kDockClockDateAlpha = 0.82;
const double kDockClockTimeMinFont = 16;

/// 音乐卡紧凑阈值：iconSize<36 时封面叠播停钮 + 单行滚动 metadata。
///
/// KOS: dock/DockMusicPlayer.qml:31（`isCompact = iconSize < 36`）。
const double kDockMusicCompactThreshold = 36;

/// 音乐卡竖向内边距：`round(iconSize*0.25)`。
///
/// KOS: dock/DockMusicPlayer.qml:30 — vPadding = round(iconSize*0.25)。
const double kDockMusicVPaddingRatio = 0.25;

/// 音乐控制钮尺寸（px）：prev/next 24、play 27。
///
/// KOS: common/MediaControlButton.qml / dock/DockMusicPlayer.qml:392-397 —
/// prev/next ~24px、play ~27px 圆形钮。
const double kDockMusicNavButtonSize = 24;
const double kDockMusicPlayButtonSize = 27;

/// 音乐卡 full marquee 节奏（KOS `trackScroll`）：停留 1200ms → 线性滚动
/// `max(900, 溢出px*35)`ms → 停留 800ms → 归零。
///
/// KOS: dock/DockMusicPlayer.qml:259-282（PauseAnimation 1200ms /
/// NumberAnimation Linear / PauseAnimation 800ms 的循环）。
const int kDockMusicMarqueePauseStartMs = 1200;
const int kDockMusicMarqueePauseEndMs = 800;
const double kDockMusicMarqueeMinDurationMs = 900;
const double kDockMusicMarqueeSpeed = 35;

/// 音乐卡 compact marquee 节奏（KOS `compactTrackScroll`）：停留 900ms →
/// 线性滚动 `max(800, 溢出px*32)`ms → 停留 650ms → 归零。
///
/// KOS: dock/DockMusicPlayer.qml:356-379。
const int kDockMusicCompactMarqueePauseStartMs = 900;
const int kDockMusicCompactMarqueePauseEndMs = 650;
const double kDockMusicCompactMarqueeMinDurationMs = 800;
const double kDockMusicCompactMarqueeSpeed = 32;

/// metrics 三环半径比（外 CPU / 中 memory / 内 storage）与环宽比。
///
/// KOS: dock/DockTemperatureWidget.qml:203（环宽）、:219-221（半径
/// 0.39/0.285/0.18）。
const double kDockMetricsRingOuterRatio = 0.39;
const double kDockMetricsRingMidRatio = 0.285;
const double kDockMetricsRingInnerRatio = 0.18;
const double kDockMetricsRingWidthRatio = 0.075;
const double kDockMetricsRingMinWidth = 2.4;

/// metrics 三环字面色（KOS 语义环色，任务卡批准保留字面 + 注释行号）。
///
/// KOS: dock/DockTemperatureWidget.qml:219-221 — 外环 CPU `#ff375f`、
/// 中环 memory `#30d158`、内环 storage `#64d2ff`（同 accent 点
/// `#64d2ff`/#ff6b62 的温度行配色族）。
const int kDockMetricsRingCpuColor = 0xffff375f;
const int kDockMetricsRingMemoryColor = 0xff30d158;
const int kDockMetricsRingStorageColor = 0xff64d2ff;

/// metrics 温度行 accent 点色：均值行 `#64d2ff` / 峰值行 `#ff6b62`
/// （KOS 字面色；经语义映射走 shellTheme accent / performanceBad，见
/// metrics_card.dart）。
///
/// KOS: dock/DockTemperatureWidget.qml:115,117 温度行 accent 点。
const int kDockMetricsTempPeakColor = 0xffff6b62;

// ── TASK-06 托盘区（trailing accessory：托盘项 + 状态格） ────────────────

/// 托盘内图标边长（px）：KOS dockHosted 实例 `SysTray.iconSize: 18`
/// （BarStatusArea.qml:221-227）；宿主 `buildSystemTray` 实际画 22px 按钮，
/// 本常量只作为 itemSize 的 KOS 主源参与推导。
///
/// KOS: bar/SysTray.qml:12 — `iconSize: 18`。
const double kDockTrayIconSize = 18;

/// 托盘格边长（px）：KOS `SysTray.itemSize = iconSize + 8 = 26`
/// （估宽与格体槽宽共用）。
///
/// KOS: bar/SysTray.qml:32 — `itemSize: iconSize + 8`。
const double kDockTrayItemSize = kDockTrayIconSize + 8;

/// 托盘格间距（px）：KOS `SysTray.iconSpacing`（格间 + 换行列距共用）。
///
/// KOS: bar/SysTray.qml:13 — `iconSpacing: 6`；宿主 wrap 实现固定
/// spacing/runSpacing=8，折行时的间距偏差记 docs/visual-deltas.md。
const double kDockTrayIconSpacing = 6;

/// 折两行判定需要的可用高（px）：`itemSize * 2 = 52`。
///
/// KOS: bar/SysTray.qml:74-77 — `twoRowThreshold: itemSize * 2`、
/// `twoRows: dockHosted && itemCount > 1 && availableHeight >= twoRowThreshold`。
const double kDockTrayTwoRowThreshold = kDockTrayItemSize * 2;

/// 状态格内图标边长（px）：`systemTray.iconSize + 3 = 21`（network/battery 等
/// 细线格在共享托盘格内多给 3px 空间）——不做常量：格体槽宽 = `kDockTrayItemSize`
/// （KOS `SysTray.qml:503-504` `width: slotWidth`），图标 21px 数值只出现在
/// 电量格外框推导注释里。
///
/// KOS: bar/BarStatusArea.qml:115,144 — `iconSize: systemTray.iconSize + 3`。

/// 电量格外框宽/高（px）：`max(12, iconSize-2) × max(8, round(iconSize*0.56))`
/// → 19×12（iconSize 为格内图标边长 21）。
///
/// KOS: bar/Battery.qml:43-44 — outline `width: Math.max(12, iconSize - 2)`、
/// `height: Math.max(8, Math.round(iconSize * 0.56))`。
const double kDockBatteryOutlineWidth = 19;
const double kDockBatteryOutlineHeight = 12;

/// 电量格外框圆角 / 描边宽（px）。
///
/// KOS: bar/Battery.qml:45,48 — `radius: 3`、`border.width: 1.5`。
const double kDockBatteryOutlineRadius = 3;
const double kDockBatteryOutlineBorder = 1.5;

/// 电量格电极宽/高与圆角（px）：`max(1.5, iconSize-outline.width)` ×
/// `max(3, iconSize*0.20)`，radius 1 → 2×4.2。
///
/// KOS: bar/Battery.qml:58-60。
const double kDockBatteryTipWidth = 2;
const double kDockBatteryTipHeight = 4.2;
const double kDockBatteryTipRadius = 1;

/// 电量格填充内缩/最小宽/圆角（px）：leftMargin 2、填充 `max(2,
/// (outline.width-4)*level)` × `outline.height-4`，radius 2。
///
/// KOS: bar/Battery.qml:64-76。
const double kDockBatteryFillInset = 2;
const double kDockBatteryFillMinWidth = 2;
const double kDockBatteryFillRadius = 2;

/// 充电「⚡」字号（px）：`max(7, iconSize*0.44)` ≈ 9.24。
///
/// KOS: bar/Battery.qml:78-84 — `font.pixelSize: Math.max(7, iconSize*0.44)`。
const double kDockBatteryBoltFontSize = 9.24;

/// 电量格状态色阈值：fillColor 分档 >95 / ≥50 / ≥15 / <15。
///
/// KOS: bar/Battery.qml:111-121 — `percent > 95 ? #30d158 : >= 50 ? 前景
/// : >= 15 ? #ff9f0a : #ff453a`。
const int kDockBatteryFullThreshold = 95;
const int kDockBatteryMidThreshold = 50;
const int kDockBatteryLowThreshold = 15;

/// 电量格 KOS 字面状态色（**不**走 shellTheme 语义映射——用户要求严格对齐
/// KOS 视觉效果：>95 绿 `#30d158`、15–49 橙 `#ff9f0a`、<15 红 `#ff453a`、
/// 其余档=前景 `textPrimary`）。KOS `IconAppearanceService` tint 分支不移植
/// （Denial 无图标外观服务）；字面色是 KOS 设计原色，记 docs/visual-deltas.md。
///
/// KOS: bar/Battery.qml:113,117-118。
const int kDockBatteryFullColor = 0xff30d158;
const int kDockBatteryWarnColor = 0xffff9f0a;
const int kDockBatteryCritColor = 0xffff453a;

// ── TASK-08 托盘 Wi-Fi / 蓝牙状态格 + 弹层面板 ──────────────────────────

/// Wi-Fi/蓝牙格内图标边长（px）：KOS `NetworkStatus.qml` 格内 `iconSize: 18`
/// （格点击面 23×20，本端格体槽宽仍走 [kDockTrayItemSize] 26 与托盘格一致）。
///
/// KOS: bar/NetworkStatus.qml:19 — `iconSize: 18`。
const double kDockStatusCellIconSize = 18;

/// Wi-Fi 格 busy 态降透明度：KOS toggle 进行中 opacity .55（开关球同值）。
///
/// KOS: bar/NetworkPanel.qml:269,286 — `wifiToggleInProgress → opacity .55`。
const double kDockWifiBusyOpacity = 0.55;

/// Wi-Fi 格图标透明度（无 busy）：KOS `statusIconOpacity × (connected ? 0.96
/// : 0.68)`（`statusIconOpacity` 属 IconAppearanceService，本端恒 1）。
///
/// KOS: bar/NetworkStatus.qml:65。
const double kDockWifiCellConnectedAlpha = 0.96;
const double kDockWifiCellIdleAlpha = 0.68;

/// WifiSignalIcon 底层全弧 alpha（enabled 0.22 / disabled 0.16）。
///
/// KOS: bar/WifiSignalIcon.qml:51 — `wifiEnabled ? 0.22 : 0.16`。
const double kDockWifiGlyphBaseAlphaOn = 0.22;
const double kDockWifiGlyphBaseAlphaOff = 0.16;

/// WifiSignalIcon 顶层点亮 alpha（connected 1.0 / 未连接 0.52）。
///
/// KOS: bar/WifiSignalIcon.qml:57-58。
const double kDockWifiGlyphLitAlpha = 1.0;
const double kDockWifiGlyphTopAlpha = 0.52;

/// WifiSignalIcon 关闭斜杠 alpha 与 20px 逻辑画布线宽。
///
/// KOS: bar/WifiSignalIcon.qml:16（`lineWidth: 1.55`）,:65（斜线 .72）。
const double kDockWifiGlyphSlashAlpha = 0.72;
const double kDockWifiGlyphLineWidth = 1.55;

/// WifiSignalIcon 格图标分档阈值：<30→1 弧、<60→2 弧、≥60→3 弧。
///
/// KOS: bar/WifiSignalIcon.qml:17-19。
const int kDockWifiLevel1Max = 30;
const int kDockWifiLevel2Max = 60;

/// Wi-Fi 面板行内信号弧分档阈值：<25→1 弧、<50→2 弧、≥50→3 弧（**与格图标
/// 档 <30/<60 不同**，勿混用 [kDockWifiLevel1Max]/[kDockWifiLevel2Max]）。
///
/// KOS: bar/NetworkPanel.qml:454-455 — `signalStrength < 25 ? 1 :
/// (signalStrength < 50 ? 2 : 3)`。
const int kDockWifiRowLevel1Max = 25;
const int kDockWifiRowLevel2Max = 50;

/// Wi-Fi 面板宽/高/圆角（px，KOS squircle r19 退化 circular）。
///
/// KOS: bar/NetworkPanel.qml:36-38（310×365）、:213（LiquidGlassPanel
/// radius 19）、:69（blurRadius = clamp(1,19,155) = 19）。
const double kDockWifiPanelWidth = 310;
const double kDockWifiPanelHeight = 365;
const double kDockWifiPanelRadius = 19;

/// 蓝牙面板宽/高/圆角（px，KOS squircle r20 退化 circular）。
///
/// KOS: bar/BluetoothPanel.qml:19-20（300×340）、:91（radius 20）、
/// :47（blurRadius = clamp(1,20,150) = 20）。
const double kDockBluetoothPanelWidth = 300;
const double kDockBluetoothPanelHeight = 340;
const double kDockBluetoothPanelRadius = 20;

/// 面板与格间距（px）：bottom dock `margins.top` 负值上推 —— Wi-Fi −8、
/// 蓝牙 −6；tooltip 同蓝牙 −6。
///
/// KOS: bar/NetworkPanel.qml:54-55（-8）、bar/BluetoothPanel.qml:31-34（-6）、
/// bar/StatusTooltip.qml:35（-6）。
const double kDockWifiPanelGap = 8;
const double kDockBluetoothPanelGap = 6;
const double kDockStatusTooltipGap = 6;

/// 面板内容外边距/列表内边距（px）：KOS Column `anchors.margins: 10`、
/// ListView `left/right/top 8, bottom 0`、行 spacing 2。
///
/// KOS: bar/NetworkPanel.qml:226-229,412-417；bar/BluetoothPanel.qml:103-106。
const double kDockStatusPanelMargin = 10;
const double kDockStatusListMargin = 8;
const double kDockStatusRowSpacing = 2;

/// 列表行高/行圆角/hover 填充 alpha/渐变色时长。
///
/// KOS: bar/NetworkPanel.qml:421-428（行 46 r10，hover rgba(1,1,1,.12) 110ms
/// ColorAnimation）；bar/BluetoothPanel.qml:109-115（行 46 r11 同式）。
const double kDockStatusRowHeight = 46;
const double kDockStatusRowRadius = 10;
const double kDockBluetoothRowRadius = 11;
const double kDockStatusRowHoverAlpha = 0.12;
const Duration kDockStatusRowHoverDuration = Duration(milliseconds: 110);

/// 列表行内图标/文字槽位（px）：✓ 19px 左 8；wifi 弧 24×24 左 32；锁 8×11
/// 紧随弧右 +1；SSID 12px DemiBold，左边距有锁 73 / 无锁 64、右边距 12。
///
/// KOS: bar/NetworkPanel.qml:429-510。
const double kDockWifiRowCheckSize = 19;
const double kDockWifiRowGlyphLeft = 32;
const double kDockWifiRowGlyphSize = 24;
const double kDockWifiRowLockGap = 1;
const double kDockWifiRowLockWidth = 8;
const double kDockWifiRowLockHeight = 11;
const double kDockWifiRowLabelLeftLocked = 73;
const double kDockWifiRowLabelLeft = 64;
const double kDockWifiRowLabelRight = 12;
const double kDockStatusRowFontSize = 12;

/// 蓝牙行内槽位（px）：✓ 18px 左 8、BT glyph 18×18 左 31、名称左 58 右 12。
///
/// KOS: bar/BluetoothPanel.qml:116-141。
const double kDockBluetoothRowCheckSize = 18;
const double kDockBluetoothRowGlyphLeft = 31;
const double kDockBluetoothRowGlyphSize = 18;
const double kDockBluetoothRowLabelLeft = 58;

/// 面板列表卡填充/边线 alpha（KOS `rgba(1,1,1,.08)` 填 + `rgba(0.74,0.95,1,
/// .28)` 边 → 语义色 textPrimary/hairlineSoft 近似，映射记 deltas）。
///
/// KOS: bar/NetworkPanel.qml:393-399。
const double kDockStatusCardFillAlpha = 0.08;

/// 面板空态字号/透明度（「正在扫描…」/「未发现可用 Wi-Fi」/「蓝牙已关闭」等）。
///
/// KOS: bar/NetworkPanel.qml:519-536；bar/BluetoothPanel.qml:151-176
/// （12px、opacity .5/.52——取 .5 统一，记 deltas）。
const double kDockStatusEmptyFontSize = 12;
const double kDockStatusEmptyAlpha = 0.5;

/// 面板底脚高/分隔线 alpha/左边距/字号。
///
/// KOS: bar/NetworkPanel.qml:541-564（50px、1px rgba(1,1,1,.16)、left 18、
/// 14px DemiBold）；bar/BluetoothPanel.qml:179-201 同式。
const double kDockStatusFooterHeight = 50;
const double kDockStatusFooterDividerAlpha = 0.16;
const double kDockStatusFooterLabelLeft = 18;
const double kDockStatusFooterFontSize = 14;

/// Wi-Fi 面板头行开关球尺寸/圆角（32×32 r16，toggle 中 opacity .55 见
/// [kDockWifiBusyOpacity]）。
///
/// KOS: bar/NetworkPanel.qml:260-294（32×32 radius 16）。
const double kDockWifiToggleSize = 32;

/// Wi-Fi 面板头行标题字号（KOS 停用头行的「Wi-Fi」16px Bold，本端启用行
/// 保留同字号）。
///
/// KOS: bar/NetworkPanel.qml:236-247。
const double kDockWifiPanelTitleSize = 16;

/// StatusTooltip 规格（KOS `bar/StatusTooltip.qml`）：黑底 r7、内边距
/// h9/v6（`implicitWidth = max(minimumWidth, 内容宽+18)` / `+12`）、行距 3、
/// 12px DemiBold 主行 + 10px Medium 副行、minimumWidth 150。
///
/// KOS: bar/StatusTooltip.qml:23-24,41-63；NetworkStatus.qml:105。
const double kDockStatusTooltipRadius = 7;
const double kDockStatusTooltipPaddingH = 9;
const double kDockStatusTooltipPaddingV = 6;
const double kDockStatusTooltipRowGap = 3;
const double kDockStatusTooltipPrimarySize = 12;
const double kDockStatusTooltipSecondarySize = 10;
const double kDockStatusTooltipMinWidth = 150;

/// Wi-Fi 加入/密码弹层宽/高上限与屏边距（px）：宽 min(420, w−44)、高
/// min(292, h−40)（v1 只做非 enterprise 分支，292 一档）。
///
/// KOS: bar/NetworkPanel.qml:588-594。
const double kDockWifiDialogWidth = 420;
const double kDockWifiDialogScreenInset = 44;
const double kDockWifiDialogHeight = 292;
const double kDockWifiDialogHeightInset = 40;

/// 密码弹层内部节奏（px）：取消/确认环 30×30 位 margin 13/12；logo 弧 58×48
/// top 43；标题 18px Bold、说明 14px、框 r14、错误行 12px。
///
/// KOS: bar/NetworkPanel.qml:606-625,627-641,653-666,724-804,872-879。
const double kDockWifiDialogRingSize = 30;
const double kDockWifiDialogRingMarginH = 13;
const double kDockWifiDialogRingMarginTop = 12;
const double kDockWifiDialogGlyphWidth = 58;
const double kDockWifiDialogGlyphHeight = 48;
const double kDockWifiDialogGlyphTop = 43;
const double kDockWifiDialogSidePadding = 22;
const double kDockWifiDialogTitleSize = 18;
const double kDockWifiDialogBodySize = 14;
const double kDockWifiDialogFieldHeight = 42;
const double kDockWifiDialogFieldRadius = 14;
const double kDockWifiDialogErrorSize = 12;

/// 密码框聚焦蓝边 alpha（KOS `rgba(0.15,0.52,1,.80)` → accent 同 alpha）。
///
/// KOS: bar/NetworkPanel.qml:731-732。
const double kDockWifiDialogFocusAlpha = 0.80;

/// Wi-Fi 列表行锁形钥匙孔 alpha（KOS `rgba(0,0,0,0.28)` 字面量——不是
/// shellTheme 角色：它是打在浅色锁体上的镂空点，用黑色低 alpha 而非前景色）。
///
/// KOS: bar/NetworkPanel.qml:486-489。
const double kDockWifiLockKeyholeAlpha = 0.28;

/// Wi-Fi 格图标纵向偏移（px）：KOS `anchors.verticalCenterOffset: 2`。
///
/// KOS: bar/NetworkStatus.qml:55-56。
const double kDockWifiCellIconOffsetY = 2;

// ── TASK-09 控制中心格 + 弹层面板 ──────────────────────────────────────

/// 控制中心格点击面（px）：KOS 24×24（格宽仍走 [kDockTrayItemSize] 26，
/// 与其它状态格一致）。
///
/// KOS: bar/ControlCenterToggle.qml:18-19 — `implicitWidth/Height: 24`。
const double kDockControlCenterCellSize = 24;

/// 控制中心格图标边长（px）。
///
/// KOS: bar/ControlCenterToggle.qml:16,25-26 — `iconSize: 18`。
const double kDockControlCenterIconSize = 18;

/// 控制中心格透明度：面板开 1.0 / 关 0.88。
///
/// KOS: bar/ControlCenterToggle.qml:31-33。
const double kDockControlCenterCellOpenOpacity = 1.0;
const double kDockControlCenterCellClosedOpacity = 0.88;

/// 控制中心格 scale：按下 0.90 / hover 1.06 / 常态 1（135ms OutCubic）。
///
/// KOS: bar/ControlCenterToggle.qml:34-35 —
/// `hoverArea.pressed ? 0.90 : containsMouse ? 1.06 : 1`，Behavior
/// `AppearanceTokens.motion.fastDuration`（135ms）OutCubic。
const double kDockControlCenterCellPressedScale = 0.90;
const double kDockControlCenterCellHoverScale = 1.06;
const Duration kDockControlCenterCellDuration = Duration(milliseconds: 135);

/// 控制中心格 tooltip：「控制中心」、最小宽 92、panelOpen 时不显示。
///
/// KOS: bar/ControlCenterToggle.qml:45-51。
const String kDockControlCenterTooltip = '控制中心';
const double kDockControlCenterTooltipMinWidth = 92;

/// 控制中心面板宽（px）。
///
/// KOS: bar/ControlCenterPanel.qml:139 — `controlCenterWidth: 336`。
const double kDockControlCenterPanelWidth = 336;

/// KOS 源面板高（px）；v1 无通知历史卡 → 紧凑重排（见
/// docs/visual-deltas.md TASK-09 节），实际容器高 = 最高子页 + 上下 20。
///
/// KOS: bar/ControlCenterPanel.qml:138 — `controlCenterHeight: 597`。
const double kDockControlCenterHeight = 597;

/// 面板内边距（px）：卡片 `offsetTop/offsetRight` 基准 20。
///
/// KOS: bar/ControlCenterPanel.qml:533-534,818-819（offsetTop 20 / offsetRight 20）。
const double kDockControlCenterMargin = 20;

/// 面板容器高（px）：最高子页（sound 420，KOS :1860）+ 上下 20。
/// 主页面与子页卡都**底对齐**容器（KOS dockHosted 子页
/// `offsetTop = height - 20 - cardHeight`，:1838-1840）。
const double kDockControlCenterBoxHeight = 460;

/// 面板与格间距（px）：任务卡要求同 Wi-Fi 面板 8px（KOS dockHosted
/// `margins.bottom: 0` 贴边，见 :50）。
const double kDockControlCenterPanelGap = 8;

/// 面板/卡圆角（px，squircle 退化 circular）。
///
/// KOS: bar/ControlCenterPanel.qml:1846（子页卡 glass baseRadius 22）、
/// :1137,:1206（亮度/音量条 19）、:535,:669（pill 29.5）、:820（媒体卡 25）。
const double kDockControlCenterRadius = 22;
const double kDockControlCenterBarRadius = 19;
const double kDockControlCenterPillRadius = 29.5;
const double kDockControlCenterMediaRadius = 25;

/// pill（Wi-Fi/蓝牙）几何（px）：137×59，左列 20，wifi top 20 / bt top 87。
///
/// KOS: bar/ControlCenterPanel.qml:533-537（wifiCard）、:667-671（bluetoothCard）；
/// 本端相对 top-left：`left = 336 - 179 - 137 = 20`。
const double kDockControlCenterPillWidth = 137;
const double kDockControlCenterPillHeight = 59;
const double kDockControlCenterColumnLeft = 20;
const double kDockControlCenterWifiTop = 20;
const double kDockControlCenterBluetoothTop = 87;

/// 媒体卡几何（px）：151×127，top 20、left `336-20-151 = 165`。
///
/// KOS: bar/ControlCenterPanel.qml:818-822。
const double kDockControlCenterMediaWidth = 151;
const double kDockControlCenterMediaHeight = 127;
const double kDockControlCenterMediaLeft = 165;
const double kDockControlCenterMediaTop = 20;

/// 亮度/音量条几何（px）：296×57。
///
/// KOS: bar/ControlCenterPanel.qml:1138-1139（亮度）、:1207-1208（音量）。
const double kDockControlCenterBarWidth = 296;
const double kDockControlCenterBarHeight = 57;

/// 亮度/音量条纵向坐标（px）：**紧凑重排**——KOS 为 217/282（:1135,:1204），
/// 中间 52px 胶囊卡与通知历史卡 v1 砍掉后上移补空（记 deltas）。
const double kDockControlCenterBrightnessTop = 155;
const double kDockControlCenterVolumeTop = 220;

/// 主页面紧凑内容高（px）：`220 + 57 + 20`。
const double kDockControlCenterMainHeight = 297;

/// pill 内部几何（px）：圆开关盘 39、左 10 居中；文字列 left 58 right 18；
/// 「›」right 8；整卡点击区（圆盘外）left 49 起。
///
/// KOS: bar/ControlCenterPanel.qml:544-545,620,638-642,651。
const double kDockControlCenterPillDiscSize = 39;
const double kDockControlCenterPillDiscLeft = 10;
const double kDockControlCenterPillTextLeft = 58;
const double kDockControlCenterPillTextRight = 18;
const double kDockControlCenterPillChevronRight = 8;
const double kDockControlCenterPillTapLeft = 49;

/// pill 字号/图标（px）：标题 12 Bold、副标题 10、「›」14 Bold、盘内图标 20。
///
/// KOS: bar/ControlCenterPanel.qml:626,634,642,557。
const double kDockControlCenterPillTitleSize = 12;
const double kDockControlCenterPillSubtitleSize = 10;
const double kDockControlCenterPillChevronSize = 14;
const double kDockControlCenterPillGlyphSize = 20;

/// pill 交互态：盘 toggle 中 opacity .55、卡不可用 alpha .48；卡 scale
/// 1.015/0.97、盘 scale 1.04/0.92。
///
/// KOS: bar/ControlCenterPanel.qml:531-532,549,551-554,665-666,673。
const double kDockControlCenterPillBusyOpacity = 0.55;
const double kDockControlCenterPillUnavailableAlpha = 0.48;
const double kDockControlCenterPillCardHoverScale = 1.015;
const double kDockControlCenterPillCardPressedScale = 0.97;
const double kDockControlCenterPillDiscHoverScale = 1.04;
const double kDockControlCenterPillDiscPressedScale = 0.92;

/// 媒体卡内部几何（px）：专辑图 43 r13 @(13,13)；文字列 art.right+8 / right 10；
/// 底部控制行 bottomMargin 15、间距 12；prev/next 32、play 40。
///
/// KOS: bar/ControlCenterPanel.qml:828-829,860-861,879-881,147-151。
const double kDockControlCenterMediaArtSize = 43;
const double kDockControlCenterMediaArtRadius = 13;
const double kDockControlCenterMediaArtLeft = 13;
const double kDockControlCenterMediaArtTop = 13;
const double kDockControlCenterMediaTextLeft = 8;
const double kDockControlCenterMediaTextRight = 10;
const double kDockControlCenterMediaControlsBottom = 15;
const double kDockControlCenterMediaControlsSpacing = 12;
const double kDockControlCenterMediaNavSize = 32;
const double kDockControlCenterMediaPlaySize = 40;

/// 媒体卡字号/占位（px）：标题 12 Bold、艺术家 10 @0.70、占位「♫」21 @0.86。
///
/// KOS: bar/ControlCenterPanel.qml:833-836,867,875。
const double kDockControlCenterMediaTitleSize = 12;
const double kDockControlCenterMediaArtistSize = 10;
const double kDockControlCenterMediaArtistAlpha = 0.70;
const double kDockControlCenterMediaPlaceholderSize = 21;
const double kDockControlCenterMediaPlaceholderAlpha = 0.86;

/// 亮度/音量条内部几何（px）：标题 left 14 / top 8；亮度右上「%/无亮度设备」
/// right 30（9px @0.50）、音量右上「%」right 14（10px @0.72）；
/// 「›」right 13 / top 5（15px）；顶部热区亮度 27 / 音量 26；
/// 滑条 left 31（亮度）/ 34（音量）right 31/17、bottom 8；
/// 「☀」/喇叭 glyph left 12 bottom 12（13/15px）。
///
/// KOS: bar/ControlCenterPanel.qml:1145-1175,1192-1196,1214-1272。
const double kDockControlCenterBarLabelLeft = 14;
const double kDockControlCenterBarLabelTop = 8;
const double kDockControlCenterBarLabelSize = 11;
const double kDockControlCenterBarValueSize = 9;
const double kDockControlCenterBarValueAlpha = 0.50;
const double kDockControlCenterBarValueRight = 30;
const double kDockControlCenterBarChevronSize = 15;
const double kDockControlCenterBarChevronRight = 13;
const double kDockControlCenterBarChevronTop = 5;
const double kDockControlCenterBrightnessHotZone = 27;
const double kDockControlCenterSoundHotZone = 26;
const double kDockControlCenterSoundValueSize = 10;
const double kDockControlCenterSoundValueAlpha = 0.72;
const double kDockControlCenterSoundValueRight = 14;
const double kDockControlCenterBrightnessSliderLeft = 31;
const double kDockControlCenterBrightnessSliderRight = 31;
const double kDockControlCenterVolumeSliderLeft = 34;
const double kDockControlCenterVolumeSliderRight = 17;
const double kDockControlCenterSliderBottom = 8;
const double kDockControlCenterBarGlyphLeft = 12;
const double kDockControlCenterBarGlyphBottom = 12;
const double kDockControlCenterBarGlyphAlpha = 0.65;
const double kDockControlCenterSunGlyphSize = 13;
const double kDockControlCenterVolumeGlyphSize = 15;

/// `DockControlCenterSlider` 规格（KOS `bar/ControlCenterSlider.qml` →
/// `shared/qml/controls/LiquidSlider.qml`）：高 30、track 4、thumb 白
/// 36×18 r9；glass 轨 `rgba(1,1,1,0.17)`/accent `rgba(1,1,1,0.42)`，
/// material 轨 surfaceVariant/accent primary。
///
/// KOS: bar/ControlCenterSlider.qml:12-23。
const double kDockControlCenterSliderHeight = 30;
const double kDockControlCenterTrackHeight = 4;
const double kDockControlCenterThumbWidth = 36;
const double kDockControlCenterThumbHeight = 18;
const double kDockControlCenterThumbRadius = 9;

/// glass 轨/进度 alpha（KOS `Qt.rgba(1,1,1,0.17)`/`0.42` → textPrimary 同
/// alpha 语义映射）。
///
/// KOS: bar/ControlCenterSlider.qml:18-21。
const double kDockControlCenterTrackAlpha = 0.17;
const double kDockControlCenterTrackAccentAlpha = 0.42;

/// 子页卡几何（px）：宽 296；高 wifi 360 / bt 340 / brightness 280 /
/// sound 420。
///
/// KOS: bar/ControlCenterPanel.qml:1853,1857-1860。
const double kDockControlCenterSubmenuWidth = 296;
const double kDockControlCenterWifiPageHeight = 360;
const double kDockControlCenterBluetoothPageHeight = 340;
const double kDockControlCenterBrightnessPageHeight = 280;
const double kDockControlCenterSoundPageHeight = 420;

/// 子页共用 header（px）：top 12、左右 12、高 28；返回钮 26×26 r13
/// （「‹」18 Bold）；标题 left 8、13 Bold；分隔线 top `header.bottom + 9`、
/// 左右 12。
///
/// KOS: bar/ControlCenterPanel.qml:1898-1930,1946,1954,2005-2013。
const double kDockControlCenterHeaderTop = 12;
const double kDockControlCenterHeaderSideMargin = 12;
const double kDockControlCenterHeaderHeight = 28;
const double kDockControlCenterBackSize = 26;
const double kDockControlCenterBackRadius = 13;
const double kDockControlCenterBackGlyphSize = 18;
const double kDockControlCenterTitleSize = 13;
const double kDockControlCenterTitleLeft = 8;
const double kDockControlCenterDividerTop = 9;

/// wifi/bt 子页右侧开关球（px）：38×22 r11、thumb 18 r9、内缩 2；
/// x 动画 160ms OutCubic、toggle 中 opacity .6。
///
/// KOS: bar/ControlCenterPanel.qml:1958-1998。
const double kDockControlCenterSwitchWidth = 38;
const double kDockControlCenterSwitchHeight = 22;
const double kDockControlCenterSwitchRadius = 11;
const double kDockControlCenterSwitchThumbSize = 18;
const double kDockControlCenterSwitchThumbInset = 2;
const double kDockControlCenterSwitchBusyOpacity = 0.6;
const Duration kDockControlCenterSwitchDuration = Duration(milliseconds: 160);

/// 子页列表/底脚几何（px）：行 42、底脚 38（11 DemiBold + 「›」）、
/// 列表左右 14。
///
/// KOS: bar/ControlCenterPanel.qml:2065-2066,2109,2375,2600-2616,2991-3011。
const double kDockControlCenterPageRowHeight = 42;
const double kDockControlCenterPageFooterHeight = 38;
const double kDockControlCenterPageFooterFontSize = 11;
const double kDockControlCenterPageListMargin = 14;

/// 亮度子页行高（px）：label 11 DemiBold + 「%」10 + 副行 9 + 滑条 bottom 3。
///
/// KOS: bar/ControlCenterPanel.qml:2549-2586。
const double kDockControlCenterBrightnessRowHeight = 82;

/// 声音子页几何（px）：主音量区 62（「主音量」11 + %10 + 19×16 喇叭 glyph、
/// 滑条高 28 left 26 right 2 bottom 4）；「输出设备」区 52（标题 10 @0.60 +
/// r10 设备框）；「应用音量」行 58（间距 3）r8、滑条高 27。
///
/// KOS: bar/ControlCenterPanel.qml:2648-2775,2788-2835,2870-2980。
const double kDockControlCenterVolumeSectionHeight = 62;
const double kDockControlCenterOutputSectionHeight = 52;
const double kDockControlCenterOutputRowRadius = 10;
const double kDockControlCenterAppRowHeight = 58;
const double kDockControlCenterAppRowGap = 3;
const double kDockControlCenterAppRowRadius = 8;
const double kDockControlCenterSectionTitleSize = 10;
const double kDockControlCenterSectionTitleAlpha = 0.60;
const double kDockControlCenterSubmenuVolumeSliderHeight = 28;
const double kDockControlCenterAppSliderHeight = 27;
const double kDockControlCenterSubmenuVolumeSliderLeft = 26;
const double kDockControlCenterSubmenuVolumeSliderRight = 2;
const double kDockControlCenterSubmenuVolumeSliderBottom = 4;
const double kDockControlCenterSubmenuGlyphWidth = 19;
const double kDockControlCenterSubmenuGlyphHeight = 16;

/// 应用音量行最多展示条数（KOS `audioApplications.slice(0, 3)`）。
///
/// KOS: bar/ControlCenterPanel.qml:2880。
const int kDockControlCenterAppRowCount = 3;

/// 子页导航 crossfade（KOS `common/PageMotion.qml` → enter =
/// `normalDuration` 200ms OutCubic、exit = `fastDuration`）：入场卡
/// scale 0.96→1、出场 1→0.96，入场内容位移 8px。
///
/// KOS: bar/ControlCenterPanel.qml:347-353,357-371；common/PageMotion.qml:4-5。
const Duration kDockControlCenterPageDuration = Duration(milliseconds: 200);
const double kDockControlCenterPageStartScale = 0.96;
const double kDockControlCenterPageOffset = 8;


/// pill busy 档（Wi-Fi/蓝牙）旋转弧（px/s）：21×21 画布、`r = w/2 − 1.5`、
/// lineWidth 2、扫 1.5π、900ms/圈；glyph/spinner 交叉淡入 140ms。
///
/// KOS: bar/ControlCenterPanel.qml:549-617（`wifiBusySpinner` / `wifiBusyArc`
/// / `RotationAnimation` 900ms）。
const double kDockControlCenterPillSpinnerSize = 21;
const double kDockControlCenterPillSpinnerInset = 1.5;
const double kDockControlCenterPillSpinnerStroke = 2;
const Duration kDockControlCenterBusySpinDuration = Duration(milliseconds: 900);
const Duration kDockControlCenterBusyFadeDuration = Duration(milliseconds: 140);

/// 应用音量行 hover 底 alpha（KOS 深色档 `rgba(1,1,1,.10)`，浅色档
/// `rgba(0,0,0,.055)` → 同式前景低 alpha 近似）。
///
/// KOS: bar/ControlCenterPanel.qml:2898-2903。
const double kDockControlCenterAppRowHoverAlpha = 0.10;

/// 面板打开期间的周期刷新（KOS `ControlCenterService`）：
/// `audioApplicationsTimer` 1.8s（:437-440）、`refreshTimer` 面板开 3s /
/// 关 120s（:428-433；本端面板只在开着时挂载 → 恒取 3s 档）。
const Duration kDockControlCenterAppRefreshInterval = Duration(
  milliseconds: 1800,
);
const Duration kDockControlCenterRefreshInterval = Duration(seconds: 3);
