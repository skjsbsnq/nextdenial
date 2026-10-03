/// KOS DeskCenter 待办详情面板（TASK-14）：`kos-todo --view/--item` 的
/// DenialUI 重写。
///
/// 源端对照（`apps/todo/qml/Main.qml`，行号锚 NextKde 根）：
/// - 入口 `handleActivation`（:41-47）：`--view inbox|today|planned|
///   calendar|completed` → `activeFilter`；`--item` 值 → 快照到达后
///   `todoEditor.openForTodo`（`openPendingItem` :49-64）；
/// - 侧栏（:235-361）：5 个 `KosNavigationButton` 智能过滤 + `MY LISTS`
///   自定义清单（:328-349）+ `+` 新建清单（`listDialog` :193-222 →
///   `createList`）；`inbox` 为内置清单，不可删；
/// - 列表（:414-602）：快速添加框（`addTask` :154-165 →
///   `createTodo{title,listId,order:epochMs}`）+ 任务行（勾选
///   `updateTodo{id,completed}` :502-511、4px 优先级色条 :513-520、
///   标题完成划线 :526-536、截止标签逾期红 :542-548、清单名 :550-555、
///   `↻` 重复 :557-563、「已关联日历」徽章 :565-572、`⋯` 编辑 :576-581、
///   `×` 删 :583-590）；
/// - 分桶 `filteredTodos()`（:81-108）见 [_TodoPanelState._filtered]；
/// - 编辑器 `TodoEditorDialog.qml` 全字段（title/list/priority/
///   due date+time/allDay/repeat/reminder/notes/delete），关联事件
///   （`linkedEventId` 非空）时 reminder 禁用（:236-237——提醒归事件
///   持有）。
///
/// DenialUI：全前景/材质走 `context.shellTheme`/`shellColors`；表单控件
/// 走 `theme.toMaterialTheme()` 的局部 `Theme`（SDK 已配 inputDecoration
/// 主题）；激活态 `accentPalette.subtle`/`accent`，逾期/删除
/// `colors.performanceBad`，次要 `textSecondary`。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/material.dart'
    show
        Checkbox,
        DropdownMenu,
        DropdownMenuEntry,
        InputDecoration,
        TextEditingController,
        TextField,
        Theme;
import 'package:flutter/widgets.dart';
import '../data/pim/ical_parser.dart' show IcalTodo;
import '../data/pim/pim_store.dart'
    show
        PimList,
        PimPriorityLevel,
        PimStore,
        pimPriorityLevelOf,
        pimPriorityValueOf;
import '../data/widget_snapshot_watcher.dart' show WidgetSnapshot;
import 'desk_panel_shell.dart';

/// 注册 `kos-todo` 的面板内容构造器（装配点启动时调用一次；
/// `buildDeskPanelContent` 先查 `deskPanelBuilderRegistry`）。
void registerTodoPanel() {
  registerDeskPanelBuilder('kos-todo', buildTodoPanel);
}

/// `DeskPanelBuilder` 形态的 todo 面板入口。
Widget buildTodoPanel(DeskPanelRequest request, DeskPanelData data) =>
    TodoPanel(request: request, data: data);

/// 智能过滤档位（`--view` 合法值集，Main.qml:43）；`list` 为自定义
/// 清单桶（activeListId 区分，Main.qml:101-103）。
enum _TodoFilter { inbox, today, planned, calendar, completed, list }

/// 重复预设选项（TodoEditorDialog.qml:43 `recurrenceValues` + :222-224
/// 文案）；custom 规则不在编辑器重写（rrule.dart 头注）。
const List<(String, String)> _kRecurrenceOptions = [
  ('none', '不重复'),
  ('daily', '每天'),
  ('weekly', '每周'),
  ('monthly', '每月'),
  ('yearly', '每年'),
];

/// 提醒提前分钟选项（:49 `reminderValues` + :238-240 文案）。
const List<(int, String)> _kReminderOptions = [
  (-1, '无'),
  (0, '到时提醒'),
  (5, '提前 5 分钟'),
  (15, '提前 15 分钟'),
  (30, '提前 30 分钟'),
  (60, '提前 1 小时'),
  (1440, '提前 1 天'),
];

/// 优先级档位选项（:183 `model` + :106 `priorityValues` ——
/// `None/Low/Medium/High ↔ 0/9/5/1`，映射见 pim_store 的
/// [pimPriorityLevelOf]/[pimPriorityValueOf]）。
const List<(PimPriorityLevel, String)> _kPriorityOptions = [
  (PimPriorityLevel.none, '无'),
  (PimPriorityLevel.low, '低'),
  (PimPriorityLevel.medium, '中'),
  (PimPriorityLevel.high, '高'),
];

/// `yyyy-MM-dd`（`todayKey()`，Main.qml:77-79）。
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `datePart`（Main.qml:73-75）：编码日期时间取前 10 位日段。
String _datePart(String value) =>
    value.length >= 10 ? value.substring(0, 10) : '';

/// `HH:MM`（`dueTimeField` 回填，TodoEditorDialog.qml:93-94）。
String _timePart(String value) {
  final match = RegExp(r'T(\d{2}:\d{2})').firstMatch(value);
  return match?.group(1) ?? '';
}

/// todo 面板块：`DeskPanelShell.child` 内容（路由经 [registerTodoPanel]）。
class TodoPanel extends StatefulWidget {
  const TodoPanel({required this.request, required this.data, super.key});

  /// argv：`--view` → `activeFilter`（:42-44）、`--item` →
  /// `pendingItemId`（:45-46）。
  final DeskPanelRequest request;

  /// `pimStore` 为读写入口（`data.pimStore as PimStore`）；`snapshot`
  /// 供无 store 时只读预览。
  final DeskPanelData data;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  /// 数据源：面板写操作全走 store；快照订阅驱动重建（等价
  /// `PimClient.onSnapshotChanged` → `openPendingItem`，:173-176）。
  late final PimStore? _store =
      widget.data.pimStore is PimStore ? widget.data.pimStore as PimStore : null;

  StreamSubscription<WidgetSnapshot>? _snapshotSub;
  int _revision = 0;

  /// `activeFilter`/`activeListId`/`pendingItemId`（Main.qml:16-18）。
  _TodoFilter _activeFilter = _TodoFilter.inbox;
  String _activeListId = 'inbox';
  String _pendingItemId = '';

  /// 编辑器态：非 null 时整个面板切换为编辑表单（DeskPanelShell 场景下
  /// 不叠第二层 popup；对齐 `TodoEditorDialog` 模态语义）。
  IcalTodo? _editing;
  bool _editingNew = false;

  /// 新建清单内联输入态（`listDialog` :193-222 的窄列内联化）。
  bool _creatingList = false;
  final TextEditingController _listNameController = TextEditingController();

  final TextEditingController _quickAddController = TextEditingController();
  final FocusNode _quickAddFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // `--view` → `activeFilter`（:42-44）：五档合法值；未识别保持 inbox。
    _activeFilter = switch (widget.request.view) {
      'today' => _TodoFilter.today,
      'planned' => _TodoFilter.planned,
      'calendar' => _TodoFilter.calendar,
      'completed' => _TodoFilter.completed,
      _ => _TodoFilter.inbox,
    };
    // `--item` → `pendingItemId`：快照到达后开对应编辑器（:45-46）。
    _pendingItemId = widget.request.itemId ?? '';
    final store = _store;
    if (store != null) {
      _snapshotSub = store.snapshots.listen((_) {
        if (!mounted) return;
        setState(() => _revision += 1);
        _openPendingItem();
      });
      // store 可能已就绪（面板打开晚于 load）：立即尝试一次，
      // 对齐 `onSnapshotChanged` + `ready` 早退（:49-63）。
      _openPendingItem();
    }
  }

  @override
  void dispose() {
    unawaited(_snapshotSub?.cancel());
    _quickAddController.dispose();
    _quickAddFocus.dispose();
    _listNameController.dispose();
    super.dispose();
  }

  // ---------- argv → 编辑器 ----------

  /// `openPendingItem`（:49-64）：按 `--item` id 找到 todo 开编辑器；
  /// store 已就绪仍找不到则丢弃 pending（:62-63 `pim.ready` 早退）。
  void _openPendingItem() {
    if (_pendingItemId.isEmpty) return;
    final store = _store;
    if (store == null) {
      _pendingItemId = '';
      return;
    }
    final todo = store.todoById(_pendingItemId);
    if (todo != null) {
      _pendingItemId = '';
      _openEditor(todo);
    } else if (store.revision > 0 || store.rawTodos.isNotEmpty) {
      _pendingItemId = '';
    }
  }

  void _openEditor(IcalTodo todo) => setState(() {
    _editing = todo;
    _editingNew = false;
  });

  void _openNewEditor() => setState(() {
    _editing = null;
    _editingNew = true;
  });

  void _closeEditor() => setState(() {
    _editing = null;
    _editingNew = false;
  });

  // ---------- 数据 ----------

  List<PimList> get _lists => _store?.lists ?? const [];

  List<IcalTodo> get _todos => _store?.rawTodos ?? const [];

  /// `filteredTodos()`（Main.qml:81-108）分桶等价：
  /// inbox=未完成且 listId=inbox；today=未完成且 due 日段==今天；
  /// planned=未完成且有 due；calendar=未完成且 linkedEventId 非空；
  /// completed=已完成；list=未完成且 listId==activeListId。
  List<IcalTodo> _filtered() {
    final today = _ymd(DateTime.now());
    return [
      for (final t in _todos)
        if (switch (_activeFilter) {
          _TodoFilter.inbox =>
            !t.completed && (t.listId.isEmpty ? 'inbox' : t.listId) == 'inbox',
          _TodoFilter.today =>
            !t.completed &&
                t.due != null &&
                _datePart(PimStore.encodeDateTime(t.due)) == today,
          _TodoFilter.planned => !t.completed && t.due != null,
          _TodoFilter.calendar =>
            !t.completed && t.linkedEventId.isNotEmpty,
          _TodoFilter.completed => t.completed,
          _TodoFilter.list =>
            !t.completed &&
                (t.listId.isEmpty ? 'inbox' : t.listId) == _activeListId,
        })
          t,
    ];
  }

  /// `filterTitle`（:110-117）。
  String _filterTitle() => switch (_activeFilter) {
    _TodoFilter.today => '今天',
    _TodoFilter.planned => '计划',
    _TodoFilter.calendar => '日历',
    _TodoFilter.completed => '已完成',
    _TodoFilter.list => _listName(_activeListId),
    _TodoFilter.inbox => '收件箱',
  };

  /// `listName`（:119-126）。
  String _listName(String id) {
    for (final l in _lists) {
      if (l.id == id) return l.name;
    }
    return id == 'inbox' ? '收件箱' : '清单';
  }

  /// `isOverdue`（:139-143）：due 日段 < 今天且未完成。
  bool _isOverdue(IcalTodo t) {
    if (t.due == null || t.completed) return false;
    return _datePart(PimStore.encodeDateTime(t.due)).compareTo(_ymd(
          DateTime.now(),
        )) <
        0;
  }

  /// `dueLabel`（:128-137）：allDay → 今天显示「今天」否则日段；timed →
  /// `日期 · HH:MM`。
  String _dueLabel(IcalTodo t) {
    if (t.due == null) return '';
    final encoded = PimStore.encodeDateTime(t.due);
    final date = _datePart(encoded);
    if (t.allDay) {
      return date == _ymd(DateTime.now()) ? '今天' : date;
    }
    final time = _timePart(encoded);
    return time.isEmpty ? date : '$date · $time';
  }

  /// `priorityColor`（:145-152）：1-3 → destructive；4-6 → warning；
  /// 7-9 → accent。
  Color _priorityColor(IcalTodo t) {
    final colors = context.shellColors;
    if (t.priority > 0 && t.priority <= 3) return colors.performanceBad;
    if (t.priority > 0 && t.priority <= 6) return colors.performanceWarning;
    return context.shellTheme.accent;
  }

  // ---------- 写操作 ----------

  /// `addTask`（:154-165）：标题 → `createTodo{title,listId,order}`；
  /// 自定义清单视图落到该清单，其余回 `inbox`。
  Future<void> _addTask() async {
    final store = _store;
    final title = _quickAddController.text.trim();
    if (store == null || title.isEmpty) return;
    final listId =
        _activeFilter == _TodoFilter.list ? _activeListId : 'inbox';
    await store.addTodo(title: title, listId: listId);
    _quickAddController.clear();
    if (mounted) _quickAddFocus.requestFocus();
  }

  Future<void> _createList() async {
    final store = _store;
    final name = _listNameController.text.trim();
    if (store == null || name.isEmpty) {
      setState(() => _creatingList = false);
      return;
    }
    final list = await store.createList(name: name, color: '#4f8cff');
    _listNameController.clear();
    if (!mounted) return;
    setState(() {
      _creatingList = false;
      // 对齐 `selectFilter("list", id)`（:346-347）：新建后直接选中。
      if (list != null) {
        _activeFilter = _TodoFilter.list;
        _activeListId = list.id;
      }
    });
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    // _revision 只为让 setState 依赖可读（快照驱动重建）。dart 分析对
    // 「读而未用」不告警，但显式消费避免无用字段味。
    assert(_revision >= 0);
    // 编辑器态整面板替换（模态语义；`TodoEditorDialog` 对齐）。
    if (_editing != null || _editingNew) {
      return Theme(
        data: theme.toMaterialTheme(),
        child: _TodoEditor(
          key: ValueKey(_editing?.uid ?? 'new'),
          todo: _editing,
          lists: _lists,
          defaultListId:
              _activeFilter == _TodoFilter.list ? _activeListId : 'inbox',
          writable: _store?.writable ?? false,
          onSave: _saveEditor,
          onDelete: _deleteEditing,
          onCancel: _closeEditor,
        ),
      );
    }
    return SizedBox(
      // 面板内容固定底宽（DeskPanelShell 随内容自适应，上限 70% 屏）；
      // 侧栏+列表双列需最小宽度才不挤（对齐源 侧栏+正文 RowLayout）。
      width: 560,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSidebar(colors),
          const SizedBox(width: 16),
          Expanded(child: _buildBody(colors)),
        ],
      ),
    );
  }

  /// 侧栏（Main.qml:240-361）：5 智能过滤 + MY LISTS + 新建清单。
  Widget _buildSidebar(dynamic colors) {
    final theme = context.shellTheme;
    final palette = theme.accentPalette;
    Widget navItem(
      String label,
      String symbol,
      bool active,
      VoidCallback onTap,
    ) => _NavItem(
      label: label,
      symbol: symbol,
      active: active,
      onTap: onTap,
      // 激活态：accentPalette.subtle 底 + accent 字色（任务卡 §DenialUI）。
      activeColor: palette.subtle,
      activeTextColor: theme.accent,
      textColor: colors.textSecondary,
    );
    return SizedBox(
      width: 148,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // :262-304 五档智能过滤。
          navItem('收件箱', '▣', _activeFilter == _TodoFilter.inbox, () {
            setState(() => _activeFilter = _TodoFilter.inbox);
          }),
          navItem('今天', '◉', _activeFilter == _TodoFilter.today, () {
            setState(() => _activeFilter = _TodoFilter.today);
          }),
          navItem('计划', '◫', _activeFilter == _TodoFilter.planned, () {
            setState(() => _activeFilter = _TodoFilter.planned);
          }),
          navItem('日历', '▦', _activeFilter == _TodoFilter.calendar, () {
            setState(() => _activeFilter = _TodoFilter.calendar);
          }),
          navItem('已完成', '✓', _activeFilter == _TodoFilter.completed, () {
            setState(() => _activeFilter = _TodoFilter.completed);
          }),
          const SizedBox(height: 14),
          // :306-326 「MY LISTS」头 + 「+」钮（`listDialog.open`）。
          Row(
            children: [
              Expanded(
                child: Text(
                  'MY LISTS', // :311
                  style: ShellText.base.copyWith(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('todo-new-list'),
                behavior: HitTestBehavior.opaque,
                onTap: (_store?.writable ?? false)
                    ? () => setState(() => _creatingList = true)
                    : null, // :322 `pim.connected && pim.writable`
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Text(
                    '+',
                    style: ShellText.base.copyWith(
                      color: (_store?.writable ?? false)
                          ? colors.textSecondary
                          : colors.textTertiary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // `listDialog` 内联化（:193-222）：输入名 → createList。
          if (_creatingList)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Theme(
                data: theme.toMaterialTheme(),
                child: TextField(
                  key: const ValueKey('todo-new-list-field'),
                  controller: _listNameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '清单名',
                    isDense: true,
                  ),
                  onSubmitted: (_) => unawaited(_createList()),
                ),
              ),
            ),
          const SizedBox(height: 6),
          // :328-349 自定义清单条目（「●」符号位上色用清单色——清单色是
          // metadata.json 数据色，非前景硬编码）。
          for (final l in _lists)
            _NavItem(
              key: ValueKey('todo-list-${l.id}'),
              label: l.name,
              symbol: '●',
              symbolColor: _listColor(l.color, colors),
              active: _activeFilter == _TodoFilter.list &&
                  _activeListId == l.id,
              onTap: () => setState(() {
                _activeFilter = _TodoFilter.list;
                _activeListId = l.id;
              }),
              // inbox 保护（removeList :1374-1376 + 任务卡「inbox 不可删」）。
              trailing: l.id == 'inbox'
                  ? null
                  : GestureDetector(
                      key: ValueKey('todo-list-remove-${l.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: (_store?.writable ?? false)
                          ? () => unawaited(_removeList(l.id))
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Text(
                          '×',
                          style: ShellText.base.copyWith(
                            color: colors.textTertiary,
                            fontSize: 12,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
              activeColor: palette.subtle,
              activeTextColor: theme.accent,
              textColor: colors.textSecondary,
            ),
        ],
      ),
    );
  }

  /// 清单数据色（metadata.json `color` `#rrggbb`）→ Color；解析失败
  /// 回退 textSecondary。数据色按任务卡允许保留（非「前景硬编码」——
  /// 是用户数据）。
  Color _listColor(String hex, dynamic colors) {
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
    if (m == null) return colors.textSecondary as Color;
    return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
  }

  Future<void> _removeList(String id) async {
    final store = _store;
    if (store == null) return;
    await store.removeList(id); // store 层有 inbox 保护（:1374-1376）
    if (!mounted) return;
    if (_activeFilter == _TodoFilter.list && _activeListId == id) {
      setState(() {
        _activeFilter = _TodoFilter.inbox;
        _activeListId = 'inbox';
      });
    }
  }

  /// 右列（:363-603）：标题计数 + 快速添加 + 任务列表/空态。
  Widget _buildBody(dynamic colors) {
    final theme = context.shellTheme;
    final todos = _filtered();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // :372-386 标题 + 「%n task(s)」+ 「New task」钮（:409-413）。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _filterTitle(),
                    style: ShellText.base.copyWith(
                      color: colors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  Text(
                    '${todos.length} 项任务', // :383
                    style: ShellText.base.copyWith(
                      color: colors.textSecondary,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            // `New task`（:409-413，highlighted 主钮）：全字段新建入口，
            // 空 uid 走 `createTodo` 分支（`_saveEditor` else 路径）。
            GestureDetector(
              key: const ValueKey('todo-new-task'),
              behavior: HitTestBehavior.opaque,
              onTap: (_store?.writable ?? false) ? _openNewEditor : null,
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: theme.accentPalette.container, // highlighted
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.accentPalette.outline),
                ),
                alignment: Alignment.center,
                child: Text(
                  '新建任务',
                  style: ShellText.base.copyWith(
                    color: theme.accentPalette.onContainer,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // :414-438 快速添加框（`addTask`）。
        Theme(
          data: theme.toMaterialTheme(),
          child: TextField(
            key: const ValueKey('todo-quick-add'),
            controller: _quickAddController,
            focusNode: _quickAddFocus,
            enabled: _store?.writable ?? false, // :427
            decoration: InputDecoration(
              hintText: _activeFilter == _TodoFilter.list
                  ? '添加任务到「${_listName(_activeListId)}」…'
                  : '添加任务到「收件箱」…', // :423-425
              isDense: true,
            ),
            onSubmitted: (_) => unawaited(_addTask()),
          ),
        ),
        const SizedBox(height: 10),
        // :459-602 列表 / `KosEmptyState` 空态（:463-477）。
        if (todos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                _store == null
                    ? '未连接待办服务'
                    : _activeFilter == _TodoFilter.completed
                        ? '没有已完成任务' // :470-471
                        : '这里没有任务', // :469-471
                style: ShellText.base.copyWith(
                  color: colors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          )
        else
          for (var i = 0; i < todos.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6), // :484 spacing:6
              child: _TodoRowTile(
                key: ValueKey('todo-row-${todos[i].uid}'),
                todo: todos[i],
                listName: _listName(
                  todos[i].listId.isEmpty ? 'inbox' : todos[i].listId,
                ),
                dueLabel: _dueLabel(todos[i]),
                overdue: _isOverdue(todos[i]),
                priorityColor: _priorityColor(todos[i]),
                onToggle: (_store?.writable ?? false)
                    ? () => unawaited(
                        _store!.setTodoCompleted(
                          todos[i].uid,
                          !todos[i].completed,
                        ),
                      )
                    : null,
                onEdit: () => _openEditor(todos[i]),
                onDelete: (_store?.writable ?? false)
                    ? () => unawaited(_store!.removeTodo(todos[i].uid))
                    : null,
              ),
            ),
      ],
    );
  }

  /// `onSaveRequested`（Main.qml:184-189）：uid 非空 → `updateTodo`；
  /// 空 → `createTodo`（本端 `addTodo` 最小形态只收标题级，全字段走
  /// `updateTodo` 编辑；新建先用 addTodo 再立刻 updateTodo 全字段补齐——
  /// 保持 addTodo 签名不被本卡扩）。
  Future<void> _saveEditor(_TodoDraft draft) async {
    final store = _store;
    if (store == null) return;
    final editing = _editing;
    if (editing != null) {
      await store.updateTodo(
        editing.uid,
        title: draft.title,
        description: draft.description,
        listId: draft.listId,
        due: draft.due,
        clearDue: draft.due == null,
        allDay: draft.allDay,
        priority: draft.priority,
        recurrence: draft.recurrence,
        // 关联事件时 reminder 禁用且事件独占 alarm（:236-237/:1248）——
        // 传 null 不改，store 层 linked 分支恒写 -1。
        reminderMinutes:
            editing.linkedEventId.isNotEmpty ? null : draft.reminderMinutes,
      );
    } else {
      // openNew → createTodo 路径（:186-188）：先标题级建，再全字段补写。
      final created = await store.addTodo(
        title: draft.title,
        listId: draft.listId,
        priority: draft.priority,
        due: draft.due,
        allDay: draft.allDay,
      );
      if (created != null) {
        await store.updateTodo(
          created.uid,
          description: draft.description,
          recurrence: draft.recurrence,
          reminderMinutes: draft.reminderMinutes,
        );
      }
    }
    if (mounted) _closeEditor();
  }

  Future<void> _deleteEditing() async {
    final store = _store;
    final editing = _editing;
    if (store == null || editing == null) return;
    await store.removeTodo(editing.uid); // `onDeleteRequested`（:190）
    if (mounted) _closeEditor();
  }
}

/// 侧栏导航条目（`KosNavigationButton` 的 DenialUI 等价：激活态
/// accentPalette.subtle 底 + accent 字）。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.symbol,
    required this.active,
    required this.onTap,
    required this.activeColor,
    required this.activeTextColor,
    required this.textColor,
    this.symbolColor,
    this.trailing,
    super.key,
  });

  final String label;
  final String symbol;
  final Color? symbolColor;
  final bool active;
  final VoidCallback onTap;
  final Color activeColor;
  final Color activeTextColor;
  final Color textColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: active ? activeColor : const Color(0x00000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(
              symbol,
              style: ShellText.base.copyWith(
                color: symbolColor ??
                    (active ? activeTextColor : textColor),
                fontSize: 11,
                height: 1,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: active ? activeTextColor : textColor,
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  height: 1.2,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 任务行（Main.qml:488-599 delegate）：勾选 / 优先级色条 / 标题 /
/// 副行（截止+清单+↻+已关联日历）/ ⋯ 编辑 / × 删。
class _TodoRowTile extends StatelessWidget {
  const _TodoRowTile({
    required this.todo,
    required this.listName,
    required this.dueLabel,
    required this.overdue,
    required this.priorityColor,
    this.onToggle,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  final IcalTodo todo;
  final String listName;
  final String dueLabel;
  final bool overdue;
  final Color priorityColor;
  final VoidCallback? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final completed = todo.completed;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onEdit, // :497 行点击开编辑器
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        child: Row(
          children: [
            // 勾选（:502-511 `updateTodo{id,completed}`——本端
            // `setTodoCompleted` 即该分支最小形态）。
            GestureDetector(
              key: ValueKey('todo-check-${todo.uid}'),
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: completed
                      ? theme.accent
                      : const Color(0x00000000),
                  border: Border.all(
                    color: completed ? theme.accent : colors.hairline,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: completed
                    ? Text(
                        '✓',
                        style: TextStyle(
                          color: theme.accentPalette.onPrimary,
                          fontSize: 11,
                          height: 1,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            // 优先级色条（:513-520）：priority==0 时 0.18 透明度弱化。
            Container(
              width: 4,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: priorityColor.withValues(
                  alpha: todo.priority > 0 ? 1 : 0.18,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题（:526-536）：完成 → muted + 划线。
                  Text(
                    todo.summary.isEmpty ? '未命名任务' : todo.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.base.copyWith(
                      color: completed
                          ? colors.textSecondary
                          : colors.textPrimary,
                      fontSize: 13,
                      height: 1.3,
                      decoration:
                          completed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  // 副行（:538-573）：截止 / 清单名 / ↻ / 关联徽章。
                  if (dueLabel.isNotEmpty ||
                      todo.recurrencePreset != 'none' ||
                      todo.linkedEventId.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Row(
                        children: [
                          if (dueLabel.isNotEmpty)
                            Text(
                              dueLabel,
                              style: ShellText.base.copyWith(
                                color: overdue
                                    ? colors.performanceBad // :544-545
                                    : colors.textSecondary,
                                fontSize: 11,
                                height: 1.3,
                              ),
                            ),
                          if (dueLabel.isNotEmpty)
                            const SizedBox(width: 8),
                          Text(
                            listName, // :550-555
                            style: ShellText.base.copyWith(
                              color: colors.textSecondary,
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                          if (todo.recurrencePreset != 'none' &&
                              todo.recurrencePreset.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(
                              '↻', // :557-563
                              style: ShellText.base.copyWith(
                                color: theme.accent,
                                fontSize: 11,
                                height: 1.3,
                              ),
                            ),
                          ],
                          if (todo.linkedEventId.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(
                              '已关联日历', // :565-572 "Calendar linked"
                              style: ShellText.base.copyWith(
                                color: theme.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // `⋯` 编辑（:576-581）。
            _iconButton(
              key: ValueKey('todo-edit-${todo.uid}'),
              label: '⋯',
              color: colors.textSecondary,
              onTap: onEdit,
            ),
            // `×` 删（:583-590 destructive）。
            _iconButton(
              key: ValueKey('todo-delete-${todo.uid}'),
              label: '×',
              color: colors.performanceBad,
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton({
    required Key key,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 14, height: 1),
      ),
    ),
  );
}

/// 编辑器表单提交草稿（`todoPayload`，TodoEditorDialog.qml:103-123）。
final class _TodoDraft {
  const _TodoDraft({
    required this.title,
    required this.description,
    required this.listId,
    required this.due,
    required this.allDay,
    required this.priority,
    required this.recurrence,
    required this.reminderMinutes,
  });

  final String title;
  final String description;
  final String listId;
  final DateTime? due;
  final bool allDay;
  final int priority;
  final String recurrence;
  final int reminderMinutes;
}

/// `TodoEditorDialog.qml` 的 DenialUI 全字段表单：title/list/priority/
/// due date+time/allDay/repeat/reminder/notes/delete（关联事件禁改
/// reminder，:236-237 + 横幅 :134-152）。
class _TodoEditor extends StatefulWidget {
  const _TodoEditor({
    required this.todo,
    required this.lists,
    required this.defaultListId,
    required this.writable,
    required this.onSave,
    required this.onDelete,
    required this.onCancel,
    super.key,
  });

  /// null = `openNew`（:70-84）；非 null = `openForTodo`（:86-101）。
  final IcalTodo? todo;
  final List<PimList> lists;
  final String defaultListId;
  final bool writable;
  final Future<void> Function(_TodoDraft draft) onSave;
  final Future<void> Function() onDelete;
  final VoidCallback onCancel;

  @override
  State<_TodoEditor> createState() => _TodoEditorState();
}

class _TodoEditorState extends State<_TodoEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.todo?.summary ?? '');
  late final TextEditingController _notes =
      TextEditingController(text: widget.todo?.description ?? '');
  late final TextEditingController _dueDate = TextEditingController(
    text: widget.todo?.due == null
        ? ''
        : _datePart(PimStore.encodeDateTime(widget.todo!.due!)),
  );
  late final TextEditingController _dueTime = TextEditingController(
    text: widget.todo?.due == null
        ? '18:00' // :77 openNew 默认
        : _timePart(PimStore.encodeDateTime(widget.todo!.due!)),
  );

  late String _listId = () {
    final id = widget.todo?.listId ?? widget.defaultListId;
    // `listIndex`（:34-40）：不在清单回退首项（inbox 恒在首位）。
    return widget.lists.any((l) => l.id == id)
        ? (id.isEmpty ? 'inbox' : id)
        : (widget.lists.isEmpty ? 'inbox' : widget.lists.first.id);
  }();
  late bool _allDay = widget.todo?.allDay ?? true; // :78 openNew 默认
  late PimPriorityLevel _priority =
      pimPriorityLevelOf(widget.todo?.priority ?? 0);
  late String _recurrence = () {
    final preset = widget.todo?.recurrencePreset ?? 'none';
    // `recurrenceIndex`（:42-46）：custom/未知 → 下标 0（编辑器不重写
    // custom 规则，rrule.dart 头注——但显示上保持原值不被误改：custom
    // 时提交仍写 'custom' 会 被 store 拒绝，故 UI 对 custom 直接只读
    // 展示「自定义」）。
    return preset;
  }();
  late int _reminder = () {
    final minutes = widget.todo?.reminderMinutes ?? -1;
    // `reminderIndex`（:48-52）：不在预设值 → 下标 0（无）。
    return _kReminderOptions.any((o) => o.$1 == minutes) ? minutes : -1;
  }();

  /// `linkedToCalendar`（:16）：`linkedEventId` 非空。
  bool get _linked => (widget.todo?.linkedEventId ?? '').isNotEmpty;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _dueDate.dispose();
    _dueTime.dispose();
    super.dispose();
  }

  /// `todoPayload`（:103-123）：date+time 组装 due；重复要求有日期
  /// （:118-119）；无日期 reminder 强 -1（:120-121）。
  _TodoDraft _payload() {
    final date = _dueDate.text.trim();
    DateTime? due;
    if (date.isNotEmpty) {
      final time = _allDay ? '00:00' : _dueTime.text.trim();
      due = DateTime.tryParse('${date}T$time:00') ??
          DateTime.tryParse('${date}T00:00:00');
    }
    return _TodoDraft(
      title: _title.text.trim(),
      description: _notes.text.trim(),
      listId: _listId,
      due: due,
      allDay: _allDay,
      priority: pimPriorityValueOf(_priority),
      recurrence: due == null ? 'none' : _recurrence,
      reminderMinutes: due == null ? -1 : _reminder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final editing = widget.todo != null;
    final hasDue = _dueDate.text.trim().isNotEmpty;
    final canSave = widget.writable && _title.text.trim().isNotEmpty;

    TextStyle label() => ShellText.base.copyWith(
      color: colors.textSecondary,
      fontSize: 11.5,
      height: 1.3,
    );

    return SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // :134-152 关联横幅（linkedToCalendar 时显示）。
          if (_linked)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.accentPalette.subtle,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.accentPalette.outline),
              ),
              child: Text(
                '已关联日历事件。标题与截止时间的修改会同步到日历；提醒由日历管理。',
                style: ShellText.base.copyWith(
                  color: colors.textPrimary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          Text('标题', style: label()), // :154
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('todo-editor-title'),
            controller: _title,
            autofocus: true,
            enabled: widget.writable,
            decoration: const InputDecoration(hintText: '任务标题'),
            onChanged: (_) => setState(() {}), // canSave 跟随标题
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // 清单（:165-175 ComboBox）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('清单', style: label()),
                    const SizedBox(height: 4),
                    DropdownMenu<String>(
                      key: const ValueKey('todo-editor-list'),
                      initialSelection: _listId,
                      enabled: widget.writable,
                      dropdownMenuEntries: [
                        for (final l in widget.lists)
                          DropdownMenuEntry(value: l.id, label: l.name),
                      ],
                      onSelected: (v) =>
                          setState(() => _listId = v ?? _listId),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 优先级（:179-186）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('优先级', style: label()),
                    const SizedBox(height: 4),
                    DropdownMenu<PimPriorityLevel>(
                      key: const ValueKey('todo-editor-priority'),
                      initialSelection: _priority,
                      enabled: widget.writable,
                      dropdownMenuEntries: [
                        for (final o in _kPriorityOptions)
                          DropdownMenuEntry(value: o.$1, label: o.$2),
                      ],
                      onSelected: (v) =>
                          setState(() => _priority = v ?? _priority),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('截止日期', style: label()), // :189
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('todo-editor-due-date'),
                  controller: _dueDate,
                  enabled: widget.writable,
                  decoration: const InputDecoration(
                    hintText: '可选 YYYY-MM-DD',
                  ),
                  onChanged: (_) =>
                      setState(() {}), // :204/:223/:236 联动 enabled
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: TextField(
                  key: const ValueKey('todo-editor-due-time'),
                  controller: _dueTime,
                  // :204 `enabled: dueDate 非空 && !allDay`
                  enabled: widget.writable && hasDue && !_allDay,
                  decoration: const InputDecoration(hintText: 'HH:MM'),
                ),
              ),
              const SizedBox(width: 8),
              // :208-211 `CheckBox{text:"All day"}`
              GestureDetector(
                key: const ValueKey('todo-editor-allday'),
                behavior: HitTestBehavior.opaque,
                onTap: widget.writable
                    ? () => setState(() => _allDay = !_allDay)
                    : null,
                child: Row(
                  children: [
                    Checkbox(
                      value: _allDay,
                      onChanged: widget.writable
                          ? (v) => setState(() => _allDay = v ?? false)
                          : null,
                    ),
                    Text('全天', style: label()),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // 重复（:217-228；enabled 要求有截止日期）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('重复', style: label()),
                    const SizedBox(height: 4),
                    if (_recurrence == 'custom')
                      // custom 规则编辑器不重写（rrule.dart 头注）：只读展示。
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '自定义',
                          style: label().copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                      )
                    else
                      DropdownMenu<String>(
                        key: const ValueKey('todo-editor-recurrence'),
                        initialSelection: _recurrence,
                        // :223 `enabled: dueDate 非空`
                        enabled: widget.writable && hasDue,
                        dropdownMenuEntries: [
                          for (final o in _kRecurrenceOptions)
                            DropdownMenuEntry(value: o.$1, label: o.$2),
                        ],
                        onSelected: (v) =>
                            setState(() => _recurrence = v ?? _recurrence),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 提醒（:230-243）：`enabled: dueDate 非空 &&
              // !linkedToCalendar`——关联事件时禁用（任务卡硬约束）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('提醒', style: label()),
                    const SizedBox(height: 4),
                    DropdownMenu<int>(
                      key: const ValueKey('todo-editor-reminder'),
                      initialSelection: _reminder,
                      enabled: widget.writable && hasDue && !_linked,
                      dropdownMenuEntries: [
                        for (final o in _kReminderOptions)
                          DropdownMenuEntry(value: o.$1, label: o.$2),
                      ],
                      onSelected: (v) =>
                          setState(() => _reminder = v ?? _reminder),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('备注', style: label()), // :246
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('todo-editor-notes'),
            controller: _notes,
            enabled: widget.writable,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(hintText: '可选备注'),
          ),
          const SizedBox(height: 14),
          // 底部按钮行：Cancel / Delete（编辑态）/ Save（:26
          // `standardButtons: Save|Cancel` + :259-268 删除钮）。
          Row(
            children: [
              if (editing)
                GestureDetector(
                  key: const ValueKey('todo-editor-delete'),
                  behavior: HitTestBehavior.opaque,
                  onTap:
                      widget.writable ? () => unawaited(widget.onDelete()) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Text(
                      '删除任务', // :261
                      style: ShellText.base.copyWith(
                        color: colors.performanceBad,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              _panelButton(
                key: const ValueKey('todo-editor-cancel'),
                label: '取消',
                color: colors.textSecondary,
                onTap: widget.onCancel,
              ),
              const SizedBox(width: 8),
              _panelButton(
                key: const ValueKey('todo-editor-save'),
                label: '保存',
                color: theme.accent,
                filled: true,
                fillColor: theme.accentPalette.subtle,
                onTap: canSave
                    ? () => unawaited(widget.onSave(_payload()))
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _panelButton({
    required Key key,
    required String label,
    required Color color,
    VoidCallback? onTap,
    bool filled = false,
    Color? fillColor,
  }) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: filled && onTap != null
            ? fillColor
            : const Color(0x00000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: ShellText.base.copyWith(
          color: onTap == null
              ? context.shellColors.textTertiary
              : color,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
