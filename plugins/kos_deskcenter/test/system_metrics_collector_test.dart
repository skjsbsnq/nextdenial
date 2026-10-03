// SystemMetricsCollector 解析纯 Dart 测试（不触真实 /proc、/sys、df）。
//
// 覆盖（源端锚点 main.go）：/proc/stat 差分 CPU（:569-595）、meminfo
// MemTotal/MemAvailable（:597-622）、df -B1 解析（:626-635）、cpufreq
// policy* 均值与 cpuinfo fallback（:637-669）、thermal/hwmon 温度优先级
// （:675-767）、环形缓冲容量 45（LoadSeries.capacity）、失败保留上一份快照。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/system_metrics_collector.dart';

void main() {
  /// 组装一个全 mock 采集器：`files` 为路径→内容，`dirs` 为目录→子项路径，
  /// `df`/`dfExitCode` 喂默认 runProcess；`runProcess` 可直接注入整段 mock。
  SystemMetricsCollector collector({
    Map<String, String> files = const {},
    Map<String, List<String>> dirs = const {},
    String df = '',
    int dfExitCode = 0,
    MetricsRunProcess? runProcess,
    DateTime Function()? now,
  }) {
    return SystemMetricsCollector(
      now: now,
      readFile: (path) async {
        final content = files[path];
        if (content == null) throw FileSystemException('no file', path);
        return content;
      },
      listDirectory: (path) async {
        final entries = dirs[path];
        if (entries == null) throw FileSystemException('no dir', path);
        return entries;
      },
      runProcess:
          runProcess ??
          (executable, arguments) async {
            expect(executable, 'df');
            return ProcessResult(0, dfExitCode, df, '');
          },
    );
  }

  const procStat1 =
      'cpu  100 0 100 800 0 0 0 0 0 0\n'
      'cpu0 50 0 50 400 0 0 0 0 0 0\n';
  const procStat2 =
      'cpu  200 0 200 900 100 0 0 0 0 0\n'
      'cpu0 100 0 100 450 50 0 0 0 0 0\n';
  const meminfo =
      'MemTotal:       16384000 kB\n'
      'MemFree:         4096000 kB\n'
      'MemAvailable:    8192000 kB\n';
  const dfOut =
      'Filesystem     1B-blocks        Used   Available Use% Mounted on\n'
      '/dev/nvme0n1p2 536870912000 107374182400 402653184000  22% /\n';

  group('CPU /proc/stat 差分（main.go:569-595）', () {
    test('首次采样无前值 → 0；二次差分计算占用', () async {
      var stat = procStat1;
      final c = SystemMetricsCollector(
        readFile: (path) async {
          if (path == '/proc/stat') return stat;
          throw FileSystemException('no file', path);
        },
        listDirectory: (path) async =>
            throw FileSystemException('no dir', path),
        runProcess: (e, a) async => ProcessResult(0, 1, '', ''),
      );
      expect((await c.sample()), isNotNull);
      expect(c.cpuSeries.current, 0); // 首次差分 → 0
      stat = procStat2;
      await c.sample();
      // total 差 400（100→500），idle 差 200（800→1000）→ usage = 0.5。
      expect(c.cpuSeries.current!, closeTo(0.5, 1e-9));
      c.dispose();
    });

    test('cpuSeries 历史容量 45（LoadSeries.capacity 对齐）', () async {
      final c = collector(files: {'/proc/stat': procStat1});
      for (var i = 0; i < 50; i++) {
        await c.sample();
      }
      expect(c.cpuSeries.history.length, lessThanOrEqualTo(45));
      c.dispose();
    });
  });

  group('内存 /proc/meminfo（main.go:597-622）', () {
    test('MemTotal/MemAvailable KiB→字节，used=total-available', () async {
      final c = collector(
        files: {'/proc/meminfo': meminfo, '/proc/stat': procStat1},
        runProcess: (e, a) async => ProcessResult(0, 0, dfOut, ''),
      );
      final m = await c.sample();
      expect(m!.memoryTotalBytes, 16384000 * 1024);
      expect(m.memoryUsedBytes, (16384000 - 8192000) * 1024);
      c.dispose();
    });

    test('meminfo 缺失 → 0/0 不抛穿', () async {
      final c = collector(files: {'/proc/stat': procStat1});
      final m = await c.sample();
      expect(m!.memoryTotalBytes, 0);
      expect(m.memoryUsedBytes, 0);
      c.dispose();
    });
  });

  group('磁盘 df -B1（main.go:626-635 的 Dart 等价）', () {
    test('正常两行输出解析 used/total', () async {
      final c = collector(
        files: {'/proc/stat': procStat1},
        runProcess: (e, a) async => ProcessResult(0, 0, dfOut, ''),
      );
      final m = await c.sample();
      expect(m!.diskTotalBytes, 536870912000);
      expect(m.diskUsedBytes, 107374182400);
      c.dispose();
    });

    test('长设备名换行（统计行只有 5 字段）', () async {
      final c = collector(
        files: {'/proc/stat': procStat1},
        runProcess: (e, a) async => ProcessResult(
          0,
          0,
          'Filesystem          1B-blocks      Used  Available Use% Mounted on\n'
          '/dev/mapper/verylongname\n'
          '                   536870912000 107374182400 402653184000  22% /\n',
          '',
        ),
      );
      final m = await c.sample();
      expect(m!.diskTotalBytes, 536870912000);
      expect(m.diskUsedBytes, 107374182400);
      c.dispose();
    });

    test('df 失败 → 0/0', () async {
      final c = collector(
        files: {'/proc/stat': procStat1},
        runProcess: (e, a) async => ProcessResult(0, 1, '', 'error'),
      );
      final m = await c.sample();
      expect(m!.diskTotalBytes, 0);
      c.dispose();
    });
  });

  group('CPU 频率（main.go:637-669）', () {
    test('cpufreq policy* scaling_cur_freq 均值 kHz→MHz', () async {
      final c = collector(
        files: {
          '/proc/stat': procStat1,
          '/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq': '3400000',
          '/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq': '2800000',
        },
        dirs: {
          '/sys/devices/system/cpu/cpufreq': [
            '/sys/devices/system/cpu/cpufreq/policy0',
            '/sys/devices/system/cpu/cpufreq/policy4',
            '/sys/devices/system/cpu/cpufreq/other',
          ],
        },
      );
      final m = await c.sample();
      expect(m!.cpuFrequencyMhz, closeTo(3100, 1e-9)); // (3400+2800)/2 MHz
      c.dispose();
    });

    test('无 cpufreq → /proc/cpuinfo "cpu MHz" fallback', () async {
      final c = collector(
        files: {
          '/proc/stat': procStat1,
          '/proc/cpuinfo':
              'processor\t: 0\ncpu MHz\t\t: 3400.000\n'
              'processor\t: 1\ncpu MHz\t\t: 2800.000\n',
        },
        dirs: {}, // cpufreq 目录不存在 → listDirectory 抛 → fallback
      );
      final m = await c.sample();
      expect(m!.cpuFrequencyMhz, closeTo(3100, 1e-9));
      c.dispose();
    });
  });

  group('CPU 温度（main.go:675-767）', () {
    test('hwmon coretemp "Package id 0" 优先级 100 胜出', () async {
      final c = collector(
        files: {
          '/proc/stat': procStat1,
          '/sys/class/hwmon/hwmon0/name': 'coretemp',
          '/sys/class/hwmon/hwmon0/temp1_input': '45000',
          '/sys/class/hwmon/hwmon0/temp1_label': 'Package id 0',
          '/sys/class/hwmon/hwmon0/temp2_input': '40000',
          '/sys/class/hwmon/hwmon0/temp2_label': 'Core 0',
        },
        dirs: {
          '/sys/class/hwmon': ['/sys/class/hwmon/hwmon0'],
          '/sys/class/hwmon/hwmon0': [
            '/sys/class/hwmon/hwmon0/temp1_input',
            '/sys/class/hwmon/hwmon0/temp2_input',
          ],
        },
      );
      final m = await c.sample();
      expect(m!.currentMilliC, 45000); // package id 优先于 core
      expect(m.maximum5MinuteMilliC, 45000);
      c.dispose();
    });

    test('thermal_zone 只收 label 含 cpu/pkg 的 zone', () async {
      final c = collector(
        files: {
          '/proc/stat': procStat1,
          '/sys/class/thermal/thermal_zone0/type': 'x86_pkg_temp',
          '/sys/class/thermal/thermal_zone0/temp': '44000',
          '/sys/class/thermal/thermal_zone1/type': 'acpitz', // 非 cpu → 跳过
          '/sys/class/thermal/thermal_zone1/temp': '99999',
        },
        dirs: {
          '/sys/class/thermal': [
            '/sys/class/thermal/thermal_zone0',
            '/sys/class/thermal/thermal_zone1',
          ],
        },
      );
      final m = await c.sample();
      expect(m!.currentMilliC, 44000); // acpitz 99999 不采信
      c.dispose();
    });

    test('无任何传感器 → -1（空态）', () async {
      final c = collector(files: {'/proc/stat': procStat1});
      final m = await c.sample();
      expect(m!.currentMilliC, -1);
      expect(m.maximum5MinuteMilliC, -1);
      c.dispose();
    });
  });

  group('历史缓冲与降级', () {
    test('memoryHistory/frequencyHistory 容量 45', () async {
      final c = collector(
        files: {
          '/proc/stat': procStat1,
          '/proc/meminfo': meminfo,
          '/proc/cpuinfo': 'cpu MHz\t\t: 3000.000\n',
        },
        runProcess: (e, a) async => ProcessResult(0, 0, dfOut, ''),
      );
      for (var i = 0; i < 50; i++) {
        await c.sample();
      }
      expect(c.latest!.memoryHistory.length, 45);
      expect(c.latest!.frequencyHistory.length, 45);
      c.dispose();
    });

    test('采样整体抛错 → 保留上一份快照不抛穿（else 空分支）', () async {
      var statOk = true;
      final c = SystemMetricsCollector(
        readFile: (path) async {
          if (path == '/proc/stat' && !statOk) {
            throw const FormatException('boom');
          }
          if (path == '/proc/stat') return procStat1;
          if (path == '/proc/meminfo') return meminfo;
          throw FileSystemException('', path);
        },
        listDirectory: (path) async => throw FileSystemException('', path),
        runProcess: (e, a) async => ProcessResult(0, 0, dfOut, ''),
      );
      final first = await c.sample();
      expect(first!.memoryTotalBytes, greaterThan(0));
      statOk = false;
      final second = await c.sample();
      expect(identical(second, first), isTrue); // 保留上一份
      c.dispose();
    });
  });
}
