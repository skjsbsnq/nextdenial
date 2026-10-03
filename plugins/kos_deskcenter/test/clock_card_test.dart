// KosClockCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:608-706 的 clock 分支：CustomPainter 表盘 +
// 右下计时器入口。数据经注入的
// `Provider<AsyncValue<DateTime>>`（对应 services.telemetry.clock）。

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/clock_card.dart';
import 'package:kos_deskcenter/src/widgets/desk_card.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart' show WidgetSize;

final _fixedNow = DateTime(2026, 9, 30, 15, 42, 18);

Widget _wrap(Widget child) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 200, height: 200, child: child)),
  ),
);

void main() {
  testWidgets('clock 卡以注入时刻渲染表盘与数字', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosClockCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_fixedNow)),
        ),
      ),
    );
    await tester.pump();
    // 表盘 CustomPaint 存在；数字 1-12 由 TextPainter 绘制（非 Widget），
    // 验证组件树含 KosClockPainter 即可。
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is KosClockPainter,
      ),
      findsOneWidget,
    );
    // TASK-09：flowerShaped 已删除——卡片统一吃 Denial ShellTheme 材质，
    // 不再透传表面形态参数；断言 DeskCard 包装仍在即可。
    expect(find.byType(DeskCard), findsOneWidget);
    // 收尾卸载，取消秒级 Timer（D5 补足），避免测试末 pending timer。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AsyncValue 无值时回退 now() 仍能渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosClockCard(
          clock: Provider<AsyncValue<DateTime>>(
            (_) => const AsyncLoading<DateTime>(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(KosClockCard), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // 收尾取消秒级 Timer
  });

  testWidgets('空态：clock 缺省且无 ShellServicesScope 回退 now() 渲染', (tester) async {
    // D4 修复：不注入 clock 也没有 ShellServicesScope 时不再抛 StateError，
    // 而是回退 DateTime.now() 渲染表盘（预览/独立挂载形态）。scope 存在时
    // services.telemetry.clock 仍优先（见 clock_card.dart build 注释）。
    await tester.pumpWidget(_wrap(const KosClockCard()));
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is KosClockPainter,
      ),
      findsOneWidget,
    );
    // 收尾卸载，取消秒级 Timer（D5 补足），避免测试末 pending timer。
    await tester.pumpWidget(const SizedBox());
  });

  test('KosClockPainter 几何常数对齐源公式', () {
    // :636-639 radius = size/2 - 3；:657 12 条整点刻度。
    expect(KosClockPainter.tickCount, 12);
    expect(KosClockPainter.radiusInset, 3.0);
  });

  testWidgets('计时器入口回调触发', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        KosClockCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_fixedNow)),
          size: WidgetSize.small, // 200×200 测试窗口对应 1×1 卡
          onLaunchTimer: () => tapped = true,
        ),
      ),
    );
    await tester.pump();
    // 右下角 21px 计时器按钮区域（:708-734）；取按钮中心而非卡角，
    // 避免 ClipRRect 圆角裁剪边缘。
    await tester.tapAt(
      tester.getRect(find.byType(KosClockCard)).bottomRight -
          const Offset(12 + 10.5, 12 + 10.5),
    );
    expect(tapped, isTrue);
    await tester.pumpWidget(const SizedBox()); // 收尾取消秒级 Timer
  });
}
