// /proc + /sys backed dock metrics collector (dart:io implementation).
//
// Trimmed port of plugins/kos_deskcenter/lib/src/data/system_metrics_collector.dart
// which ports services/data-service/main.go. Differences (per CONSTRAINTS §12
// copy-and-attribute):
// - CPU usage /proc/stat diffing is NOT ported — the dock consumes
//   `services.cpu` (SDK `LoadSeries`) for the CPU ring instead; this
//   collector supplies memory/disk/temperature/frequency only.
// - Output shape is `DockMetricsSnapshot` (no cpu/network fields).
//
// Sources kept verbatim (algorithm + line anchors):
// - memory: /proc/meminfo MemTotal/MemAvailable (main.go:597-622)
// - disk: one-shot `df -B1 /` (main.go:624-635 statfs equivalent)
// - frequency: cpufreq policy* mean kHz→MHz, /proc/cpuinfo fallback
//   (main.go:637-669)
// - temperature: one-shot probe enumeration thermal_zone*/hwmon* +
//   cpuTemperaturePriority selection (main.go:675-777), 5-minute peak window

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'dock_metrics.dart';

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

Future<DockMetricsProcessResult> _defaultRunProcess(
  String executable,
  List<String> arguments,
) async {
  final result = await Process.run(executable, arguments);
  return DockMetricsProcessResult(
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
  );
}

/// Dock 系统指标采集器（memory/disk/温度/频率；CPU 走 `services.cpu`）。
///
/// 用法：`start()` 后立即采一次并按 [interval] 周期采样；`dispose()` 停表。
/// 采样失败保留上一份快照，不向调用方抛穿（对齐源端 else 空分支）。
final class ProcfsDockMetricsCollector implements DockMetricsCollector {
  ProcfsDockMetricsCollector({
    this.interval = defaultInterval,
    DockMetricsReadFile? readFile,
    DockMetricsListDirectory? listDirectory,
    DockMetricsRunProcess? runProcess,
    DateTime Function()? now,
  })  : _readFile = readFile ?? ((path) => File(path).readAsString()),
        _listDirectory = listDirectory ??
            ((path) => Directory(path)
                .list()
                .map((entity) => entity.path)
                .toList()),
        _runProcess = runProcess ?? _defaultRunProcess,
        _now = now ?? DateTime.now;

  /// 采样周期（对齐 MetricsService.qml:44）。
  final Duration interval;

  /// 默认采样周期 10s（MetricsService.qml:44 / deskcenter
  /// system_metrics_collector.dart:116）。
  static const Duration defaultInterval = Duration(seconds: 10);

  /// 历史环形缓冲容量：对齐 `LoadSeries.capacity` = 45。
  static const int historyCapacity = 45;

  /// 5 分钟温度峰值窗口（main.go `maximum5MinuteMilliC` 语义）。
  static const Duration _peakWindow = Duration(minutes: 5);

  final DockMetricsReadFile _readFile;
  final DockMetricsListDirectory _listDirectory;
  final DockMetricsRunProcess _runProcess;
  final DateTime Function() _now;

  Timer? _timer;
  bool _disposed = false;
  bool _sampling = false;

  DockMetricsSnapshot? _latest;

  /// 一次性枚举的温度探针缓存（main.go `sensorsOnce`+`sensors`，
  /// main.go:789-792：拓扑/标签运行期不变，只重读 inputPath）。
  List<_SensorProbe>? _probes;

  /// 5 分钟温度样本窗（(atMs, milliC)），驱动 `maximum5MinuteMilliC`。
  final ListQueue<({int at, int milliC})> _tempWindow = ListQueue();

  /// 内存/频率环形缓冲（0-1 分数 / MHz），容量 [historyCapacity]。
  final ListQueue<double> _memoryHistory = ListQueue();
  final ListQueue<double> _frequencyHistory = ListQueue();

  final StreamController<DockMetricsSnapshot> _snapshots =
      StreamController<DockMetricsSnapshot>.broadcast();

  @override
  DockMetricsSnapshot? get latest => _latest;

  @override
  Stream<DockMetricsSnapshot> get snapshots => _snapshots.stream;

  @override
  void start() {
    if (_disposed || _timer != null) return;
    unawaited(sample());
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
  }

  @override
  Future<DockMetricsSnapshot?> sample() async {
    if (_disposed || _sampling) return _latest;
    _sampling = true;
    try {
      final (memUsed, memTotal) = await _readMemory();
      final (diskUsed, diskTotal) = await _readDisk();
      final frequency = await _readFrequency();
      final temperature = await _readTemperature();
      _pushBounded(
          _memoryHistory, memTotal > 0 ? memUsed / memTotal : 0.0);
      _pushBounded(_frequencyHistory, frequency);
      final snapshot = DockMetricsSnapshot(
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
      if (!_snapshots.isClosed) _snapshots.add(snapshot);
      return snapshot;
    } on Object {
      return _latest; // 保留上一份快照，不抛穿调用方。
    } finally {
      _sampling = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_snapshots.close());
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
