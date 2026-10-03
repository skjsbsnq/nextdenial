// KosCalendarCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:2171-2347 的 calendar 分支：左栏 d日+农历+
// 事件列、右栏月历网格（周一至周日列头、今日高亮、跨月灰显）。

import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/widget_snapshot_watcher.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart';
import 'package:kos_deskcenter/src/widgets/calendar_card.dart';

final _now = DateTime(2026, 9, 30); // 周三

Widget _wrap(Widget child) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 340, height: 200, child: child)),
  ),
);

WidgetSnapshot _snap({List<PimEvent> events = const []}) => WidgetSnapshot(
  schemaVersion: 1,
  revision: 1,
  generatedAt: 0,
  today: '2026-09-30',
  events: events,
  todos: const [],
);

PimEvent _event(String title, [String start = '2026-09-30T10:00:00']) =>
    PimEvent(
      id: title,
      seriesId: title,
      title: title,
      start: start,
      end: '',
      allDay: false,
      calendarId: 'personal',
      recurrence: 'none',
      reminderMinutes: -1,
      modifiedAt: '',
    );

void main() {
  testWidgets('calendar 渲染月份标题/今日/事件', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosCalendarCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
          snapshot: _snap(events: [_event('例会'), _event('明日会', '2026-10-01')]),
          state: WidgetSnapshotState.ready,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2026年9月'), findsOneWidget); // :2244 "yyyy年M月"
    expect(find.text('30日'), findsOneWidget); // :2251 "d日"
    expect(find.text('周三 · 农历日期'), findsOneWidget); // :2257 ddd+农历兜底
    // 今日事件列（medium→1 条上限，:2190-2191）：今日一条、明日不入选。
    expect(find.text('• 例会'), findsOneWidget);
    expect(find.text('• 明日会'), findsNothing);
    for (final h in ['一', '二', '三', '四', '五', '六', '日']) {
      expect(find.text(h), findsOneWidget);
    }
    // 今日高亮（:2315-2325）：30 号格子为 16px 圆底 todayFill + 白 Bold。
    expect(find.text('30'), findsOneWidget);
    final todayText = tester.widget<Text>(find.text('30'));
    expect(
      todayText.style?.color,
      const Color(0xFFF4EFF4), // todayForeground→shell textPrimary（暗壳回退）
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle &&
            // todayFill→shell accent@0.22（暗壳默认 accent 0xFFD0BCFF）。
            (w.decoration as BoxDecoration).color == const Color(0x38D0BCFF),
      ),
      findsOneWidget,
    );
  });

  testWidgets('月份标题颜色按亮度取（TASK-09：!onBackdrop 自绘块删除）', (tester) async {
    // 源 :2208/:2218 的红带与右侧面板仅 !onBackdrop（glass+色艺）画；
    // TASK-09 起统一 Denial ShellTheme 材质（等价 onBackdrop），自绘块
    // 恒不画。标题色 :2246 改经 shell `textPrimary` 解析——light 壳→
    // ShellColorScheme.light.textPrimary(0xFF1B1B21)、dark 壳→0xFFF4EFF4。
    // 测试环境无 ShellTheme 时回退暗壳，故显式注入亮壳校验。
    await tester.pumpWidget(
      _wrap(
        ShellTheme(
          data: const ShellThemeData(colors: ShellColorScheme.light),
          child: KosCalendarCard(
            clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
            snapshot: _snap(),
            state: WidgetSnapshotState.ready,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2026年9月'), findsOneWidget); // 标题仍在（无红带）
    final title = tester.widget<Text>(find.text('2026年9月'));
    expect(
      title.style?.color,
      const Color(0xFF1B1B21), // light 壳 → ShellColorScheme.light.textPrimary
    );
  });

  testWidgets('small 档隐藏事件列表（:2262-2263）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosCalendarCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
          snapshot: _snap(events: [_event('例会')]),
          state: WidgetSnapshotState.ready,
          size: WidgetSize.small,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('• 例会'), findsNothing);
  });

  testWidgets('空态：unavailable 显「未连接日历服务」（:2280）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosCalendarCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
          snapshot: null,
          state: WidgetSnapshotState.unavailable,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('未连接日历服务'), findsOneWidget);
  });

  testWidgets('loading 空态不渲染事件也不显 unavailable 文案', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosCalendarCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
          snapshot: null,
          state: WidgetSnapshotState.loading,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('未连接日历服务'), findsNothing);
    expect(find.text('2026年9月'), findsOneWidget);
  });

  testWidgets('整卡点击回调携带 kos-calendar 与日期', (tester) async {
    String? appId;
    List<String>? args;
    await tester.pumpWidget(
      _wrap(
        KosCalendarCard(
          clock: Provider<AsyncValue<DateTime>>((_) => AsyncData(_now)),
          snapshot: _snap(),
          state: WidgetSnapshotState.ready,
          onLaunchApp: (id, a) {
            appId = id;
            args = a;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(KosCalendarCard));
    expect(appId, 'kos-calendar');
    expect(args, ['--date', '2026-09-30']); // :2197 yyyy-MM-dd
  });
}
