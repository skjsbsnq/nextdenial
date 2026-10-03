// KosTodoCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:2027-2169 的 todo 分支：红标题带+「提醒事项」、
// small 计数 / medium 3 条 / large 6 条列表、截止着色（逾期 #e23d52、
// 其余 #7b7b84，:2134-2138）、空态三态文案（:2159-2162）。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/widget_snapshot_watcher.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart';
import 'package:kos_deskcenter/src/widgets/todo_card.dart';

Widget _wrap(Widget child, {double w = 340, double h = 200}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(width: w, height: h, child: child),
  ),
);

WidgetSnapshot _snap(List<PimTodo> todos) => WidgetSnapshot(
  schemaVersion: 1,
  revision: 1,
  generatedAt: 0,
  today: '2026-09-30',
  events: const [],
  todos: todos,
);

PimTodo _todo(
  String id, {
  String due = '',
  bool completed = false,
  String seriesId = '',
}) => PimTodo(
  id: id,
  title: id,
  listId: 'inbox',
  parentId: '',
  order: 0,
  start: '',
  due: due,
  allDay: false,
  priority: 0,
  completed: completed,
  completedAt: '',
  recurrence: 'none',
  reminderMinutes: -1,
  modifiedAt: '',
  seriesId: seriesId,
);

void main() {
  testWidgets('todo 渲染标题/未完成列表/截止', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosTodoCard(
          snapshot: _snap([
            _todo('买奶', due: '2026-10-02'), // 未来 → 灰
            _todo('报告', due: '2026-09-28'), // 逾期 → 红
            _todo('已完成', completed: true), // 被滤掉
          ]),
          state: WidgetSnapshotState.ready,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('提醒事项'), findsOneWidget); // :2085
    expect(find.text('买奶'), findsOneWidget);
    expect(find.text('报告'), findsOneWidget);
    expect(find.text('已完成'), findsNothing); // :77-79 滤 completed
    expect(find.text('2026-10-02'), findsOneWidget); // :2133 due.slice(0,10)
    expect(find.text('2026-09-28'), findsOneWidget);
    // 截止着色：逾期保留语义红 #e23d52；未逾期走 shell textSecondary
    // （测试环境无 ShellTheme → 回退暗壳 textSecondary 0xFFCAC4D0）。
    final overdue = tester.widget<Text>(find.text('2026-09-28'));
    expect(overdue.style?.color, const Color(0xFFE23D52));
    final future = tester.widget<Text>(find.text('2026-10-02'));
    expect(future.style?.color, const Color(0xFFCAC4D0));
  });

  testWidgets('small 档渲染计数与「项待办」（:2089-2103）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosTodoCard(
          snapshot: _snap([
            _todo('a'),
            _todo('b'),
            _todo('done', completed: true),
          ]),
          state: WidgetSnapshotState.ready,
          size: WidgetSize.small,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget); // :2093 pendingTodos(99).length
    expect(find.text('项待办'), findsOneWidget); // :2100
    expect(find.text('a'), findsNothing); // small 不渲染列表
  });

  testWidgets('ready 空列表显「今天已全部完成」（:2160）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosTodoCard(
          snapshot: _snap(const []),
          state: WidgetSnapshotState.ready,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('今天已全部完成'), findsOneWidget);
  });

  testWidgets('loading 空态显「正在载入待办…」（:2161-2162）', (tester) async {
    await tester.pumpWidget(
      _wrap(const KosTodoCard(state: WidgetSnapshotState.loading)),
    );
    await tester.pump();
    expect(find.text('正在载入待办…'), findsOneWidget);
  });

  testWidgets('unavailable 空态显「未连接待办服务」（:2162）', (tester) async {
    await tester.pumpWidget(
      _wrap(const KosTodoCard(state: WidgetSnapshotState.unavailable)),
    );
    await tester.pump();
    expect(find.text('未连接待办服务'), findsOneWidget);
  });

  testWidgets('整卡与行点击回调（:2045-2050、:2141-2148）', (tester) async {
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      _wrap(
        KosTodoCard(
          snapshot: _snap([_todo('t1')]),
          state: WidgetSnapshotState.ready,
          onLaunchApp: (id, a) => calls.add((id, a)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('t1')); // 行点击 → --item（行 GestureDetector
    // 先于整卡命中：行级 detector 覆盖在行内容上）
    // matcher 0.12.20 无 record 深比较——逐字段断言。
    expect(calls.last.$1, 'kos-todo');
    expect(calls.last.$2, ['--item', 't1']);
    // 点击标题带区域（无行覆盖）→ 整卡 --view today。
    await tester.tap(find.text('提醒事项'));
    expect(calls.last.$1, 'kos-todo');
    expect(calls.last.$2, ['--view', 'today']);
  });

  testWidgets('行点击回退链 id→seriesId（:2145-2146，D3）', (tester) async {
    // 源 value(m,"id", value(m,"seriesId",""))：id 为空时回退 seriesId
    // （快照 todoObject 不写 seriesId，仅 todoOccurrenceObject 有，
    // PimStore.cpp:400-424 vs :432——本断言验证回退链字段序）。
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      _wrap(
        KosTodoCard(
          snapshot: _snap([_todo('', seriesId: 'occ-1')]),
          state: WidgetSnapshotState.ready,
          onLaunchApp: (id, a) => calls.add((id, a)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('未命名任务')); // title 空 → :2125 兜底
    expect(calls.last.$1, 'kos-todo');
    expect(calls.last.$2, ['--item', 'occ-1']);
  });
}
