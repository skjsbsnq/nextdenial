// TASK-17 activity 详情面板 widget 测试。
//
// 覆盖（任务卡 §验收）：
// - `registerActivityPanel()` 写入 `deskPanelBuilderRegistry['kos-activity']`；
// - 渲染：热力图 60 格（MouseRegion 计数）、今日应用时长榜（名称 + 时长）、
//   总开机时长（今日 `uptimeByDay[today]`）；
// - tracker 实时源：`Timer.periodic(5s)` 轮询重建——tick 后榜条目上屏；
// - 空态降级：无 tracker/snapshot → 「今日无前台应用记录」、热力图仍渲染；
// - 悬停热力格显 `key · 开机时长：x`（同卡表头语义）。
//
// 宿主：`MaterialApp(home:Scaffold)` + `Size(1000,800)`。fake-async 铁律：
// 面板 `Timer.periodic` 在用例体末尾经 `pumpWidget(SizedBox())` 卸载取消。

import 'dart:ui' show Offset, PointerDeviceKind, Size;

import 'package:flutter/material.dart'
    show Color, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/activity_card.dart';
import 'package:kos_deskcenter/src/widgets/activity_panel.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';

Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: const Color(0x00000000),
    body: Center(child: SizedBox(width: 560, height: 640, child: child)),
  ),
);

ActivityPanel _panel({
  ActivitySnapshot? snapshot,
  ActivityTracker? tracker,
  DeskPanelData? data,
}) => ActivityPanel(
  request: const DeskPanelRequest(appId: 'kos-activity'),
  data: data ??
      DeskPanelData(activity: snapshot, activityTracker: tracker),
  snapshot: snapshot,
  tracker: tracker,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

void main() {
  final today = kosDayKey(DateTime.now());

  group('activity 面板', () {
    testWidgets('注册函数写入 deskPanelBuilderRegistry', (tester) async {
      registerActivityPanel();
      expect(deskPanelBuilderRegistry['kos-activity'], isNotNull);
      final widget = deskPanelBuilderRegistry['kos-activity']!(
        const DeskPanelRequest(appId: 'kos-activity'),
        const DeskPanelData(),
      );
      expect(widget, isA<ActivityPanel>());
    });

    testWidgets('渲染热力图 60 格 + 总开机时长 + 榜单', (tester) async {
      final tracker = ActivityTracker(
        windows: () => const [],
        scheduleTick: (_, _) {},
      );
      tracker.seedUptimeByDay({today: 7380});
      tracker.seedFromEntries(const [
        ActivityAppEntry(id: 'ff', name: 'Firefox', seconds: 3665),
        ActivityAppEntry(id: 'term', seconds: 60),
      ]);
      await _pump(tester, _panel(tracker: tracker));
      await tester.pump();

      // 热力图 60 格（MouseRegion 计数）。
      expect(
        find.descendant(
          of: find.byType(ActivityPanel),
          matching: find.byType(MouseRegion),
        ),
        findsNWidgets(60),
      );
      // 总开机时长（今日 uptimeByDay）。
      expect(find.text('2小时3分'), findsOneWidget);
      // 榜单：名称 + 时长（tracker entries）。
      expect(find.text('Firefox'), findsOneWidget);
      expect(find.text('1小时1分'), findsOneWidget);
      expect(find.text('term'), findsOneWidget);
      expect(find.text('1分'), findsOneWidget);
      tracker.stop();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('snapshot 兜底：无 tracker 时用 ActivitySnapshot 数据', (
      tester,
    ) async {
      await _pump(
        tester,
        _panel(
          snapshot: ActivitySnapshot(
            uptimeByDay: {today: 3600},
            todayApps: const [
              ActivityAppEntry(id: 'code', name: '编辑器', seconds: 600),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1小时'), findsOneWidget); // 总开机时长
      expect(find.text('编辑器'), findsOneWidget);
      expect(find.text('10分'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('空态：无 tracker/snapshot → 「今日无前台应用记录」+ 热力图仍渲染', (
      tester,
    ) async {
      await _pump(tester, _panel());
      await tester.pump();
      expect(find.text('今日无前台应用记录'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ActivityPanel),
          matching: find.byType(MouseRegion),
        ),
        findsNWidgets(60),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('悬停热力格显 `key · 开机时长：x`', (tester) async {
      final daySeconds = <String, double>{today: 3600};
      await _pump(
        tester,
        _panel(snapshot: ActivitySnapshot(uptimeByDay: daySeconds)),
      );
      await tester.pump();
      final cell = find.descendant(
        of: find.byType(ActivityPanel),
        matching: find.byType(MouseRegion),
      );
      final oldest = tester.getCenter(cell.first); // 60 天前那格
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: oldest);
      await gesture.moveTo(oldest);
      await tester.pump();
      final oldestKey = kosDayKey(
        DateTime.now().subtract(const Duration(days: 59)),
      );
      expect(
        find.text('$oldestKey · 开机时长：0分'),
        findsOneWidget,
      );
      await gesture.moveTo(Offset.zero); // onExit
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
