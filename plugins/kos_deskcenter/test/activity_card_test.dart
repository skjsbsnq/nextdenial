// KosActivityCard widget 测试 + ActivityTracker/ActivitySnapshot 纯 Dart
// 测试（TASK-06）。
//
// 对齐 DeskCenterWindow.qml:1514-1647 的 activity 分支：左栏「已开机」
// 表头 + 60 日热力图（悬停改显 `key · 开机时长：x`）、右栏今日前台应用
// 时长榜（slice(0,8)）。数据源：activity.snapshot 投影（uptimeByDay/
// todayApps）+ 插件侧轮询累计（ActivityTracker，窗口表 + 假时钟注入）。
//
// 源锚点：formatDuration :144-149；dayKey/recentUptimeDays
// ActivityUsageService.qml:25-61；updateActiveApp/sendActiveApp :63-83。

import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/activity_card.dart';
import 'package:kos_deskcenter/src/widgets/desk_center_view.dart';

Widget _wrap(Widget child, {double w = 340, double h = 220}) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(width: w, height: h, child: child),
    ),
  ),
);

void main() {
  group('kosFormatDuration（DeskCenterWindow.qml:144-149）', () {
    test('小时/分钟档位与取整', () {
      expect(kosFormatDuration(0), '0分');
      expect(kosFormatDuration(59), '<1分'); // 非零<60s → <1分（防看似空数据）
      expect(kosFormatDuration(0.4), '0分'); // round(0.4)=0 → 真 0
      expect(kosFormatDuration(60), '1分');
      expect(kosFormatDuration(3599), '59分');
      expect(kosFormatDuration(3600), '1小时'); // minutes==0 → 不拼「0分」
      expect(kosFormatDuration(3665), '1小时1分');
      expect(kosFormatDuration(7380), '2小时3分');
      expect(kosFormatDuration(-5), '0分'); // max(0,·)
    });
  });

  group('kosDayKey / kosRecentUptimeDays（ActivityUsageService.qml:25-61）', () {
    test('dayKey 为 yyyy-MM-dd 零填充', () {
      expect(kosDayKey(DateTime(2026, 9, 8)), '2026-09-08');
      expect(kosDayKey(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('60 日窗：今天为末格、缺日补 0、键对齐 dayKey', () {
      final now = DateTime(2026, 9, 30, 15, 4);
      final days = kosRecentUptimeDays(
        {'2026-09-30': 3600, '2026-09-29': 7200},
        60,
        now: now,
      );
      expect(days.length, 60);
      expect(days.last.key, '2026-09-30');
      expect(days.last.seconds, 3600);
      expect(days[58].key, '2026-09-29');
      expect(days[58].seconds, 7200);
      expect(days.first.key, kosDayKey(now.subtract(const Duration(days: 59))));
      expect(days.first.seconds, 0); // 缺日补 0（:58 `|| 0`）
    });
  });

  group('ActivitySnapshot.fromJson（main.go:73-89 结构）', () {
    test('uptimeByDay/todayApps 逐项解析 + todayApps 按 seconds 降序', () {
      final snap = ActivitySnapshot.fromJson(const {
        'uptimeByDay': {'2026-09-30': 3665.5, '2026-09-29': 'bad'},
        'todayApps': {
          'term': {'name': '终端', 'seconds': 60},
          'ff': {'name': 'Firefox', 'icon': 'firefox', 'seconds': 3665},
          'weird': 'not-a-map',
        },
      });
      expect(snap.uptimeByDay['2026-09-30'], 3665.5);
      expect(snap.uptimeByDay.containsKey('2026-09-29'), isFalse); // 非数值丢弃
      expect(snap.todayApps.length, 2); // 非 Map 条目丢弃
      expect(snap.todayApps[0].id, 'ff'); // seconds 降序（:46）
      expect(snap.todayApps[0].name, 'Firefox');
      expect(snap.todayApps[0].icon, 'firefox');
      expect(snap.todayApps[0].seconds, 3665);
      expect(snap.todayApps[1].id, 'term');
    });

    test('NaN/Infinity 值丢弃（F4：封死进入 kosFormatDuration/_cellColor）', () {
      final snap = ActivitySnapshot.fromJson({
        'uptimeByDay': {'d1': double.nan, 'd2': double.infinity, 'd3': 60},
        'todayApps': {
          'a': {'name': 'A', 'seconds': double.nan},
        },
      });
      expect(snap.uptimeByDay.keys.toList(), ['d3']); // 非有限值丢键
      expect(snap.todayApps.single.seconds, 0); // seconds NaN → 0
    });

    test('空 activity 对象 → 空表', () {
      const snap = ActivitySnapshot();
      expect(snap.uptimeByDay, isEmpty);
      expect(snap.todayApps, isEmpty);
    });

    group('ActivityTracker 累计逻辑（fake window list + fake clock）', () {
      var now = DateTime(2026, 9, 30, 12);
      List<ActivityWindowRow> rows = const [];

      ActivityTracker tracker({Map<String, String> names = const {}}) =>
          ActivityTracker(
            windows: () => rows,
            resolveName: (id) => names[id],
            clock: () => now,
            scheduleTick: (_, _) {},
          );

      ActivityWindowRow win(
        int id,
        String appId, {
        bool active = false,
        bool minimized = false,
        String title = '',
      }) => ActivityWindowRow(
        id: id,
        appId: appId,
        title: title,
        active: active,
        minimized: minimized,
      );

      setUp(() {
        now = DateTime(2026, 9, 30, 12);
        rows = const [];
      });

      test('首次 tick 只建基准不计时；同前台应用逐周期累计', () {
        final t = tracker();
        rows = [win(1, 'firefox', active: true)];
        expect(t.tick(), 'firefox');
        expect(t.entries, isEmpty); // 无 elapsed
        now = now.add(const Duration(seconds: 5));
        expect(t.tick(), 'firefox');
        expect(t.entries.single.seconds, 5);
        now = now.add(const Duration(seconds: 5));
        t.tick();
        expect(t.entries.single.seconds, 10);
      });

      test('前台切换：周期时长记给采样时刻的前台 app，各 app 独立累计', () {
        final t = tracker(names: {'firefox': 'Firefox'});
        rows = [
          win(1, 'firefox', active: true),
          win(2, 'term', title: 'Terminal'),
        ];
        t.tick();
        now = now.add(const Duration(seconds: 5));
        // 周期末采样时前台已是 term → 整段归 term（源端周期内切换按
        // 服务端结算时点的活跃 app 归属，:76-82 注释）。
        rows = [win(1, 'firefox'), win(2, 'term', active: true)];
        t.tick();
        expect(t.entries.single.id, 'term');
        expect(t.entries.single.seconds, 5);
        now = now.add(const Duration(seconds: 10));
        t.tick();
        expect(t.entries.single.seconds, 15); // 持续前台累计
        // name 解析（resolveName）优先，未匹配回退 appId（:1635 name||id）。
        expect(t.entries.single.name, 'term'); // 未命中 names → appId
        // 记录过的条目再次累计时保留已解析名（name 回退链 resolver → 已记名
        // → appId）。
        rows = [win(1, 'firefox', active: true)];
        now = now.add(const Duration(seconds: 5));
        t.tick();
        final ff = t.entries.firstWhere((e) => e.id == 'firefox');
        expect(ff.name, 'Firefox');
        expect(ff.seconds, 5);
      });

      test('无前台窗口 / 前台最小化 → 周期不归属任何应用', () {
        final t = tracker();
        rows = [win(1, 'firefox', active: true)];
        t.tick();
        now = now.add(const Duration(seconds: 5));
        rows = []; // 无窗口（源端 appID=="" 停止归属，:77-78）
        expect(t.tick(), isNull);
        now = now.add(const Duration(seconds: 5));
        rows = [win(1, 'firefox', active: true, minimized: true)];
        expect(t.tick(), isNull); // minimized 不计
        expect(t.entries, isEmpty); // 两段窗口期均不外溢
      });

      test('entries 按 seconds 降序（todayApps() :44-47）', () {
        final t = tracker();
        rows = [win(1, 'a', active: true)];
        t.tick();
        now = now.add(const Duration(seconds: 3));
        t.tick(); // a 得 3s
        now = now.add(const Duration(seconds: 7));
        rows = [win(2, 'b', active: true)];
        t.tick(); // b 得 7s
        expect(t.entries.map((e) => e.id).toList(), ['b', 'a']);
        expect(t.entries.map((e) => e.seconds).toList(), [7, 3]);
      });

      test('F3：stop() 后注入调度器再调 tick 为空转，累计截停', () {
        // 注入调度器持有 body 回调，容器 stop() 后它仍会回调 tick——
        // 只能靠 tick 的 _running 守卫截停（注入路径无 Timer 可 cancel）。
        late void Function() scheduledBody;
        final t = ActivityTracker(
          windows: () => rows,
          clock: () => now,
          scheduleTick: (_, body) => scheduledBody = body,
        );
        t.start();
        rows = [win(1, 'firefox', active: true)];
        scheduledBody();
        now = now.add(const Duration(seconds: 5));
        scheduledBody();
        expect(t.entries.single.seconds, 5);
        t.stop();
        now = now.add(const Duration(seconds: 5));
        scheduledBody(); // 注入调度器仍在回调 → 空转
        expect(t.entries.single.seconds, 5); // 不再累计
        t.start(); // 恢复后重建基准（首 tick 不计时）
        now = now.add(const Duration(seconds: 5));
        scheduledBody();
        expect(t.entries.single.seconds, 10);
      });

      test('外部驱动用法：不经 start() 直接 tick 即累计（容器路径）', () {
        // KosDeskCenterView 走外部驱动（视图 Timer 调 tick，不调 start）：
        // _running 默认 true，tick 不应被守卫挡住。
        final t = tracker();
        rows = [win(1, 'firefox', active: true)];
        t.tick();
        now = now.add(const Duration(seconds: 5));
        t.tick();
        expect(t.entries.single.seconds, 5);
      });
    });
  });

  group('KosActivityCard 渲染（:1514-1647）', () {
    final today = kosDayKey(DateTime.now());

    testWidgets('注入数据：表头「已开机」+ 榜行名称/时长（:1546、:1629/:1635）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          KosActivityCard(
            snapshot: ActivitySnapshot(
              uptimeByDay: {today: 7380},
              todayApps: const [],
            ),
            apps: const [
              ActivityAppEntry(id: 'ff', name: 'Firefox', seconds: 3665),
              ActivityAppEntry(id: 'term', seconds: 60),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('已开机：2小时3分'), findsOneWidget); // :1546
      expect(find.text('Firefox'), findsOneWidget); // :1635 name
      expect(find.text('1小时1分'), findsOneWidget); // :1629
      expect(find.text('term'), findsOneWidget); // name 空 → id 回退
      expect(find.text('1分'), findsOneWidget);
    });

    testWidgets('榜单截断为前 8（:1596 slice(0,8)）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          KosActivityCard(
            apps: [
              for (var i = 0; i < 10; i++)
                ActivityAppEntry(id: 'app$i', seconds: (10 - i) * 60),
            ],
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        expect(find.text('app$i'), findsOneWidget);
      }
      expect(find.text('app8'), findsNothing);
      expect(find.text('app9'), findsNothing);
    });

    testWidgets('空态：无 snapshot/榜 → 已开机 0 分、热力图 60 格', (tester) async {
      await tester.pumpWidget(_wrap(const KosActivityCard()));
      await tester.pump();
      expect(find.text('已开机：0分'), findsOneWidget);
      // 热力图格 60 个（recentUptimeDays(60)，:1567）。
      expect(
        find.descendant(
          of: find.byType(KosActivityCard),
          matching: find.byType(MouseRegion),
        ),
        findsNWidgets(60),
      );
    });

    testWidgets('悬停格改显 `key · 开机时长：x`（:1543-1547）', (tester) async {
      final daySeconds = <String, double>{kosDayKey(DateTime.now()): 3600};
      await tester.pumpWidget(
        _wrap(
          KosActivityCard(snapshot: ActivitySnapshot(uptimeByDay: daySeconds)),
        ),
      );
      await tester.pump();
      expect(find.text('已开机：1小时'), findsOneWidget);
      final cell = find.descendant(
        of: find.byType(KosActivityCard),
        matching: find.byType(MouseRegion),
      );
      final oldest = tester.getCenter(cell.first); // 60 天前那格
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: oldest);
      await gesture.moveTo(oldest);
      await tester.pump();
      final oldestKey = kosDayKey(
        DateTime.now().subtract(const Duration(days: 59)),
      );
      expect(find.text('$oldestKey · 开机时长：0分'), findsOneWidget);
      await gesture.moveTo(Offset.zero); // onExit → 回到「已开机」
      await tester.pump();
      expect(find.text('已开机：1小时'), findsOneWidget);
    });
  });

  group('容器接线（desk_center_view）', () {
    testWidgets('activity 实卡替换占位（TASK-06）', (tester) async {
      // 800×1200 surface：7 卡网格在 600 高排不下（desk_center_view_test
      // 的 _pumpView 同样放大）。
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      await tester.pumpWidget(_wrap(const KosDeskCenterView(), w: 800, h: 1200));
      await tester.pump();
      expect(find.byType(KosActivityCard), findsOneWidget);
      // 部件库条目 label「活动」始终挂载（opacity 门控，非移除）。
      expect(find.text('活动'), findsOneWidget);
      expect(find.text('已开机：0分'), findsOneWidget); // 无数据空态
      await tester.pumpWidget(const SizedBox()); // 收尾取消 timers
      await tester.pumpWidget(const SizedBox()); // 收尾取消 timers
    });

    testWidgets('F1：注入 tracker 时容器启动 tick 驱动，榜条目累计上卡', (tester) async {
      // initState 漏调 _startActivityTracking 的回归：注入 tracker 后容器
      // 应自跑 Timer.periodic 驱动 tick——首个 5s 周期内前台 firefox 计入。
      var now = DateTime(2026, 9, 30, 12);
      final tracker = ActivityTracker(
        windows: () => const [
          ActivityWindowRow(
            id: 1,
            appId: 'firefox',
            title: 'Firefox',
            active: true,
          ),
        ],
        clock: () => now,
      );
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      await tester.pumpWidget(
        _wrap(KosDeskCenterView(activityTracker: tracker), w: 800, h: 1200),
      );
      await tester.pump();
      expect(tracker.entries, isEmpty); // 首 tick 仅建基准
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5)); // 容器 Timer 驱动 tick
      expect(tracker.entries.single.id, 'firefox');
      expect(tracker.entries.single.seconds, 5);
      expect(find.text('firefox'), findsOneWidget); // 榜行上卡（name 空→id）
      await tester.pumpWidget(const SizedBox()); // dispose → stop() 截停
    });
  });
}
