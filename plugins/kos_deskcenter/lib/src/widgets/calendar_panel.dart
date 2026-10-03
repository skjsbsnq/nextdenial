/// KOS DeskCenter calendar 详情面板（TASK-13）：`kos-calendar` 的内嵌面板
/// 内容体，放进 `DeskPanelShell.child`。
///
/// 源端对照（行号锚 `/home/wwt/文档/NextKde/apps/calendar/qml/`）：
/// - `Main.qml:143-166 handleActivation`：`--date` → `selectedDate`/
///   `visibleMonth`，`--view` → month/week/day 索引；
/// - `CalendarMonthView.qml`：42 格月网格、每日 ≤3 chip +「+N」、点日期
///   选中（:64-194）；
/// - `CalendarScheduleView.qml`：week/day 共用的 24h×dayCount 小时格 +
///   全日行（:98-338；不画红时刻线，面板为静态预览）；
/// - `Main.qml:222-281 buildItemsByDate`：occurrences + todoOccurrences
///   合并、linked-todo 去重、多日事件铺到覆盖日、allDay 优先排序；
/// - `EventEditorDialog.qml` / `CalendarTaskEditorDialog.qml`：编辑器
///   全字段/子集。
///
/// 数据：`data.pimStore as PimStore` 的 `eventsForRange`（窗口随视图：
/// month=月网格 42 格、week=周日、day=当日，Main.qml:394-408）；
/// 写侧 `addEvent`/`updateEvent`/`removeEvent`/`updateTodo`/
/// `setTodoCompleted`/`removeTodo`（TASK-13 补的写方法）。
///
/// DenialUI：无 MaterialApp/Theme 祖先，前景全走 `context.shellTheme`/
/// `context.shellColors`/`ShellText`；语义色：今日/选中=accent、
/// 逾期待办=performanceBad、清单色=accentPalette。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/widgets.dart';

import '../data/pim/pim_store.dart';
import '../data/widget_snapshot_watcher.dart' show PimEvent, PimTodo;
import 'desk_panel_shell.dart';

/// `kos-calendar` 面板内容构造器（注册表入口）。
Widget buildCalendarPanel(DeskPanelRequest request, DeskPanelData data) =>
    CalendarPanel(request: request, data: data);

/// 注册 calendar 面板 builder；幂等（后注册覆盖）。
/// 由装配层（主代理收口）统一调用，本文件不自调。
void registerCalendarPanel() =>
    registerDeskPanelBuilder('kos-calendar', buildCalendarPanel);

/// 面板视图（`Main.qml:28` `["month","week","day"]`）。
enum _CalView { month, week, day }

/// `itemsByDate` 的条目：kind + 记录（Main.qml:233/:266）。
final class _CalItem {
  const _CalItem.event(this.event) : todo = null;
  const _CalItem.todo(this.todo) : event = null;

  final PimEvent? event;
  final PimTodo? todo;

  bool get isTodo => todo != null;

  /// `itemTitle`（:307-309）：todo/event title，空 → 「无标题」。
  String get title {
    final t = isTodo ? todo!.title : event!.title;
    return t.isEmpty ? '无标题' : t;
  }

  /// `itemDateTime`（:311-314）：todo 用 due、event 用 start。
  String get dateTime => isTodo ? todo!.due : event!.start;

  /// `itemAllDay`（:328-330）。
  bool get allDay => isTodo ? todo!.allDay : event!.allDay;

  /// `itemCompleted`（:332-337）：todo.completed /
  /// event.linkedTodoCompleted。
  bool get completed =>
      isTodo ? todo!.completed : event!.linkedTodoCompleted;

  /// `itemTodoId`（:339-344）：todo → seriesId/id 回退、event →
  /// linkedTodoId。
  String get todoId => isTodo
      ? (todo!.seriesId.isNotEmpty ? todo!.seriesId : todo!.id)
      : (event!.linkedTodoId ?? '');

  /// `itemHour`（:323-326）：`T(\d{2}):` 提取；无时制 → 0。
  int get hour {
    final m = RegExp(r'T(\d{2}):').firstMatch(dateTime);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }
}

/// `yyyy-MM-dd`（`dateKey`，Main.qml:181-183）。
String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _dayZero(DateTime d) => DateTime(d.year, d.month, d.day);

/// `encodeDateTime` 前缀 → 本地 DateTime（`yyyy-MM-dd[THH:mm:ss...]`）。
DateTime? _parseEncoded(String s) {
  if (s.length < 10) return null;
  final y = int.tryParse(s.substring(0, 4));
  final m = int.tryParse(s.substring(5, 7));
  final d = int.tryParse(s.substring(8, 10));
  if (y == null || m == null || d == null) return null;
  var hour = 0, minute = 0;
  final tm = RegExp(r'T(\d{2}):(\d{2})').firstMatch(s);
  if (tm != null) {
    hour = int.tryParse(tm.group(1)!) ?? 0;
    minute = int.tryParse(tm.group(2)!) ?? 0;
  }
  return DateTime(y, m, d, hour, minute);
}

/// `#rrggbb`/`#aarrggbb` → Color；非法 → null。
Color? _parseHexColor(String raw) {
  var hex = raw.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}

/// calendar 面板内容（`DeskPanelShell.child`）。
///
/// 自持有 `selectedDate`/`visibleMonth`/`viewIndex` 状态；订阅
/// `store.changes` 在 mutation 后重建（对齐 `changed` → `updateEventRange`
/// 链路，Main.qml:466-485）。
class CalendarPanel extends StatefulWidget {
  const CalendarPanel({
    required this.request,
    required this.data,
    super.key,
  });

  final DeskPanelRequest request;
  final DeskPanelData data;

  @override
  State<CalendarPanel> createState() => _CalendarPanelState();
}

class _CalendarPanelState extends State<CalendarPanel> {
  late DateTime _selectedDate;
  late DateTime _visibleMonth;
  late _CalView _view;
  final DateTime _now = DateTime.now();
  StreamSubscription<int>? _sub;

  /// 行内编辑器态（`null` = 不显示；事件与待办编辑器共用一槽）。
  _EditorRequest? _editor;

  PimStore? get _store => widget.data.pimStore as PimStore?;

  @override
  void initState() {
    super.initState();
    // handleActivation（Main.qml:143-166）：--view → 视图索引；
    // --date（`yyyy-MM-dd` 或 `today`）→ selectedDate/visibleMonth。
    _view = switch (widget.request.view) {
      'week' => _CalView.week,
      'day' => _CalView.day,
      _ => _CalView.month,
    };
    var initial = _dayZero(_now);
    final requested = widget.request.date;
    if (requested != null && requested != 'today') {
      final parsed = DateTime.tryParse(requested);
      if (parsed != null && _dateKey(parsed) == requested) {
        initial = _dayZero(parsed);
      }
    }
    _selectedDate = initial;
    _visibleMonth = DateTime(initial.year, initial.month);
    _sub = _store?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  // ---------- 视图几何（Main.qml:185-198,394-408）----------

  /// 周一为首列（`localeFirstDayOfWeek`，中文语境 Monday-first，
  /// :30 与 calendar_card 一致）。
  DateTime get _weekStart =>
      _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));

  /// 月网格第 [index] 格的日期（`dateForMonthCell`，:194-198 /
  /// CalendarMonthView.qml:24-29）；visibleMonth 起 42 格。
  DateTime _monthCellDate(int index) {
    final first = DateTime(_visibleMonth.year, _visibleMonth.month);
    final offset = (first.weekday - 1) % 7; // 周一为首列
    return DateTime(
      _visibleMonth.year,
      _visibleMonth.month,
      index - offset + 1,
    );
  }

  /// `updateEventRange`（:394-408）：month=网格 42 格、week=周日、day=当日。
  (DateTime, DateTime) get _range => switch (_view) {
    _CalView.month => (_monthCellDate(0), _monthCellDate(41)),
    _CalView.week => (_weekStart, _weekStart.add(const Duration(days: 6))),
    _CalView.day => (_selectedDate, _selectedDate),
  };

  /// `shiftView`（:418-433）：month 保留日号钳到月末；week ±7 天、
  /// day ±1 天并同步 visibleMonth。
  void _shiftView(int offset) {
    setState(() {
      if (_view == _CalView.month) {
        final target = DateTime(
          _visibleMonth.year,
          _visibleMonth.month + offset,
        );
        final lastDay = DateTime(target.year, target.month + 1, 0).day;
        _visibleMonth = target;
        _selectedDate = DateTime(
          target.year,
          target.month,
          _selectedDate.day.clamp(1, lastDay),
        );
      } else {
        final days = _view == _CalView.week ? 7 : 1;
        _selectedDate =
            _selectedDate.add(Duration(days: offset * days));
        _visibleMonth = DateTime(_selectedDate.year, _selectedDate.month);
      }
    });
  }

  /// `showToday`（:410-416）。
  void _showToday() => setState(() {
    _selectedDate = _dayZero(DateTime.now());
    _visibleMonth = DateTime(_selectedDate.year, _selectedDate.month);
  });

  void _selectDate(DateTime day) => setState(() {
    _selectedDate = _dayZero(day);
    if (day.month != _visibleMonth.month || day.year != _visibleMonth.year) {
      _visibleMonth = DateTime(day.year, day.month);
    }
  });

  // ---------- itemsByDate（Main.qml:222-281）----------

  /// 合并 occurrences + todoOccurrences 并按日铺排、linked-todo 去重。
  /// `showEvents`/`showTasks` 面板本期恒 true；完成待办仍显示（
  /// `showCompletedTasks` 面板不做过滤开关，与月网格「完成态删除线」
  /// 展示配合）。
  Map<String, List<_CalItem>> _buildItemsByDate(PimStore store) {
    final (lo, hi) = _range;
    final range = store.eventsForRange(lo, hi);
    final result = <String, List<_CalItem>>{};
    final representedTodos = <String, Set<String>>{};

    void addDayRange(String startKey, String endKey, _CalItem item,
        [Map<String, Set<String>>? bucket]) {
      // `addDayRange`（:206-220）：startKey..endKey 逐日落桶。
      final start = _parseEncoded(startKey);
      if (start == null) return;
      final end = _parseEncoded(endKey) ?? start;
      for (var day = _dayZero(start);
          !day.isAfter(_dayZero(end));
          day = day.add(const Duration(days: 1))) {
        final key = _dateKey(day);
        if (bucket != null) {
          (bucket[key] ??= <String>{}).add(key);
        } else {
          (result[key] ??= []).add(item);
        }
      }
    }

    void addRange(DateTime? start, DateTime? end, _CalItem item,
        [Map<String, Set<String>>? bucket]) {
      if (start == null) return;
      final sKey = _dateKey(start);
      // end > start 时末格取前一日（:236-239：多日事件落在开始日与
      // 覆盖日，不含排他 end 日）。
      final eKey = end != null && _dayZero(end).isAfter(_dayZero(start))
          ? _dateKey(_dayZero(end).subtract(const Duration(days: 1)))
          : sKey;
      if (bucket != null) {
        for (var day = _dayZero(start);
            !day.isAfter(_dayZero(_parseEncoded(eKey)!));
            day = day.add(const Duration(days: 1))) {
          (bucket[_dateKey(day)] ??= <String>{}).add(_dateKey(day));
        }
      } else {
        addDayRange(sKey, eKey, item);
      }
    }

    for (final e in range.occurrences) {
      final item = _CalItem.event(e);
      final start = _parseEncoded(e.start);
      final end = _parseEncoded(e.end);
      addRange(start, end, item);
      final todoId = e.linkedTodoId ?? '';
      if (todoId.isNotEmpty) {
        // :240-248 —— 该 linked todo 已被 event 行代表的日期集合。
        final days = representedTodos.putIfAbsent(todoId, () => <String>{});
        if (start != null) {
          final eKey = end != null && _dayZero(end).isAfter(_dayZero(start))
              ? _dayZero(end).subtract(const Duration(days: 1))
              : _dayZero(start);
          for (var day = _dayZero(start);
              !day.isAfter(eKey);
              day = day.add(const Duration(days: 1))) {
            days.add(_dateKey(day));
          }
        }
      }
    }
    for (final t in range.todoOccurrences) {
      final due = t.due.length >= 10 ? t.due.substring(0, 10) : '';
      if (due.isEmpty) continue;
      final id = t.seriesId.isNotEmpty ? t.seriesId : t.id;
      // :260-262 —— linked todo 在 event 行已落同一天的跳过（去重）。
      if (representedTodos[id]?.contains(due) ?? false) continue;
      addDayRange(due, due, _CalItem.todo(t));
    }
    // :271-279 —— 全日优先，再按时刻字符串排序。
    for (final list in result.values) {
      list.sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.dateTime.compareTo(b.dateTime);
      });
    }
    return result;
  }

  List<_CalItem> _itemsFor(
          Map<String, List<_CalItem>> byDate, DateTime day) =>
      byDate[_dateKey(day)] ?? const [];

  /// `itemColor`（:364-369）：todo → 清单色；event → accent。
  Color _itemColor(_CalItem item, Color accent) {
    if (!item.isTodo) return accent;
    final store = _store;
    final listId = item.todo!.listId;
    if (store != null) {
      for (final l in store.lists) {
        if (l.id == listId) {
          return _parseHexColor(l.color) ?? accent;
        }
      }
    }
    return accent;
  }

  /// `itemSubtitle`（:371-379）：todo → 清单名；event → 地点 /
  /// 「已关联待办」/「日程」。
  String _itemSubtitle(_CalItem item) {
    final store = _store;
    if (item.isTodo) {
      final listId = item.todo!.listId;
      if (store != null) {
        for (final l in store.lists) {
          if (l.id == listId) return l.name;
        }
      }
      return '清单';
    }
    final e = item.event!;
    if (e.location.isNotEmpty) return e.location;
    return (e.linkedTodoId ?? '').isNotEmpty ? '已关联待办' : '日程';
  }

  /// `itemTime`（:316-321）：allDay → 「全日」，否则 `HH:mm`。
  String _itemTime(_CalItem item) {
    if (item.allDay) return '全日';
    final m = RegExp(r'T(\d{2}:\d{2})').firstMatch(item.dateTime);
    return m?.group(1) ?? '--:--';
  }

  // ---------- 写侧（Main.qml:515-529 回调 + :388-392 toggleItem）----------

  Future<void> _toggleItem(_CalItem item, bool completed) async {
    final store = _store;
    final todoId = item.todoId;
    if (store == null || todoId.isEmpty) return;
    await store.setTodoCompleted(todoId, completed);
  }

  void _openItem(_CalItem item) => setState(() {
    _editor = item.isTodo
        ? _EditorRequest.todo(item.todo!)
        : _EditorRequest.event(item.event!);
  });

  void _createForDate(DateTime day, [int? hour]) => setState(() {
    _editor = _EditorRequest.newEvent(_dayZero(day), hour: hour);
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final store = _store;
    final byDate =
        store == null ? const <String, List<_CalItem>>{} : _buildItemsByDate(store);
    final selectedItems = _itemsFor(byDate, _selectedDate);
    final accent = theme.accent;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          title: _headerTitle(),
          view: _view,
          writable: store?.writable ?? false,
          onShift: _shiftView,
          onToday: _showToday,
          onViewChanged: (v) => setState(() => _view = v),
          onNewEvent: () => _createForDate(_selectedDate),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // mini 月历导航（Main.qml:649-774）。
            SizedBox(
              width: 168,
              child: _MiniMonth(
                visibleMonth: _visibleMonth,
                selectedDate: _selectedDate,
                now: _now,
                onSelect: _selectDate,
                onShiftMonth: (offset) => setState(() {
                  _visibleMonth = DateTime(
                    _visibleMonth.year,
                    _visibleMonth.month + offset,
                  );
                }),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: switch (_view) {
                _CalView.month => _MonthGrid(
                    visibleMonth: _visibleMonth,
                    selectedDate: _selectedDate,
                    now: _now,
                    itemsForDate: (d) => _itemsFor(byDate, d),
                    colorOf: (i) => _itemColor(i, accent),
                    onSelectDate: _selectDate,
                    onActivate: _openItem,
                  ),
                _CalView.week => _ScheduleView(
                    firstDate: _weekStart,
                    dayCount: 7,
                    now: _now,
                    itemsForDate: (d) => _itemsFor(byDate, d),
                    colorOf: (i) => _itemColor(i, accent),
                    onSelectDate: _selectDate,
                    onActivate: _openItem,
                    onCreate: _createForDate,
                  ),
                _CalView.day => _ScheduleView(
                    firstDate: _selectedDate,
                    dayCount: 1,
                    now: _now,
                    itemsForDate: (d) => _itemsFor(byDate, d),
                    colorOf: (i) => _itemColor(i, accent),
                    onSelectDate: _selectDate,
                    onActivate: _openItem,
                    onCreate: _createForDate,
                  ),
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Agenda(
          date: _selectedDate,
          items: selectedItems,
          timeOf: _itemTime,
          subtitleOf: _itemSubtitle,
          colorOf: (i) => _itemColor(i, accent),
          onToggle: _toggleItem,
          onActivate: _openItem,
          colors: colors,
        ),
        if (_editor != null) ...[
          const SizedBox(height: 12),
          _EditorHost(
            request: _editor!,
            store: store,
            onClose: () => setState(() => _editor = null),
          ),
        ],
      ],
    );
  }

  /// `headerTitle`（:435-447）的中文版：month=「yyyy年M月」、
  /// day=「yyyy年M月d日」、week=「M月d日 – M月d日」。
  String _headerTitle() => switch (_view) {
    _CalView.month => '${_visibleMonth.year}年${_visibleMonth.month}月',
    _CalView.day =>
      '${_selectedDate.year}年${_selectedDate.month}月${_selectedDate.day}日',
    _CalView.week => () {
        final end = _weekStart.add(const Duration(days: 6));
        return '${_weekStart.month}月${_weekStart.day}日 – '
            '${end.month}月${end.day}日';
      }(),
  };
}

// ---------- 工具条（Main.qml:939-1046 精简：‹ › 今天 + 分段 + 新建）----------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.view,
    required this.writable,
    required this.onShift,
    required this.onToday,
    required this.onViewChanged,
    required this.onNewEvent,
  });

  final String title;
  final _CalView view;
  final bool writable;
  final void Function(int) onShift;
  final VoidCallback onToday;
  final void Function(_CalView) onViewChanged;
  final VoidCallback onNewEvent;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return Row(
      children: [
        _NavButton(label: '‹', onTap: () => onShift(-1)),
        _NavButton(label: '›', onTap: () => onShift(1)),
        _NavButton(label: '今天', onTap: onToday, wide: true),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
        _ViewSegmented(view: view, onChanged: onViewChanged),
        const SizedBox(width: 8),
        _NavButton(
          label: '+ 日程',
          onTap: writable ? onNewEvent : null,
          wide: true,
          accent: theme.accent,
        ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.label,
    required this.onTap,
    this.wide = false,
    this.accent,
  });

  final String label;
  final VoidCallback? onTap;
  final bool wide;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final enabled = onTap != null;
    final color = accent ?? colors.surfaceContainerHigh;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 26,
        width: wide ? null : 30,
        padding: wide ? const EdgeInsets.symmetric(horizontal: 10) : null,
        margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(
          color: enabled
              ? (accent ?? color).withValues(
                  alpha: accent != null ? 0.9 : 1,
                )
              : colors.surfaceContainerHigh.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(
            context.shellTheme.scaledRadius(8),
          ),
          border: accent == null
              ? Border.all(color: colors.hairlineSoft)
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: ShellText.base.copyWith(
            color: enabled
                ? (accent != null
                    ? context.shellTheme.accentPalette.onPrimary
                    : colors.textPrimary)
                : colors.textTertiary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// 月/周/日分段（`LiquidSegmentedControl`，Main.qml:1026-1037）。
class _ViewSegmented extends StatelessWidget {
  const _ViewSegmented({required this.view, required this.onChanged});

  final _CalView view;
  final void Function(_CalView) onChanged;

  static const _labels = ['月', '周', '日']; // Month/Week/Day

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(theme.scaledRadius(8)),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _labels.length; i++)
            GestureDetector(
              key: ValueKey('cal-view-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(_CalView.values[i]),
              child: Container(
                width: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _CalView.values[i] == view
                      ? theme.accentPalette.mutedContainer
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(
                    theme.scaledRadius(8),
                  ),
                ),
                child: Text(
                  _labels[i],
                  style: ShellText.base.copyWith(
                    color: _CalView.values[i] == view
                        ? theme.accentPalette.onMutedContainer
                        : colors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------- mini 月历（Main.qml:649-774）----------

class _MiniMonth extends StatelessWidget {
  const _MiniMonth({
    required this.visibleMonth,
    required this.selectedDate,
    required this.now,
    required this.onSelect,
    required this.onShiftMonth,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime now;
  final void Function(DateTime) onSelect;
  final void Function(int) onShiftMonth;

  static const _headers = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final first = DateTime(visibleMonth.year, visibleMonth.month);
    final offset = (first.weekday - 1) % 7;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _NavButton(label: '‹', onTap: () => onShiftMonth(-1)),
            Expanded(
              child: Text(
                '${visibleMonth.year}年${visibleMonth.month}月',
                textAlign: TextAlign.center,
                maxLines: 1,
                style: ShellText.base.copyWith(
                  color: colors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
            _NavButton(label: '›', onTap: () => onShiftMonth(1)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final h in _headers)
              Expanded(
                child: Text(
                  h,
                  textAlign: TextAlign.center,
                  style: ShellText.base.copyWith(
                    color: colors.textTertiary,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
        // 42 格（Repeater model 42，:710-773）。
        for (var row = 0; row < 6; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: _MiniDayCell(
                    date: DateTime(
                      visibleMonth.year,
                      visibleMonth.month,
                      row * 7 + col - offset + 1,
                    ),
                    inMonth: DateTime(
                          visibleMonth.year,
                          visibleMonth.month,
                          row * 7 + col - offset + 1,
                        ).month ==
                        visibleMonth.month,
                    selectedDate: selectedDate,
                    now: now,
                    onSelect: onSelect,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _MiniDayCell extends StatelessWidget {
  const _MiniDayCell({
    required this.date,
    required this.inMonth,
    required this.selectedDate,
    required this.now,
    required this.onSelect,
  });

  final DateTime date;
  final bool inMonth;
  final DateTime selectedDate;
  final DateTime now;
  final void Function(DateTime) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final isToday = _dayZero(date) == _dayZero(now);
    final isSelected = _dayZero(date) == _dayZero(selectedDate);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSelect(date),
      child: Center(
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // :748-754 —— today → accent 实底；selected → accent 浅底 +
            // 描边（:755-756）。
            color: isToday
                ? theme.accent
                : isSelected
                    ? theme.accentPalette.mutedContainer
                    : const Color(0x00000000),
            border: isSelected && !isToday
                ? Border.all(color: theme.accentPalette.outline)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            '${date.day}',
            style: TextStyle(
              color: isToday
                  ? theme.accentPalette.onPrimary
                  : isSelected
                      ? theme.accent
                      : colors.textPrimary,
              fontSize: 9,
              fontWeight:
                  isToday || isSelected ? FontWeight.w600 : FontWeight.w400,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 月网格（CalendarMonthView.qml:43-195）----------

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.visibleMonth,
    required this.selectedDate,
    required this.now,
    required this.itemsForDate,
    required this.colorOf,
    required this.onSelectDate,
    required this.onActivate,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime now;
  final List<_CalItem> Function(DateTime) itemsForDate;
  final Color Function(_CalItem) colorOf;
  final void Function(DateTime) onSelectDate;
  final void Function(_CalItem) onActivate;

  static const _headers = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final first = DateTime(visibleMonth.year, visibleMonth.month);
    final offset = (first.weekday - 1) % 7;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 列头行（:48-62）。
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: SizedBox(
                  height: 22,
                  child: Center(
                    child: Text(
                      _headers[i],
                      style: ShellText.base.copyWith(
                        color: colors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (var row = 0; row < 6; row++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: _MonthCell(
                    date: DateTime(
                      visibleMonth.year,
                      visibleMonth.month,
                      row * 7 + col - offset + 1,
                    ),
                    inMonth: DateTime(
                          visibleMonth.year,
                          visibleMonth.month,
                          row * 7 + col - offset + 1,
                        ).month ==
                        visibleMonth.month,
                    isSelected: _dayZero(
                          DateTime(
                            visibleMonth.year,
                            visibleMonth.month,
                            row * 7 + col - offset + 1,
                          ),
                        ) ==
                        _dayZero(selectedDate),
                    isToday: _dayZero(
                          DateTime(
                            visibleMonth.year,
                            visibleMonth.month,
                            row * 7 + col - offset + 1,
                          ),
                        ) ==
                        _dayZero(now),
                    items: itemsForDate(
                      DateTime(
                        visibleMonth.year,
                        visibleMonth.month,
                        row * 7 + col - offset + 1,
                      ),
                    ),
                    colorOf: colorOf,
                    onTap: onSelectDate,
                    onActivate: onActivate,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 月格（CalendarMonthView.qml:64-194）：24px 今日圆、≤3 chip、+N。
class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.date,
    required this.inMonth,
    required this.isSelected,
    required this.isToday,
    required this.items,
    required this.colorOf,
    required this.onTap,
    required this.onActivate,
  });

  final DateTime date;
  final bool inMonth;
  final bool isSelected;
  final bool isToday;
  final List<_CalItem> items;
  final Color Function(_CalItem) colorOf;
  final void Function(DateTime) onTap;
  final void Function(_CalItem) onActivate;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(date),
      child: Opacity(
        // :85 inVisibleMonth 外 0.42。
        opacity: inMonth ? 1 : 0.42,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54), // :80
          margin: const EdgeInsets.all(1.5),
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
          decoration: BoxDecoration(
            // :186-190 —— selected 浅 accent 底 + 描边。
            color: isSelected
                ? theme.accentPalette.subtle
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
            border:
                isSelected ? Border.all(color: theme.accentPalette.outline) : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 20,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // :100 today → accent 实底（源 `AppTheme.accent`）。
                      color: isToday
                          ? theme.accent
                          : const Color(0x00000000),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        color: isToday
                            ? theme.accentPalette.onPrimary
                            : colors.textPrimary,
                        fontSize: 10.5,
                        fontWeight: isToday || isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              // ≤3 chip +「+N」（:129-179）。
              for (final item in items.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _ItemChip(
                    item: item,
                    color: colorOf(item),
                    onTap: () {
                      onTap(date);
                      onActivate(item);
                    },
                  ),
                ),
              if (items.length > 3)
                Text(
                  '+${items.length - 3} 更多', // :175 "+%1 more"
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 9,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// chip（CalendarMonthView.qml:132-170 / ScheduleView 全日 chip
/// :184-209）：左 3px 色条 + 标题 9px、完成态 0.52 透明度 + 删除线。
class _ItemChip extends StatelessWidget {
  const _ItemChip({
    required this.item,
    required this.color,
    required this.onTap,
    this.tall = false,
  });

  final _CalItem item;
  final Color color;
  final VoidCallback onTap;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: item.completed ? 0.52 : 1, // :141/:193
        child: Container(
          height: tall ? 21 : 18, // :189/:295
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.28), // :139-140
            borderRadius: BorderRadius.circular(5), // :138 radius:5
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Container(width: 3, color: color), // :143-150 左色条
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 9,
                    height: 1.2,
                    decoration: item.completed
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 周/日时刻表（CalendarScheduleView.qml:98-338）----------

/// 简化语义：日列头 + 全日行 + 24h 行格；不画当前时刻红线（面板静态
/// 预览，`createRequested` 走双击行格 → 小时预设）。
class _ScheduleView extends StatelessWidget {
  const _ScheduleView({
    required this.firstDate,
    required this.dayCount,
    required this.now,
    required this.itemsForDate,
    required this.colorOf,
    required this.onSelectDate,
    required this.onActivate,
    required this.onCreate,
  });

  final DateTime firstDate;
  final int dayCount;
  final DateTime now;
  final List<_CalItem> Function(DateTime) itemsForDate;
  final Color Function(_CalItem) colorOf;
  final void Function(DateTime) onSelectDate;
  final void Function(_CalItem) onActivate;
  final void Function(DateTime, int) onCreate;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const double _hourHeight = 30; // 源 54 → 面板内压缩
  static const double _labelWidth = 44;

  DateTime _columnDate(int index) =>
      _dayZero(firstDate).add(Duration(days: index));

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 日列头（:101-144）。
        Row(
          children: [
            const SizedBox(width: _labelWidth),
            for (var i = 0; i < dayCount; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelectDate(_columnDate(i)),
                  child: Container(
                    height: 40,
                    color: _dayZero(_columnDate(i)) == _dayZero(now)
                        ? theme.accentPalette.subtle
                        : const Color(0x00000000),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '周${_weekdays[_columnDate(i).weekday - 1]}',
                          style: TextStyle(
                            color: colors.textTertiary,
                            fontSize: 10,
                            height: 1.2,
                          ),
                        ),
                        Text(
                          '${_columnDate(i).day}',
                          style: TextStyle(
                            color: _dayZero(_columnDate(i)) == _dayZero(now)
                                ? theme.accent
                                : colors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        Container(height: 1, color: colors.hairlineSoft),
        // 全日行（:152-214）。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _labelWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '全日', // :159 "all-day"
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 9,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < dayCount; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in itemsForDate(_columnDate(i))
                          .where((it) => it.allDay)
                          .take(2))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _ItemChip(
                            item: item,
                            color: colorOf(item),
                            onTap: () => onActivate(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Container(height: 1, color: colors.hairlineSoft),
        // 24h × dayCount 行格（:222-338）：固定高 + 内滚，保证
        // DeskPanelShell 的 shrink-wrap Column 可布局。
        SizedBox(
          height: 280,
          child: ListView.builder(
            primary: false,
            itemCount: 24,
            itemExtent: _hourHeight,
            itemBuilder: (context, hour) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Text(
                      '${hour.toString().padLeft(2, '0')}:00', // :255-257
                      style: TextStyle(
                        color: colors.textTertiary,
                        fontSize: 9,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < dayCount; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelectDate(_columnDate(i)),
                      onDoubleTap: () =>
                          onCreate(_columnDate(i), hour), // :276-279
                      child: Container(
                        decoration: BoxDecoration(
                          color:
                              _dayZero(_columnDate(i)) == _dayZero(now)
                                  ? theme.accentPalette.subtle
                                      .withValues(alpha: 0.35)
                                  : const Color(0x00000000),
                          border: Border(
                            left: BorderSide(color: colors.hairlineSoft),
                            bottom: BorderSide(color: colors.hairlineSoft),
                          ),
                        ),
                        padding: const EdgeInsets.all(2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final item
                                in itemsForDate(_columnDate(i))
                                    .where(
                                      (it) => !it.allDay && it.hour == hour,
                                    )
                                    .take(2))
                              _ItemChip(
                                item: item,
                                color: colorOf(item),
                                tall: true,
                                onTap: () => onActivate(item),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- 选中日程列表（Main.qml:1091-1227）----------

class _Agenda extends StatelessWidget {
  const _Agenda({
    required this.date,
    required this.items,
    required this.timeOf,
    required this.subtitleOf,
    required this.colorOf,
    required this.onToggle,
    required this.onActivate,
    required this.colors,
  });

  final DateTime date;
  final List<_CalItem> items;
  final String Function(_CalItem) timeOf;
  final String Function(_CalItem) subtitleOf;
  final Color Function(_CalItem) colorOf;
  final void Function(_CalItem, bool) onToggle;
  final void Function(_CalItem) onActivate;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final c = context.shellColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${date.year}年${date.month}月${date.day}日', // :1101
              style: ShellText.base.copyWith(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length} 项', // :1107 "%n item(s)"
              style: TextStyle(color: c.textTertiary, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Text(
                '这一天没有日程或到期任务', // :1123
                style: TextStyle(color: c.textTertiary, fontSize: 11.5),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 190),
            child: ListView.builder(
              primary: false,
              shrinkWrap: true,
              itemCount: items.length,
              itemExtent: 38,
              itemBuilder: (context, i) =>
                  _AgendaRow(item: items[i], agenda: this),
            ),
          ),
      ],
    );
  }
}

/// 日程行（Main.qml:1139-1226）：完成圈 + 色条 + 时间 + 标题/副标题 +
/// 类型标签。
class _AgendaRow extends StatelessWidget {
  const _AgendaRow({required this.item, required this.agenda});

  final _CalItem item;
  final _Agenda agenda;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final color = agenda.colorOf(item);
    final todoId = item.todoId;
    // 逾期：未完成 todo 且 due 日 < 今日（语义色 performanceBad）。
    final overdue = item.isTodo &&
        !item.completed &&
        (_parseEncoded(item.todo!.due)?.isBefore(_dayZero(DateTime.now())) ??
            false);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => agenda.onActivate(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // 完成钮（:1148-1185）：仅 todo 关联条目显示。
            SizedBox(
              width: 24,
              child: todoId.isEmpty
                  ? null
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => agenda.onToggle(item, !item.completed),
                      child: Center(
                        child: Container(
                          width: 17,
                          height: 17,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: item.completed
                                ? color
                                : const Color(0x00000000),
                            border: Border.all(color: color),
                          ),
                          child: item.completed
                              ? Center(
                                  child: Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
            ),
            Container(
              width: 4,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              child: Text(
                agenda.timeOf(item),
                style: TextStyle(
                  color: overdue
                      ? colors.performanceBad
                      : colors.textTertiary,
                  fontSize: 11,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item.completed
                          ? colors.textTertiary
                          : colors.textPrimary,
                      fontSize: 12.5,
                      height: 1.2,
                      decoration: item.completed
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                  ),
                  Text(
                    agenda.subtitleOf(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 10,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              // :1217-1220 —— TASK / EVENT + TASK / EVENT。
              item.isTodo
                  ? '任务'
                  : todoId.isNotEmpty
                      ? '日程+任务'
                      : '日程',
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 行内编辑器（EventEditorDialog / CalendarTaskEditorDialog）----------

/// 编辑器请求：新建/编辑事件或编辑待办。
final class _EditorRequest {
  const _EditorRequest._({
    this.event,
    this.todo,
    this.newDate,
    this.newHour,
  });

  factory _EditorRequest.event(PimEvent e) => _EditorRequest._(event: e);
  factory _EditorRequest.todo(PimTodo t) => _EditorRequest._(todo: t);
  factory _EditorRequest.newEvent(DateTime day, {int? hour}) =>
      _EditorRequest._(newDate: day, newHour: hour);

  final PimEvent? event;
  final PimTodo? todo;
  final DateTime? newDate;
  final int? newHour;
}

class _EditorHost extends StatelessWidget {
  const _EditorHost({
    required this.request,
    required this.store,
    required this.onClose,
  });

  final _EditorRequest request;
  final PimStore? store;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(theme.scaledRadius(10)),
        border: Border.all(color: colors.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: request.todo != null
          ? _TodoEditor(
              key: ValueKey('todo-${request.todo!.id}'),
              todo: request.todo!,
              store: store,
              onClose: onClose,
            )
          : _EventEditor(
              key: ValueKey('event-${request.event?.id ?? 'new'}'),
              event: request.event,
              newDate: request.newDate,
              newHour: request.newHour,
              store: store,
              onClose: onClose,
            ),
    );
  }
}

/// 表单共用：标签 + 文本框（`LiquidTextField` → widgets `EditableText`
/// 风格容器；无 Material 祖先故用手绘框 + `EditableText`）。
class _FormField extends StatelessWidget {
  const _FormField({
    required this.label,
    required this.controller,
    this.placeholder = '',
    this.width,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String placeholder;
  final double? width;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final field = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: EditableText(
        controller: controller,
        focusNode: FocusNode(),
        maxLines: maxLines,
        style: ShellText.base.copyWith(
          color: colors.textPrimary,
          fontSize: 12,
          height: 1.3,
        ),
        cursorColor: theme.accent,
        backgroundCursorColor: colors.hairline,
        selectionColor: theme.accentPalette.selection,
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textTertiary,
            fontSize: 10.5,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 3),
        field,
      ],
    );
  }
}

/// checkbox（`CheckBox`/`SidebarToggle` 的简化：圆点 + 标签）。
class _Check extends StatelessWidget {
  const _Check({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: value
                  ? theme.accent
                  : const Color(0x00000000),
              border: Border.all(
                color: value ? theme.accent : colors.hairline,
              ),
            ),
            child: value
                ? Center(
                    child: Text(
                      '✓',
                      style: TextStyle(
                        color: theme.accentPalette.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 11.5,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 下拉选择（`ComboBox` 等价：行内 chips 循环选择——面板内避免
/// Overlay 依赖，单击循环到下一项）。
class _CycleChoice<T> extends StatelessWidget {
  const _CycleChoice({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<(T, String)> options;
  final T value;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final index = options.indexWhere((o) => o.$1 == value);
    final current = index >= 0 ? options[index].$2 : options.first.$2;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textTertiary,
            fontSize: 10.5,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 3),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final next = options[(index + 1) % options.length].$1;
            onChanged(next);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
              border: Border.all(color: colors.hairlineSoft),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '▾',
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 9,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// `yyyy-MM-dd` / `HH:mm` 文本校验。
DateTime? _parseDateText(String text) {
  final t = text.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) return null;
  return DateTime.tryParse(t);
}

(int, int)? _parseTimeText(String text) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return (h, min);
}

/// 重复预设选项（EventEditorDialog.qml:137 + :322-323）。
const _kRecurrenceOptions = <(String, String)>[
  ('none', '不重复'),
  ('daily', '每天'),
  ('weekly', '每周'),
  ('monthly', '每月'),
  ('yearly', '每年'),
];

/// 提醒选项（EventEditorDialog.qml:138 + :333-336）。
const _kReminderOptions = <(int, String)>[
  (-1, '无'),
  (0, '开始时'),
  (5, '提前 5 分钟'),
  (15, '提前 15 分钟'),
  (30, '提前 30 分钟'),
  (60, '提前 1 小时'),
  (1440, '提前 1 天'),
];

/// 优先级选项（priorityValues [0,9,5,1] ↔ None/Low/Medium/High，
/// EventEditorDialog.qml:139 / CalendarTaskEditorDialog.qml:71）。
const _kPriorityOptions = <(int, String)>[
  (0, '无'),
  (9, '低'),
  (5, '中'),
  (1, '高'),
];

/// 事件编辑器（`EventEditorDialog` 全字段：标题/全日/起止/地点/
/// 关联待办/重复/提醒/备注/删除）。
class _EventEditor extends StatefulWidget {
  const _EventEditor({
    required this.event,
    required this.newDate,
    required this.newHour,
    required this.store,
    required this.onClose,
    super.key,
  });

  /// null → 新建（`openForDate`）；非 null → 编辑（`openForEvent`）。
  final PimEvent? event;
  final DateTime? newDate;
  final int? newHour;
  final PimStore? store;
  final VoidCallback onClose;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late final TextEditingController _startDate;
  late final TextEditingController _startTime;
  late final TextEditingController _endDate;
  late final TextEditingController _endTime;
  late bool _allDay;
  late String _recurrence;
  late int _reminder;
  late bool _linkTodo;
  late String _todoListId;
  late int _todoPriority;
  String _error = '';

  bool get _editing => widget.event != null;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    // `openForDate`（:91-111）/ `openForEvent`（:113-134）初值。
    final baseDate = e == null
        ? (widget.newDate ?? _dayZero(DateTime.now()))
        : (_parseEncoded(e.start) ?? _dayZero(DateTime.now()));
    final startHour = e == null
        ? (widget.newHour ?? 9).clamp(0, 22)
        : (_parseEncoded(e.start)?.hour ?? 9);
    _title = TextEditingController(text: e?.title ?? '');
    _location = TextEditingController(text: e?.location ?? '');
    _notes = TextEditingController(text: e?.description ?? '');
    _startDate = TextEditingController(text: _dateKey(baseDate));
    _endDate = TextEditingController(
      text: e == null
          ? _dateKey(baseDate)
          : _dateKey(_parseEncoded(e.end) ?? baseDate),
    );
    _startTime = TextEditingController(
      text: '${startHour.toString().padLeft(2, '0')}:00',
    );
    _endTime = TextEditingController(
      text: e == null
          ? '${(startHour + 1).toString().padLeft(2, '0')}:00'
          : _timePart(e.end, '10:00'),
    );
    _allDay = e?.allDay ?? false;
    _recurrence = switch (e?.recurrence) {
      'daily' || 'weekly' || 'monthly' || 'yearly' => e!.recurrence,
      _ => 'none',
    };
    _reminder = _kReminderOptions.any((o) => o.$1 == e?.reminderMinutes)
        ? e!.reminderMinutes
        : -1;
    _linkTodo = (e?.linkedTodoId ?? '').isNotEmpty;
    _todoListId = e?.linkedTodoListId ?? 'personal';
    _todoPriority = e?.linkedTodoPriority ?? 0;
  }

  static String _timePart(String encoded, String fallback) {
    final m = RegExp(r'T(\d{2}:\d{2})').firstMatch(encoded);
    return m?.group(1) ?? fallback; // `isoTimePart`（:51-54）
  }

  @override
  void dispose() {
    for (final c in [
      _title, _location, _notes, _startDate, _startTime, _endDate, _endTime,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final store = widget.store;
    if (store == null) return;
    final title = _title.text.trim();
    final startDay = _parseDateText(_startDate.text);
    final endDay = _parseDateText(_endDate.text);
    if (title.isEmpty || startDay == null || endDay == null) {
      setState(() => _error = '标题必填；日期格式 YYYY-MM-DD'); // :904-906/:913-915
      return;
    }
    DateTime start;
    DateTime end;
    if (_allDay) {
      start = startDay;
      end = endDay;
    } else {
      final st = _parseTimeText(_startTime.text);
      final et = _parseTimeText(_endTime.text);
      if (st == null || et == null) {
        setState(() => _error = '时间格式 HH:MM');
        return;
      }
      start = DateTime(startDay.year, startDay.month, startDay.day,
          st.$1, st.$2);
      end = DateTime(endDay.year, endDay.month, endDay.day, et.$1, et.$2);
    }
    if (!end.isAfter(start)) {
      setState(() => _error = '结束必须晚于开始'); // :918-920/:1010-1012
      return;
    }
    // `eventPayload`（:136-158）→ createEvent/updateEvent。
    final ok = _editing
        ? await store.updateEvent(
            widget.event!.id,
            title: title,
            description: _notes.text,
            location: _location.text,
            start: start,
            end: end,
            allDay: _allDay,
            recurrence: _recurrence,
            reminderMinutes: _reminder,
            linkedTodo: _linkTodo,
            todoListId: _todoListId,
            todoPriority: _todoPriority,
          )
        : (await store.addEvent(
            title: title,
            description: _notes.text,
            location: _location.text,
            start: start,
            end: end,
            allDay: _allDay,
            recurrence: _recurrence,
            reminderMinutes: _reminder,
            linkedTodo: _linkTodo,
            todoListId: _todoListId,
            todoPriority: _todoPriority,
          )) !=
            null;
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = '写入失败（存储只读或清单无效）');
      return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final lists = widget.store?.lists ?? const <PimList>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _editing ? '编辑日程' : '新建日程', // :20
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        _FormField(label: '标题', controller: _title, placeholder: '日程标题'),
        const SizedBox(height: 8),
        Row(
          children: [
            _Check(
              label: '全日', // :186 "All day"
              value: _allDay,
              onChanged: (v) => setState(() {
                _allDay = v;
                // :188-192 —— 勾全日且 end==start 时 end 推一日；
                // 取消且 end==start+1 时收回同日。
                final sd = _parseDateText(_startDate.text);
                final ed = _parseDateText(_endDate.text);
                if (sd == null || ed == null) return;
                if (v && ed == sd) {
                  _endDate.text =
                      _dateKey(sd.add(const Duration(days: 1)));
                } else if (!v &&
                    ed == sd.add(const Duration(days: 1))) {
                  _endDate.text = _dateKey(sd);
                }
              }),
            ),
            const Spacer(),
            Text(
              'YYYY-MM-DD · 24 小时制', // :199
              style: TextStyle(color: colors.textTertiary, fontSize: 10),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _FormField(label: '开始', controller: _startDate),
            ),
            const SizedBox(width: 8),
            if (!_allDay)
              _FormField(label: '', controller: _startTime, width: 72),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: _FormField(label: '结束', controller: _endDate)),
            const SizedBox(width: 8),
            if (!_allDay)
              _FormField(label: '', controller: _endTime, width: 72),
          ],
        ),
        const SizedBox(height: 8),
        _FormField(
          label: '地点',
          controller: _location,
          placeholder: '可选地点',
        ),
        const SizedBox(height: 8),
        // 关联待办块（:250-311）。
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.accentPalette.subtle,
            borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
            border: Border.all(color: theme.accentPalette.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Check(
                label: '同时在待办中显示为任务', // :266
                value: _linkTodo,
                onChanged: (v) => setState(() => _linkTodo = v),
              ),
              const SizedBox(height: 4),
              Text(
                // :273-279 —— 已有关联且取消勾选 → 警告文案。
                (widget.event?.linkedTodoId ?? '').isNotEmpty && !_linkTodo
                    ? '保存将解除关联，但任务保留在待办中。'
                    : '标题与日期的修改会同步到两个应用。',
                style: TextStyle(
                  color: (widget.event?.linkedTodoId ?? '').isNotEmpty &&
                          !_linkTodo
                      ? colors.performanceWarning
                      : colors.textTertiary,
                  fontSize: 10.5,
                  height: 1.3,
                ),
              ),
              if (_linkTodo) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _CycleChoice<String>(
                        label: '待办清单',
                        options: [
                          for (final l in lists) (l.id, l.name),
                          if (lists.isEmpty) ('inbox', 'Inbox'),
                        ],
                        value: _todoListId,
                        onChanged: (v) => setState(() => _todoListId = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _CycleChoice<int>(
                        label: '优先级',
                        options: _kPriorityOptions,
                        value: _todoPriority,
                        onChanged: (v) => setState(() => _todoPriority = v),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CycleChoice<String>(
                label: '重复', // :318
                options: _kRecurrenceOptions,
                value: _recurrence,
                onChanged: (v) => setState(() => _recurrence = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CycleChoice<int>(
                label: '提醒', // :330
                options: _kReminderOptions,
                value: _reminder,
                onChanged: (v) => setState(() => _reminder = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _FormField(label: '备注', controller: _notes, maxLines: 3),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _error,
            style: TextStyle(
              color: colors.performanceBad,
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (_editing)
              _ActionButton(
                label: '删除日程', // :357
                color: colors.performanceBad,
                onTap: () async {
                  await widget.store?.removeEvent(widget.event!.id);
                  widget.onClose();
                },
              ),
            const Spacer(),
            _ActionButton(
              label: '取消',
              color: colors.textSecondary,
              onTap: widget.onClose,
            ),
            const SizedBox(width: 8),
            _ActionButton(
              key: const ValueKey('cal-editor-save'),
              label: '保存',
              color: theme.accent,
              filled: true,
              onTap: _save,
            ),
          ],
        ),
      ],
    );
  }
}

/// 待办编辑器（`CalendarTaskEditorDialog` 子集：title/completed/list/
/// priority/due/notes + 删除）。
class _TodoEditor extends StatefulWidget {
  const _TodoEditor({
    required this.todo,
    required this.store,
    required this.onClose,
    super.key,
  });

  final PimTodo todo;
  final PimStore? store;
  final VoidCallback onClose;

  @override
  State<_TodoEditor> createState() => _TodoEditorState();
}

class _TodoEditorState extends State<_TodoEditor> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late final TextEditingController _dueDate;
  late final TextEditingController _dueTime;
  late bool _completed;
  late bool _allDay;
  late String _listId;
  late int _priority;
  String _error = '';

  String get _linkedEventId => widget.todo.linkedEventId ?? '';

  @override
  void initState() {
    super.initState();
    final t = widget.todo;
    // `openForTodo`（CalendarTaskEditorDialog.qml:53-68）。
    _title = TextEditingController(text: t.title);
    _notes = TextEditingController(text: t.description);
    _completed = t.completed;
    _listId = t.listId;
    _priority = t.priority;
    _allDay = t.allDay;
    final due = _parseEncoded(t.due);
    _dueDate = TextEditingController(
      text: due == null ? '' : _dateKey(due),
    );
    _dueTime = TextEditingController(
      text: _dueTimePart(t.due) ?? '18:00', // :62-63 缺省 18:00
    );
  }

  static String? _dueTimePart(String encoded) {
    final m = RegExp(r'T(\d{2}:\d{2})').firstMatch(encoded);
    return m?.group(1);
  }

  @override
  void dispose() {
    for (final c in [_title, _notes, _dueDate, _dueTime]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final store = widget.store;
    if (store == null) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题必填');
      return;
    }
    DateTime? due;
    final dueDay = _parseDateText(_dueDate.text);
    if (dueDay != null) {
      if (_allDay) {
        due = dueDay;
      } else {
        final t = _parseTimeText(_dueTime.text);
        if (t == null) {
          setState(() => _error = '时间格式 HH:MM');
          return;
        }
        due = DateTime(dueDay.year, dueDay.month, dueDay.day, t.$1, t.$2);
      }
    }
    if (_linkedEventId.isNotEmpty && due == null) {
      // :338-340 + :190-191 —— linked todo 必须保留 due。
      setState(() => _error = '关联日程的任务必须保留截止日期');
      return;
    }
    // `payload`（CalendarTaskEditorDialog.qml:70-85）→ updateTodo。
    final ok = await store.updateTodo(
      // :54 editingId = seriesId/id 回退已在 _CalItem.todoId 做过；
      // 这里 todo 记录即原始 series（PimTodo.id == uid）。
      widget.todo.seriesId.isNotEmpty
          ? widget.todo.seriesId
          : widget.todo.id,
      title: title,
      description: _notes.text,
      listId: _listId,
      due: due,
      clearDue: due == null,
      allDay: _allDay,
      priority: _priority,
      completed: _completed,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = '写入失败（存储只读或清单无效）');
      return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final lists = widget.store?.lists ?? const <PimList>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '编辑任务', // :18 "Edit task"
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        if (_linkedEventId.isNotEmpty) ...[
          const SizedBox(height: 6),
          // 关联事件提示块（CalendarTaskEditorDialog.qml:96-114）。
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: theme.accentPalette.subtle,
              borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
              border: Border.all(color: theme.accentPalette.outline),
            ),
            child: Text(
              '此任务关联着日程；修改标题或日期会同步更新日程。',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 10.5,
                height: 1.3,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _FormField(
                label: '标题',
                controller: _title,
                placeholder: '任务标题',
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _Check(
                label: '完成', // :132 "Completed"
                value: _completed,
                onChanged: (v) => setState(() => _completed = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CycleChoice<String>(
                label: '清单', // :142
                options: [
                  for (final l in lists) (l.id, l.name),
                  if (lists.isEmpty) ('inbox', 'Inbox'),
                ],
                value: _listId,
                onChanged: (v) => setState(() => _listId = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CycleChoice<int>(
                label: '优先级',
                options: _kPriorityOptions,
                value: _priority,
                onChanged: (v) => setState(() => _priority = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _FormField(
                label: '截止', // :162 "Due date"
                controller: _dueDate,
                placeholder: 'YYYY-MM-DD',
              ),
            ),
            const SizedBox(width: 8),
            if (!_allDay)
              _FormField(label: '', controller: _dueTime, width: 72),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _Check(
                label: '全日',
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          // :189-191 —— linked → 必须保 due；否则无 due 不上日历。
          _linkedEventId.isNotEmpty
              ? '关联日程的任务必须保留截止日期（它决定日程时间）。'
              : '没有截止日期的任务不会出现在日历中。',
          style: TextStyle(color: colors.textTertiary, fontSize: 10),
        ),
        const SizedBox(height: 8),
        _FormField(label: '备注', controller: _notes, maxLines: 3),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _error,
            style: TextStyle(
              color: colors.performanceBad,
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            _ActionButton(
              label: '删除任务', // :210
              color: colors.performanceBad,
              onTap: () async {
                final uid = widget.todo.seriesId.isNotEmpty
                    ? widget.todo.seriesId
                    : widget.todo.id;
                await widget.store?.removeTodo(uid);
                widget.onClose();
              },
            ),
            const Spacer(),
            _ActionButton(
              label: '取消',
              color: colors.textSecondary,
              onTap: widget.onClose,
            ),
            const SizedBox(width: 8),
            _ActionButton(
              key: const ValueKey('cal-todo-save'),
              label: '保存',
              color: theme.accent,
              filled: true,
              onTap: _save,
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.onTap,
    this.filled = false,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: filled ? color : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(theme.scaledRadius(7)),
          border: filled ? null : Border.all(color: colors.hairlineSoft),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? theme.accentPalette.onPrimary : color,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
