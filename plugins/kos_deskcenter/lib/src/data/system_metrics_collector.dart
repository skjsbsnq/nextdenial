/// 插件内嵌系统指标采集器（`SystemMetricsCollector`）。
///
/// `kos-data.sock` 在 Denial 会话不存在（kos-data-service 未运行），本采集器
/// 把 NextKde `services/data-service/main.go` 的 metrics 采样逻辑直接移植为
/// Dart，产出 `KosSystemMetrics`（system_card.dart:55-146 已消费的结构）与
/// CPU `LoadSeries`（denial_sdk load_series.dart:29-35）。
///
/// 逐项数据源对应（main.go 行号锚点）：
/// - CPU 占用：`/proc/stat` 首行差分（`readCPU` main.go:566-595；
///   idle = idle+iowait 字段，首次采样无前值 → 0）；
/// - 内存：`/proc/meminfo` `MemTotal:`/`MemAvailable:`（`readMem`
///   main.go:597-622；KiB×1024 → 字节，used=max(0,total-available)）；
/// - 磁盘：源端 `unix.Statfs("/")`（`readDisk` main.go:624-635），
///   Dart 无 statfs，等价为一次性 `df -B1 /` 子进程解析
///   （任务卡允许一次性 `df`；输出行与 statfs 同计数）；
/// - CPU 频率：`/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq`
///   均值 kHz→MHz，fallback `/proc/cpuinfo` "cpu MHz"（`readFrequency`
///   main.go:637-669）；
/// - CPU 温度：一次性枚举 `/sys/class/thermal/thermal_zone*/type` +
///   `/sys/class/hwmon/hwmon*/temp*_input`（`enumerateSensors`
///   main.go:733-767，probe 只枚举一次），按 `cpuTemperaturePriority`
///   （main.go:675-703）coretemp/k10temp 优先级选单值，单位 millidegree。
///
/// CPU 占用不喂 `KosSystemMetrics`（该结构无 cpu 字段）：卡片 CPU 环/sparkline
/// 消费 `ProviderListenable<LoadSeries>`（system_card.dart:237），容器层优先
/// 注入 SDK `services.cpu`（ShellTelemetryServices.cpu）；SDK telemetry 不可用
/// 时改用 [cpuSeries]/[cpuUpdates]——由本采集器 /proc/stat 差分维护的同容量
/// （45，LoadSeries.capacity）序列。
///
/// 周期默认 10s（对齐 desk_center_view.dart:90 `_kMetricsPoll` 与
/// MetricsService.qml:44）。采样失败保留上一份快照，不向调用方抛穿
/// （对齐源端 else 空分支降级语义）。
///
/// 文件系统/进程访问全部经构造注入回调（`readFile`/`listDirectory`/
/// `runProcess`），单测可喂 mock 内容不触真实 /proc /sys。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:denial_sdk/system.dart' show LoadSeries;

import '../widgets/system_card.dart' show KosSystemMetrics;

/// 读单个文件文本的注入点（默认 `File(path).readAsString()`）。
typedef MetricsReadFile = Future<String> Function(String path);

/// 列目录项（返回完整路径列表）的注入点（默认 `Directory(path).list()`）。
typedef MetricsListDirectory = Future<List<String>> Function(String path);

/// 一次性子进程的注入点（默认 `Process.run`）。
typedef MetricsRunProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// 单次采样的 `/proc/stat` CPU 计数快照（差分输入）。
final class _CpuCounters {
  const _CpuCounters({required this.total, required this.idle});

  /// 全部字段之和（main.go:577-582）。
  final double total;

  /// idle+iowait（main.go:583-585 `i==4||i==5`）。
  final double idle;
}

/// 一次性枚举到的温度探针（main.go:724-731 `sensorProbe`）。
final class _SensorProbe {
  const _SensorProbe({
    required this.source,
    required this.device,
    required this.label,
    required this.inputPath,
  });

  /// `thermal`/`hwmon`（main.go:678 `strings.ToLower(reading.Source)`）。
  final String source;

  /// hwmon 设备名（`/sys/class/hwmon/hwmon*/name`）；thermal zone 恒
  /// `kernel`（main.go:752）。
  final String device;

  /// thermal zone `type` 或 hwmon `temp*_label`（缺省 `"Temperature N"`，
  /// main.go:761-763）。
  final String label;

  /// 每周期重读的 live 值文件（millidegree）。
  final String inputPath;
}

/// 插件内嵌系统指标采集器。
///
/// 用法：`start()` 后立即采一次并按 [interval] 周期采样；`dispose()` 停表。
/// 最新快照读 [latest]/[metrics] 流；CPU 序列读 [cpuSeries]/[cpuUpdates]。
final class SystemMetricsCollector {
  SystemMetricsCollector({
    this.interval = defaultInterval,
    MetricsReadFile? readFile,
    MetricsListDirectory? listDirectory,
    MetricsRunProcess? runProcess,
    DateTime Function()? now,
  }) : _readFile =
           readFile ?? ((path) => File(path).readAsString()),
       _listDirectory =
           listDirectory ??
           ((path) => Directory(
             path,
           ).list().map((entity) => entity.path).toList()),
       _runProcess = runProcess ?? Process.run,
       _now = now ?? DateTime.now;

  /// 采样周期（对齐 `_kMetricsPoll`，desk_center_view.dart:90）。
  final Duration interval;

  /// 默认采样周期 10s（MetricsService.qml:44 / desk_center_view.dart:90）。
  static const Duration defaultInterval = Duration(seconds: 10);

  /// 历史环形缓冲容量（sparkline 用）：对齐 `LoadSeries.capacity`=45
  /// （denial_sdk load_series.dart:30-31），不抄源端 360。
  static const int historyCapacity = LoadSeries.capacity;

  /// 5 分钟温度峰值窗口（main.go `maximum5MinuteMilliC` 语义）。
  static const Duration _peakWindow = Duration(minutes: 5);

  final MetricsReadFile _readFile;
  final MetricsListDirectory _listDirectory;
  final MetricsRunProcess _runProcess;
  final DateTime Function() _now;

  Timer? _timer;
  bool _disposed = false;
  bool _sampling = false;

  KosSystemMetrics? _latest;
  LoadSeries _cpu = LoadSeries.empty;

  /// /proc/stat 差分前值（main.go:187 `prevCPUTotal/prevCPUIdle`）。
  _CpuCounters? _prevCpu;

  /// 一次性枚举的温度探针缓存（main.go `sensorsOnce`+`sensors`，
  /// main.go:789-792 注释：拓扑/标签运行期不变，只重读 inputPath）。
  List<_SensorProbe>? _probes;

  /// 5 分钟温度样本窗（(atMs, milliC)），驱动 `maximum5MinuteMilliC`。
  final ListQueue<({int at, int milliC})> _tempWindow = ListQueue();

  /// 内存/频率环形缓冲（0-1 分数 / MHz），容量 [historyCapacity]。
  final ListQueue<double> _memoryHistory = ListQueue();
  final ListQueue<double> _frequencyHistory = ListQueue();

  final StreamController<KosSystemMetrics> _metrics =
      StreamController<KosSystemMetrics>.broadcast();
  final StreamController<LoadSeries> _cpuUpdates =
      StreamController<LoadSeries>.broadcast();

  /// 最近一次成功快照；尚无成功采样时为 null。
  KosSystemMetrics? get latest => _latest;

  /// 逐快照广播流（仅成功采样时追加；失败保留上一份不发帧）。
  Stream<KosSystemMetrics> get metrics => _metrics.stream;

  /// 当前 CPU `LoadSeries`（/proc/stat 差分，0-1 分数，容量 45）。
  LoadSeries get cpuSeries => _cpu;

  /// CPU 序列更新流；容器层在 SDK `services.cpu` 不可用时用它喂 system 卡。
  Stream<LoadSeries> get cpuUpdates => _cpuUpdates.stream;

  /// 立即采一次并启动周期采样（幂等）。
  void start() {
    if (_disposed || _timer != null) return;
    unawaited(sample());
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
  }

  /// 手动采一次样；成功时更新 [latest]/[cpuSeries] 并广播，失败保留上一份
  /// 快照（对齐源端 else 空分支）返回 null。
  Future<KosSystemMetrics?> sample() async {
    if (_disposed || _sampling) return _latest;
    _sampling = true;
    try {
      final cpu = await _readCpu();
      final (memUsed, memTotal) = await _readMemory();
      final (diskUsed, diskTotal) = await _readDisk();
      final frequency = await _readFrequency();
      final temperature = await _readTemperature();
      _pushBounded(_memoryHistory, memTotal > 0 ? memUsed / memTotal : 0);
      _pushBounded(_frequencyHistory, frequency);
      _cpu = _cpu.append(cpu.clamp(0.0, 1.0));
      final snapshot = KosSystemMetrics(
        currentMilliC: temperature,
        maximum5MinuteMilliC: _peakTemperature(temperature),
        cpuFrequencyMhz: frequency,
        memoryUsedBytes: memUsed,
        memoryTotalBytes: memTotal,
        diskUsedBytes: diskUsed,
        diskTotalBytes: diskTotal,
        memoryHistory: _memoryHistory.toList(),
        frequencyHistory: _frequencyHistory.toList(),
      );
      _latest = snapshot;
      if (!_metrics.isClosed) _metrics.add(snapshot);
      if (!_cpuUpdates.isClosed) _cpuUpdates.add(_cpu);
      return snapshot;
    } on Object {
      return _latest; // 保留上一份快照，不抛穿调用方。
    } finally {
      _sampling = false;
    }
  }

  /// 停止采样并关闭流；之后对象不可复用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_metrics.close());
    unawaited(_cpuUpdates.close());
  }

  static void _pushBounded(ListQueue<double> buffer, double value) {
    buffer.add(value);
    while (buffer.length > historyCapacity) {
      buffer.removeFirst();
    }
  }

  /// 5 分钟峰值温度（main.go `maximum5MinuteMilliC`）；无样本 → -1。
  int _peakTemperature(int milliC) {
    final cutoff = _now().millisecondsSinceEpoch - _peakWindow.inMilliseconds;
    while (_tempWindow.isNotEmpty && _tempWindow.first.at < cutoff) {
      _tempWindow.removeFirst();
    }
    if (milliC > 0) {
      _tempWindow.add((at: _now().millisecondsSinceEpoch, milliC: milliC));
    }
    var peak = -1;
    for (final sample in _tempWindow) {
      if (sample.milliC > peak) peak = sample.milliC;
    }
    return peak;
  }

  /// `readCPU`（main.go:569-595）：/proc/stat 首行差分；首次无前值 → 0。
  Future<double> _readCpu() async {
    final raw = await _readFile('/proc/stat');
    final firstLine = raw.split('\n').first;
    final fields = firstLine.trim().split(RegExp(r'\s+'));
    if (fields.length < 5) return _cpuUsage(0, 0);
    var total = 0.0;
    var idle = 0.0;
    for (var i = 1; i < fields.length; i++) {
      final n = double.tryParse(fields[i]) ?? 0;
      total += n;
      if (i == 4 || i == 5) idle += n; // idle+iowait（main.go:583-585）
    }
    return _cpuUsage(total, idle);
  }

  double _cpuUsage(double total, double idle) {
    final prev = _prevCpu;
    _prevCpu = _CpuCounters(total: total, idle: idle);
    if (prev != null && prev.total > 0 && total > prev.total) {
      final usage = 1 - (idle - prev.idle) / (total - prev.total);
      return usage.clamp(0.0, 1.0); // main.go:589 math.Max(0,Min(1,…))
    }
    return 0;
  }

  /// `readMem`（main.go:597-622）：KiB→字节，used=max(0,total-available)。
  Future<(double, double)> _readMemory() async {
    try {
      final raw = await _readFile('/proc/meminfo');
      var memTotal = 0.0;
      var memAvailable = 0.0;
      for (final line in raw.split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 2) continue;
        final value = double.tryParse(fields[1]) ?? 0;
        if (fields[0] == 'MemTotal:') {
          memTotal = value;
        } else if (fields[0] == 'MemAvailable:') {
          memAvailable = value;
        }
      }
      if (memTotal <= 0) return (0.0, 0.0);
      final used = memTotal - memAvailable;
      return (used > 0 ? used * 1024 : 0.0, memTotal * 1024);
    } on Object {
      return (0.0, 0.0);
    }
  }

  /// `readDisk`（main.go:626-635）的 Dart 等价：一次性 `df -B1 /`。
  /// 数据行取最后一行；长设备名换行时统计行只有 5 字段（total 起自
  /// fields[0]），正常行 ≥6 字段（total/used 为 fields[1]/[2]）。
  Future<(double, double)> _readDisk() async {
    try {
      final result = await _runProcess('df', const ['-B1', '/']);
      if (result.exitCode != 0) return (0.0, 0.0);
      final lines = result.stdout
          .toString()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      if (lines.length < 2) return (0.0, 0.0);
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      final totalIndex = fields.length >= 6 ? 1 : 0;
      if (fields.length < 5) return (0.0, 0.0);
      final total = double.tryParse(fields[totalIndex]) ?? 0;
      final used = double.tryParse(fields[totalIndex + 1]) ?? 0;
      if (total <= 0) return (0.0, 0.0);
      return (used, total);
    } on Object {
      return (0.0, 0.0);
    }
  }

  /// `readFrequency`（main.go:637-669）：cpufreq policy* 均值 kHz→MHz；
  /// 无 cpufreq 驱动时 fallback /proc/cpuinfo "cpu MHz" 均值（MHz 原域）。
  Future<double> _readFrequency() async {
    try {
      final entries = await _listDirectory('/sys/devices/system/cpu/cpufreq');
      var sum = 0.0;
      var count = 0;
      for (final entry in entries) {
        final name = entry.split('/').last;
        if (!name.startsWith('policy')) continue;
        final value = await _parseDoubleFile('$entry/scaling_cur_freq');
        if (value > 0) {
          sum += value;
          count++;
        }
      }
      if (count > 0) return sum / count / 1000; // kHz -> MHz
    } on Object {
      // cpufreq 目录不存在 → 走 cpuinfo fallback（main.go:644 同源语义）。
    }
    try {
      final raw = await _readFile('/proc/cpuinfo');
      var sum = 0.0;
      var count = 0;
      for (final line in raw.split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        // "cpu MHz\t: 3400.000" → [cpu, MHz, :, 3400.000]（main.go:652-659）。
        if (fields.length >= 4 && fields[0] == 'cpu' && fields[1] == 'MHz') {
          final value = double.tryParse(fields[3]);
          if (value != null) {
            sum += value;
            count++;
          }
        }
      }
      return count > 0 ? sum / count : 0;
    } on Object {
      return 0;
    }
  }

  /// `readTemperature`（main.go:769-777）：probe 一次性枚举 + 每周期重读
  /// inputPath，经 `_cpuTemperaturePriority` 选单值（millidegree；-1 缺失）。
  Future<int> _readTemperature() async {
    _probes ??= await _enumerateSensors();
    var priority = 0;
    var current = -1;
    for (final probe in _probes!) {
      final milliC = (await _parseDoubleFile(probe.inputPath)).round();
      final candidate = _cpuTemperaturePriority(
        source: probe.source,
        device: probe.device,
        label: probe.label,
        milliC: milliC,
      );
      if (candidate == 0 || candidate < priority) continue;
      // main.go:711-717：同级取更大值，更高级直接替换。
      if (candidate > priority || milliC > current) {
        priority = candidate;
        current = milliC;
      }
    }
    return current;
  }

  /// `enumerateSensors`（main.go:734-767）：thermal_zone 只收 label 含
  /// cpu/pkg 的 zone；hwmon 收全部 temp*_input（优先级在选择时判定）。
  Future<List<_SensorProbe>> _enumerateSensors() async {
    final probes = <_SensorProbe>[];
    try {
      for (final entry in await _listDirectory('/sys/class/thermal')) {
        final name = entry.split('/').last;
        if (!name.startsWith('thermal_zone')) continue;
        final label = (await _readTrimmed('$entry/type')).toLowerCase();
        if (!label.contains('cpu') && !label.contains('pkg')) continue;
        probes.add(
          _SensorProbe(
            source: 'thermal',
            device: 'kernel',
            label: label,
            inputPath: '$entry/temp',
          ),
        );
      }
    } on Object {
      // /sys/class/thermal 不存在（虚拟机/容器）→ 只走 hwmon。
    }
    try {
      for (final hwmon in await _listDirectory('/sys/class/hwmon')) {
        if (!hwmon.split('/').last.startsWith('hwmon')) continue;
        final device = await _readTrimmed('$hwmon/name');
        try {
          for (final input in await _listDirectory(hwmon)) {
            final name = input.split('/').last;
            if (!name.startsWith('temp') || !name.endsWith('_input')) {
              continue;
            }
            final index = name.substring(4, name.length - 6); // tempN_input→N
            var label = await _readTrimmed('$hwmon/temp${index}_label');
            if (label.isEmpty) {
              label = 'Temperature $index'; // main.go:762-763
            }
            probes.add(
              _SensorProbe(
                source: 'hwmon',
                device: device,
                label: label,
                inputPath: input,
              ),
            );
          }
        } on Object {
          continue; // 单个 hwmon 目录读失败不拖垮枚举。
        }
      }
    } on Object {
      // /sys/class/hwmon 不存在 → probes 可能为空，温度恒 -1。
    }
    return probes;
  }

  /// `cpuTemperaturePriority`（main.go:675-703）逐行移植：选包级温度而非
  /// 平均 ACPI/thermal/逐核重复视图。0 = 不采信。
  static int _cpuTemperaturePriority({
    required String source,
    required String device,
    required String label,
    required int milliC,
  }) {
    if (milliC <= 0) return 0;
    final dev = device.toLowerCase();
    final lab = label.toLowerCase();
    if (dev == 'coretemp' && lab.contains('package id')) return 100;
    if ((dev == 'k10temp' || dev.contains('zenpower')) && lab == 'tctl') {
      return 100;
    }
    if ((dev == 'k10temp' || dev.contains('zenpower')) && lab == 'tdie') {
      return 95;
    }
    if (source == 'thermal' && lab == 'x86_pkg_temp') return 90;
    if (lab.contains('package') || lab.contains('pkg')) return 80;
    if (source == 'thermal' && lab.contains('tcpu')) return 70;
    if (dev == 'coretemp' && lab.startsWith('core ')) return 60;
    if (source == 'thermal' && lab.contains('cpu')) return 50;
    return 0;
  }

  Future<double> _parseDoubleFile(String path) async {
    try {
      return double.tryParse(await _readTrimmed(path)) ?? 0;
    } on Object {
      return 0;
    }
  }

  Future<String> _readTrimmed(String path) async {
    try {
      return (await _readFile(path)).trim();
    } on Object {
      return '';
    }
  }
}
