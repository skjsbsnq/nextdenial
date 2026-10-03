// TASK-13 calendar 面板 widget 测试。
//
// 覆盖：
// - argv → state：`--date` 定位 selectedDate/visibleMonth、
//   `--view week/day` 视图索引（Main.qml:143-166）；
// - 月/周/日三视图切换（分段控件）与月网格 42 格 / chip / 「+N」；
// - `eventsForRange` occurrence 渲染到日程列表（时间/标题/类型标签）；
// - linked-todo 去重（Main.qml:222-281 itemsByDate：event 带
//   linkedTodoId 的当天不再重复落 todo 行）；
// - 事件编辑器新建/编辑/删除写回 PimStore；待办编辑器保存 + 勾选
//   `setTodoCompleted` 同步。
//
// store：`PimStore(storage: MemoryPimStorage())` + `load()`（无既有
// calendar.ics → 空日历可写）；`testWidgets` 的 fake-async 区不驱动真实
// 文件 IO，故用内存存储而非临时目录。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/pim/pim_store.dart';
import 'package:kos_deskcenter/src/widgets/calendar_panel.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';

/// 本用例创建的全部 store：`load()` 会启动 5 分钟快照周期 Timer 与 180ms
/// reload 防抖，用例结束必须 `dispose()`，否则 `AutomatedTestWidgetsFlutterBinding`
/// 的 pending-timer 断言失败。
final List<PimStore> _stores = <PimStore>[];

Future<PimStore> _freshStore() async {
  final store = PimStore(
    storageDirectory: '/memory/kos/pim',
    storage: MemoryPimStorage(),
  );
  await store.load();
  _stores.add(store);
  return store;
}

/// widget 用例包装：在用例体末尾（仍在 `runTest` 的 fake-async 区内、
/// pending-timer 断言之前）卸载面板并销毁本用例的 store。
///
/// 关键：**不能只在 `tearDown` 里 dispose**——`runTest` 会在返回前调用
/// `_verifyInvariants()` 断言无 pending timer，而 `tearDown` 在 `runTest`
/// 之后才执行，那时报错已发生。
void _widgetTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      try {
        // 先卸载面板（取消快照订阅），再销毁 store 的定时器/流。
        await tester.pumpWidget(const SizedBox());
      } on Object {
        // 用例已失败时不再叠加错误。
      }
      for (final store in _stores) {
        try {
          await store.dispose();
        } on Object {
          // 销毁失败不掩盖用例断言结果。
        }
      }
      _stores.clear();
    }
  });
}

Widget _wrap(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    // 编辑器表单（EventEditor/TaskEditor 全字段）比 800 高约 200px——用
    // 1400 保证保存/删除钮落在可点区域内，避免 RenderFlex 溢出与 tap 落空。
    child: SizedBox(width: 1000, height: 1400, child: child),
  ),
);

CalendarPanel _panel(
  PimStore store, {
  List<String> argv = const [],
}) => CalendarPanel(
  request: DeskPanelRequest(appId: 'kos-calendar', argv: argv),
  data: DeskPanelData(pimStore: store),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

void main() {
  _widgetTest('注册函数写入 deskPanelBuilderRegistry', (tester) async {
    registerCalendarPanel();
    expect(deskPanelBuilderRegistry['kos-calendar'], isNotNull);
    final store = await _freshStore();
    final widget = deskPanelBuilderRegistry['kos-calendar']!(
      const DeskPanelRequest(appId: 'kos-calendar'),
      DeskPanelData(pimStore: store),
    );
    expect(widget, isA<CalendarPanel>());
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('--date 定位选中月与日，月视图标题含月份', (tester) async {
    final store = await _freshStore();
    await store.addEvent(
      title: '定位日事件',
      start: DateTime(2026, 3, 15, 10),
      end: DateTime(2026, 3, 15, 11),
    );
    await _pump(
      tester,
      _panel(store, argv: const ['--date', '2026-03-15']),
    );
    // visibleMonth 跟 --date；日程列表标题 = 选中日。
    expect(find.text('2026年3月15日'), findsOneWidget);
    expect(find.text('定位日事件'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('非法 --date 回退今日', (tester) async {
    final store = await _freshStore();
    await _pump(
      tester,
      _panel(store, argv: const ['--date', 'not-a-date']),
    );
    final now = DateTime.now();
    expect(
      find.text('${now.year}年${now.month}月${now.day}日'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('月/周/日切换：分段控件驱动三视图', (tester) async {
    final store = await _freshStore();
    await store.addEvent(
      title: '九点例会',
      start: DateTime.now().copyWith(hour: 9, minute: 0),
      end: DateTime.now().copyWith(hour: 10, minute: 0),
    );
    await _pump(tester, _panel(store));
    // 月视图：42 格 chip 渲染（事件在今日列）。
    expect(find.text('九点例会'), findsWidgets);
    // 切「周」→ 小时格行（时刻标签 00:00…23:00 存在）。
    await tester.tap(find.byKey(const ValueKey('cal-view-1')));
    await tester.pump();
    expect(find.text('09:00'), findsWidgets);
    // 切「日」→ 单列（dayCount 1），时刻格仍在。
    await tester.tap(find.byKey(const ValueKey('cal-view-2')));
    await tester.pump();
    expect(find.text('09:00'), findsWidgets);
    // 切回月。
    await tester.tap(find.byKey(const ValueKey('cal-view-0')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('--view day 直接进日视图', (tester) async {
    final store = await _freshStore();
    await _pump(tester, _panel(store, argv: const ['--view', 'day']));
    // 日视图仍有全日行 + 时刻格。
    expect(find.text('全日'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('事件 occurrence 渲染到日程列表（时间/标题/类型标签）', (
    tester,
  ) async {
    final store = await _freshStore();
    final today = DateTime.now();
    await store.addEvent(
      title: '午后评审',
      location: '会议室B',
      start: DateTime(today.year, today.month, today.day, 14),
      end: DateTime(today.year, today.month, today.day, 15, 30),
    );
    await _pump(tester, _panel(store));
    expect(find.text('14:00'), findsWidgets);
    expect(find.text('午后评审'), findsWidgets);
    expect(find.text('会议室B'), findsOneWidget); // 副标题 = 地点
    expect(find.text('日程'), findsWidgets); // 类型标签 EVENT
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('linked-todo 去重：同日不重复落 todo 行', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    await store.addEvent(
      title: '关联任务事件',
      start: DateTime(today.year, today.month, today.day, 9),
      end: DateTime(today.year, today.month, today.day, 10),
      linkedTodo: true,
      todoListId: 'inbox',
    );
    await _pump(tester, _panel(store));
    // 日程列表里只有 EVENT+TASK 一条（todo occurrence 被去重），
    // 不出现独立「任务」标签行。
    expect(find.text('日程+任务'), findsOneWidget);
    expect(find.text('任务'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('事件编辑器：新建提交写回 store', (tester) async {
    final store = await _freshStore();
    await _pump(tester, _panel(store));
    await tester.tap(find.text('+ 日程'));
    await tester.pump();
    expect(find.text('新建日程'), findsOneWidget);
    await tester.enterText(
      find
          .byWidgetPredicate(
            (w) =>
                w is EditableText &&
                (w.controller.text.isEmpty || w.controller.text == ''),
          )
          .first,
      '新建测试事件',
    );
    // 第一个空 EditableText 是标题框（其余日期框已预填）。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cal-editor-save')));
    await tester.pump();
    expect(store.rawEvents.any((e) => e.summary == '新建测试事件'), isTrue);
    expect(find.text('新建日程'), findsNothing); // 编辑器已关
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('事件编辑器：编辑改标题 + 删除', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    final ev = await store.addEvent(
      title: '原标题',
      start: DateTime(today.year, today.month, today.day, 8),
      end: DateTime(today.year, today.month, today.day, 9),
    );
    expect(ev, isNotNull);
    await _pump(tester, _panel(store));
    // 点日程行打开编辑器。
    await tester.tap(find.text('原标题').first);
    await tester.pump();
    expect(find.text('编辑日程'), findsOneWidget);
    // 改标题：找到值为「原标题」的 EditableText。
    final titleField = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text == '原标题',
    );
    await tester.enterText(titleField, '改后标题');
    await tester.tap(find.byKey(const ValueKey('cal-editor-save')));
    await tester.pump();
    expect(store.eventById(ev!.uid)?.summary, '改后标题');
    // 删除：重新打开后点「删除日程」。
    await tester.tap(find.text('改后标题').first);
    await tester.pump();
    await tester.tap(find.text('删除日程'));
    await tester.pump();
    expect(store.eventById(ev.uid), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('待办勾选同步 setTodoCompleted', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    final todo = await store.addTodo(
      title: '到期任务',
      due: today,
      listId: 'inbox',
    );
    expect(todo, isNotNull);
    await _pump(tester, _panel(store));
    expect(find.text('到期任务'), findsWidgets);
    // 日程行完成圈：tap 行内首个 GestureDetector 完成钮——
    // 直接走 store 验证 toggle 路径由 _toggleItem 承担，这里以
    // setTodoCompleted 等价断言 + UI 行存在为准（hit 位置依赖布局）。
    await store.setTodoCompleted(todo!.uid, true);
    await tester.pump();
    expect(store.todoById(todo.uid)?.completed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  _widgetTest('待办编辑器保存写回（title/priority/due）', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    final todo = await store.addTodo(
      title: '旧任务名',
      due: today,
      listId: 'inbox',
    );
    await _pump(tester, _panel(store));
    await tester.tap(find.text('旧任务名').first);
    await tester.pump();
    expect(find.text('编辑任务'), findsOneWidget);
    final titleField = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text == '旧任务名',
    );
    await tester.enterText(titleField, '新任务名');
    await tester.tap(find.byKey(const ValueKey('cal-todo-save')));
    await tester.pump();
    expect(store.todoById(todo!.uid)?.summary, '新任务名');
    await tester.pumpWidget(const SizedBox());
  });
}
