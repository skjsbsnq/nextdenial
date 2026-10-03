// KosSystemCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:1240-1512 的 system 分支：三环+温度摘要+
// 三段趋势标签。数据源：telemetry.cpu（LoadSeries 注入）+
// KosSystemMetrics（metrics.snapshot 投影注入）。

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_sdk/system.dart' show LoadSeries;
import 'package:kos_deskcenter/src/widgets/system_card.dart';

Widget _wrap(Widget child, {double w = 340, double h = 200}) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(width: w, height: h, child: child),
    ),
  ),
);

void main() {
  testWidgets('system 卡渲染趋势标签与温度（:1444-1509、:1386-1442）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosSystemCard(
          cpu: Provider<LoadSeries>(
            (_) =>
                LoadSeries(current: 0.42, history: const [0.1, 0.2, 0.3, 0.42]),
          ),
          metrics: KosSystemMetrics(
            currentMilliC: 46000,
            maximum5MinuteMilliC: 61000,
            cpuFrequencyMhz: 3400.5,
            memoryUsedBytes: 8000,
            memoryTotalBytes: 16000,
            diskUsedBytes: 107374182400,
            diskTotalBytes: 536870912000,
            memoryHistory: const [0.4, 0.5, 0.5],
            frequencyHistory: const [3000, 3200, 3400],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('内存  50%'), findsOneWidget); // :1455
    expect(find.text('CPU  42%'), findsOneWidget); // :1475-1476
    expect(find.text('平均频率  3401 MHz'), findsOneWidget); // :1496 round
    expect(find.text('46°'), findsOneWidget); // :1410-1411
    expect(find.text('61°'), findsOneWidget); // :1430-1431
    expect(find.text('当前'), findsOneWidget); // :1416
    expect(find.text('最高'), findsOneWidget); // :1436
  });

  testWidgets('空态：无 metrics → 0% 与 --（:1395-1396、:1411/:1431）', (tester) async {
    await tester.pumpWidget(
      _wrap(KosSystemCard(cpu: Provider<LoadSeries>((_) => LoadSeries.empty))),
    );
    await tester.pump();
    expect(find.text('内存  0%'), findsOneWidget);
    expect(find.text('CPU  0%'), findsOneWidget);
    expect(find.text('平均频率  0 MHz'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2)); // 当前/最高温度
  });

  testWidgets('无 cpu provider 且无 scope → 空序列渲染（宽容回退）', (tester) async {
    await tester.pumpWidget(_wrap(const KosSystemCard()));
    await tester.pump();
    expect(find.text('CPU  0%'), findsOneWidget);
  });

  test('KosSparklinePainter.displayValues 对齐 UsageSparkline.qml:19-54', () {
    // maxPoints 桶平均 + smoothingWindow=5（radius 2）滑动平均。
    final p = KosSparklinePainter(
      values: List.generate(45, (i) => i / 45),
      lineColor: const Color(0xFFFF375F),
    );
    final reduced = p.displayValues();
    expect(reduced.length, 36); // maxPoints 截断
    // displayValues 平滑后单调性保持。
    for (var i = 1; i < reduced.length; i++) {
      expect(reduced[i] >= reduced[i - 1], isTrue);
    }
    // 空输入 → 空。
    expect(
      KosSparklinePainter(
        values: const [],
        lineColor: const Color(0xFF000000),
      ).displayValues(),
      isEmpty,
    );
  });
}
