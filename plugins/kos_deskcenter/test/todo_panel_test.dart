// TASK-14 todo 面板 widget 测试。
//
// 覆盖（TASK-14 验收标准）：
// - 注册函数写入 `deskPanelBuilderRegistry`（路由收口契约）；
// - argv → state：`--view today` 定位 `activeFilter`、`--item <id>` 快照
//   就绪后直达编辑器（Main.qml:41-64）；
// - 五个智能过滤（inbox/today/planned/calendar/completed）+ 自定义清单
//   正确分桶渲染真实 todo（filteredTodos，Main.qml:81-108）；
// - 勾选完成写回 `setTodoCompleted`（:502-511）；
// - 快速添加（`addTask` :154-165）写回 store；
// - 编辑器提交写回（`TodoEditorDialog` todoPayload，:103-123）；
// - 新建清单（`createList`）并自动选中；`inbox` 不可删；
// - 关联事件的 todo 其 reminder 控件禁用（:236-237，提醒归事件持有）。
//
// store：`PimStore(storage: MemoryPimStorage())`——`testWidgets` 的 fake-async
// 区不驱动真实文件 IO。每次 `load()` 会启动 5 分钟快照周期 Timer，必须在
// 用例体末尾（`runTest` 的 pending-timer 断言之前）`dispose()`，见 [_widgetTest]。

import 'package:flutter/material.dart'
    show Color, DropdownMenu, MaterialApp, Scaffold, TextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/pim/pim_store.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';
import 'package:kos_deskcenter/src/widgets/todo_panel.dart';

/// 本用例创建的全部 store（见 [_widgetTest] 末尾统一销毁）。
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

/// widget 用例包装：用例体末尾（仍在 `runTest` 的 fake-async 区内、
/// pending-timer 断言之前）卸载面板并销毁 store。
///
/// 关键：**不能只在 `tearDown` 里 dispose**——`runTest` 会在返回前调用
/// `_verifyInvariants()` 断言无 pending timer，而 `tearDown` 在其之后执行。
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

/// 面板用 TextField/Checkbox/DropdownMenu，需要 Material / Localizations /
/// Overlay 宿主（真宿主 = `DeskPanelShell` 的 Material + popup host Overlay）。
Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: const Color(0x00000000),
    body: Center(child: SizedBox(width: 820, height: 780, child: child)),
  ),
);

TodoPanel _panel(PimStore store, {List<String> argv = const []}) => TodoPanel(
  request: DeskPanelRequest(appId: 'kos-todo', argv: argv),
  data: DeskPanelData(pimStore: store),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(820, 780));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

/// 点击侧栏导航（按标签文本；侧栏在 Row 首列，`.first` 避开正文同名文案，
/// 如「今天」过滤项与今日截止标签同名）。
Future<void> _tapNav(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pump();
}

void main() {
  _widgetTest('注册函数写入 deskPanelBuilderRegistry', (tester) async {
    registerTodoPanel();
    expect(deskPanelBuilderRegistry['kos-todo'], isNotNull);
    final store = await _freshStore();
    final widget = deskPanelBuilderRegistry['kos-todo']!(
      const DeskPanelRequest(appId: 'kos-todo'),
      DeskPanelData(pimStore: store),
    );
    expect(widget, isA<TodoPanel>());
  });

  _widgetTest('--view today 定位「今天」过滤', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    await store.addTodo(title: '今日任务', due: today, listId: 'inbox');
    await store.addTodo(title: '无期任务', listId: 'inbox');
    await _pump(tester, _panel(store, argv: const ['--view', 'today']));
    expect(find.text('今日任务'), findsOneWidget);
    expect(find.text('无期任务'), findsNothing);
  });

  _widgetTest('五个智能过滤 + 自定义清单正确分桶', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    final list = await store.createList(name: '工作');
    expect(list, isNotNull);
    await store.addTodo(title: '收件箱任务', listId: 'inbox');
    await store.addTodo(title: '今天任务', due: today, listId: 'inbox');
    await store.addTodo(
      title: '计划任务',
      due: today.add(const Duration(days: 3)),
      listId: 'inbox',
    );
    await store.addTodo(title: '清单任务', listId: list!.id);
    final event = await store.addEvent(
      title: '关联事件',
      start: DateTime(today.year, today.month, today.day, 9),
      end: DateTime(today.year, today.month, today.day, 10),
      linkedTodo: true,
      todoListId: 'inbox',
    );
    expect(event, isNotNull);
    final done = await store.addTodo(title: '已完成任务', listId: 'inbox');
    await store.setTodoCompleted(done!.uid, true);

    await _pump(tester, _panel(store));
    // inbox：未完成且 listId=inbox（自定义清单/已完成不落此桶）。
    expect(find.text('收件箱任务'), findsOneWidget);
    expect(find.text('清单任务'), findsNothing);
    expect(find.text('已完成任务'), findsNothing);

    await _tapNav(tester, '今天');
    expect(find.text('今天任务'), findsOneWidget);
    expect(find.text('收件箱任务'), findsNothing);

    await _tapNav(tester, '计划');
    expect(find.text('今天任务'), findsOneWidget);
    expect(find.text('计划任务'), findsOneWidget);
    expect(find.text('收件箱任务'), findsNothing);

    // 日历桶：linkedEventId 非空（关联事件同步建的 todo）。
    await _tapNav(tester, '日历');
    expect(find.text('关联事件'), findsOneWidget);
    expect(find.text('收件箱任务'), findsNothing);

    await _tapNav(tester, '已完成');
    expect(find.text('已完成任务'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('todo-list-${list.id}')));
    await tester.pump();
    expect(find.text('清单任务'), findsOneWidget);
    expect(find.text('收件箱任务'), findsNothing);
  });

  _widgetTest('勾选完成写回 setTodoCompleted 并从 inbox 消失', (tester) async {
    final store = await _freshStore();
    final todo = await store.addTodo(title: '勾选任务', listId: 'inbox');
    expect(todo, isNotNull);
    await _pump(tester, _panel(store));
    expect(find.text('勾选任务'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('todo-check-${todo!.uid}')));
    await tester.pump();
    expect(store.todoById(todo.uid)?.completed, isTrue);
    // 变更 → `_markChanged` → 150ms 保存防抖 → flush → 快照流 → 面板重建。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('勾选任务'), findsNothing);
  });

  _widgetTest('快速添加写回 store', (tester) async {
    final store = await _freshStore();
    await _pump(tester, _panel(store));
    await tester.enterText(
      find.byKey(const ValueKey('todo-quick-add')),
      '快速新任务',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(store.rawTodos.any((t) => t.summary == '快速新任务'), isTrue);
    // 跨过 150ms 保存防抖 → 快照流推送 → 新任务出现在 inbox 列表。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('快速新任务'), findsOneWidget);
  });

  _widgetTest('--item 直达编辑器（标题预填）', (tester) async {
    final store = await _freshStore();
    final todo = await store.addTodo(title: '直达任务', listId: 'inbox');
    await _pump(tester, _panel(store, argv: ['--item', todo!.uid]));
    expect(find.byKey(const ValueKey('todo-editor-title')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('todo-editor-title')))
          .controller
          ?.text,
      '直达任务',
    );
  });

  _widgetTest('编辑器提交改标题写回', (tester) async {
    final store = await _freshStore();
    final todo = await store.addTodo(title: '旧标题', listId: 'inbox');
    await _pump(tester, _panel(store, argv: ['--item', todo!.uid]));
    await tester.enterText(
      find.byKey(const ValueKey('todo-editor-title')),
      '新标题',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('todo-editor-save')));
    await tester.pump();
    expect(store.todoById(todo.uid)?.summary, '新标题');
    // 保存后面板回到列表视图。
    expect(find.byKey(const ValueKey('todo-editor-title')), findsNothing);
  });

  _widgetTest('新建任务编辑器提交写回', (tester) async {
    final store = await _freshStore();
    await _pump(tester, _panel(store));
    await tester.tap(find.byKey(const ValueKey('todo-new-task')));
    await tester.pump();
    expect(find.byKey(const ValueKey('todo-editor-title')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('todo-editor-title')),
      '全新任务',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('todo-editor-save')));
    await tester.pump();
    expect(store.rawTodos.any((t) => t.summary == '全新任务'), isTrue);
  });

  _widgetTest('新建清单生效并自动选中', (tester) async {
    final store = await _freshStore();
    await _pump(tester, _panel(store));
    await tester.tap(find.byKey(const ValueKey('todo-new-list')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('todo-new-list-field')),
      '购物',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(store.lists.any((l) => l.name == '购物'), isTrue);
    // 新建后直接选中该清单（activeFilter=list），侧栏 + 正文标题各一处。
    expect(find.text('购物'), findsWidgets);
  });

  _widgetTest('inbox 不提供删除钮，自定义清单可删', (tester) async {
    final store = await _freshStore();
    final list = await store.createList(name: '可删清单');
    expect(list, isNotNull);
    await _pump(tester, _panel(store));
    expect(find.byKey(const ValueKey('todo-list-remove-inbox')), findsNothing);
    expect(
      find.byKey(ValueKey('todo-list-remove-${list!.id}')),
      findsOneWidget,
    );
  });

  _widgetTest('关联事件的 todo 其提醒控件禁用', (tester) async {
    final store = await _freshStore();
    final today = DateTime.now();
    await store.addEvent(
      title: '关联事件',
      start: DateTime(today.year, today.month, today.day, 9),
      end: DateTime(today.year, today.month, today.day, 10),
      linkedTodo: true,
    );
    final todo = store.rawTodos.firstWhere((t) => t.linkedEventId.isNotEmpty);
    await _pump(tester, _panel(store, argv: ['--item', todo.uid]));
    final reminder = tester.widget<DropdownMenu<int>>(
      find.byKey(const ValueKey('todo-editor-reminder')),
    );
    expect(reminder.enabled, isFalse);
  });
}
