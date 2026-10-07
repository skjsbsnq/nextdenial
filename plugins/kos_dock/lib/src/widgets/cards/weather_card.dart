/// KOS Dock 信息卡——天气页（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/weather/DockWeatherWidget.qml`（行号在
/// 各段标注）：
/// - full（iconSize≥32）：conditionSymbol 大字 + 温度 Bold + `城市 · 条件` +
///   右列「体感 xx°/湿度 xx%」（DockWeatherWidget.qml:160-215）；
/// - compact（iconSize<32）：`symbol 温度 · 体感` 单行（:217-249）。
///
/// 偏差（记 docs/visual-deltas.md）：
/// - 卡背恢复源天气 artwork 渐变（:19-40），按 weatherCode/isDay 切换；
/// - 云/太阳/雨装饰层（:69-157，BundledIcons 资产 + 旋转光线/雨滴 Repeater）
///   省略——无对应打包资产；
/// - `tone()` 的用户图标着色选项未移植；保留天气 artwork 原色。
library;

import 'dart:math' as math;

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
          // backgroundStart/End :19-40），按天气状态横向变化；
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
                gradient: dockWeatherGradient(
                  snapshot.weatherCode,
                  isDay: snapshot.isDay,
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
    // This card owns a translucent weather artwork backdrop in every mode.
    const ink = Color(0xFFFFFFFF);
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
                color: ink,
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
                    color: ink,
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
                    color: ink.withValues(alpha: 0.75), // :186
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
                    color: ink.withValues(alpha: 0.88),
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
                    color: ink.withValues(alpha: 0.74),
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
    // This card owns a translucent weather artwork backdrop in every mode.
    const ink = Color(0xFFFFFFFF);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          dockWeatherConditionSymbol(
            snapshot.weatherCode,
            isDay: snapshot.isDay,
          ),
          style: TextStyle(
            color: ink,
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
            color: ink,
            fontSize: math.max(9, (iconSize * 0.48).roundToDouble()), // :235
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        Text(
          ' · 体感 ${snapshot.apparentTemperature}', // KOS: :240
          style: TextStyle(
            color: ink.withValues(alpha: 0.68), // :242
            fontSize: math.max(6, (iconSize * 0.28).roundToDouble()),
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

/// NextKde weather artwork palette (DockWeatherWidget.qml:19–40).
LinearGradient dockWeatherGradient(int code, {required bool isDay}) {
  final (Color start, Color end) = switch (code) {
    0 =>
      isDay
          ? (
              const Color.fromRGBO(46, 138, 240, 0.58),
              const Color.fromRGBO(255, 184, 77, 0.42),
            )
          : (
              const Color.fromRGBO(26, 38, 97, 0.66),
              const Color.fromRGBO(92, 107, 179, 0.38),
            ),
    1 || 2 => (
      const Color.fromRGBO(92, 148, 194, 0.56),
      const Color.fromRGBO(224, 230, 232, 0.46),
    ),
    3 => (
      const Color.fromRGBO(89, 110, 133, 0.62),
      const Color.fromRGBO(235, 240, 242, 0.48),
    ),
    45 || 48 => (
      const Color.fromRGBO(97, 115, 125, 0.60),
      const Color.fromRGBO(209, 217, 217, 0.44),
    ),
    >= 51 && <= 67 => (
      const Color.fromRGBO(51, 89, 125, 0.64),
      const Color.fromRGBO(148, 173, 186, 0.40),
    ),
    >= 71 && <= 86 => (
      const Color.fromRGBO(138, 173, 199, 0.58),
      const Color.fromRGBO(240, 250, 255, 0.50),
    ),
    >= 95 => (
      const Color.fromRGBO(61, 59, 102, 0.70),
      const Color.fromRGBO(145, 138, 184, 0.46),
    ),
    _ => (
      const Color.fromRGBO(82, 112, 148, 0.58),
      const Color.fromRGBO(194, 209, 219, 0.42),
    ),
  };
  return LinearGradient(colors: [start, end]);
}
