/// KOS Dock 信息卡——时钟页（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/dock/DockClockWidget.qml`（行号在各段
/// 标注；紧凑阈值/字号比常量在 `dock_tokens.dart` TASK-05 区段）：
/// - full（iconSize≥32）：左列 60% 双行 `HH:mm:ss` + `yyyy年M月d日 周X`，
///   右列 40% 日落/日出两行（DockClockWidget.qml:123-270）；
/// - compact（iconSize<32）：单行 `glyph + HH:mm · 日落 --:--`（:272-306）。
///
/// 偏差（记 docs/visual-deltas.md）：
/// - iOS 玻璃字形（ambientTexture/FastBlur/glyphSheen OpacityMask，:144-204）
///   → `shellColors.textPrimary` 语义色；
/// - 卡背壁纸 ambient 渐变（:96-121）→ `panelGradient(panelBackground,
///   panelBackgroundBottom)`；
/// - `services.clock` 不 tick（fake 恒值）时由 carousel 经 `Timer.periodic(1s)`
///   自建驱动刷新 [DockClockCardData.now]。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/material.dart';

import '../../theme/dock_tokens.dart';

/// 时钟卡的即时数据（由 carousel 从 `services.clock` 快照组装传入，
/// 使卡体本身无 Provider 依赖、可在 pumpWidget 直接测试）。
final class DockClockCardData {
  const DockClockCardData({
    required this.now,
    this.sunrise = '--:--',
    this.sunset = '--:--',
  });

  /// 当前时刻（`services.clock` 的 DateTime；渲染 `HH:mm:ss` 与日期行）。
  final DateTime now;

  /// 日出/日落 `HH:mm`（来自天气 provider；无数据 `--:--`，
  /// KOS WeatherService.sunriseTime/sunsetTime 缺省同式）。
  final String sunrise;
  final String sunset;
}

/// KOS `DockClockWidget`（carousel 页）。尺寸 = `contentWidth +
/// backgroundGap*2` × `iconSize`（DockClockWidget.qml:20-25,96-121；
/// carousel 槽 clip 掉上下外延）。
class DockClockCard extends StatelessWidget {
  const DockClockCard({required this.data, super.key});

  final DockClockCardData data;

  /// KOS `shortWeekday`（DockClockWidget.qml:37-39；weekday 1=周一 → 索引
  /// `weekday % 7`，周日=0）。
  static const List<String> _weekdays = [
    '周日', '周一', '周二', '周三', '周四', '周五', '周六',
  ];

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `HH:mm:ss`（DockClockWidget.qml:210 `Qt.formatDateTime(clock.date,
  /// "HH:mm:ss")`）。
  static String timeText(DateTime now) =>
      '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';

  /// `HH:mm`（compact 行，DockClockWidget.qml:286 `minuteDate`）。
  static String shortTimeText(DateTime now) =>
      '${_two(now.hour)}:${_two(now.minute)}';

  /// `周X`（DockInfoPopup 详情行复用；DockClockWidget.qml:37-39 同表）。
  static String weekdayName(DateTime now) => _weekdays[now.weekday % 7];

  /// `yyyy年M月d日 周X`（DockClockWidget.qml:235-236）。
  static String dateText(DateTime now) =>
      '${now.year}年${now.month}月${now.day}日 ${weekdayName(now)}';

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    final backgroundGap = iconSize * 0.1; // KOS: DockClockWidget.qml:20
    final cardWidth = iconSize * metrics.infoUnits + backgroundGap * 2; // :24
    final compact = iconSize < kDockClockCompactThreshold; // :22

    return SizedBox(
      width: cardWidth,
      height: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 卡背：KOS ambient 壁纸渐变（DockClockWidget.qml:96-121）→
          // 语义 panelGradient；上下外延 backgroundGap（:99-101）。
          Positioned(
            top: -backgroundGap,
            bottom: -backgroundGap,
            width: cardWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  iconSize * kDockInfoCardRadiusRatio,
                ),
                gradient: context.shellTheme.panelGradient(
                  colors.panelBackground,
                  colors.panelBackgroundBottom,
                ),
              ),
            ),
          ),
          // 紧凑行内容比卡宽时按比例缩进卡内（KOS 该行落在 carousel
          // `clip` 内被直接裁切；本端 `scaleDown` 避免 debug 溢出横幅——
          // 等宽/CJK 宽字形下 `glyph + HH:mm + · 日落 --:--` 会超卡宽，
          // 记 docs/visual-deltas.md）。
          if (compact)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: _CompactRow(data: data),
            )
          else
            _FullRows(data: data),
        ],
      ),
    );
  }
}

/// full 布局（DockClockWidget.qml:123-270）：左列 60% 时间+日期、右列 40%
/// 日落/日出。
class _FullRows extends StatelessWidget {
  const _FullRows({required this.data});

  final DockClockCardData data;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    final backgroundGap = iconSize * 0.1;
    // KOS: DockClockWidget.qml:127-129（宽 min(父宽-gap*2, iconSize*3.86)，
    // 高 round(iconSize*0.88)）。
    final rowWidth = math.min(
      iconSize * metrics.infoUnits - backgroundGap * 2,
      iconSize * 3.86,
    );
    return SizedBox(
      width: rowWidth,
      height: (iconSize * 0.88).roundToDouble(),
      child: Row(
        children: [
          SizedBox(
            width: rowWidth * 0.60, // KOS: :133 `width * 0.60`
            child: Column(
              children: [
                SizedBox(
                  // KOS: :140 `height: Math.round(widget.iconSize * 0.58)`。
                  height: (iconSize * 0.58).roundToDouble(),
                  child: Center(
                    child: Text(
                      DockClockCard.timeText(data.now),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        // iOS 玻璃字形降级 → 语义 textPrimary（记 deltas）。
                        color: colors.textPrimary,
                        // KOS: :223-228（pixelSize max(16,
                        // round(iconSize*0.43))，DemiBold，letterSpacing
                        // 0.6）。
                        fontSize: math.max(
                          kDockClockTimeMinFont,
                          (iconSize * kDockClockTimeFontRatio).roundToDouble(),
                        ),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  // KOS: :232-247 `height: Math.round(iconSize * 0.27)`，
                  // opacity 0.82、pixelSize max(9, round(iconSize*0.21))
                  // Medium。
                  height: (iconSize * 0.27).roundToDouble(),
                  child: Center(
                    child: Text(
                      DockClockCard.dateText(data.now),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.textPrimary.withValues(
                          alpha: kDockClockDateAlpha,
                        ),
                        fontSize: math.max(
                          9,
                          (iconSize * kDockClockDateFontRatio).roundToDouble(),
                        ),
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: rowWidth * 0.40, // KOS: :253 `width * 0.40`
            child: Column(
              children: [
                Expanded(
                  child: _SolarEventRow(label: '日落', value: data.sunset),
                ),
                Expanded(
                  child: _SolarEventRow(label: '日出', value: data.sunrise),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// KOS `SolarEventRow` component（DockClockWidget.qml:63-92）：label
/// Medium @0.72 + value DemiBold @0.92（`--:--` 时 0.48）。
class _SolarEventRow extends StatelessWidget {
  const _SolarEventRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    final colors = context.shellColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textPrimary.withValues(alpha: 0.72), // KOS: :74
            fontSize: math.max(8, (iconSize * 0.18).roundToDouble()), // :77
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
        // KOS: :69 `spacing: Math.max(1, Math.round(iconSize * 0.04))`。
        SizedBox(width: math.max(1, (iconSize * 0.04).roundToDouble())),
        Text(
          value,
          style: TextStyle(
            color: colors.textPrimary.withValues(
              alpha: value == '--:--' ? 0.48 : 0.92, // KOS: :84
            ),
            fontSize: math.max(8, (iconSize * 0.19).roundToDouble()), // :87
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

/// compact 单行（DockClockWidget.qml:272-306）：glyph + `HH:mm` +
/// `· 日落 --:--`。
class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.data});

  final DockClockCardData data;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    final colors = context.shellColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          // KOS DockMetricGlyph kind:"clock"（DockClockWidget.qml:278-284）
          // → material schedule glyph 近似（记 deltas）。
          Icons.schedule,
          size: math.max(8, (iconSize * 0.42).roundToDouble()),
          color: colors.textPrimary,
        ),
        // KOS: :276 `spacing: Math.max(2, Math.round(iconSize * 0.08))`。
        SizedBox(width: math.max(2, (iconSize * 0.08).roundToDouble())),
        Text(
          DockClockCard.shortTimeText(data.now),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: math.max(9, (iconSize * 0.52).roundToDouble()), // :291
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        Text(
          ' · 日落 ${data.sunset}', // KOS: :296 `"· 日落 " + sunsetTime`
          style: TextStyle(
            color: colors.textPrimary.withValues(alpha: 0.68), // :298
            fontSize: math.max(6, (iconSize * 0.28).roundToDouble()),
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}
