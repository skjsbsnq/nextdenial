/// KOS Dock 信息卡——天气页（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/weather/DockWeatherWidget.qml`（行号在
/// 各段标注）：
/// - full（iconSize≥32）：conditionSymbol 大字 + 温度 Bold + `城市 · 条件` +
///   右列「体感 xx°/湿度 xx%」（DockWeatherWidget.qml:160-215）；
/// - compact（iconSize<32）：`symbol 温度 · 体感` 单行（:217-249）。
///
/// 偏差（记 docs/visual-deltas.md）：
/// - 卡背天气状态渐变 `backgroundStart/backgroundEnd`（:19-40，8 组
///   weatherCode 字面 RGBA）→ `panelGradient(panelBackground,
///   panelBackgroundBottom)`（CONSTRAINTS §3 禁硬编码颜色）；
/// - 云/太阳/雨装饰层（:69-157，BundledIcons 资产 + 旋转光线/雨滴 Repeater）
///   省略——无对应打包资产；
/// - `tone()`（IconAppearanceService.styledColor）不移植——色板走 shellTheme。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:flutter/material.dart';

import '../../data/dock_weather.dart';
import '../../theme/dock_tokens.dart';

/// KOS `DockWeatherWidget`（carousel 页）。无数据 → `--` 占位（任务卡约束；
/// KOS 卡背/字段在无 WeatherService.available 时同样画 `--°` 占位文本，
/// visible 由 carousel `cardVisible` 门控）。
class DockWeatherCard extends StatelessWidget {
  const DockWeatherCard({required this.snapshot, super.key});

  /// 天气快照（[DockWeatherSnapshot]；`!available` 时全部 `--` 降级）。
  final DockWeatherSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    final backgroundGap = iconSize * 0.1; // KOS: DockWeatherWidget.qml:12
    final cardWidth = iconSize * metrics.infoUnits + backgroundGap * 2; // :42
    final compact = iconSize < kDockClockCompactThreshold; // :14 同 32 阈值

    return SizedBox(
      width: cardWidth,
      height: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 卡背：KOS weatherCode 渐变（DockWeatherWidget.qml:45-63 +
          // backgroundStart/End :19-40）→ 语义 panelGradient（记 deltas）；
          // 装饰层（云/太阳/雨 :69-157）省略。
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
          // 紧凑行比卡宽时 scaleDown 进卡内（KOS 落在 carousel `clip` 内被
          // 裁切；本端避免 debug 溢出横幅，记 docs/visual-deltas.md）。
          if (compact)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: _CompactRow(snapshot: snapshot),
            )
          else
            _FullRow(snapshot: snapshot),
        ],
      ),
    );
  }
}

/// full 布局（DockWeatherWidget.qml:160-215）：symbol 大字 + 温度/城市·条件
/// 列 + 1px 分隔占位 + 「体感/湿度」右列。
class _FullRow extends StatelessWidget {
  const _FullRow({required this.snapshot});

  final DockWeatherSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    final symbol = dockWeatherConditionSymbol(
      snapshot.weatherCode,
      isDay: snapshot.isDay,
    );
    // KOS: :166-167 — 行宽 contentWidth - round(iconSize*0.4)，spacing
    // round(iconSize*0.09)；metricGapFiller 并入行宽余量（记 deltas：1px
    // 分隔占位+10px gap filler 在 Flutter Row 里由 spaceBetween 近似）。
    final rowWidth = iconSize * metrics.infoUnits - (iconSize * 0.4).round();
    final spacing = (iconSize * 0.09).roundToDouble();
    final symbolWidth = (iconSize * 0.82).roundToDouble(); // :172
    final metricColumnWidth = (iconSize * 0.78).roundToDouble(); // :195
    return SizedBox(
      width: rowWidth,
      child: Row(
        children: [
          SizedBox(
            width: symbolWidth,
            child: Text(
              symbol,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                // KOS: :175 `pixelSize: Math.round(iconSize * 0.70)`。
                fontSize: (iconSize * 0.70).roundToDouble(),
                height: 1.0,
              ),
            ),
          ),
          SizedBox(width: spacing),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.temperature,
                  maxLines: 1,
                  style: TextStyle(
                    color: colors.textPrimary,
                    // KOS: :185 `pixelSize: Math.max(16, iconSize * 0.42)`
                    // Bold。
                    fontSize: math.max(16, iconSize * 0.42),
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 1), // KOS: :184 `spacing: 1`
                Text(
                  '${snapshot.cityName} · ${dockWeatherConditionText(snapshot.weatherCode)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis, // KOS: :186 elide
                  style: TextStyle(
                    color: colors.textPrimary.withValues(alpha: 0.75), // :186
                    fontSize: math.max(9, iconSize * 0.20),
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: spacing),
          SizedBox(
            width: metricColumnWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '体感 ${snapshot.apparentTemperature}',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    // KOS: :198-205 opacity 0.88、pixelSize max(8,
                    // iconSize*0.19)。
                    color: colors.textPrimary.withValues(alpha: 0.88),
                    fontSize: math.max(8, iconSize * 0.19),
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2), // KOS: :197 `spacing: 2`
                Text(
                  '湿度 ${snapshot.humidity}',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    // KOS: :206-213 opacity 0.74。
                    color: colors.textPrimary.withValues(alpha: 0.74),
                    fontSize: math.max(8, iconSize * 0.19),
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// compact 单行（DockWeatherWidget.qml:217-249）：`symbol 温度 · 体感`。
class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.snapshot});

  final DockWeatherSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    final colors = context.shellColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          dockWeatherConditionSymbol(
            snapshot.weatherCode,
            isDay: snapshot.isDay,
          ),
          style: TextStyle(
            color: colors.textPrimary,
            // KOS: :228 `pixelSize: Math.max(9, Math.round(iconSize*0.55))`。
            fontSize: math.max(9, (iconSize * 0.55).roundToDouble()),
            height: 1.0,
          ),
        ),
        SizedBox(
          // KOS: :221 `spacing: Math.max(2, Math.round(iconSize*0.08))`。
          width: math.max(2, (iconSize * 0.08).roundToDouble()),
        ),
        Text(
          snapshot.temperature,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: math.max(9, (iconSize * 0.48).roundToDouble()), // :235
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        Text(
          ' · 体感 ${snapshot.apparentTemperature}', // KOS: :240
          style: TextStyle(
            color: colors.textPrimary.withValues(alpha: 0.68), // :242
            fontSize: math.max(6, (iconSize * 0.28).roundToDouble()),
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}
