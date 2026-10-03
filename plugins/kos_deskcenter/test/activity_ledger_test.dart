// TASK-18 `ActivityLedger` 持久化测试（Memory 存储 + fake-async）。
//
// 覆盖（任务卡 §验收）：
// - 写读往返：`update` + `flush` → 新实例 `load` 恢复 `uptimeByDay`/apps；
// - debounce：多次 `update` 合并为一次写（`MemoryActivityLedgerStorage`
//   `writeCount` 断言）；`dispose` flush 尾部变更；
// - schema 容错：损坏 JSON / schemaVersion 不符 / 非有限值 → 空态不抛；
// - `defaultActivityLedgerPath`：`XDG_STATE_HOME` 优先、`HOME` 回退；
// - 容器接线（desk_center_view）：注入 ledger + tracker，tick 后 ledger
//   收到 `uptimeByDay`/当日条目；重启（新建 view 用同一 Memory 内容）
//   恢复历史天数与当日 app 秒数。
//
// 全部走 `MemoryActivityLedgerStorage`——`testWidgets`/`test` 的 fake-async
// 区不驱动真实文件 IO。


import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/activity_ledger.dart';
import 'package:kos_deskcenter/src/widgets/activity_card.dart';
import 'package:kos_deskcenter/src/widgets/desk_center_view.dart';

void main() {
  group('ActivityLedger', () {
    test('写读往返：uptimeByDay + apps 恢复', () async {
      final storage = MemoryActivityLedgerStorage();
      final ledger = ActivityLedger(storage: storage);
      ledger.update(
        uptimeByDay: const {'2026-09-30': 3600.0, '2026-09-29': 7200.0},
        apps: const [
          ActivityLedgerAppEntry(
            id: 'firefox',
            name: 'Firefox',
            icon: 'firefox',
            day: '2026-09-30',
            seconds: 120.0,
          ),
          ActivityLedgerAppEntry(id: 'term', day: '2026-09-29', seconds: 30.0),
        ],
      );
      await ledger.flush();

      final restored = ActivityLedger(storage: storage);
      await restored.load();
      expect(restored.uptimeByDay['2026-09-30'], 3600.0);
      expect(restored.uptimeByDay['2026-09-29'], 7200.0);
      expect(restored.apps.length, 2);
      expect(restored.apps.first.id, 'firefox');
      expect(restored.apps.first.name, 'Firefox');
      expect(restored.apps.first.icon, 'firefox');
      expect(restored.apps.first.day, '2026-09-30');
      expect(restored.apps.first.seconds, 120.0);
    });

    test('debounce：多次 update 合并为一次写', () async {
      final storage = MemoryActivityLedgerStorage();
      final ledger = ActivityLedger(storage: storage);
      ledger.update(uptimeByDay: const {'d': 1.0});
      ledger.update(uptimeByDay: const {'d': 2.0});
      ledger.update(uptimeByDay: const {'d': 3.0});
      expect(storage.writeCount, 0); // 防抖窗口内未落盘
      // 用例体末尾 flush（fake-async 兼容：不 await Timer 到期）。
      await ledger.flush();
      expect(storage.writeCount, 1);
      expect(storage.contents, contains('"d": 3.0'));
    });

    test('dispose flush 尾部变更', () async {
      final storage = MemoryActivityLedgerStorage();
      final ledger = ActivityLedger(storage: storage);
      ledger.update(uptimeByDay: const {'d': 1.0});
      expect(storage.writeCount, 0);
      await ledger.dispose();
      expect(storage.writeCount, 1);
      expect(storage.contents, contains('"d": 1.0'));
    });

    test('损坏 JSON / schemaVersion 不符 / 非有限值 → 空态不抛', () async {
      final storage = MemoryActivityLedgerStorage();
      storage.contents = 'not-json{';
      var ledger = ActivityLedger(storage: storage);
      await ledger.load();
      expect(ledger.hasData, isFalse);

      storage.contents = '{"schemaVersion":2,"uptimeByDay":{"d":1}}';
      ledger = ActivityLedger(storage: storage);
      await ledger.load();
      expect(ledger.hasData, isFalse);

      storage.contents =
          '{"schemaVersion":1,"uptimeByDay":{"d":1.5,"bad":"x","neg":-1},'
          '"apps":[{"id":"a","seconds":5},{"id":"b"},42]}';
      ledger = ActivityLedger(storage: storage);
      await ledger.load();
      expect(ledger.uptimeByDay.keys.toList(), ['d']); // 非数值/负值丢键
      expect(ledger.uptimeByDay['d'], 1.5);
      expect(ledger.apps.length, 2); // id 非空即收；seconds 缺省 0
      expect(ledger.apps.last.seconds, 0.0);
    });

    test('defaultActivityLedgerPath：XDG_STATE_HOME 优先、HOME 回退', () {
      expect(
        defaultActivityLedgerPath(
          environment: const {'XDG_STATE_HOME': '/xdg/state', 'HOME': '/home/u'},
        ),
        '/xdg/state/denial/kos_deskcenter/activity-ledger.json',
      );
      expect(
        defaultActivityLedgerPath(environment: const {'HOME': '/home/u'}),
        '/home/u/.local/state/denial/kos_deskcenter/activity-ledger.json',
      );
    });
  });

  group('容器接线（TASK-18）', () {
    testWidgets('tick 后 ledger 收到 uptimeByDay + 当日条目', (tester) async {
      final storage = MemoryActivityLedgerStorage();
      final ledger = ActivityLedger(storage: storage);
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
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 800,
              height: 1200,
              child: KosDeskCenterView(
                activityTracker: tracker,
                activityLedger: ledger,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 首 tick 仅建基准；第二个 5s 周期写入 5s uptime + firefox 5s。
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      expect(tracker.uptimeByDay[kosDayKey(now)], 5.0);
      // ledger debounce 未到：writeCount 0，但 update 已标 dirty。
      expect(storage.writeCount, 0);
      await ledger.flush();
      expect(storage.writeCount, greaterThan(0));
      expect(storage.contents, contains('"${kosDayKey(now)}": 5'));
      expect(storage.contents, contains('"id": "firefox"'));
      // ledger `day` 键走容器真实时钟（tracker 假时钟只驱动 uptime/app 桶）。
      expect(
        storage.contents,
        contains('"day": "${kosDayKey(DateTime.now())}"'),
      );
      await ledger.dispose();
    });

    testWidgets('重启恢复：同一 Memory 内容 seed tracker 历史 + 当日秒数', (
      tester,
    ) async {
      final storage = MemoryActivityLedgerStorage();
      final today = kosDayKey(DateTime.now());
      // 预置「上次会话」的 ledger：昨日 7200s + 当日 firefox 120s。
      storage.contents =
          '{"schemaVersion":1,"uptimeByDay":{"${kosDayKey(DateTime.now().subtract(const Duration(days: 1)))}":7200.0,"$today":600.0},'
          '"apps":[{"id":"firefox","name":"Firefox","icon":"firefox","day":"$today","seconds":120.0}]}';
      final ledger = ActivityLedger(storage: storage);
      await ledger.load();

      final tracker = ActivityTracker(
        windows: () => const [],
        scheduleTick: (_, _) {},
      );
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 800,
              height: 1200,
              child: KosDeskCenterView(
                activityTracker: tracker,
                activityLedger: ledger,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(); // unawaited(_restoreActivityLedger) 完成

      // 历史天数灌回；当日键 max(600, tracker 已累计) 不回退。
      final yesterday = kosDayKey(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(tracker.uptimeByDay[yesterday], 7200.0);
      expect(tracker.uptimeByDay[today], greaterThanOrEqualTo(600.0));
      // 当日 app 秒数灌回榜单。
      expect(tracker.entries.single.id, 'firefox');
      expect(tracker.entries.single.name, 'Firefox');
      expect(tracker.entries.single.seconds, 120.0);
      await tester.pumpWidget(const SizedBox());
      await ledger.dispose();
    });
  });
}
