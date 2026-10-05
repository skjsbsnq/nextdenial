/// KOS Dock 信息卡区系统指标数据接口层（纯接口/模型层，无 dart:io）。
///
/// 接口/IO 分离（CONSTRAINTS §10）：本文件声明 [DockMetricsSnapshot]、
/// 抽象 [DockMetricsCollector] 接口与采集注入点 typedef
/// （`DockMetricsReadFile`/`DockMetricsListDirectory`/`DockMetricsRunProcess`）；
/// dart:io 实现在 `dock_metrics_io.dart`（`ProcfsDockMetricsCollector`）。
/// CPU 占用环直接消费 `services.cpu`（SDK `LoadSeries`），本 collector
/// 不重复 /proc/stat 差分（记 docs/visual-deltas.md）。
///
/// 快照语义锚定 NextKde `shell/desktop/modules/dock/DockTemperatureWidget.qml`
/// 与 `services/data-service/main.go` 的 metrics 读数；采集语义行号在 io
/// 实现内标注。
library;

/// Dock metrics 卡的快照投影。
///
/// 字段子集对应 `KosSystemMetrics`（kos_deskcenter widgets/system_card.dart）
/// 去掉 dock 侧不消费的 cpu/network 维度：
/// - `currentMilliC`/`maximum5MinuteMilliC`：thermal/hwmon 单值温度
///   （millidegree；-1 = 不可用 → 卡面 `--°`，KOS DockMetricGlyph 同式）；
/// - `cpuFrequencyMhz`：cpufreq 均值 MHz（0 = 不可用）；
/// - `memoryUsedBytes`/`memoryTotalBytes`、`diskUsedBytes`/`diskTotalBytes`：
///   字节；total ≤ 0 → 对应环按 0 绘制；
/// - `memoryHistory`/`frequencyHistory`：0-1 分数 / MHz 环形缓冲，
///   容量对齐 `LoadSeries.capacity` = 45。
final class DockMetricsSnapshot {
  const DockMetricsSnapshot({
    this.currentMilliC = -1,
    this.maximum5MinuteMilliC = -1,
    this.cpuFrequencyMhz = 0,
    this.memoryUsedBytes = 0,
    this.memoryTotalBytes = 0,
    this.diskUsedBytes = 0,
    this.diskTotalBytes = 0,
    this.memoryHistory = const <double>[],
    this.frequencyHistory = const <double>[],
  });

  final int currentMilliC;
  final int maximum5MinuteMilliC;
  final double cpuFrequencyMhz;
  final double memoryUsedBytes;
  final double memoryTotalBytes;
  final double diskUsedBytes;
  final double diskTotalBytes;
  final List<double> memoryHistory;
  final List<double> frequencyHistory;

  /// 温度可用性：KOS DockTemperatureWidget `available = currentMilliC>=0
  /// && maximum5MinuteMilliC>=0`；不可用卡面显 `--°`。
  bool get temperatureAvailable =>
      currentMilliC >= 0 && maximum5MinuteMilliC >= 0;

  /// 内存使用分数 0-1（total ≤ 0 → 0）。
  double get memoryFraction =>
      memoryTotalBytes > 0 ? (memoryUsedBytes / memoryTotalBytes).clamp(0.0, 1.0) : 0.0;

  /// 磁盘使用分数 0-1（total ≤ 0 → 0）。
  double get diskFraction =>
      diskTotalBytes > 0 ? (diskUsedBytes / diskTotalBytes).clamp(0.0, 1.0) : 0.0;
}

/// 系统指标采集器接口（CONSTRAINTS §10：测试注入假实现）。
///
/// 用法：`start()` 立即采一次并按周期采样；`dispose()` 停表；最新快照读
/// [latest]/[snapshots] 流。CPU 占用不在此接口内（走 `services.cpu`）。
abstract interface class DockMetricsCollector {
  /// 最近一次成功快照；尚无成功采样时为 null。
  DockMetricsSnapshot? get latest;

  /// 逐快照广播流（仅成功采样时追加；失败保留上一份不发帧）。
  Stream<DockMetricsSnapshot> get snapshots;

  /// 立即采一次并启动周期采样（幂等）。
  void start();

  /// 手动采一次样；成功时更新 [latest] 并广播，失败保留上一份返回 null。
  Future<DockMetricsSnapshot?> sample();

  /// 停止采样并关闭流；之后对象不可复用。
  void dispose();
}

/// 读单个文件文本的注入点（默认 `File(path).readAsString()`）。
typedef DockMetricsReadFile = Future<String> Function(String path);

/// 列目录项（返回完整路径列表）的注入点（默认 `Directory(path).list()`）。
typedef DockMetricsListDirectory = Future<List<String>> Function(String path);

/// 一次性子进程结果（不引 dart:io `ProcessResult` 进接口层）。
final class DockMetricsProcessResult {
  const DockMetricsProcessResult({
    required this.exitCode,
    required this.stdout,
  });

  final int exitCode;
  final String stdout;
}

/// 一次性子进程的注入点（默认 `Process.run` → [DockMetricsProcessResult]）。
typedef DockMetricsRunProcess = Future<DockMetricsProcessResult> Function(
  String executable,
  List<String> arguments,
);
