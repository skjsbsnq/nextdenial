/// Dock 时钟页：秒级时间与短日期，完整日期和日出日落保留在详情中。
/// 卡片沿用信息轮播的固定尺寸，轻透渐变与 Dock 玻璃融合。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/material.dart';

import '../../theme/dock_tokens.dart';

/// A restrained tint lets the Dock's existing glass remain visible.
LinearGradient dockClockGradient(BuildContext context) {
  final theme = context.shellTheme;
  if (!theme.backdropBlurEnabled) {
    return LinearGradient(
      colors: [
        theme.colors.panelBackground,
        theme.colors.panelBackgroundBottom,
      ],
    );
  }
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color.lerp(
        const Color(0xFF263348),
        theme.accentSeed,
        0.22,
      )!.withValues(alpha: 0.24),
      const Color(0xFF263348).withValues(alpha: 0.12),
    ],
  );
}

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
    '周日',
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
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
    final backgroundGap = iconSize * 0.1; // KOS: DockClockWidget.qml:20
    final cardWidth = iconSize * metrics.infoUnits + backgroundGap * 2; // :24
    final compact = iconSize < kDockClockCompactThreshold; // :22

    return SizedBox(
      width: cardWidth,
      height: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient 横向渐变；上下外延 backgroundGap（:99-101）。
          Positioned(
            top: -backgroundGap,
            bottom: -backgroundGap,
            width: cardWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  iconSize * kDockInfoCardRadiusRatio,
                ),
                gradient: dockClockGradient(context),
              ),
            ),
          ),
          // Preserve the fixed carousel slot even on narrow Dock sizes.
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

/// Keep the reading hierarchy simple at Dock scale. Detailed solar times are
/// available in the existing popup rather than competing with the clock face.
class _FullRows extends StatelessWidget {
  const _FullRows({required this.data});

  final DockClockCardData data;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final theme = context.shellTheme;
    final ink = theme.backdropBlurEnabled
        ? Colors.white
        : theme.colors.textPrimary;
    final rowWidth = math.min(
      iconSize * (metrics.infoUnits - 0.4),
      iconSize * 3.86,
    );
    return SizedBox(
      width: math.max(0, rowWidth),
      height: iconSize * 0.88,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule_outlined,
              size: iconSize * 0.54,
              color: ink.withValues(alpha: 0.80),
            ),
            SizedBox(width: iconSize * 0.20),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DockClockCard.timeText(data.now),
                  maxLines: 1,
                  style: TextStyle(
                    color: ink,
                    fontSize: iconSize * 0.40,
                    fontWeight: FontWeight.w500,
                    height: 1.05,
                  ),
                ),
                SizedBox(height: iconSize * 0.07),
                Text(
                  '${data.now.month}月${data.now.day}日  ·  '
                  '${DockClockCard.weekdayName(data.now)}',
                  maxLines: 1,
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.72),
                    fontSize: iconSize * 0.20,
                    fontWeight: FontWeight.w400,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// At smaller sizes, show only the glyph and second-level time.
class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.data});

  final DockClockCardData data;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    final theme = context.shellTheme;
    final ink = theme.backdropBlurEnabled
        ? Colors.white
        : theme.colors.textPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule_outlined,
          size: iconSize * 0.48,
          color: ink.withValues(alpha: 0.80),
        ),
        SizedBox(width: iconSize * 0.18),
        Text(
          DockClockCard.timeText(data.now),
          maxLines: 1,
          style: TextStyle(
            color: ink,
            fontSize: iconSize * 0.42,
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}
