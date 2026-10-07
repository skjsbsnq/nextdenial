/// KOS Dock 信息卡——资源占用（metrics/温度）页（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/dock/DockTemperatureWidget.qml`（行号在
/// 各段标注）：
/// - full（iconSize≥32）：白色温度计 + 两行温度和原色 accent 点，
///   右列三色 CPU / memory / storage 活动环；
/// - compact（iconSize<32）：`glyph + 平均° · 峰值°` 单行（:238-273）；
/// - `available = currentMilliC>=0 && maximum5MinuteMilliC>=0`（:20-21）→
///   [DockMetricsSnapshot.temperatureAvailable]；不可用显 `--°`（:156-157）。
///
/// 数据：`cpuFraction` ← `services.cpu.current`（SDK `LoadSeries`；KOS 侧
/// `MetricsService.cpuUsage`）；温度/内存/磁盘 ← [DockMetricsSnapshot]。
/// CPU 不重复 /proc/stat 差分（记 deltas）。
///
/// 偏差（记 docs/visual-deltas.md）：
/// - 卡背 thermalColor 横向渐变按温度由蓝变橙红（:38-69）；
/// - KOS 页内嵌 `TemperatureSensorPopups`（:278-281，传感器 dashboard）无对应
///   组件 → hover/点击走通用 DockInfoPopup（carousel 层统一处理）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/dock_metrics.dart';
import '../../theme/dock_tokens.dart';

/// NextKde thermal artwork: cool blue at 35°C, warm orange at 90°C.
LinearGradient dockMetricsGradient(DockMetricsSnapshot? snapshot) {
  final available = snapshot?.temperatureAvailable ?? false;
  final warmth = available
      ? ((snapshot!.currentMilliC / 1000 - 35) / 55).clamp(0.0, 1.0)
      : 0.25;
  Color tone(Color cool, Color warm, double alpha) =>
      Color.lerp(cool, warm, warmth)!.withValues(alpha: alpha);
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      tone(
        const Color.fromRGBO(41, 97, 158, 1),
        const Color.fromRGBO(173, 56, 46, 1),
        0.68,
      ),
      tone(
        const Color.fromRGBO(51, 143, 173, 1),
        const Color.fromRGBO(245, 133, 46, 1),
        0.54,
      ),
    ],
  );
}

/// KOS `DockTemperatureWidget`（carousel 页）。快照缺省（collector 尚未采样）
/// → `temperatureAvailable=false`，温度显 `--°`、三环按 0 绘制——KOS 同式
/// （DockTemperatureWidget.qml:20-33，MetricsService 未就绪时 value=0）。
class DockMetricsCard extends StatelessWidget {
  const DockMetricsCard({
    required this.snapshot,
    required this.cpuFraction,
    super.key,
  });

  /// metrics 快照（null = 未采样；字段按 0/不可用降级）。
  final DockMetricsSnapshot? snapshot;

  /// CPU 使用分数 0-1（`services.cpu.current`，null → 0；KOS
  /// `cpuValue = clamp(MetricsService.cpuUsage)` :26-27 同式 clamp）。
  final double? cpuFraction;

  /// `widget.cpuValue`（:26-27 `Math.max(0, Math.min(1, cpuUsage))`）。
  double get _cpuValue => (cpuFraction ?? 0).clamp(0.0, 1.0);

  /// `widget.memoryValue`（:28-30）。
  double get _memoryValue => snapshot?.memoryFraction ?? 0;

  /// `widget.storageValue`（:31-33）。
  double get _storageValue => snapshot?.diskFraction ?? 0;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final backgroundGap = iconSize * 0.1; // KOS: DockTemperatureWidget.qml:17
    final cardWidth = iconSize * metrics.infoUnits + backgroundGap * 2; // :35
    final compact = iconSize < kDockClockCompactThreshold; // :19 同 32 阈值

    return SizedBox(
      width: cardWidth,
      height: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // NextKde 的温度驱动横向卡背（:48-69）。
          Positioned(
            top: -backgroundGap,
            bottom: -backgroundGap,
            width: cardWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  iconSize * kDockInfoCardRadiusRatio,
                ),
                gradient: dockMetricsGradient(snapshot),
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
            _FullRow(
              snapshot: snapshot,
              cpuValue: _cpuValue,
              memoryValue: _memoryValue,
              storageValue: _storageValue,
            ),
        ],
      ),
    );
  }
}

/// full 布局（DockTemperatureWidget.qml:71-236）：左温度列 + 1px 分隔 +
/// 右三环。
class _FullRow extends StatelessWidget {
  const _FullRow({
    required this.snapshot,
    required this.cpuValue,
    required this.memoryValue,
    required this.storageValue,
  });

  final DockMetricsSnapshot? snapshot;
  final double cpuValue;
  final double memoryValue;
  final double storageValue;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    // KOS: :77-80 — 行宽 min(父宽-gap*2, iconSize*3.44)，高 round(*0.82)，
    // spacing max(4, round(*0.10))。
    final rowWidth = math.min(
      iconSize * metrics.infoUnits - iconSize * 0.1 * 2,
      iconSize * 3.44,
    );
    final spacing = math.max(4.0, (iconSize * 0.10).roundToDouble());
    final temperaturesWidth = (iconSize * 2.18).roundToDouble(); // :87
    final ringsExtent = rowWidth - temperaturesWidth - 1 - spacing * 2; // :184
    final available = snapshot?.temperatureAvailable ?? false;
    final currentC = available
        ? (snapshot!.currentMilliC / 1000).round()
        : -1; // :22-23
    final peakC = available
        ? (snapshot!.maximum5MinuteMilliC / 1000).round()
        : -1; // :24-25

    return SizedBox(
      width: rowWidth,
      height: (iconSize * 0.82).roundToDouble(),
      child: Row(
        children: [
          SizedBox(
            width: temperaturesWidth,
            child: Row(
              children: [
                Icon(
                  // KOS DockMetricGlyph kind:"temperature"（:90-100）→
                  // material thermostat glyph 近似（记 deltas）。
                  Icons.thermostat,
                  size: (iconSize * 0.42).roundToDouble(),
                  color: Colors.white,
                ),
                SizedBox(
                  // KOS: :105 `leftMargin: Math.max(3, round(iconSize*0.09))`。
                  width: math.max(3, (iconSize * 0.09).roundToDouble()),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: _TemperatureRow(
                          label: '平均温度', // KOS: :114
                          celsius: currentC,
                          // NextKde cyan temperature accent (:115).
                          accent: const Color(0xFF64D2FF),
                        ),
                      ),
                      Expanded(
                        child: _TemperatureRow(
                          label: '最高温度', // KOS: :116
                          celsius: peakC,
                          // NextKde coral peak-temperature accent (:117).
                          accent: const Color(0xFFFF6B62),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: spacing),
          // KOS: :173-177 — 1px 分隔占位（不画可见 rule）。
          const SizedBox(width: 1),
          SizedBox(width: spacing),
          SizedBox(
            // KOS: :182-186 `activityRegion`：剩余右区，三环居中。
            width: math.max(0, ringsExtent),
            child: Center(
              child: SizedBox(
                // KOS: :190-194 `activityRings` 边长 round(iconSize*0.96)。
                width: (iconSize * 0.96).roundToDouble(),
                height: (iconSize * 0.96).roundToDouble(),
                child: CustomPaint(
                  painter: DockMetricsRingsPainter(
                    cpuValue: cpuValue,
                    memoryValue: memoryValue,
                    storageValue: storageValue,
                    // KOS :205 keeps the unfilled activity track dark.
                    trackColor: const Color.from(
                      alpha: 0.16,
                      red: 0.19,
                      green: 0.17,
                      blue: 0.20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 温度行（DockTemperatureWidget.qml:119-166）：accent 点 + label +
/// 右对齐 `xx°`/`--°`。
class _TemperatureRow extends StatelessWidget {
  const _TemperatureRow({
    required this.label,
    required this.celsius,
    required this.accent,
  });

  final String label;

  /// 摄氏整数；-1 = 不可用 → `--°`（KOS: :156-157 `available ? v+"°" : "--°"`）。
  final int celsius;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    const ink = Colors.white;
    return Row(
      children: [
        Container(
          // KOS: :124-134 accent 点 `Math.max(4, round(iconSize*0.09))` 圆点。
          width: math.max(4, (iconSize * 0.09).roundToDouble()),
          height: math.max(4, (iconSize * 0.09).roundToDouble()),
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        SizedBox(
          // KOS: :138 `leftMargin: Math.round(iconSize * 0.16)`（相对行左缘；
          // 此处用等效 spacing 近似）。
          width: math.max(2, (iconSize * 0.07).roundToDouble()),
        ),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              // KOS: :135-149 opacity 0.82、pixelSize max(9,
              // round(iconSize*0.21)) Medium。
              color: ink.withValues(alpha: 0.82),
              fontSize: math.max(9, (iconSize * 0.21).roundToDouble()),
              fontWeight: FontWeight.w500,
              height: 1.0,
            ),
          ),
        ),
        Text(
          celsius >= 0 ? '$celsius°' : '--°', // KOS: :156-157
          style: TextStyle(
            color: ink,
            // KOS: :151-165 pixelSize max(11, round(iconSize*0.27))
            // DemiBold。
            fontSize: math.max(11, (iconSize * 0.27).roundToDouble()),
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

/// compact 单行（DockTemperatureWidget.qml:238-273）：`glyph + 平均° · 峰值°`。
class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.snapshot});

  final DockMetricsSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    const ink = Colors.white;
    final available = snapshot?.temperatureAvailable ?? false;
    final currentC = available ? (snapshot!.currentMilliC / 1000).round() : -1;
    final peakC = available
        ? (snapshot!.maximum5MinuteMilliC / 1000).round()
        : -1;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.thermostat,
          // KOS: :245 `Math.max(9, Math.round(iconSize*0.52))`。
          size: math.max(9, (iconSize * 0.52).roundToDouble()),
          color: ink,
        ),
        SizedBox(
          // KOS: :242 `spacing: Math.max(2, Math.round(iconSize*0.10))`。
          width: math.max(2, (iconSize * 0.10).roundToDouble()),
        ),
        Text(
          currentC >= 0 ? '$currentC°' : '--°', // KOS: :252
          style: TextStyle(
            color: ink,
            fontSize: math.max(9, (iconSize * 0.48).roundToDouble()), // :257
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        Text(
          ' · 峰值 ${peakC >= 0 ? '$peakC°' : '--°'}', // KOS: :262-263
          style: TextStyle(
            color: ink.withValues(alpha: 0.68), // :265
            fontSize: math.max(6, (iconSize * 0.28).roundToDouble()),
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

/// metrics 三环 painter（KOS `activityCanvas` drawRing，
/// DockTemperatureWidget.qml:196-232）：track 整圆 + 值弧（-90° 起顺时针，
/// lineCap round）。
///
/// 外 CPU `kDockMetricsRingCpuColor` / 中 memory `…MemoryColor` / 内
/// storage `…StorageColor`——KOS 语义环色字面保留（任务卡批准；
/// `dock_tokens.dart` 注释行号）。
final class DockMetricsRingsPainter extends CustomPainter {
  const DockMetricsRingsPainter({
    required this.cpuValue,
    required this.memoryValue,
    required this.storageValue,
    required this.trackColor,
  });

  final double cpuValue;
  final double memoryValue;
  final double storageValue;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // KOS: :203 `ctx.lineWidth = Math.max(2.4, width * 0.075)`。
    final strokeWidth = math.max(
      kDockMetricsRingMinWidth,
      w * kDockMetricsRingWidthRatio,
    );
    final center = Offset(w / 2, size.height / 2);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    void drawRing(double radiusRatio, double value, int argb) {
      final radius = w * radiusRatio;
      // KOS: :205-208 track 整圆。
      canvas.drawCircle(center, radius, trackPaint);
      // KOS: :209-213 值弧 `arc(center, radius, -π/2, -π/2 + 2π·value)`。
      final clamped = value.clamp(0.0, 1.0);
      if (clamped <= 0) return;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * clamped,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = Color(argb),
      );
    }

    // KOS: :219-221 外 CPU / 中 memory / 内 storage（半径比 0.39/0.285/0.18）。
    drawRing(kDockMetricsRingOuterRatio, cpuValue, kDockMetricsRingCpuColor);
    drawRing(
      kDockMetricsRingMidRatio,
      memoryValue,
      kDockMetricsRingMemoryColor,
    );
    drawRing(
      kDockMetricsRingInnerRatio,
      storageValue,
      kDockMetricsRingStorageColor,
    );
  }

  @override
  bool shouldRepaint(DockMetricsRingsPainter oldDelegate) =>
      cpuValue != oldDelegate.cpuValue ||
      memoryValue != oldDelegate.memoryValue ||
      storageValue != oldDelegate.storageValue ||
      trackColor != oldDelegate.trackColor;
}
