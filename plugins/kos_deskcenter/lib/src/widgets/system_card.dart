/// KOS DeskCenter 系统监控小部件（`KosSystemCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 system 分支（Loader
/// :1240-1512）——4:6 分栏：左侧 Activity 三环 + 温度摘要，右侧三条
/// sparkline 趋势。源侧数据源是 `MetricsService`（kos-data-service 的
/// `metrics.snapshot` 适配，MetricsService.qml:51-77）；本端数据源映射：
///
/// - CPU 环与 cpu sparkline：`services.dart telemetry.cpu`
///   （`LoadSeries`：`current` 0-1 分数、history 容量 45，
///   denial_sdk load_series.dart:29-35）；
/// - 内存环与 memory sparkline：SDK 无内存 telemetry——由构造注入
///   `KosSystemMetrics`（容器层经 `KosDataClient metrics.snapshot`
///   供给；字段对齐 MetricsService.qml:59-64 的读取键）；
/// - 存储环 / cpuFrequencyMhz / 双温度：同上（MetricsService.qml:60、
///   :63-64 与 :15-16）；
/// - 频率 sparkline：`metrics.snapshot` `history[].frequencyMhz` 经
///   `KosSystemMetrics.frequencyHistory` 注入（SDK 无频率序列）。
///
/// 映射明细表见 docs/widgets/system.md。
///
/// 布局逐项（源行号锚点）：
/// - 三环 Item（:1259-1263）：左 0.02w、顶 0.035h、边长
///   `min(0.36w, 0.7h)`；Canvas 画三环（:1291-1342）：半径
///   w·0.39/0.285/0.18 = cpu/内存/存储，描边
///   `pick(max(6,w·0.085), max(5,w·0.065))`（material 前项，:1301-1302）、
///   圆头、轨道色 pick(outlineVariant，rgba(0.19,0.17,0.2,0.12))、
///   环色 material → [primary,tertiary,secondary]（:1273-1279）；
/// - 悬停态（:1344-1381）：环心显图标+「标签 百分比」，鼠标距离
///   ≥0.335w→cpu、≥0.23w→内存、否则存储；本端以 MouseRegion 等效；
/// - 温度摘要（:1386-1442）：左 0.02w、底 0.045h、宽 0.36w、高 0.17h；
///   图标 + 「当前 °」+ 1px 分隔 + 「最高 °」（5 分钟峰值）；
/// - 右侧趋势列（:1444-1509）：左 0.47w、右 0.07w、垂直居中、高 0.76h、
///   三段等高；每段「标签 + UsageSparkline」：
///   内存（adaptiveRange）、CPU（固定 0-1）、平均频率（adaptiveRange，
///   MHz 域），`maxPoints:36、smoothingWindow:5`（:1465-1466 等）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../theme/backdrop_content.dart';

import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_sdk/system.dart' show LoadSeries;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../layout/widget_layout.dart' show WidgetSize;
import 'desk_card.dart';

/// `metrics.snapshot` result.metrics 的轻量投影（MetricsService.qml:55-69
/// 读取键）。sdk 的 `LoadSeries` 只覆盖 CPU；内存/存储/频率/温度由本模型
/// 经 `KosDataClient` 供给（docs/widgets/system.md 映射表）。
final class KosSystemMetrics {
  const KosSystemMetrics({
    this.currentMilliC = -1,
    this.maximum5MinuteMilliC = -1,
    this.cpuFrequencyMhz = 0,
    this.memoryUsedBytes = 0,
    this.memoryTotalBytes = 0,
    this.diskUsedBytes = 0,
    this.diskTotalBytes = 0,
    this.memoryHistory = const [],
    this.frequencyHistory = const [],
  });

  /// 当前封装温度（毫摄氏度；MetricsService.qml:55-56，
  /// `currentMilliC ?? averageMilliC ?? -1`）。
  final int currentMilliC;

  /// 5 分钟峰值温度（毫摄氏度；:57-58）。
  final int maximum5MinuteMilliC;

  /// 平均 CPU 频率 MHz（:60 `metrics.frequencyMhz`）。
  final double cpuFrequencyMhz;

  /// 内存已用/总量字节（:61-62）。
  final double memoryUsedBytes;
  final double memoryTotalBytes;

  /// 存储已用/总量字节（:63-64）。
  final double diskUsedBytes;
  final double diskTotalBytes;

  /// `history[].memory` 序列（0-1 分数；:66-69 normalized(history,"memory")，
  /// 1h 窗口 + 0..1 域过滤已在 fromJson 应用）。
  final List<double> memoryHistory;

  /// `history[].frequencyMhz` 序列（MHz 域、1h 窗口，不夹取 0..1；:68-69）。
  final List<double> frequencyHistory;

  /// `metrics.snapshot` result 的 `metrics` 对象解析（MetricsService.qml
  /// :54 `response.result?.metrics ?? response.result` 的兼容读取——本端
  /// 只接受解包后的 metrics 对象，容器层负责取 `result.metrics`）。
  factory KosSystemMetrics.fromJson(Map<String, Object?> metrics) {
    double numOrZero(Object? v) => switch (v) {
      final num n => n.toDouble(),
      _ => 0.0,
    };
    // （numOrZero 为 :55-64 `Number(metrics.x ?? 0)` 的等价抽取）
    // :82-97 normalized(history, pick, minimum, maximum) 的等价投影：
    // `at`（Unix 毫秒，data-service main.go:1013 `UnixMilli()`）早于
    // 1h 截止的样本丢弃；`at` 缺省/非数值按 :90 `?? 0` → 0 恒出窗；
    // 值须为有限数且落在 [minimum, maximum]（ratio 默认 0..1）。
    final cutoff = DateTime.now().millisecondsSinceEpoch - 60 * 60 * 1000;
    List<double> history(String key, [double minimum = 0, double maximum = 1]) {
      final result = <double>[];
      if (metrics['history'] is! List) return result;
      for (final s in metrics['history'] as List) {
        if (s is! Map) continue;
        final at = s['at'];
        final value = s[key];
        if (at is! num || !(at >= cutoff)) continue; // :83、:90-92
        if (value is! num ||
            !value.isFinite ||
            value < minimum ||
            value > maximum) {
          continue; // :92-93 越界/非有限样本丢弃（非夹取）
        }
        result.add(value.toDouble());
      }
      return result;
    }

    return KosSystemMetrics(
      currentMilliC: numOrZero(
        metrics['currentMilliC'] ?? metrics['averageMilliC'],
      ).round(), // :55-56 兼容别名
      maximum5MinuteMilliC: numOrZero(
        metrics['maximum5MinuteMilliC'] ?? metrics['maximumMilliC'],
      ).round(), // :57-58
      cpuFrequencyMhz: numOrZero(metrics['frequencyMhz']), // :60
      memoryUsedBytes: numOrZero(metrics['memoryUsedBytes']), // :61
      memoryTotalBytes: numOrZero(metrics['memoryTotalBytes']), // :62
      diskUsedBytes: numOrZero(metrics['diskUsedBytes']), // :63
      diskTotalBytes: numOrZero(metrics['diskTotalBytes']), // :64
      memoryHistory: history('memory'), // :66 ratio 默认 0..1
      frequencyHistory: history(
        'frequencyMhz',
        0,
        double.infinity,
      ), // :68-69 MHz 原域
    );
  }
}

/// 系统卡内容色板：`content.ink/accent` 与 `colors.primary/tertiary/
/// secondary` 角色解析结果的注入形式。TASK-09 起 `onBackdrop`/`isMaterial`
/// 分叉改为按 `context.shellTheme` 解析（[KosSystemCardColors.forShell]）：
/// 插件表面下没有 MaterialApp/Theme 祖先，Theme.of 恒回退 light 基线，
/// 真实亮度/色板走 shell。
final class KosSystemCardColors {
  const KosSystemCardColors({
    this.ringCpu = const Color(0xFFFF375F), // :1279 "#ff375f"
    this.ringMemory = const Color(0xFF30D158), // :1279 "#30d158"
    this.ringStorage = const Color(0xFF64D2FF), // :1279 "#64d2ff"
    this.ringTrack = const Color(0x1F302B33), // :1306 rgba(0.19,0.17,0.2,0.12)
    this.detailInk = const Color(0xFF7D7782), // ink("#7d7782") :1353/:1360
    this.labelInk = const Color(
      0xC74C4A54,
    ), // ink(rgba(0.30,0.29,0.33,0.78)) :1457
    this.memoryActiveInk = const Color(
      0xD61F804F,
    ), // :1457 rgba(0.12,0.50,0.31,0.84)
    this.cpuActiveInk = const Color(
      0xD6C2243B,
    ), // :1478 rgba(0.76,0.14,0.23,0.84)
    this.divider = const Color(0x1F302B33), // :1424 rgba(0.19,0.17,0.2,0.12)
    this.tempSubInk = const Color(
      0xB87D7882,
    ), // ink(rgba(0.49,0.47,0.51,0.76),0.72) :1417
    this.memoryLine = const Color(
      0xFF30D158,
    ), // accent(tertiary,"#30d158") :1463
    this.cpuLine = const Color(0xFFFF375F), // accent(primary,"#ff375f") :1484
    this.frequencyLine = const Color(
      0xFF64D2FF,
    ), // accent(secondary,\"#64d2ff\") :1503
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosSystemCardColors forShell(ShellThemeData theme) {
    final ink = backdropInk(theme);
    final onBackdrop = usesBackdropInk(theme);
    return KosSystemCardColors(
      ringCpu: onBackdrop ? ink : const Color(0xFFFF375F),
      ringMemory: onBackdrop ? ink : const Color(0xFF30D158),
      ringStorage: onBackdrop ? ink : const Color(0xFF64D2FF),
      memoryLine: onBackdrop ? ink : const Color(0xFF30D158),
      cpuLine: onBackdrop ? ink : const Color(0xFFFF375F),
      frequencyLine: onBackdrop ? ink : const Color(0xFF64D2FF),
      memoryActiveInk: onBackdrop ? ink : const Color(0xFF30D158),
      cpuActiveInk: onBackdrop ? ink : const Color(0xFFFF375F),
      ringTrack: backdropHairline(
        theme,
      ), // :1306 outlineVariant@0.12 → hairlineSoft
      detailInk: backdropSecondaryInk(theme), // :1353/:1360 ink
      labelInk: backdropSecondaryInk(theme)
          .withValues(alpha: 0.78), // :1457 ink(…,0.78)
      divider: backdropHairline(theme), // :1424 rgba(…,0.12) → hairlineSoft
      tempSubInk: backdropSecondaryInk(theme)
          .withValues(alpha: 0.72), // :1417 ink(…,0.72)
    );
  }

  final Color ringCpu;
  final Color ringMemory;
  final Color ringStorage;
  final Color ringTrack;
  final Color detailInk;
  final Color labelInk;
  final Color memoryActiveInk;
  final Color cpuActiveInk;
  final Color divider;
  final Color tempSubInk;
  final Color memoryLine;
  final Color cpuLine;
  final Color frequencyLine;
}

/// DeskCenter 系统监控卡（`modelData.id === \"system\"`，:1240-1512）。
class KosSystemCard extends ConsumerWidget {
  const KosSystemCard({
    super.key,
    this.cpu,
    this.metrics,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onRemove,
    this.onCycleSize,
  });

  /// CPU 数据源：`ProviderListenable<LoadSeries>`；null 时经
  /// `ShellServicesScope` 取 `services.cpu`（telemetry 接口，
  /// services.dart:109）。`LoadSeries.current` 为 0-1 分数，
  /// `history` 容量 45。
  final ProviderListenable<LoadSeries>? cpu;

  /// metrics.snapshot 投影（内存/存储/频率/温度）；null → 各值 0、
  /// 温度 `--`、内存/频率 sparkline 空。
  final KosSystemMetrics? metrics;

  /// 内容色板；null → build 时按 `context.shellTheme` 解析
  /// （[KosSystemCardColors.forShell]）。
  final KosSystemCardColors? colors;

  /// 尺寸档位（透传 [DeskCard.size]）。
  final WidgetSize size;

  /// 编辑模式角标。
  /// 编辑模式角标。
  final bool editMode;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // cpu listenable 为空且无 ShellServicesScope 时取空序列
    // （对齐 clock 卡的宽容回退，docs/visual-deltas §6 D4）。
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    final listenable = cpu ?? scope?.services.cpu;
    final cpuSeries = listenable != null
        ? ref.watch(listenable)
        : LoadSeries.empty;
    final colors =
        this.colors ?? KosSystemCardColors.forShell(context.shellTheme);
    return DeskCard(
      size: size,
      editMode: editMode,
      onRemove: onRemove,
      onCycleSize: onCycleSize,
      child: _SystemCardBody(
        cpuSeries: cpuSeries,
        metrics: metrics,
        colors: colors,
      ),
    );
  }
}

class _SystemCardBody extends StatefulWidget {
  const _SystemCardBody({
    required this.cpuSeries,
    required this.metrics,
    required this.colors,
  });

  final LoadSeries cpuSeries;
  final KosSystemMetrics? metrics;
  final KosSystemCardColors colors;

  @override
  State<_SystemCardBody> createState() => _SystemCardBodyState();
}

class _SystemCardBodyState extends State<_SystemCardBody> {
  /// 悬停指标（:1264 `hoveredMetric`）：-1 无、0 CPU、1 内存、2 存储。
  int _hoveredMetric = -1;

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    final cpuValue = widget.cpuSeries.current ?? 0; // :1265 ?? 0
    final memoryValue = // :1266-1267
    (metrics != null && metrics.memoryTotalBytes > 0)
        ? metrics.memoryUsedBytes / metrics.memoryTotalBytes
        : 0.0;
    final storageValue = // :1268-1269
    (metrics != null && metrics.diskTotalBytes > 0)
        ? metrics.diskUsedBytes / metrics.diskTotalBytes
        : 0.0;
    final currentC = // :1391-1392 milliC/1000，-1 表示缺
        (metrics?.currentMilliC ?? -1) / 1000;
    final max5C = (metrics?.maximum5MinuteMilliC ?? -1) / 1000; // :1393-1394
    final tempAvailable = currentC >= 0 && max5C >= 0; // :1395-1396
    final dark = context.shellTheme.brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final ringSize = math.min(w * 0.36, h * 0.7); // :1262
        final labels = ['CPU', '内存', '存储']; // :1270
        final values = [cpuValue, memoryValue, storageValue]; // :1272
        return Stack(
          fit: StackFit.expand,
          children: [
            // 三环区（:1259-1382）。
            Positioned(
              left: w * 0.02, // :1261 leftMargin
              top: h * 0.035, // :1261 topMargin
              width: ringSize,
              height: ringSize, // :1263 height: width
              child: MouseRegion(
                // :1365-1381 MouseArea hoverEnabled + 距离分带
                // （onPositionChanged → onHover）。
                onEnter: (_) => setState(() => _hoveredMetric = 0),
                onExit: (_) => setState(() => _hoveredMetric = -1),
                onHover: (event) => setState(
                  () => _hoveredMetric = _bandForOffset(
                    event.localPosition,
                    ringSize,
                  ),
                ),
                child: CustomPaint(
                  painter: _RingsPainter(
                    values: values,
                    colors: widget.colors,
                    // :1301-1302 pick 前项 material——dark（玻璃白系语义）
                    // 走后项细档，light 走 material 粗档。
                    isMaterial: !dark,
                  ),
                  child: _hoveredMetric >= 0
                      // 环心悬停详情（:1344-1363）：图标+「标签 百分比」。
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _metricIcon(_hoveredMetric),
                                style: TextStyle(
                                  color: widget.colors.detailInk,
                                  fontSize: math.max(
                                    10,
                                    ringSize * 0.1, // :1354
                                  ),
                                  height: 1,
                                ),
                              ),
                              Text(
                                '${labels[_hoveredMetric]} '
                                '${(values[_hoveredMetric] * 100).round()}%', // :1358-1359
                                style: TextStyle(
                                  color: widget.colors.detailInk,
                                  fontSize: math.max(
                                    8,
                                    ringSize * 0.075, // :1361
                                  ),
                                  fontWeight: FontWeight.w600,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
              ),
            ),
            // 温度摘要（:1386-1442）：左 0.02w、底 0.045h、0.36w × 0.17h。
            Positioned(
              left: w * 0.02, // :1388
              bottom: h * 0.045, // :1388
              width: w * 0.36, // :1389
              height: h * 0.17, // :1390
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 温度图标（:1401-1406）：源为 bundled SVG
                    // "temperature"，本端绘简化温度计。
                    CustomPaint(
                      size: Size.square(
                        math.max(12, h * 0.17 * 0.54), // :1404
                      ),
                      painter: _ThermometerPainter(
                        color: widget.colors.detailInk,
                      ),
                    ),
                    SizedBox(
                      width: math.max(4, w * 0.36 * 0.04), // :1400 spacing
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tempAvailable
                              ? '${currentC.round()}°'
                              : '--', // :1410-1411
                          style: TextStyle(
                            color: widget.colors.detailInk,
                            fontSize: math.max(10, h * 0.17 * 0.42), // :1413
                            fontWeight: FontWeight.w600,
                            height: 1,
                          ),
                        ),
                        Text(
                          '当前', // :1416
                          style: TextStyle(
                            color: widget.colors.tempSubInk,
                            fontSize: math.max(8, h * 0.17 * 0.25), // :1418
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(width: math.max(4, w * 0.36 * 0.04)),
                    // 1px 分隔（:1421-1426）：高 0.56×栏高。明暗合并 →
                    // `divider`（forShell 取 shell `hairlineSoft`，随壳亮度解析）。
                    Container(
                      width: 1,
                      height: h * 0.17 * 0.56, // :1423
                      color: widget.colors.divider,
                    ),
                    SizedBox(width: math.max(4, w * 0.36 * 0.04)),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tempAvailable
                              ? '${max5C.round()}°'
                              : '--', // :1430-1431
                          style: TextStyle(
                            color: widget.colors.detailInk,
                            fontSize: math.max(10, h * 0.17 * 0.42),
                            fontWeight: FontWeight.w600,
                            height: 1,
                          ),
                        ),
                        Text(
                          '最高', // :1436
                          style: TextStyle(
                            color: widget.colors.tempSubInk,
                            fontSize: math.max(8, h * 0.17 * 0.25),
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 右侧趋势列（:1444-1509）：左 0.47w、右 0.07w、垂直居中、
            // 高 0.76h、spacing max(2,h·0.035)。
            Positioned(
              left: w * 0.47, // :1445
              right: w * 0.07, // :1445
              top: h * 0.12, // verticalCenter 高 0.76h → top=0.12h
              bottom: h * 0.12,
              child: LayoutBuilder(
                builder: (context, col) {
                  final spacing = math.max(2.0, col.maxHeight * 0.035); // :1447
                  final section =
                      (col.maxHeight - spacing * 2) / 3; // :1451/:1472/:1492
                  return Column(
                    children: [
                      SizedBox(
                        height: section,
                        child: _TrendSection(
                          label: '内存  ${(memoryValue * 100).round()}%', // :1455
                          labelColor: _hoveredMetric == 1
                              ? widget
                                    .colors
                                    .memoryActiveInk // :1456-1457
                              : widget.colors.labelInk,
                          values: metrics?.memoryHistory ?? const [],
                          lineColor: widget.colors.memoryLine, // :1463
                          adaptiveRange: true, // :1464
                          fontSize: math.max(8, h * 0.06), // :1458
                        ),
                      ),
                      SizedBox(height: spacing),
                      SizedBox(
                        height: section,
                        child: _TrendSection(
                          label:
                              'CPU  ${(cpuValue * 100).round()}%', // :1475-1476
                          labelColor: _hoveredMetric == 0
                              ? widget
                                    .colors
                                    .cpuActiveInk // :1477-1478
                              : widget.colors.labelInk,
                          values: widget.cpuSeries.history, // :1483
                          lineColor: widget.colors.cpuLine, // :1484
                          adaptiveRange: false,
                          fontSize: math.max(8, h * 0.06),
                        ),
                      ),
                      SizedBox(height: spacing),
                      SizedBox(
                        height: section,
                        child: _TrendSection(
                          label:
                              '平均频率  '
                              '${(metrics?.cpuFrequencyMhz ?? 0).round()} MHz', // :1496
                          labelColor: widget.colors.labelInk, // :1497
                          values:
                              metrics?.frequencyHistory ?? const [], // :1502
                          lineColor: widget.colors.frequencyLine, // :1503
                          adaptiveRange: true, // :1504
                          fontSize: math.max(8, h * 0.06),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// :1369-1379 距离分带：≥0.335w→CPU、≥0.23w→内存、否则存储。
  int _bandForOffset(Offset pos, double width) {
    final dx = pos.dx - width / 2;
    final dy = pos.dy - width / 2;
    final distance = math.sqrt(dx * dx + dy * dy) / width;
    if (distance >= 0.335) return 0;
    if (distance >= 0.23) return 1;
    return 2;
  }
}

/// 悬停指标图标：源 `BundledIcon`（:1271 cpu/memory/drive-harddisk）；
/// 无 SVG 资源，用文字占位符近似（记 deltas §7）。
String _metricIcon(int metric) => switch (metric) {
  0 => '▮', // cpu
  1 => '▤', // memory
  _ => '◉', // drive-harddisk
};

/// 三环 Canvas（:1291-1342）：逐行等价 `drawRing`。
class _RingsPainter extends CustomPainter {
  const _RingsPainter({
    required this.values,
    required this.colors,
    required this.isMaterial,
  });

  final List<double> values;
  final KosSystemCardColors colors;

  /// `AppearanceTokens.isMaterial`：线宽 pick 第一参（:1301-1302）。
  final bool isMaterial;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final center = width / 2;
    // :1297-1298 amount clamp 与 start=-π/2。
    final ringColors = _ringColors();
    final radii = [width * 0.39, width * 0.285, width * 0.18]; // :1319-1321
    // :1301-1302 pick(max(6,w·0.085), max(5,w·0.065))。
    final lineWidth = isMaterial
        ? math.max(6.0, width * 0.085)
        : math.max(5.0, width * 0.065);
    final trackPaint = Paint()
      ..color = colors
          .ringTrack // :1304-1306
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round; // :1303 lineCap round
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final radius = radii[i];
      final r = Rect.fromCircle(center: Offset(center, center), radius: radius);
      // 轨道整圆（:1307-1309）。
      canvas.drawArc(r, 0, math.pi * 2, false, trackPaint);
      // 值弧（:1310-1313）：从 -π/2 起 amount·2π。
      final amount = values[i].clamp(0.0, 1.0); // :1297
      arcPaint.color = ringColors[i];
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * amount, false, arcPaint);
    }
  }

  List<Color> _ringColors() => [
    colors.ringCpu,
    colors.ringMemory,
    colors.ringStorage,
  ]; // :1270-1279

  @override
  bool shouldRepaint(covariant _RingsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.colors != colors ||
      oldDelegate.isMaterial != isMaterial;
}

/// 温度计图标近似（:1401-1406 bundled "temperature" SVG → 简化描边）。
class _ThermometerPainter extends CustomPainter {
  const _ThermometerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, size.width * 0.12)
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    // 管身 + 球泡。
    canvas.drawLine(Offset(w / 2, h * 0.15), Offset(w / 2, h * 0.62), paint);
    canvas.drawCircle(
      Offset(w / 2, h * 0.74),
      w * 0.22,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _ThermometerPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 趋势段：标签 + UsageSparkline（:1449-1508 同构三段）。
class _TrendSection extends StatelessWidget {
  const _TrendSection({
    required this.label,
    required this.labelColor,
    required this.values,
    required this.lineColor,
    required this.adaptiveRange,
    required this.fontSize,
  });

  final String label;
  final Color labelColor;
  final List<double> values;
  final Color lineColor;
  final bool adaptiveRange;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            color: labelColor,
            fontSize: fontSize,
            fontWeight: FontWeight.w600, // DemiBold（:1458/:1479/:1498）
            height: 1,
          ),
        ),
        const SizedBox(height: 1), // :1461 topMargin:1
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
    );
  }
}

/// `UsageSparkline.qml`（bar/UsageSparkline.qml:19-113）逐行移植：
/// `displayValues()` 降采样（maxPoints=36）+ 平滑窗（smoothingWindow=5，
/// radius=2）+ 二次贝塞尔折线（quadraticCurveTo 中点链，:99-103）。
class KosSparklinePainter extends CustomPainter {
  const KosSparklinePainter({
    required this.values,
    required this.lineColor,
    this.adaptiveRange = false,
    this.maxPoints = 36, // :1465/:1485/:1505
    this.smoothingWindow = 5, // :1466/:1486/:1506
  });

  final List<double> values;
  final Color lineColor;
  final bool adaptiveRange;
  final int maxPoints;
  final int smoothingWindow;

  /// `displayValues()`（UsageSparkline.qml:19-54）：maxPoints 桶平均 +
  /// `floor((w-1)/2)` 半径滑动平均。
  List<double> displayValues() {
    final source = values;
    if (source.isEmpty) return const [];
    final count = maxPoints > 1
        ? math.min(maxPoints, source.length)
        : source.length;
    final reduced = List<double>.filled(count, 0);
    for (var point = 0; point < count; ++point) {
      final start = (point * source.length) ~/ count; // :26 floor
      final end = math.max(
        start + 1,
        ((point + 1) * source.length) ~/ count,
      ); // :27
      var total = 0.0;
      var samples = 0;
      for (var index = start; index < end; ++index) {
        final value = source[index];
        if (value.isFinite) {
          total += value;
          samples++;
        }
      }
      reduced[point] = samples > 0 ? total / samples : 0; // :37
    }
    final radius = math.max(0, (smoothingWindow - 1) ~/ 2); // :39 floor
    if (radius == 0) return reduced;
    return [
      for (var index = 0; index < reduced.length; index++) // :42-53
        (() {
          var total = 0.0;
          var samples = 0;
          for (var offset = -radius; offset <= radius; ++offset) {
            final neighbor = index + offset;
            if (neighbor >= 0 && neighbor < reduced.length) {
              total += reduced[neighbor];
              samples++;
            }
          }
          return total / samples;
        })(),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final points = displayValues();
    if (points.length < 2 || size.width <= 0 || size.height <= 0) {
      return; // :60-61
    }
    const inset = 2.0; // :63
    final plotWidth = size.width - inset * 2;
    final plotHeight = size.height - inset * 2;
    var low = 0.0;
    var high = 1.0;
    if (adaptiveRange) {
      // :68-80：取观测范围；极差 <0.01 时以中点 ±0.005 夹取。
      low = points[0];
      high = points[0];
      for (var i = 1; i < points.length; ++i) {
        low = math.min(low, points[i]);
        high = math.max(high, points[i]);
      }
      if (high - low < 0.01) {
        final middle = (high + low) / 2;
        low = math.max(0, middle - 0.005);
        high = math.min(1, middle + 0.005);
      }
    }
    // :81-86 基线：lineColor@0.24、1px。
    canvas.drawLine(
      Offset(inset, size.height - inset),
      Offset(size.width - inset, size.height - inset),
      Paint()
        ..color = lineColor.withValues(alpha: 0.24)
        ..strokeWidth = 1,
    );
    // :93-97 坐标映射。
    final coordinates = [
      for (var i = 0; i < points.length; i++)
        Offset(
          inset + plotWidth * i / (points.length - 1),
          inset +
              plotHeight *
                  (1 - ((points[i] - low) / (high - low)).clamp(0.0, 1.0)),
        ),
    ];
    // :88-106 折线：quadraticCurveTo 中点链，圆 join/cap、2px。
    final path = Path()..moveTo(coordinates[0].dx, coordinates[0].dy);
    for (var i = 1; i < coordinates.length - 1; ++i) {
      final midpointX = (coordinates[i].dx + coordinates[i + 1].dx) / 2;
      final midpointY = (coordinates[i].dy + coordinates[i + 1].dy) / 2;
      path.quadraticBezierTo(
        coordinates[i].dx,
        coordinates[i].dy,
        midpointX,
        midpointY,
      );
    }
    path.lineTo(coordinates.last.dx, coordinates.last.dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            2 // :89
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant KosSparklinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.adaptiveRange != adaptiveRange ||
      oldDelegate.maxPoints != maxPoints ||
      oldDelegate.smoothingWindow != smoothingWindow;
}
