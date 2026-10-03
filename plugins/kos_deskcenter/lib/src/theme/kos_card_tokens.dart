/// KOS DeskCenter 卡片视觉令牌。
///
/// 每个常量逐项抄自 NextKde 源码，注释格式 `文件:行号`；相对根为
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`。
///
/// TASK-09 起卡片表面（填充/描边/阴影）一律吃 Denial ShellTheme 材质
/// （`DeskCard` 经 `ShellBackdropBlur` + `Material` 由 `context.shellTheme`
/// 供色），卡片圆角默认取 `context.shellTheme.tileRadius`（可由
/// `DeskCard.cornerRadius` 覆盖）；源端手动近似的 tonal/glass 表面令牌、
/// 色艺渐变表与天气色板、花形轮廓参数、bloom 泛光全部删除。
library;

import 'dart:ui' show Color;

/// DeskCenter 卡片视觉令牌。所有取值来源见逐项注释。
abstract final class KosCardTokens {

  /// 栅格列数 10（DeskCenterWindow.qml:41）。
  static const int gridColumns = 10;

  /// 小部件可用列数 4（DeskCenterWindow.qml:42）。
  static const int widgetColumns = 4;

  /// 视觉侧外边距 20（DeskCenterWindow.qml:43）。
  static const double sideMargin = 20;

  /// 布局基准侧外边距 8（DeskCenterWindow.qml:47）。
  static const double layoutBaseSideMargin = 8;

  /// 布局基准间隙 10（DeskCenterWindow.qml:48）。
  static const double layoutBaseGap = 10;

  // ── 标题文字（DeskWidgetCard.qml:130-145）────────────────────────────────

  /// 标题左边距 18（DeskWidgetCard.qml:138）。
  static const double titleMarginLeft = 18;

  /// 标题顶边距 15（DeskWidgetCard.qml:139）。
  static const double titleMarginTop = 15;

  /// 标题字号 12（DeskWidgetCard.qml:143），字重 DemiBold（:144）。
  static const double titleFontSize = 12;

  // ── 编辑模式角标（DeskCenterWindow.qml:551-591）───────────────────────────

  /// 角标距卡缘 8（DeskCenterWindow.qml:554、572 `margins: 8`）。
  static const double badgeMargin = 8;

  /// 移除角标直径 26（:555 `width:26; height:26; radius:13`）。
  static const double removeBadgeSize = 26;

  /// 移除角标底色 #ff453a（:556）——语义警示色，保留源值。
  static const Color removeBadgeColor = Color(0xFFFF453A);

  /// 移除角标字符 "−"（U+2212，:559），白色（:560）18px Bold（:561）。
  static const double removeBadgeFontSize = 18;

  /// 尺寸循环角标高 26（:574）。
  static const double sizeBadgeHeight = 26;

  /// 尺寸角标水平内边距 8（宽 = 文本宽 + 16，:573）。
  static const double sizeBadgePaddingH = 8;

  /// 尺寸角标字号 10、DemiBold（:586）。
  static const double sizeBadgeFontSize = 10;

}
