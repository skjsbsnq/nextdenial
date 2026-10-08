/// widget-snapshot.json 的文件监听实现（`FileWidgetSnapshotWatcher`）
/// 与 PIM 模型 `fromJson` 解析（供 `widget_snapshot_watcher.dart` 委托）。
///
/// 事实来源（NextKde 仓库）：
/// - 快照生成与字段：services/pim-service/src/PimStore.cpp:725-796
///   （`writeWidgetSnapshot`）、event/todo 字段 :362-424；
/// - 消费端生命周期：shell/desktop/modules/deskcenter/PimWidgetService.qml
///   :21-38（loading → ready/5s 宽限期 unavailable）、:95-116（文件变化
///   ~180ms 防抖 reload + 30s 周期兜底；解析失败保留上一份有效快照；
///   服务上线自愈）。
///
/// 本文档行号均指上述仓库内相对路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'widget_snapshot_watcher.dart';

String _str(Object? value) => value?.toString() ?? '';
int _int(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  _ => 0,
};
bool _bool(Object? value) => value == true;
double _double(Object? value) => switch (value) {
  final double v => v,
  final num v => v.toDouble(),
  _ => 0.0,
};
String? _strOrNull(Object? value) {
  final text = value?.toString();
  return (text == null || text.isEmpty) ? null : text;
}

List<Map<String, Object?>> _mapList(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item.map((key, v) => MapEntry(key.toString(), v)),
];

/// `pim-v1.schema.json $defs.event`（行 51-90）/`eventObject()`
/// （PimStore.cpp:362-398）的解析实现。
PimEvent pimEventFromJson(Map<String, Object?> json) => PimEvent(
  id: _str(json['id']),
  seriesId: _str(json['seriesId']),
  title: _str(json['title']),
  description: _str(json['description']),
  location: _str(json['location']),
  start: _str(json['start']),
  end: _str(json['end']),
  allDay: _bool(json['allDay']),
  timeZone: _str(json['timeZone']),
  calendarId: _str(json['calendarId']),
  recurrence: _str(json['recurrence']),
  recurrenceId: _str(json['recurrenceId']),
  reminderMinutes: _int(json['reminderMinutes']),
  modifiedAt: _str(json['modifiedAt']),
  linkedTodoId: _strOrNull(json['linkedTodoId']),
  linkedTodoCompleted: _bool(json['linkedTodoCompleted']),
  linkedTodoListId: _strOrNull(json['linkedTodoListId']),
  linkedTodoPriority: _int(json['linkedTodoPriority']),
);

/// `pim-v1.schema.json $defs.todo`（行 91-129）/`todoObject()`
/// （PimStore.cpp:400-424）的解析实现；空日期字段服务写 `""` 不省略。
PimTodo pimTodoFromJson(Map<String, Object?> json) => PimTodo(
  id: _str(json['id']),
  title: _str(json['title']),
  description: _str(json['description']),
  seriesId: _str(json['seriesId']), // 快照不写此字段，恒空（见模型注释）。
  listId: _str(json['listId']),
  parentId: _str(json['parentId']),
  order: _double(json['order']),
  start: _str(json['start']),
  due: _str(json['due']),
  allDay: _bool(json['allDay']),
  priority: _int(json['priority']),
  completed: _bool(json['completed']),
  completedAt: _str(json['completedAt']),
  recurrence: _str(json['recurrence']),
  reminderMinutes: _int(json['reminderMinutes']),
  linkedEventId: _strOrNull(json['linkedEventId']),
  modifiedAt: _str(json['modifiedAt']),
);

/// 快照解析：`schemaVersion` 必须等于 1，否则抛 [FormatException]
/// （消费端丢弃语义，PimWidgetService.qml:50-51）。
WidgetSnapshot widgetSnapshotFromJson(Map<String, Object?> json) {
  final schemaVersion = _int(json['schemaVersion']);
  if (schemaVersion != 1) {
    throw FormatException('widget-snapshot schemaVersion != 1: $schemaVersion');
  }
  return WidgetSnapshot(
    schemaVersion: schemaVersion,
    revision: _int(json['revision']),
    generatedAt: _int(json['generatedAt']),
    today: _str(json['today']),
    events: [for (final e in _mapList(json['events'])) pimEventFromJson(e)],
    todos: [for (final t in _mapList(json['todos'])) pimTodoFromJson(t)],
  );
}

/// `widget-snapshot.json` 的 [WidgetSnapshotWatcher] dart:io 实现。
///
/// 监听策略对齐 PimWidgetService.qml:104-116：
/// - `FileSystemEntity.watch` 事件 → ~180ms 防抖 reload；
/// - 30s 周期兜底 reload（inotify 漏事件的保险）；
/// - start 后 5000ms 可用性宽限期：期间无有效快照 → `unavailable`
///   （:34-38、95-102）；之后成功 reload 自愈回 `ready`；
/// - 解析失败保留上一份有效快照；不重复推送 `revision` 未变的文件。
final class FileWidgetSnapshotWatcher implements WidgetSnapshotWatcher {
  FileWidgetSnapshotWatcher({String? path}) : _path = path ?? _defaultPath();

  /// 文件变化防抖（PimWidgetService.qml:104-108 `Timer interval: 180`）。
  static const Duration _debounce = Duration(milliseconds: 180);

  /// 周期兜底（PimWidgetService.qml:112-116 `interval: 30000`）。
  static const Duration _pollInterval = Duration(seconds: 30);

  /// 可用性宽限期（PimWidgetService.qml:34-38 `5000ms`）。
  static const Duration _gracePeriod = Duration(seconds: 5);

  final String _path;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _graceTimer;
  bool _started = false;
  bool _disposed = false;
  int _lastRevision = -1;

  /// 上次成功 stat 到的文件 mtime：30s 兜底轮询用它跳过未变文件的
  /// readAsString+jsonDecode（防抖路径同样经 `_reload` 更新本缓存）。
  DateTime? _lastMtime;
  WidgetSnapshotState _state = WidgetSnapshotState.loading;

  final StreamController<WidgetSnapshot> _snapshots =
      StreamController<WidgetSnapshot>.broadcast();
  final StreamController<WidgetSnapshotState> _states =
      StreamController<WidgetSnapshotState>.broadcast();

  /// 消费端路径推导（PimWidgetService.qml:10-14）：
  /// `$XDG_DATA_HOME || $HOME/.local/share` + `/kos/pim/widget-snapshot.json`；
  /// `KOS_PIM_STORAGE_DIR` 直接覆盖目录（PimStore.cpp:49-56）。
  static String _defaultPath() {
    final env = Platform.environment;
    final storageDir = env['KOS_PIM_STORAGE_DIR'];
    if (storageDir != null && storageDir.isNotEmpty) {
      return '$storageDir/widget-snapshot.json';
    }
    final dataHome =
        env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? ''}/.local/share';
    return '$dataHome/kos/pim/widget-snapshot.json';
  }

  @override
  Stream<WidgetSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<WidgetSnapshotState> get states => _states.stream;

  @override
  WidgetSnapshotState get state => _state;

  @override
  void start() {
    if (_started || _disposed) return; // 幂等。
    _started = true;
    _emit(WidgetSnapshotState.loading);
    // 宽限期计时：5000ms 内无有效快照 → unavailable（:34-38）。
    _graceTimer = Timer(_gracePeriod, () {
      if (_state == WidgetSnapshotState.loading) {
        _emit(WidgetSnapshotState.unavailable);
      }
    });
    // 文件变化防抖 reload（:104-108）。
    final file = File(_path);
    try {
      _watch = file.watch().listen((_) => _scheduleReload());
    } on Object {
      // 目录不存在等：watch 失败不影响 30s 兜底与宽限期逻辑。
      _watch = null;
    }
    _pollTimer = Timer.periodic(_pollInterval, (_) => _reload());
    _reload();
  }

  void _scheduleReload() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _reload);
  }

  Future<void> _reload() async {
    if (_disposed) return;
    final file = File(_path);
    // 先 stat：mtime 未变直接返回，不读内容不 decode（周期兜底的大头开销）。
    try {
      final modified = (await file.stat()).modified;
      if (_lastMtime != null && modified == _lastMtime) return;
      _lastMtime = modified;
    } on Object {
      // stat 失败（文件缺失等）：保持现状返回，与读失败同语义。
      return;
    }
    String text;
    try {
      text = await file.readAsString();
    } on Object {
      return; // 文件缺失/读失败：保持现状，宽限期计时照常走。
    }
    WidgetSnapshot snapshot;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      snapshot = widgetSnapshotFromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on Object {
      // 解析失败保留上一份有效快照（PimWidgetService.qml:60-63）。
      return;
    }
    if (snapshot.revision == _lastRevision) return; // 不重复推送。
    _lastRevision = snapshot.revision;
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
    _emit(WidgetSnapshotState.ready); // 服务上线自愈（unavailable → ready）。
  }

  void _emit(WidgetSnapshotState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _graceTimer?.cancel();
    unawaited(_watch?.cancel());
    unawaited(_snapshots.close());
    unawaited(_states.close());
  }
}
