/// 插件内嵌 PIM 存储（TASK-11）：解析/写回
/// `$XDG_DATA_HOME/kos/pim/{calendar.ics,metadata.json}` 并生产
/// `widget-snapshot.json`。
///
/// 事实来源（NextKde 仓库，行号均指 `services/pim-service/src/PimStore.cpp`）：
/// - 存储目录：`KOS_PIM_STORAGE_DIR` 覆盖，否则
///   `$XDG_DATA_HOME || $HOME/.local/share` + `/kos/pim`（:49-56）；
/// - 默认清单 `inbox`(#4f8cff,不可删)/`personal`(#39c487)（:133-149），
///   `inbox` 缺失时补到首位（:572-573）；
/// - metadata.json：`{schemaVersion:1,revision,lists}`（:540-546）；
/// - widget-snapshot.json：`{schemaVersion:1,revision,generatedAt(ms),
///   today,events[<=16],todos[<=16]}`（:725-796）：事件 = 今日 00:00 起
///   8 天窗口 occurrence（:737-750），待办 = 未完成按 order+summary
///   排序（:752-775）；
/// - 事件字段：`eventObject`（:362-398）；待办字段：`todoObject`
///   （:400-424）与 `todoOccurrenceObject`（:426-441）；全量排序见
///   `snapshot()`（:798-846）。
///
/// 写侧（TASK-13 扩展）：`setTodoCompleted`/`addTodo`/`createList`/
/// `removeTodo`/`removeEvent` 之上补 `addEvent`/`updateEvent`（全字段 +
/// linkedTodo 同步）与 `updateTodo`（日历侧编辑子集），语义对齐
/// `PimStore.cpp` 的 createEvent(:891-965)/updateEvent(:967-1083)/
/// removeEvent(:1085-1118)/updateTodo(:1176-1274)；`removeEvent` 升级为
/// 源端完整语义（删除前把 linked todo 解链保留）。
///
/// 共存语义：解析 `calendar.ics` 失败 → `writable=false`、保留内存态、
/// 不落坏盘（对齐 :578-581）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../widget_snapshot_watcher.dart';
import 'ical_parser.dart';
import 'rrule.dart';

/// 待办优先级档位（`TodoEditorDialog.qml:106` `priorityValues = [0,9,5,1]`
/// ↔ `model: [None, Low, Medium, High]`（:184））。任务卡验收文本把
/// 配对写成 `None/High/Medium/Low` 是笔误，以源端为准。
enum PimPriorityLevel {
  /// 0 —— 未指定。
  none,

  /// 9 —— 低（KCalendarCore 语义：1 最高、9 最低，0 = 未指定，
  /// schema 行 120）。
  low,

  /// 5 —— 中。
  medium,

  /// 1 —— 高。
  high,
}

/// 0-9 原始值 → 档位（`priorityIndex`，TodoEditorDialog.qml:54-61：
/// `<=0→None，<=3→High，<=6→Medium，else→Low`）。
PimPriorityLevel pimPriorityLevelOf(int priority) {
  if (priority <= 0) return PimPriorityLevel.none;
  if (priority <= 3) return PimPriorityLevel.high;
  if (priority <= 6) return PimPriorityLevel.medium;
  return PimPriorityLevel.low;
}

/// 档位 → 写回用的规范原始值（`priorityValues[priorityBox.currentIndex]`
/// ：None→0、Low→9、Medium→5、High→1）。
int pimPriorityValueOf(PimPriorityLevel level) => switch (level) {
  PimPriorityLevel.none => 0,
  PimPriorityLevel.low => 9,
  PimPriorityLevel.medium => 5,
  PimPriorityLevel.high => 1,
};

/// 清单条目（`$defs.list`，pim-v1.schema.json:40-50）。
final class PimList {
  const PimList({
    required this.id,
    required this.name,
    required this.color,
    required this.position,
  });

  final String id;
  final String name;
  final String color;
  final int position;

  PimList copyWith({String? name, String? color, int? position}) => PimList(
    id: id,
    name: name ?? this.name,
    color: color ?? this.color,
    position: position ?? this.position,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'position': position,
  };

  static PimList fromJson(Map<String, Object?> json) => PimList(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    color: json['color']?.toString() ?? '',
    position: switch (json['position']) {
      final int v => v,
      final num v => v.toInt(),
      _ => 0,
    },
  );
}

/// 默认清单（`defaultLists()`，PimStore.cpp:133-149）。
List<PimList> defaultPimLists() => const [
  PimList(id: 'inbox', name: 'Inbox', color: '#4f8cff', position: 0),
  PimList(id: 'personal', name: 'Personal', color: '#39c487', position: 1),
];

/// `PimStore` 变更通知的负载（对齐 `changed(revision)`，:962）。
typedef PimStoreRevision = int;

/// 插件内嵌 PIM 存储：内存模型 + 原子写回 + widget-snapshot 生产。
///
/// PIM 存储 IO 注入点（`calendar.ics`/`metadata.json`/`widget-snapshot.json`
/// 的读写与变更监听）。默认 [FilePimStorage]（真实 `dart:io`）；widget 测试
/// 注入 [MemoryPimStorage]——`testWidgets` 的 fake-async 区不驱动真实文件
/// IO，await 会永不完成。
abstract interface class PimStorage {
  /// 读文本；缺失/不可读返回 null。
  Future<String?> readString(String path);

  /// 路径是否存在。
  Future<bool> exists(String path);

  /// 原子写（实现须 `tmp + rename` 语义；失败自行吞掉）。
  Future<void> writeStringAtomic(String path, String contents);

  /// 确保目录存在（递归；失败自行吞掉）。
  Future<void> ensureDirectory(String path);

  /// 路径变更流（路径不存在时静默空流；error 已吞）。
  Stream<void> watch(String path);
}

/// `dart:io` 实现（生产路径）。
final class FilePimStorage implements PimStorage {
  const FilePimStorage();

  @override
  Future<String?> readString(String path) async {
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async {
    try {
      return await File(path).exists();
    } on Object {
      return false;
    }
  }

  @override
  Future<void> writeStringAtomic(String path, String contents) async {
    try {
      final tmp = File('$path.tmp');
      await tmp.writeAsString(contents, flush: true);
      await tmp.rename(path);
    } on Object {
      // 落盘失败不阻断内存态（对齐源端 write 失败仅告警）。
    }
  }

  @override
  Future<void> ensureDirectory(String path) async {
    try {
      await Directory(path).create(recursive: true);
    } on Object {
      // 同上。
    }
  }

  @override
  Stream<void> watch(String path) => File(path).watch().map((_) {}).handleError(
    (_) {},
  );
}

/// 内存实现（测试/预览）：不触盘，`watch` 返回静默流。
final class MemoryPimStorage implements PimStorage {
  final Map<String, String> files = <String, String>{};

  /// `watch` 返回的静默流后端：永不自关闭的广播控制器。
  ///
  /// 不能用 `const Stream<void>.empty()`——在 Denial 引擎的 widget 测试
  /// fake-async 区里，取消一个已完成的 `Stream.empty()` 订阅会毒化后续
  /// microtask flush（`Store.dispose()` 后 `await tester.pump()` 永久挂起）。
  /// 广播流取消订阅不会触发该路径。
  final StreamController<void> _idleWatch = StreamController<void>.broadcast();

  @override
  Future<String?> readString(String path) async => files[path];

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> writeStringAtomic(String path, String contents) async {
    files[path] = contents;
  }

  @override
  Future<void> ensureDirectory(String path) async {}

  @override
  Stream<void> watch(String path) => _idleWatch.stream;
}

/// 用法：`await store.load()` 后订阅 [changes]；写方法自动
/// `scheduleSave`（150ms 防抖，对齐 :497-515）并在落盘成功后
/// `writeWidgetSnapshot`（:608-613）。
final class PimStore {
  PimStore({String? storageDirectory, PimStorage? storage})
    : storageDirectory = storageDirectory ?? _defaultDirectory(),
      _storage = storage ?? const FilePimStorage();

  /// 存储目录（构造注入便于测试；默认走 env，对齐 :49-56）。
  final String storageDirectory;

  /// IO 注入点：默认 [FilePimStorage]（真实 `dart:io`）；widget 测试用
  /// [MemoryPimStorage]（`testWidgets` 的 fake-async 区不驱动真实文件 IO，
  /// 注入内存实现才能await 完成）。
  final PimStorage _storage;

  /// 消费端路径推导（PimWidgetService.qml:10-14 + PimStore.cpp:49-56）。
  static String _defaultDirectory() {
    final env = Platform.environment;
    final configured = env['KOS_PIM_STORAGE_DIR'];
    if (configured != null && configured.isNotEmpty) return configured;
    final dataHome =
        env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? ''}/.local/share';
    return '$dataHome/kos/pim';
  }

  String get calendarPath => '$storageDirectory/calendar.ics';
  String get metadataPath => '$storageDirectory/metadata.json';
  String get snapshotPath => '$storageDirectory/widget-snapshot.json';

  // ---------- 内存模型 ----------

  final List<IcalEvent> _events = [];
  final List<IcalTodo> _todos = [];
  List<PimList> _lists = defaultPimLists();
  int _revision = 0;
  bool _writable = true;
  String _storageError = '';
  bool _dirty = false;
  bool _loaded = false;
  Timer? _saveTimer;

  /// 变更防抖（`saveDebounceMs`，PimStore.cpp:502）。
  static const Duration _saveDebounce = Duration(milliseconds: 150);

  /// widget 快照 5 分钟周期刷新（:623-627）。
  static const Duration _snapshotInterval = Duration(minutes: 5);
  Timer? _snapshotTimer;

  /// 日历文件变化监听（与 NextKde 共存：外部改动重载）。
  StreamSubscription<void>? _watch;
  Timer? _reloadDebounce;

  /// 每个本 store 实例的 uid 计数（`QUuid::createUuid` 等价物——
  /// Dart 无 uuid 依赖，用时间戳+计数+随机后缀，与源端一样只要求唯一）。
  int _uidCounter = 0;

  static final _rng = _UidRandom();

  final StreamController<int> _changes = StreamController<int>.broadcast();

  /// 变更流：每次成功 mutation 推送递增后的 revision（`changed` 信号）。
  Stream<int> get changes => _changes.stream;

  /// 当前修订号（`metadata.json` 的 `revision` 回读，:562-563）。
  int get revision => _revision;

  /// `calendar.ics` 解析是否成功（失败=false，对齐 `writable`，:580-581）。
  bool get writable => _writable;

  /// 解析失败原因（`storageError`，:590）。
  String get storageError => _storageError;

  /// 清单（含默认补建的 inbox/personal）。
  List<PimList> get lists => List.unmodifiable(_lists);

  /// 原始事件/待办（序列级，非 occurrence）。
  List<IcalEvent> get rawEvents => List.unmodifiable(_events);
  List<IcalTodo> get rawTodos => List.unmodifiable(_todos);

  bool _disposed = false;

  // ---------- 加载 ----------

  /// 加载 `metadata.json` + `calendar.ics`；重复调用重新读盘（供 watcher）。
  ///
  /// 对齐 `Private::load`（:549-582）：lists 缺失/损坏 → 默认；
  /// `inbox` 缺失 → 补到首位；calendar.ics 缺失 → 空日历可写；
  /// 解析失败 → `writable=false`、保留既有内存模型不落盘。
  Future<void> load() async {
    _loaded = true;
    await _loadMetadata();
    await _loadCalendar();
    _startWatch();
    _startSnapshotTimer();
    // 对齐构造后 `singleShot(0, writeWidgetSnapshot)`（:621）：启动即产出。
    unawaited(writeWidgetSnapshot());
  }

  Future<void> _loadMetadata() async {
    var lists = defaultPimLists();
    try {
      final text = await _storage.readString(metadataPath);
      final decoded = text == null ? null : jsonDecode(text);
      if (decoded is Map &&
          decoded['schemaVersion'] == 1) {
        _revision = switch (decoded['revision']) {
          final int v => v,
          final num v => v.toInt(),
          _ => 0,
        };
        final loaded = <PimList>[
          if (decoded['lists'] is List)
            for (final item in decoded['lists'] as List)
              if (item is Map)
                PimList.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v)),
                ),
        ];
        if (loaded.isNotEmpty) lists = loaded;
      }
    } on Object {
      // 缺失/损坏 → 默认 lists（:552-571 容错链）。
    }
    _lists = lists;
    // inbox 缺失补到首位（:572-573）。
    if (!_lists.any((l) => l.id == 'inbox')) {
      _lists = [defaultPimLists().first, ..._lists];
    }
  }

  Future<void> _loadCalendar() async {
    if (!await _storage.exists(calendarPath)) return;
    try {
      final text = await _storage.readString(calendarPath);
      final doc = IcalParser.parse(text ?? '');
      _events
        ..clear()
        ..addAll(doc.events);
      _todos
        ..clear()
        ..addAll(doc.todos);
      _writable = true;
      _storageError = '';
    } on Object {
      // 解析失败：保留内存态，标记只读不落坏盘（:578-581）。
      _writable = false;
      _storageError = 'Unable to load the existing iCalendar file';
    }
  }

  void _startWatch() {
    _watch ??= () {
      return _storage.watch(calendarPath).listen(
        (_) {
          _reloadDebounce?.cancel();
          _reloadDebounce = Timer(const Duration(milliseconds: 180), () async {
            await _loadCalendar();
            await writeWidgetSnapshot();
            if (!_changes.isClosed) _changes.add(_revision);
          });
        },
        onError: (_) {},
      );
    }();
  }

  void _startSnapshotTimer() {
    _snapshotTimer ??= Timer.periodic(
      _snapshotInterval,
      (_) => unawaited(writeWidgetSnapshot()),
    );
  }

  // ---------- 查询 ----------

  bool hasList(String id) => _lists.any((l) => l.id == id);

  IcalTodo? todoById(String uid) {
    for (final t in _todos) {
      if (t.uid == uid) return t;
    }
    return null;
  }

  IcalEvent? eventById(String uid) {
    for (final e in _events) {
      if (e.uid == uid) return e;
    }
    return null;
  }

  /// event uid → 反链 todo uid（`todoIdsByLinkedEvent`，:244-256）。
  Map<String, String> _todoIdsByLinkedEvent() {
    final result = <String, String>{};
    for (final todo in _todos) {
      final eventId = todo.linkedEventId;
      if (eventId.isNotEmpty && !result.containsKey(eventId)) {
        result[eventId] = todo.uid;
      }
    }
    return result;
  }

  /// `linkedTodoId`（:258-271）：事件显式 `X-KOS-LINKED-TODO-ID` 有效则
  /// 用之，否则反查 todo 侧 `linkedEventId`/`RELATED-TO`。
  String _linkedTodoIdFor(IcalEvent event, Map<String, String> byEvent) {
    final custom = event.linkedTodoId;
    if (custom.isNotEmpty && todoById(custom) != null) return custom;
    return byEvent[event.uid] ?? custom;
  }

  /// `recurrencePreset`（:151-157）。
  String _presetOf(String preset, String rrule) =>
      preset.isNotEmpty ? preset : (rrule.isNotEmpty ? 'custom' : 'none');

  /// 日期时间编码（`encodeDateTime`，:128-131）：ISO 毫秒，无时区后缀
  /// （本地时刻 + `timeZone` 字段独立携带 zone id）。
  static String encodeDateTime(DateTime? value) {
    if (value == null) return '';
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-${p2(value.month)}-'
        '${p2(value.day)}T${p2(value.hour)}:${p2(value.minute)}:'
        '${p2(value.second)}.${value.millisecond.toString().padLeft(3, '0')}';
  }

  /// `eventObject`（:362-398）→ [PimEvent]。
  PimEvent _eventObject(
    IcalEvent event, {
    DateTime? occurrenceStart,
    DateTime? occurrenceEnd,
    DateTime? recurrenceId,
    Map<String, String>? todoByEvent,
  }) {
    final byEvent = todoByEvent ?? _todoIdsByLinkedEvent();
    final start = occurrenceStart ?? event.start;
    final end = occurrenceEnd ?? event.end;
    final todoId = _linkedTodoIdFor(event, byEvent);
    final linkedTodo = todoId.isEmpty ? null : todoById(todoId);
    return PimEvent(
      id: event.uid,
      seriesId: event.uid,
      title: event.summary,
      description: event.description,
      location: event.location,
      start: encodeDateTime(start),
      end: encodeDateTime(end),
      allDay: event.allDay,
      timeZone: event.timeZone,
      calendarId:
          event.calendarId.isEmpty ? 'personal' : event.calendarId,
      recurrence: _presetOf(event.recurrencePreset, event.rrule),
      recurrenceId: encodeDateTime(recurrenceId),
      reminderMinutes: event.reminderMinutes,
      linkedTodoId: todoId.isEmpty ? null : todoId,
      linkedTodoCompleted: linkedTodo?.completed ?? false,
      linkedTodoListId: linkedTodo == null
          ? null
          : (linkedTodo.listId.isEmpty ? 'inbox' : linkedTodo.listId),
      linkedTodoPriority: linkedTodo?.priority ?? 0,
      // KCalendarCore lastModified 由库维护；本端无等价物，写空串
      // （schema 允许空串，消费端不依赖）。
      modifiedAt: '',
    );
  }

  /// `todoObject`（:400-424）→ [PimTodo]。
  PimTodo _todoObject(IcalTodo todo) => PimTodo(
    id: todo.uid,
    title: todo.summary,
    description: todo.description,
    listId: todo.listId.isEmpty ? 'inbox' : todo.listId,
    parentId: todo.parentId,
    order: todo.order,
    start: todo.start == null ? '' : encodeDateTime(todo.start),
    due: todo.due == null ? '' : encodeDateTime(todo.due),
    allDay: todo.allDay,
    priority: todo.priority,
    completed: todo.completed,
    completedAt:
        todo.completedAt == null ? '' : encodeDateTime(todo.completedAt),
    recurrence: _presetOf(todo.recurrencePreset, todo.rrule),
    reminderMinutes: todo.reminderMinutes,
    linkedEventId:
        todo.linkedEventId.isEmpty ? null : todo.linkedEventId,
    modifiedAt: '',
  );

  /// `todoOccurrenceObject`（:426-441）：todoObject + `seriesId` +
  /// occurrence 的 start/due/`recurrenceId` 覆写。
  PimTodo _todoOccurrenceObject(
    IcalTodo todo, {
    DateTime? occurrenceStart,
    DateTime? occurrenceEnd,
    DateTime? recurrenceId,
  }) {
    final base = _todoObject(todo);
    return PimTodo(
      id: base.id,
      title: base.title,
      description: base.description,
      seriesId: todo.uid,
      listId: base.listId,
      parentId: base.parentId,
      order: base.order,
      start: todo.start != null && occurrenceStart != null
          ? encodeDateTime(occurrenceStart)
          : base.start,
      due: todo.due != null && occurrenceEnd != null
          ? encodeDateTime(occurrenceEnd)
          : base.due,
      allDay: base.allDay,
      priority: base.priority,
      completed: base.completed,
      completedAt: base.completedAt,
      recurrence: base.recurrence,
      reminderMinutes: base.reminderMinutes,
      linkedEventId: base.linkedEventId,
      modifiedAt: base.modifiedAt,
    );
  }

  static DateTime _dayZero(DateTime d) => DateTime(d.year, d.month, d.day);

  /// `eventsForRange`（:848-889）的 Dart 等价：
  /// `[start, end]`（含端点日期）内的 VEVENT occurrence +
  /// 有 due 的 VTODO occurrence（`todoOccurrenceObject`），合计 ≤5000。
  ({List<PimEvent> occurrences, List<PimTodo> todoOccurrences})
  eventsForRange(DateTime start, DateTime end) {
    final occurrences = <PimEvent>[];
    final todoOccurrences = <PimTodo>[];
    final lo = _dayZero(start);
    // 源端 `QDateTime(end.addDays(1), 0:0).addMSecs(-1)`：窗口右端 =
    // end 日 23:59:59.999——按日闭区间等价。
    final hi = _dayZero(end);
    final byEvent = _todoIdsByLinkedEvent();

    for (final event in _events) {
      if (occurrences.length + todoOccurrences.length >= 5000) break;
      final rule = event.rrule.isEmpty ? null : RRule.tryParse(event.rrule);
      if (rule == null) {
        // 非重复或 custom：与窗口相交即一条（OccurrenceIterator 对
        // custom RRULE 也会展开，但本端子集不近似——透传单次锚点）。
        if (!_overlaps(event, lo, hi)) continue;
        occurrences.add(_eventObject(event, todoByEvent: byEvent));
        continue;
      }
      for (final day in rruleOccurrenceDays(rule, event.start, lo, hi)) {
        if (occurrences.length + todoOccurrences.length >= 5000) break;
        final occStart = _withDay(event.start, day);
        final occEnd = occStart.add(event.end.difference(event.start));
        // 跨午夜事件落在窗口日也要算入（KCalendarCore 按重叠判定）。
        if (occEnd.isBefore(lo)) continue;
        occurrences.add(_eventObject(
          event,
          occurrenceStart: occStart,
          occurrenceEnd: occEnd,
          recurrenceId: occStart,
          todoByEvent: byEvent,
        ));
      }
    }

    for (final todo in _todos) {
      if (occurrences.length + todoOccurrences.length >= 5000) break;
      // 源端只对 `hasDueDate()` 的 todo 发 occurrence（:877-880）。
      if (todo.due == null) continue;
      final anchor = todo.due!;
      final rule = todo.rrule.isEmpty ? null : RRule.tryParse(todo.rrule);
      if (rule == null) {
        if (!_dayInRange(anchor, lo, hi) &&
            !(todo.start != null && _dayInRange(todo.start!, lo, hi))) {
          continue;
        }
        todoOccurrences.add(_todoOccurrenceObject(todo));
        continue;
      }
      for (final day in rruleOccurrenceDays(rule, anchor, lo, hi)) {
        if (occurrences.length + todoOccurrences.length >= 5000) break;
        final occDue = _withDay(anchor, day);
        todoOccurrences.add(_todoOccurrenceObject(
          todo,
          occurrenceStart: todo.start == null
              ? null
              : _withDay(todo.start!, day),
          occurrenceEnd: occDue,
          recurrenceId: occDue,
        ));
      }
    }
    return (occurrences: occurrences, todoOccurrences: todoOccurrences);
  }

  /// 非重复事件与窗口 `[lo, hi]`（日粒度）是否相交：timed 按时刻、
  /// allDay 按排他 end 日区间。
  bool _overlaps(IcalEvent event, DateTime lo, DateTime hi) {
    if (event.allDay) {
      // allDay end 排他：占用 [startDay, endDay) 日期。
      final startDay = _dayZero(event.start);
      final endDay = _dayZero(event.end);
      return startDay.isBefore(hi.add(const Duration(days: 1))) &&
          endDay.isAfter(lo);
    }
    return !event.end.isBefore(lo) &&
        event.start.isBefore(hi.add(const Duration(days: 1)));
  }

  bool _dayInRange(DateTime d, DateTime lo, DateTime hi) {
    final day = _dayZero(d);
    return !day.isBefore(lo) && !day.isAfter(hi);
  }

  /// 把 [time] 的时分秒叠加到 [day]（UTC 日零点 → 本地墙钟）。
  DateTime _withDay(DateTime time, DateTime day) => DateTime(
    day.year,
    day.month,
    day.day,
    time.hour,
    time.minute,
    time.second,
    time.millisecond,
  );

  /// `snapshot()`（:798-846）的排序等价：事件按 start 字符串升序；
  /// 待办未完成优先，再按 order+title（:819-831）。
  List<PimEvent> sortedEvents() {
    final byEvent = _todoIdsByLinkedEvent();
    final list = [
      for (final e in _events) _eventObject(e, todoByEvent: byEvent),
    ]..sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  List<PimTodo> sortedTodos() {
    final list = [for (final t in _todos) _todoObject(t)]..sort((a, b) {
      if (a.completed != b.completed) return a.completed ? 1 : -1;
      if (a.order != b.order) return a.order.compareTo(b.order);
      return a.title.compareTo(b.title);
    });
    return list;
  }

  // ---------- 最小写 ----------

  String _newUid() {
    _uidCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
        '${_uidCounter.toRadixString(16)}-${_rng.next().toRadixString(16)}';
  }

  /// `createTodo` 的最小形态（本期只支持标题级新增，:1120-1174）：
  /// listId 不在清单 → 回退 `inbox`（:1132-1134）；order 默认当前毫秒
  /// 时间戳（:1158-1160）。
  Future<IcalTodo?> addTodo({
    required String title,
    String listId = 'inbox',
    int priority = 0,
    DateTime? due,
    bool allDay = true,
  }) async {
    if (!_writable || title.trim().isEmpty) return null;
    final effectiveList = hasList(listId) ? listId : 'inbox';
    final todo = IcalTodo(
      uid: _newUid(),
      summary: title.trim(),
      listId: effectiveList,
      parentId: '',
      order: DateTime.now().millisecondsSinceEpoch.toDouble(),
      start: null,
      due: due,
      allDay: allDay,
      priority: priority.clamp(0, 9),
      completed: false,
      completedAt: null,
      rrule: '',
      recurrencePreset: 'none',
      recurrenceId: '',
      reminderMinutes: -1,
      linkedEventId: '',
    );
    _todos.add(todo);
    _markChanged();
    return todo;
  }

  /// `updateTodo` 的 completed 分支最小形态（:1231-1236）：
  /// 完成写 `STATUS:COMPLETED` + `COMPLETED`（UTC 时刻）。
  Future<bool> setTodoCompleted(String uid, bool completed) async {
    if (!_writable) return false;
    final index = _todos.indexWhere((t) => t.uid == uid);
    if (index < 0) return false;
    final t = _todos[index];
    _todos[index] = IcalTodo(
      uid: t.uid,
      summary: t.summary,
      description: t.description,
      listId: t.listId,
      parentId: t.parentId,
      order: t.order,
      start: t.start,
      due: t.due,
      allDay: t.allDay,
      priority: t.priority,
      completed: completed,
      completedAt: completed ? DateTime.now() : null,
      rrule: t.rrule,
      recurrencePreset: t.recurrencePreset,
      recurrenceId: t.recurrenceId,
      reminderMinutes: t.reminderMinutes,
      linkedEventId: t.linkedEventId,
    );
    _markChanged();
    return true;
  }

  /// `createList`（:1314-1340）。
  Future<PimList?> createList({required String name, String? color}) async {
    if (!_writable || name.trim().isEmpty) return null;
    final list = PimList(
      id: _newUid(),
      name: name.trim(),
      color: color ?? '#4f8cff',
      position: _lists.length,
    );
    _lists = [..._lists, list];
    _markChanged();
    return list;
  }

  /// `removeList`（:1374-1394）：`inbox` 保护；清单内 todo 回 `inbox`。
  Future<bool> removeList(String id) async {
    if (id == 'inbox' || !_writable) return false;
    if (!hasList(id)) return false;
    _lists = [for (final l in _lists) if (l.id != id) l];
    for (var i = 0; i < _todos.length; i += 1) {
      if (_todos[i].listId == id) {
        final t = _todos[i];
        _todos[i] = IcalTodo(
          uid: t.uid,
          summary: t.summary,
          description: t.description,
          listId: 'inbox',
          parentId: t.parentId,
          order: t.order,
          start: t.start,
          due: t.due,
          allDay: t.allDay,
          priority: t.priority,
          completed: t.completed,
          completedAt: t.completedAt,
          rrule: t.rrule,
          recurrencePreset: t.recurrencePreset,
          recurrenceId: t.recurrenceId,
          reminderMinutes: t.reminderMinutes,
          linkedEventId: t.linkedEventId,
        );
      }
    }
    _markChanged();
    return true;
  }

  /// `removeTodo`（:1276-1312）：连带清子任务 `X-KOS-PARENT-ID`；
  /// event↔todo 解链的全量逻辑留 TASK-13/14，此处仅删本体。
  Future<bool> removeTodo(String uid) async {
    if (!_writable) return false;
    final index = _todos.indexWhere((t) => t.uid == uid);
    if (index < 0) return false;
    _todos.removeAt(index);
    for (var i = 0; i < _todos.length; i += 1) {
      if (_todos[i].parentId == uid) {
        final t = _todos[i];
        _todos[i] = IcalTodo(
          uid: t.uid,
          summary: t.summary,
          description: t.description,
          listId: t.listId,
          parentId: '',
          order: t.order,
          start: t.start,
          due: t.due,
          allDay: t.allDay,
          priority: t.priority,
          completed: t.completed,
          completedAt: t.completedAt,
          rrule: t.rrule,
          recurrencePreset: t.recurrencePreset,
          recurrenceId: t.recurrenceId,
          reminderMinutes: t.reminderMinutes,
          linkedEventId: t.linkedEventId,
        );
      }
    }
    _markChanged();
    return true;
  }

  /// `removeEvent`（:1085-1118）：删 VEVENT 本体；linked todo 解链保留
  /// （`unlinkEventAndTodo` :284-295——清双侧 X-props/RELATED-TO，todo
  /// 无提醒时继承事件的 `reminderMinutes` :1098-1099）。
  Future<bool> removeEvent(String uid) async {
    if (!_writable) return false;
    final index = _events.indexWhere((e) => e.uid == uid);
    if (index < 0) return false;
    final event = _events[index];
    final todoId = _linkedTodoIdFor(event, _todoIdsByLinkedEvent());
    final linkedTodo = todoId.isEmpty ? null : todoById(todoId);
    if (linkedTodo != null) {
      _replaceTodo(_copyTodo(
        linkedTodo,
        linkedEventId: '',
        reminderMinutes: linkedTodo.reminderMinutes < 0
            ? event.reminderMinutes
            : linkedTodo.reminderMinutes,
      ));
    }
    _events.removeAt(index);
    _markChanged();
    return true;
  }

  // ---------- 事件编辑（TASK-13）----------

  /// `createEvent`（:891-965）：title 必填；`end<=start` 拒绝；
  /// `end` 缺省兜底 allDay +1 日 / timed +1 小时（:916-917）；
  /// `linkedTodo=true` 时同步建 VTODO（`synchronizeTodoFromEvent`
  /// :309-332：title/description/allDay/dtStart/due=dtStart/listId/
  /// priority/recurrence 复制 + 双向 X-props 链接）。
  ///
  /// [recurrence] 预设 `none|daily|weekly|monthly|yearly`（其余含
  /// `custom` 拒绝——本端编辑器无自定义规则入口）；`todoListId` 不在
  /// 清单回退 `inbox`（:939-942）。
  Future<IcalEvent?> addEvent({
    required String title,
    String description = '',
    String location = '',
    required DateTime start,
    DateTime? end,
    bool allDay = false,
    String calendarId = 'personal',
    String recurrence = 'none',
    int reminderMinutes = -1,
    bool linkedTodo = false,
    String todoListId = 'inbox',
    int todoPriority = 0,
  }) async {
    if (!_writable || title.trim().isEmpty) return null;
    final rrule = _rruleForPreset(recurrence);
    if (rrule == null) return null; // 不支持的预设（:219-221）。
    final effectiveEnd = end ??
        (allDay
            ? _dayZero(start).add(const Duration(days: 1))
            : start.add(const Duration(hours: 1)));
    if (!effectiveEnd.isAfter(start)) return null; // :918-920
    final event = IcalEvent(
      uid: _newUid(),
      summary: title.trim(),
      description: description.trim(),
      location: location.trim(),
      start: start,
      end: effectiveEnd,
      allDay: allDay,
      timeZone: '',
      calendarId: calendarId.isEmpty ? 'personal' : calendarId,
      rrule: rrule,
      recurrencePreset: recurrence,
      recurrenceId: '',
      reminderMinutes: reminderMinutes,
      linkedTodoId: '',
    );
    if (linkedTodo) {
      // :939-944 —— linkedTodo 分支（uid 先建再同步字段）。
      final effectiveList = hasList(todoListId) ? todoListId : 'inbox';
      final todo = IcalTodo(
        uid: _newUid(),
        summary: event.summary,
        description: event.description,
        listId: effectiveList,
        parentId: '',
        order: DateTime.now().millisecondsSinceEpoch.toDouble(),
        start: event.start,
        due: event.start, // :318 `setDtDue(dtStart)`：due = 事件开始。
        allDay: event.allDay,
        priority: todoPriority.clamp(0, 9),
        completed: false,
        completedAt: null,
        rrule: event.rrule,
        recurrencePreset: event.recurrencePreset,
        recurrenceId: '',
        reminderMinutes: -1, // :329 事件独占 alarm。
        linkedEventId: event.uid,
      );
      _todos.add(todo);
      _events.add(_copyEvent(event, linkedTodoId: todo.uid));
    } else {
      _events.add(event);
    }
    _markChanged();
    return eventById(event.uid);
  }

  /// `updateEvent`（:967-1083）的编辑器全字段形态：null 参数 = 不改；
  /// `linkedTodo` 三态（null 保持 / true 建链或改链 / false 解链）。
  /// 日期校验 `end <= start` 拒绝（:1010-1012）；`recurrence` 非 null
  /// 时先 `rule->clear()` 再按预设重写（:200-231）。
  ///
  /// linked-todo 同步（:1024-1054）：应链时
  /// `synchronizeTodoFromEvent`（title/description/allDay/dtStart/due、
  /// listId/todoPriority 缺省继承既有 todo；:1034-1046）；不应链时
  /// `unlinkEventAndTodo`（事件清 `X-KOS-LINKED-TODO-ID`，todo 清链接
  /// 字段并继承提醒）。
  Future<bool> updateEvent(
    String uid, {
    String? title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? calendarId,
    String? recurrence,
    int? reminderMinutes,
    bool? linkedTodo,
    String? todoListId,
    int? todoPriority,
  }) async {
    if (!_writable) return false;
    final index = _events.indexWhere((e) => e.uid == uid);
    if (index < 0) return false;
    final old = _events[index];
    if (title != null && title.trim().isEmpty) {
      return false; // :985-986 title 空串拒绝。
    }
    final nextAllDay = allDay ?? old.allDay;
    final nextStart = start ?? old.start;
    final nextEnd = end ?? old.end;
    if (!nextEnd.isAfter(nextStart)) return false; // :1010-1012
    String? nextRrule = old.rrule;
    String nextPreset = old.recurrencePreset;
    if (recurrence != null) {
      nextRrule = _rruleForPreset(recurrence);
      if (nextRrule == null) return false; // :219-221 不支持预设。
      // `none` 时清掉 X-KOS-RECURRENCE-PRESET（:202-204）——用
      // 'none' 存档等价（序列化不写 none）。
      nextPreset = recurrence == 'none' ? '' : recurrence;
    }

    final existingTodoId = _linkedTodoIdFor(old, _todoIdsByLinkedEvent());
    final existingTodo =
        existingTodoId.isEmpty ? null : todoById(existingTodoId);
    final shouldLink = linkedTodo ?? (existingTodo != null); // :1024-1026

    var nextLinkedTodoId = old.linkedTodoId;
    if (shouldLink) {
      // :1034-1046 —— listId/priority 缺省继承既有 todo。
      final listId = todoListId ??
          (existingTodo != null && existingTodo.listId.isNotEmpty
              ? existingTodo.listId
              : (hasList('personal') ? 'personal' : 'inbox'));
      if (!hasList(listId)) return false; // :1041-1043 invalid_list
      final priority =
          (todoPriority ?? existingTodo?.priority ?? 0).clamp(0, 9);
      final todo = existingTodo ??
          IcalTodo(
            uid: _newUid(),
            summary: '',
            description: '',
            listId: '',
            parentId: '',
            order: DateTime.now().millisecondsSinceEpoch.toDouble(),
            start: null,
            due: null,
            allDay: false,
            priority: 0,
            completed: false,
            completedAt: null,
            rrule: '',
            recurrencePreset: 'none',
            recurrenceId: '',
            reminderMinutes: -1,
            linkedEventId: '',
          );
      final synced = _copyTodo(
        todo,
        summary: (title ?? old.summary).trim(),
        description: (description ?? old.description).trim(),
        allDay: nextAllDay,
        start: nextStart,
        due: nextStart, // :318 due = event.dtStart
        listId: listId,
        priority: priority,
        rrule: nextRrule,
        recurrencePreset: nextPreset.isEmpty ? 'none' : nextPreset,
        reminderMinutes: -1, // :329 事件独占 alarm。
        linkedEventId: uid,
      );
      if (existingTodo == null) {
        _todos.add(synced);
      } else {
        _replaceTodo(synced);
      }
      nextLinkedTodoId = synced.uid;
    } else if (existingTodo != null) {
      // :1049-1051 `unlinkEventAndTodo`：todo 侧清链 + 继承事件提醒
      // （:287-288 todo 无提醒时补 event.reminderMinutes）。
      _replaceTodo(_copyTodo(
        existingTodo,
        linkedEventId: '',
        reminderMinutes: existingTodo.reminderMinutes < 0
            ? old.reminderMinutes
            : existingTodo.reminderMinutes,
      ));
      nextLinkedTodoId = '';
    } else {
      nextLinkedTodoId = ''; // :1053 removeCustomProperty
    }

    _events[index] = _copyEvent(
      old,
      summary: title?.trim(),
      description: description?.trim(),
      location: location?.trim(),
      start: nextStart,
      end: nextEnd,
      allDay: nextAllDay,
      calendarId: calendarId,
      rrule: nextRrule,
      recurrencePreset: nextPreset,
      reminderMinutes: reminderMinutes,
      linkedTodoId: nextLinkedTodoId,
    );
    _markChanged();
    return true;
  }

  /// `updateTodo`（:1176-1274）全字段形态：null 参数 = 不改（对齐
  /// `input.contains(key)` 分支语义）；`clearDue` 是因 `due==null` 与
  /// 「不改」歧义而加的显式清除位（payload 写 `""` → `parseDateTime`
  /// 无效 → `setDtDue(invalid)` 清期，:1206-1207）。
  ///
  /// 校验顺序对齐源端：title 空串拒绝（:1192-1196）；`listId` 非 null
  /// 但不在清单 → 拒绝（:1213-1219 invalid_list）；`recurrence` 非
  /// `none|daily|weekly|monthly|yearly`（含 `custom`）→ 拒绝
  /// （:219-221 unsupported preset）；非 none 重复要求 start 或 due
  /// 存在（:207-210）。
  ///
  /// linked-event 同步（`synchronizeEventFromTodo` :334-360）：todo 有
  /// `linkedEventId` 且事件存在时，标题/描述/allDay/due 回写事件
  /// （due → event.start，时长保持 :343-355）；linked todo 必须保 due
  /// （:338-340 拒绝清 due）；提醒归 VEVENT 独占——linked 对子恒写
  /// `reminderMinutes=-1`（:1248 `applyReminder(updated, -1)`）。
  Future<bool> updateTodo(
    String uid, {
    String? title,
    String? description,
    String? listId,
    DateTime? start,
    DateTime? due,
    bool clearDue = false,
    bool? allDay,
    int? priority,
    bool? completed,
    String? recurrence,
    int? reminderMinutes,
  }) async {
    if (!_writable) return false;
    final index = _todos.indexWhere((t) => t.uid == uid);
    if (index < 0) return false;
    final old = _todos[index];
    if (title != null && title.trim().isEmpty) return false; // :1194-1195
    if (listId != null && !hasList(listId)) return false; // :1217-1218
    final nextAllDay = allDay ?? old.allDay;
    final nextStart = start ?? old.start;
    final nextDue = clearDue ? null : (due ?? old.due);
    final nextCompleted = completed ?? old.completed;

    // `applyRecurrence`（:200-231）：payload 带 `recurrence` 时先
    // `rule->clear()` 再按预设重写；'none' 清 X-KOS-RECURRENCE-PRESET
    // （存 ''，序列化不写 none）。
    var nextRrule = old.rrule;
    var nextPreset = old.recurrencePreset;
    if (recurrence != null) {
      final rrule = _rruleForPreset(recurrence);
      if (rrule == null) return false; // :219-221 不支持预设（含 custom）。
      // :207-210 —— 重复 todo 需要 start 或 due 作为锚（todo 侧锚 due）。
      if (rrule.isNotEmpty && nextStart == null && nextDue == null) {
        return false;
      }
      nextRrule = rrule;
      nextPreset = recurrence == 'none' ? '' : recurrence;
    }

    // linked event 同步（:1183-1186, :1242-1252）。existingEventId 非空
    // 但事件已不存在时源端清链接字段（:1254-1257）。
    final event = old.linkedEventId.isEmpty
        ? null
        : eventById(old.linkedEventId);
    if (event != null && nextDue == null) {
      return false; // :338-340 linked todo 必须有 due。
    }

    _todos[index] = _copyTodo(
      old,
      summary: title?.trim(),
      description: description?.trim(),
      listId: listId,
      start: start ?? (event != null ? nextDue : old.start), // :342
      due: nextDue,
      allDay: nextAllDay,
      priority: priority?.clamp(0, 9),
      completed: nextCompleted,
      completedAt: completed == null
          ? old.completedAt
          : (nextCompleted ? (old.completedAt ?? DateTime.now()) : null),
      rrule: nextRrule,
      recurrencePreset: nextPreset,
      // :1248 linked 对子的提醒归 VEVENT；非 linked 时允许改提醒
      // （:1237-1239 `input.contains(reminderMinutes)` 才改）。
      reminderMinutes: event != null ? -1 : reminderMinutes,
      linkedEventId:
          event == null && old.linkedEventId.isNotEmpty ? '' : null,
    );

    if (event != null) {
      // :343-355 —— 时长保持：allDay 按日数差（≥1），timed 按秒差（≥60）。
      final duration = event.allDay
          ? Duration(
              days: (DateTime(event.end.year, event.end.month, event.end.day)
                      .difference(DateTime(
                          event.start.year, event.start.month, event.start.day))
                      .inDays)
                  .clamp(1, 1 << 30),
            )
          : event.end.difference(event.start) < const Duration(seconds: 60)
              ? const Duration(seconds: 60)
              : event.end.difference(event.start);
      // `synchronizeEventFromTodo`（:345-348）还会把 todo 的 recurrence
      // 复制到事件（`copyEditableRecurrence`）。
      _replaceEvent(_copyEvent(
        event,
        summary: (title ?? old.summary).trim(),
        description: (description ?? old.description).trim(),
        allDay: nextAllDay,
        start: nextDue,
        end: nextDue!.add(duration),
        rrule: nextRrule,
        recurrencePreset: nextPreset,
        linkedTodoId: uid,
      ));
    }

    if (event != null) {
      // :343-355 —— 时长保持：allDay 按日数差（≥1），timed 按秒差（≥60）。
      final duration = event.allDay
          ? Duration(
              days: (DateTime(event.end.year, event.end.month, event.end.day)
                      .difference(DateTime(
                          event.start.year, event.start.month, event.start.day))
                      .inDays)
                  .clamp(1, 1 << 30),
            )
          : event.end.difference(event.start) < const Duration(seconds: 60)
              ? const Duration(seconds: 60)
              : event.end.difference(event.start);
      _replaceEvent(_copyEvent(
        event,
        summary: (title ?? old.summary).trim(),
        description: (description ?? old.description).trim(),
        allDay: nextAllDay,
        start: nextDue,
        end: nextDue!.add(duration),
        linkedTodoId: uid,
      ));
    }
    _markChanged();
    return true;
  }

  /// 预设 → RRULE 文本（`applyRecurrence` :211-218 `set*(1)` 的文本
  /// 等价）；`none` → 空串，未识别（含 `custom`）→ null 拒绝。
  static String? _rruleForPreset(String preset) => switch (preset) {
    'none' => '',
    'daily' => 'FREQ=DAILY;INTERVAL=1',
    'weekly' => 'FREQ=WEEKLY;INTERVAL=1',
    'monthly' => 'FREQ=MONTHLY;INTERVAL=1',
    'yearly' => 'FREQ=YEARLY;INTERVAL=1',
    _ => null,
  };

  /// 按 uid 原位替换 todo（保持列表序）。
  void _replaceTodo(IcalTodo next) {
    final i = _todos.indexWhere((t) => t.uid == next.uid);
    if (i >= 0) _todos[i] = next;
  }

  void _replaceEvent(IcalEvent next) {
    final i = _events.indexWhere((e) => e.uid == next.uid);
    if (i >= 0) _events[i] = next;
  }

  /// `IcalEvent` 按字段克隆（KCalendarCore `event->clone()` 等价物；
  /// null 参数 = 保持原值）。
  IcalEvent _copyEvent(
    IcalEvent e, {
    String? summary,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? calendarId,
    String? rrule,
    String? recurrencePreset,
    int? reminderMinutes,
    String? linkedTodoId,
  }) => IcalEvent(
    uid: e.uid,
    summary: summary ?? e.summary,
    description: description ?? e.description,
    location: location ?? e.location,
    start: start ?? e.start,
    end: end ?? e.end,
    allDay: allDay ?? e.allDay,
    timeZone: e.timeZone,
    calendarId: calendarId ?? e.calendarId,
    rrule: rrule ?? e.rrule,
    recurrencePreset: recurrencePreset ?? e.recurrencePreset,
    recurrenceId: e.recurrenceId,
    reminderMinutes: reminderMinutes ?? e.reminderMinutes,
    linkedTodoId: linkedTodoId ?? e.linkedTodoId,
  );

  /// `IcalTodo` 按字段克隆（`todo->clone()` 等价物）。
  IcalTodo _copyTodo(
    IcalTodo t, {
    String? summary,
    String? description,
    String? listId,
    String? parentId,
    DateTime? start,
    DateTime? due,
    bool? allDay,
    int? priority,
    bool? completed,
    DateTime? completedAt,
    String? rrule,
    String? recurrencePreset,
    int? reminderMinutes,
    String? linkedEventId,
  }) => IcalTodo(
    uid: t.uid,
    summary: summary ?? t.summary,
    description: description ?? t.description,
    listId: listId ?? t.listId,
    parentId: parentId ?? t.parentId,
    order: t.order,
    start: start ?? t.start,
    due: due ?? t.due,
    allDay: allDay ?? t.allDay,
    priority: priority ?? t.priority,
    completed: completed ?? t.completed,
    completedAt: completedAt ?? t.completedAt,
    rrule: rrule ?? t.rrule,
    recurrencePreset: recurrencePreset ?? t.recurrencePreset,
    recurrenceId: t.recurrenceId,
    reminderMinutes: reminderMinutes ?? t.reminderMinutes,
    linkedEventId: linkedEventId ?? t.linkedEventId,
  );

  // ---------- 落盘 ----------

  void _markChanged() {
    _revision += 1;
    _dirty = true;
    _scheduleSave();
    if (!_changes.isClosed) _changes.add(_revision);
  }

  /// 150ms 防抖合并写（`scheduleSave`/`saveTimer`，:497-515）。
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(flush()));
  }

  /// 立即落盘（`flush`，:637-645）：成功后刷 widget 快照。
  Future<void> flush() async {
    _saveTimer?.cancel();
    if (await _flushSave()) {
      await writeWidgetSnapshot();
    }
  }

  /// `flushSave`（:516-528）：失败清 dirty、保内存态。
  Future<bool> _flushSave() async {
    if (!_dirty) return true;
    final ok = await _writeState();
    _dirty = false;
    return ok;
  }

  /// `writeState`（:530-547）：calendar.ics + metadata.json 原子写。
  Future<bool> _writeState() async {
    if (!_writable) return false;
    try {
      await _storage.ensureDirectory(storageDirectory);
      await _storage.writeStringAtomic(
        calendarPath,
        IcalParser.serialize(IcalDocument(events: _events, todos: _todos)),
      );
      await _storage.writeStringAtomic(
        metadataPath,
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 1,
          'revision': _revision,
          'lists': [for (final l in _lists) l.toJson()],
        }),
      );
      return true;
    } on Object {
      return false;
    }
  }

  /// `writeWidgetSnapshot`（:725-796）：今日起 8 天窗口 ≤16 event
  /// occurrence + ≤16 未完成 todo（order+title），原子写
  /// `widget-snapshot.json` 并向 [snapshots] 推送。
  Future<void> writeWidgetSnapshot() async {
    if (_disposed || !_loaded) return;
    final snapshot = buildWidgetSnapshot();
    try {
      await _storage.ensureDirectory(storageDirectory);
      await _storage.writeStringAtomic(
        snapshotPath,
        jsonEncode(_snapshotJson(snapshot)),
      );
    } on Object {
      // 对齐源端 write 失败仅告警（:793-795），不影响内存态。
    }
    _latestSnapshot = snapshot;
    if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
  }

  /// 生成当前快照对象（不落盘；供 provider/测试直接取）。
  WidgetSnapshot buildWidgetSnapshot() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final range = eventsForRange(today, today.add(const Duration(days: 7)));
    final events = range.occurrences.take(16).toList();
    final open = [
      for (final t in _todos)
        if (!t.completed) t,
    ]..sort((a, b) {
      if (a.order != b.order) return a.order.compareTo(b.order);
      return a.summary.compareTo(b.summary);
    });
    final todos = [for (final t in open.take(16)) _todoObject(t)];
    String p2(int v) => v.toString().padLeft(2, '0');
    return WidgetSnapshot(
      schemaVersion: 1,
      revision: _revision,
      generatedAt: DateTime.now().millisecondsSinceEpoch,
      today: '${today.year.toString().padLeft(4, '0')}-'
          '${p2(today.month)}-${p2(today.day)}',
      events: events,
      todos: todos,
    );
  }

  Map<String, Object?> _snapshotJson(WidgetSnapshot s) => {
    'schemaVersion': s.schemaVersion,
    'revision': s.revision,
    'generatedAt': s.generatedAt,
    'today': s.today,
    'events': [for (final e in s.events) _eventJson(e)],
    'todos': [for (final t in s.todos) _todoJson(t)],
  };

  /// eventObject 键集合（:374-397）。
  Map<String, Object?> _eventJson(PimEvent e) => {
    'id': e.id,
    'seriesId': e.seriesId,
    'title': e.title,
    'description': e.description,
    'location': e.location,
    'start': e.start,
    'end': e.end,
    'allDay': e.allDay,
    'timeZone': e.timeZone,
    'calendarId': e.calendarId,
    'recurrence': e.recurrence,
    'recurrenceId': e.recurrenceId,
    'reminderMinutes': e.reminderMinutes,
    'linkedTodoId': e.linkedTodoId ?? '',
    'linkedTodoCompleted': e.linkedTodoCompleted,
    'linkedTodoListId': e.linkedTodoListId ?? '',
    'linkedTodoPriority': e.linkedTodoPriority,
    'modifiedAt': e.modifiedAt,
  };

  /// todoObject 键集合（:404-422）。
  Map<String, Object?> _todoJson(PimTodo t) => {
    'id': t.id,
    'title': t.title,
    'description': t.description,
    'listId': t.listId,
    'parentId': t.parentId,
    'order': t.order,
    'start': t.start,
    'due': t.due,
    'allDay': t.allDay,
    'priority': t.priority,
    'completed': t.completed,
    'completedAt': t.completedAt,
    'recurrence': t.recurrence,
    'reminderMinutes': t.reminderMinutes,
    'linkedEventId': t.linkedEventId ?? '',
    'modifiedAt': t.modifiedAt,
  };
  /// 最近一次生产的快照（`onListen` 回放用，修复晚订阅丢首份——
  /// `pimStoreProvider` 的 `unawaited(load())` 可能先于消费者订阅
  /// 完成推送，broadcast 无回放时首份丢失）。
  WidgetSnapshot? _latestSnapshot;

  late final StreamController<WidgetSnapshot> _snapshotController =
      StreamController<WidgetSnapshot>.broadcast(
    onListen: () {
      // 晚订阅回放最新一份（对齐消费端「保留上一份有效快照」语义，
      // PimWidgetService.qml:60-63）。回放走异步微任务不挡 onListen。
      final latest = _latestSnapshot;
      if (latest != null && !_snapshotController.isClosed) {
        _snapshotController.add(latest);
      }
    },
  );

  /// 每次写快照推送（插件内权威源；`FileWidgetSnapshotWatcher` 仍可
  /// 读外部文件做迁移兼容，见任务卡 §4）。已产快照时晚订阅者
  /// 先收一份回放（`onListen` 补发 `_latestSnapshot`）。
  Stream<WidgetSnapshot> get snapshots => _snapshotController.stream;

  /// 停止定时器并关闭流；先 `flush()` 落盘防抖窗口内的尾部变更
  /// （对齐 `~Private` 强制 `flushSave` + 快照刷新，
  /// PimStore.cpp:474-479,630-635,637-645）。
  Future<void> dispose() async {
    // flush 再置 disposed：防抖内的 mutation 连同 widget 快照一起
    // 落盘（复审 #4；writeWidgetSnapshot 的 _disposed 早退要求次序）。
    try {
      await flush();
    } on Object {
      // 落盘失败不阻塞销毁（内存态随实例释放）。
    }
    _disposed = true;
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    _reloadDebounce?.cancel();
    // 取消订阅用 unawaited：在 Denial 引擎的 widget 测试 fake-async 区里，
    // `await subscription.cancel()`（订阅的是已完成的 `Stream.empty()`／
    // 广播流）之后的 `tester.pump()` 会永久挂起；不 await 即绕开该路径。
    // 取消动作本身同步发起，生产语义不变（无人依赖该 done）。
    unawaited(_watch?.cancel());
    // 同理：广播 StreamController 的 `done` future 在无订阅者时不保证在
    // fake-async 内完成；`close()` 已同步置为关闭，事件送达异步，不 await。
    unawaited(_changes.close());
    unawaited(_snapshotController.close());
  }
}

/// 简单随机源（`QUuid::createUuid` 唯一性等价物；不依赖外部包）。
final class _UidRandom {
  int _state = DateTime.now().microsecondsSinceEpoch;

  int next() {
    // xorshift64*，足够 uid 碰撞域。
    _state ^= _state >> 12;
    _state ^= _state << 25;
    _state ^= _state >> 27;
    return (_state * 0x2545F4914F6CDD1D) & 0x7FFFFFFFFFFFFFFF;
  }
}
