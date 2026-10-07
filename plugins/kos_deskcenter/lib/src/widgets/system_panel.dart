/// KOS DeskCenter 系统监控详情面板（TASK-17）：`kos-system` 卡片点击的
/// DenialUI 重写，填入 `DeskPanelShell` 内容区。
///
/// NextKde 无独立 system/monitor app（数据直接来自 kos-data），本面板是
/// system 卡片（`KosSystemCard`，:1240-1512）详情的放大版：
/// - 三环放大（CPU/内存/存储占比，`KosSystemMetrics` + `LoadSeries`）；
/// - 历史曲线区（内存/CPU/平均频率三段 `KosSparklinePainter`，同源
///   system_card 的 `_TrendSection` 语义：CPU 固定 0-1，内存/频率
///   adaptiveRange）；
/// - 数值行：CPU 频率 MHz、温度当前/5min 峰值、内存 used/total GiB、
///   磁盘 used/total GiB（MetricsService.qml:55-64 读取键）。
///
/// 数据源（任务卡 §契约）：
/// - `services.cpu`（ShellServicesScope）优先，无则 `metricsCollector`
///   的 `cpuSeries`/`cpuUpdates`（`SystemMetricsCollector`，TASK-10）；
/// - 内存/频率/温度/磁盘历史：注入的 `KosSystemMetrics`（容器层经
///   `KosDataClient metrics.snapshot` 或内嵌 collector 供给），collector
///   的 `metrics` 流随采样推帧。
///
/// DenialUI：面板材质由 `DeskPanelShell` 提供（`ShellBackdropBlur` +
/// `Material(cardColor)`）；图表区域 `Material(cardColor)` 小卡，三环/
/// 折线为自绘 `CustomPaint`。环色/趋势线保留数据语义色
/// `#ff375f`/`#30d158`/`#64d2ff`（`KosSystemCardColors`），坐标/标签
/// 文字 `textSecondary`，其余前景/材质走 `context.shellTheme/shellColors`。
library;

import '../theme/backdrop_content.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart'
    show ShellServicesScope;
import 'package:denial_flutter_sdk/shell_color_scheme.dart'
    show ShellColorScheme;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:denial_sdk/system.dart' show LoadSeries;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/system_metrics_collector.dart';
import 'desk_panel_shell.dart';
import 'system_card.dart';

/// `DeskPanelBuilder` 形态的系统监控面板入口。
Widget buildSystemPanel(DeskPanelRequest request, DeskPanelData data) =>
    SystemPanel(request: request, data: data);

/// 注册 `kos-system` 的面板内容构造器（装配层统一调用一次，幂等）。
void registerSystemPanel() {
  registerDeskPanelBuilder('kos-system', buildSystemPanel);
}

/// 系统监控详情面板：三环放大 + 三段历史曲线 + 数值行。
///
/// 构造参数全部可空（预览/测试形态直接注入；生产经 `DeskPanelData`
/// 向下转型）：[metrics] 当帧 `KosSystemMetrics`、[cpu] CPU `LoadSeries`
/// 源（SDK telemetry 或 collector 流）、[collector] 本地采集器（`latest`/
/// `metrics`/`cpuSeries`/`cpuUpdates`）。
class SystemPanel extends ConsumerStatefulWidget {
  const SystemPanel({
    required this.request,
    required this.data,
    this.metrics,
    this.cpu,
    this.collector,
    super.key,
  });

  /// 卡片弹出请求（无参；仅面板路由契约）。
  final DeskPanelRequest request;

  /// 当帧数据快照与数据源（`metrics`/`metricsCollector`/`activity`）。
  final DeskPanelData data;

  /// 直接注入的 `KosSystemMetrics`（测试/预览）；null 时经 [data.metrics]/
  /// [collector] 取。
  final KosSystemMetrics? metrics;

  /// 直接注入的 CPU `LoadSeries`（测试/预览）；null 时经 scope `services.cpu`
  /// /[collector].`cpuSeries`/`cpuUpdates` 取。
  final LoadSeries? cpu;

  /// 内嵌 metrics 采集器；null 时退化为只读当帧注入/快照。
  final SystemMetricsCollector? collector;

  @override
  ConsumerState<SystemPanel> createState() => _SystemPanelState();
}

class _SystemPanelState extends ConsumerState<SystemPanel> {
  StreamSubscription<LoadSeries>? _cpuSub;
  LoadSeries _cpuSeries = LoadSeries.empty;
  StreamSubscription<KosSystemMetrics>? _metricsSub;
  KosSystemMetrics? _metrics;

  @override
  void initState() {
    super.initState();
    _metrics = widget.metrics ?? widget.data.metrics ?? _collector?.latest;
    _cpuSeries = widget.cpu ?? _collector?.cpuSeries ?? LoadSeries.empty;
    final collector = _collector;
    if (collector != null) {
      _metricsSub = collector.metrics.listen((m) {
        if (mounted) setState(() => _metrics = m);
      });
      _cpuSub = collector.cpuUpdates.listen((series) {
        if (mounted) setState(() => _cpuSeries = series);
      });
    }
  }

  SystemMetricsCollector? get _collector =>
      widget.collector ?? widget.data.metricsCollector as SystemMetricsCollector?;

  @override
  void didUpdateWidget(SystemPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.collector, oldWidget.collector) ||
        !identical(widget.data.metricsCollector, oldWidget.data.metricsCollector)) {
      unawaited(_metricsSub?.cancel());
      unawaited(_cpuSub?.cancel());
      final collector = _collector;
      if (collector != null) {
        _metricsSub = collector.metrics.listen((m) {
          if (mounted) setState(() => _metrics = m);
        });
        _cpuSub = collector.cpuUpdates.listen((series) {
          if (mounted) setState(() => _cpuSeries = series);
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_metricsSub?.cancel());
    unawaited(_cpuSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    // CPU 源优先级：构造注入 > scope services.cpu > collector（任务卡
    // §契约：services.cpu 经 ShellServicesScope 优先，无则
    // metricsCollector.cpuSeries/cpuUpdates）。
    final cpuSeries = widget.cpu ??
        (scope != null ? ref.watch(scope.services.cpu) : null) ??
        _cpuSeries;
    final metrics = _metrics ?? widget.data.metrics;
    final cardColors =
        KosSystemCardColors.forShell(panelContentTheme(context.shellTheme));

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ringsRow(theme, colors, cardColors, cpuSeries, metrics),
          const SizedBox(height: 14),
          _trendsColumn(theme, colors, cardColors, cpuSeries, metrics),
          const SizedBox(height: 14),
          _numbersGrid(theme, colors, metrics),
        ],
      ),
    );
  }

  /// 三环区放大：CustomPaint 三环 + 环心「标签 百分比」常显（面板无需
  /// 悬停分带——放大的语义是总览）。
  Widget _ringsRow(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosSystemCardColors cardColors,
    LoadSeries cpuSeries,
    KosSystemMetrics? metrics,
  ) {
    final cpuValue = cpuSeries.current ?? 0; // :1265 ?? 0
    final memoryValue =
        (metrics != null && metrics.memoryTotalBytes > 0)
            ? metrics.memoryUsedBytes / metrics.memoryTotalBytes
            : 0.0;
    final storageValue =
        (metrics != null && metrics.diskTotalBytes > 0)
            ? metrics.diskUsedBytes / metrics.diskTotalBytes
            : 0.0;
    final values = [cpuValue, memoryValue, storageValue];
    final labels = ['CPU', '内存', '存储'];
    return Row(
      children: [
        SizedBox(
          width: 180,
          height: 180,
          child: CustomPaint(
            painter: _RingsPainter(
              values: values,
              colors: cardColors,
              isMaterial: theme.brightness == Brightness.light,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    labels[0],
                    style: TextStyle(
                      color: cardColors.detailInk,
                      fontSize: 12,
                      height: 1,
                    ),
                  ),
                  Text(
                    '${(cpuValue * 100).round()}%',
                    style: ShellText.base.copyWith(
                      color: colors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ringSummary(colors, cardColors, 'CPU', cpuValue,
                  cardColors.ringCpu),
              const SizedBox(height: 8),
              _ringSummary(colors, cardColors, '内存', memoryValue,
                  cardColors.ringMemory),
              const SizedBox(height: 8),
              _ringSummary(colors, cardColors, '存储', storageValue,
                  cardColors.ringStorage),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ringSummary(
    ShellColorScheme colors,
    KosSystemCardColors cardColors,
    String label,
    double value,
    Color accent,
  ) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
        ),
        Text(
          '${(value * 100).round()}%',
          style: ShellText.base.copyWith(
            color: colors.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  /// 三段历史曲线（内存/CPU/平均频率），同 system_card `_TrendSection`
  /// 语义但放大到面板级高度。
  Widget _trendsColumn(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosSystemCardColors cardColors,
    LoadSeries cpuSeries,
    KosSystemMetrics? metrics,
  ) {
    final memoryValue =
        (metrics != null && metrics.memoryTotalBytes > 0)
            ? metrics.memoryUsedBytes / metrics.memoryTotalBytes
            : 0.0;
    final cpuValue = cpuSeries.current ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrendRow(
          label: '内存  ${(memoryValue * 100).round()}%',
          labelColor: cardColors.labelInk,
          values: metrics?.memoryHistory ?? const [],
          lineColor: cardColors.memoryLine,
          adaptiveRange: true,
          colors: colors,
        ),
        const SizedBox(height: 10),
        _TrendRow(
          label: 'CPU  ${(cpuValue * 100).round()}%',
          labelColor: cardColors.labelInk,
          values: cpuSeries.history,
          lineColor: cardColors.cpuLine,
          adaptiveRange: false,
          colors: colors,
        ),
        const SizedBox(height: 10),
        _TrendRow(
          label:
              '平均频率  ${(metrics?.cpuFrequencyMhz ?? 0).round()} MHz',
          labelColor: cardColors.labelInk,
          values: metrics?.frequencyHistory ?? const [],
          lineColor: cardColors.frequencyLine,
          adaptiveRange: true,
          colors: colors,
        ),
      ],
    );
  }

  /// 数值网格：CPU 频率、温度（当前/5min 峰值）、内存 used/total、磁盘
  /// used/total。
  Widget _numbersGrid(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosSystemMetrics? metrics,
  ) {
    String gib(double bytes) =>
        (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
    final currentC = (metrics?.currentMilliC ?? -1) / 1000;
    final max5C = (metrics?.maximum5MinuteMilliC ?? -1) / 1000;
    final tempAvailable = currentC >= 0 && max5C >= 0;
    final rows = <(String, String)>[
      ('CPU 频率', '${(metrics?.cpuFrequencyMhz ?? 0).round()} MHz'),
      ('温度',
          tempAvailable
              ? '${currentC.round()}° / ${max5C.round()}°'
              : '-- / --'),
      ('内存',
          metrics == null || metrics.memoryTotalBytes <= 0
              ? '--'
              : '${gib(metrics.memoryUsedBytes)} / '
                  '${gib(metrics.memoryTotalBytes)} GiB'),
      ('磁盘',
          metrics == null || metrics.diskTotalBytes <= 0
              ? '--'
              : '${gib(metrics.diskUsedBytes)} / '
                  '${gib(metrics.diskTotalBytes)} GiB'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < rows.length; i++)
          _MetricCell(
            key: ValueKey('system-metric-$i'),
            theme: theme,
            colors: colors,
            label: rows[i].$1,
            value: rows[i].$2,
          ),
      ],
    );
  }
}

/// 数值格（小卡）：标签 `textSecondary` + 值 `textPrimary`。
class _MetricCell extends StatelessWidget {
  const _MetricCell({
    super.key,
    required this.theme,
    required this.colors,
    required this.label,
    required this.value,
  });

  final ShellThemeData theme;
  final ShellColorScheme colors;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor(colors.surfaceContainer),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板级趋势段：标签 + `KosSparklinePainter` 折线（同 system_card 的
/// `_TrendSection`，放大到 64 高并包 `Material(cardColor)` 小卡）。
class _TrendRow extends StatelessWidget {
  const _TrendRow({
    required this.label,
    required this.labelColor,
    required this.values,
    required this.lineColor,
    required this.adaptiveRange,
    required this.colors,
  });

  final String label;
  final Color labelColor;
  final List<double> values;
  final Color lineColor;
  final bool adaptiveRange;
  final ShellColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: context.shellTheme.cardColor(colors.surfaceContainer),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: TextStyle(
              color: labelColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: CustomPaint(
              painter: KosSparklinePainter(
                values: values,
                lineColor: lineColor,
                adaptiveRange: adaptiveRange,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 三环 Canvas（:1291-1342 同语义，面板放大复用）。
class _RingsPainter extends CustomPainter {
  const _RingsPainter({
    required this.values,
    required this.colors,
    required this.isMaterial,
  });

  final List<double> values;
  final KosSystemCardColors colors;
  final bool isMaterial;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final center = width / 2;
    final ringColors = [colors.ringCpu, colors.ringMemory, colors.ringStorage];
    final radii = [width * 0.39, width * 0.285, width * 0.18];
    final lineWidth = isMaterial
        ? math.max(6.0, width * 0.085)
        : math.max(5.0, width * 0.065);
    final trackPaint = Paint()
      ..color = colors.ringTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final radius = radii[i];
      final r = Rect.fromCircle(center: Offset(center, center), radius: radius);
      canvas.drawArc(r, 0, math.pi * 2, false, trackPaint);
      final amount = values[i].clamp(0.0, 1.0);
      arcPaint.color = ringColors[i];
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * amount, false, arcPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.colors != colors ||
      oldDelegate.isMaterial != isMaterial;
}
