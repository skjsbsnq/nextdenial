// TASK-17 system 详情面板 widget 测试。
//
// 覆盖（任务卡 §验收）：
// - `registerSystemPanel()` 写入 `deskPanelBuilderRegistry['kos-system']`；
// - 渲染：三环区（CustomPaint 环 + 百分比常显）、三段历史曲线（KosSparkline
//   的 CustomPaint）、数值行（CPU 频率 MHz、温度当前/峰值、内存/磁盘
//   used/total GiB）；
// - 空态降级：无 metrics/collector 时数值 '--'、曲线空；
// - collector 注入（`SystemMetricsCollector` + mock 文件回调）时 `metrics`
//   流推帧驱动刷新。
//
// 宿主：`MaterialApp(home:Scaffold)` + `Size(1000,800)`（面板无
// `DeskPanelShell` 材质断言——内容区断言）。SystemPanel 的 `metrics` 流/
// `cpuUpdates` 订阅在用例体末尾经 `pumpWidget(SizedBox())` 卸载面板取消
import 'dart:io' show ProcessResult;

import 'package:denial_sdk/system.dart' show LoadSeries;
import 'package:flutter/material.dart'
    show Color, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/system_metrics_collector.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';
import 'package:kos_deskcenter/src/widgets/system_card.dart';
import 'package:kos_deskcenter/src/widgets/system_panel.dart';

/// 面板用 Material 控件宿主（同 todo_panel_test `_wrap` 范式）。
Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: const Color(0x00000000),
    body: Center(child: SizedBox(width: 640, height: 560, child: child)),
  ),
);

SystemPanel _panel({
  KosSystemMetrics? metrics,
  LoadSeries? cpu,
  SystemMetricsCollector? collector,
  DeskPanelData? data,
}) => SystemPanel(
  request: const DeskPanelRequest(appId: 'kos-system'),
  data: data ??
      DeskPanelData(metrics: metrics, metricsCollector: collector),
  metrics: metrics,
  cpu: cpu,
  collector: collector,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

/// 假 metrics collector：注入 mock 文件回调（不触真实 /proc），`sample()`
/// 可推帧到 `metrics`/`cpuUpdates` 流。
SystemMetricsCollector _mockCollector({
  double cpuUsage = 0.4,
  double memUsed = 4.0,
  double memTotal = 16.0,
  double diskUsed = 100.0,
  double diskTotal = 500.0,
  double frequencyMhz = 3400,
}) {
  return SystemMetricsCollector(
    readFile: (path) async => switch (path) {
      '/proc/stat' =>
        'cpu  ${(cpuUsage * 1000).round()} 0 ${(1000 - cpuUsage * 1000).round()} 0 0 0 0 0 0 0\n',
      '/proc/meminfo' =>
        'MemTotal:       ${(memTotal * 1024 * 1024).round()} kB\n'
            'MemAvailable:   ${((memTotal - memUsed) * 1024 * 1024).round()} kB\n',
      '/proc/cpuinfo' => 'cpu MHz\t\t: $frequencyMhz\n',
      _ => '',
    },
    listDirectory: (path) async => const [],
    runProcess: (exe, args) async => ProcessResult(
      0,
      0,
      'Filesystem 1B-blocks Used Available Use% Mounted on\n'
          '/dev/root ${(diskTotal * 1024 * 1024 * 1024).round()} '
          '${(diskUsed * 1024 * 1024 * 1024).round()} 0 0% /\n',
      '',
    ),
  );
}

void main() {
  group('system 面板', () {
    testWidgets('注册函数写入 deskPanelBuilderRegistry', (tester) async {
      registerSystemPanel();
      expect(deskPanelBuilderRegistry['kos-system'], isNotNull);
      final widget = deskPanelBuilderRegistry['kos-system']!(
        const DeskPanelRequest(appId: 'kos-system'),
        const DeskPanelData(),
      );
      expect(widget, isA<SystemPanel>());
    });

    testWidgets('渲染三环区 + 曲线区 + 数值行（metrics + cpu 注入）', (
      tester,
    ) async {
      final metrics = KosSystemMetrics(
        cpuFrequencyMhz: 3400,
        currentMilliC: 42000,
        maximum5MinuteMilliC: 55000,
        memoryUsedBytes: 8.0 * 1024 * 1024 * 1024,
        memoryTotalBytes: 16.0 * 1024 * 1024 * 1024,
        diskUsedBytes: 200.0 * 1024 * 1024 * 1024,
        diskTotalBytes: 500.0 * 1024 * 1024 * 1024,
        memoryHistory: const [0.3, 0.5, 0.45],
        frequencyHistory: const [2800, 3200, 3400],
      );
      await _pump(
        tester,
        _panel(
          metrics: metrics,
          cpu: const LoadSeries(current: 0.4, history: [0.1, 0.2, 0.4]),
        ),
      );
      await tester.pump();

      // 三环区百分比常显 + 右栏摘要行。
      expect(find.text('40%'), findsWidgets); // CPU 环心 + 摘要
      expect(find.text('50%'), findsWidgets); // 内存
      expect(find.text('40%'), findsWidgets);
      // 曲线区标签。
      expect(find.textContaining('内存'), findsWidgets);
      expect(find.textContaining('CPU'), findsWidgets);
      expect(find.textContaining('平均频率'), findsWidgets);
      // 数值行。
      expect(find.text('CPU 频率'), findsOneWidget);
      expect(find.text('3400 MHz'), findsOneWidget);
      expect(find.text('42° / 55°'), findsOneWidget);
      expect(find.text('内存'), findsWidgets);
      expect(find.text('8.0 / 16.0 GiB'), findsOneWidget);
      expect(find.text('200.0 / 500.0 GiB'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('空态：无 metrics/collector → 数值 --、曲线区照常渲染', (
      tester,
    ) async {
      await _pump(tester, _panel());
      await tester.pump();
      expect(find.text('0 MHz'), findsOneWidget); // cpuFrequencyMhz 缺省 0
      expect(find.text('-- / --'), findsOneWidget); // 温度缺省
      expect(find.text('--'), findsWidgets); // 内存/磁盘缺省
      // 曲线区容器仍在（三段 _TrendRow）。
      expect(find.textContaining('内存'), findsWidgets);
      expect(find.textContaining('CPU'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('collector 注入：metrics 流推帧刷新数值', (tester) async {
      final collector = _mockCollector();
      await _pump(tester, _panel(collector: collector));
      await tester.pump();

      // 广播流事件走真实事件循环——runAsync 内采样并等交付，回到
      // fake-async 后 pump 应用 setState。
      await tester.runAsync(() async {
        await collector.sample();
        await Future<void>.delayed(Duration.zero); // 流交付
      });
      await tester.pump();
      expect(find.text('3400 MHz'), findsOneWidget);
      expect(find.textContaining('4.0 / 16.0 GiB'), findsOneWidget);
      collector.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
