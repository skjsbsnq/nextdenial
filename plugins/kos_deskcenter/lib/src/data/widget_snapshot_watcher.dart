/// widget-snapshot.json 监听接口骨架（无文件监听实现）。
///
/// 数据生产者：NextKde `kos-pim-service` 的 `PimStore::writeWidgetSnapshot()`
/// （services/pim-service/src/PimStore.cpp:725-796），原子写入
/// `$XDG_DATA_HOME/kos/pim/widget-snapshot.json`（默认目录见
/// PimStore.cpp:49-56，`KOS_PIM_STORAGE_DIR` 可覆盖；QML 消费端路径推导见
/// shell/desktop/modules/deskcenter/PimWidgetService.qml:10-14）。
///
/// 快照结构（PimStore.cpp:777-785）：
/// `{schemaVersion:1, revision, generatedAt, today, events[<=16], todos[<=16]}`。
/// event/todo 对象与 `pim-v1.schema.json` 的 `$defs.event`/`$defs.todo`
/// 同构（eventObject/todoObject，PimStore.cpp:362-424）。
///
/// 生命周期语义（PimWidgetService.qml:21-38, 95-116）：loading → ready /
/// 5000ms 宽限期后 unavailable；文件变化经 ~180ms 防抖 reload，另有 30s
/// 周期兜底；解析失败保留上一份有效快照。
///
/// TODO(TASK-03 数据接入)：以下均为接口/模型骨架，`start()` 等方法体
/// `throw UnimplementedError`，由后续任务实现 File 轮询/inotify 监听。
library;

import 'dart:async';

/// 单条日历事件投影。
///
/// 字段以 `pim-v1.schema.json` `$defs.event`（行 51-90）与
/// `eventObject()`（PimStore.cpp:362-398）为准；快照截断为 <=16 条
/// （PimStore.cpp:740）。`start`/`end`/`modifiedAt` 为服务编码的日期时间
/// 字符串（`encodeDateTime`），`recurrenceId` 发生次标识可空。
final class PimEvent {
  const PimEvent({
    required this.id,
    required this.seriesId,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.calendarId,
    required this.recurrence,
    required this.reminderMinutes,
    required this.modifiedAt,
    this.description = '',
    this.location = '',
    this.timeZone = '',
    this.recurrenceId = '',
    this.linkedTodoId,
    this.linkedTodoCompleted = false,
    this.linkedTodoListId,
    this.linkedTodoPriority = 0,
  });

  /// 事件 uid（快照中与 `seriesId` 同值，PimStore.cpp:375-376）。
  final String id;
  final String seriesId;
  final String title;
  final String description;
  final String location;

  /// ISO 风格日期时间字符串（含时区编码，见 `encodeDateTime`）。
  final String start;
  final String end;
  final bool allDay;
  final String timeZone;

  /// 日历归属；空时服务写 `"personal"`（PimStore.cpp:384-387）。
  final String calendarId;

  /// `none|daily|weekly|monthly|yearly|custom`（pim-v1.schema.json:37-39）。
  final String recurrence;
  final String recurrenceId;

  /// 提醒提前分钟数，-1 表示无提醒（schema 行 82）。
  final int reminderMinutes;

  /// 关联待办（PimStore.cpp:391-395）；无关联时为 null/默认。
  final String? linkedTodoId;
  final bool linkedTodoCompleted;
  final String? linkedTodoListId;
  final int linkedTodoPriority;
  final String modifiedAt;

  factory PimEvent.fromJson(Map<String, Object?> json) {
    // TODO: 实现任务补全。
    throw UnimplementedError('PimEvent.fromJson: 见 TASK-00 骨架约束');
  }
}

/// 单条待办投影（openTodos 截断为 <=16，PimStore.cpp:770-775）。
///
/// 字段以 `pim-v1.schema.json` `$defs.todo`（行 91-129）与
/// `todoObject()`（PimStore.cpp:400-424）为准。空日期字段服务写 `""`
/// 而非省略（PimStore.cpp:410-413, 417-418）。
final class PimTodo {
  const PimTodo({
    required this.id,
    required this.title,
    required this.listId,
    required this.parentId,
    required this.order,
    required this.start,
    required this.due,
    required this.allDay,
    required this.priority,
    required this.completed,
    required this.completedAt,
    required this.recurrence,
    required this.reminderMinutes,
    required this.modifiedAt,
    this.description = '',
    this.seriesId = '',
    this.linkedEventId,
  });

  final String id;
  final String title;
  final String description;

  /// 系列 id（仅 `todoOccurrenceObject` 写入，PimStore.cpp:426-433）。
  /// widget 快照走 `todoObject`（:400-424）无此字段；源 QML 行点击回退链
  /// `value(m,"id", value(m,"seriesId",""))`（DeskCenterWindow.qml:2145-2146）
  /// 在快照数据上恒落到 id——本字段为该回退保留占位，默认空串。
  final String seriesId;

  /// 列表归属；空时服务写 `"inbox"`（PimStore.cpp:407）。
  final String listId;
  final String parentId;

  /// 排序键（custom property ORDER 的 double 值，PimStore.cpp:409）。
  final double order;

  /// 开始/截止日期时间字符串；无对应日期时为 `""`。
  final String start;
  final String due;
  final bool allDay;

  /// 0-9（schema 行 120；KCalendarCore 语义：0 未指定，1 最高）。
  final int priority;
  final bool completed;
  final String completedAt;
  final String recurrence;
  final int reminderMinutes;
  final String? linkedEventId;
  final String modifiedAt;

  factory PimTodo.fromJson(Map<String, Object?> json) {
    // TODO: 实现任务补全。
    throw UnimplementedError('PimTodo.fromJson: 见 TASK-00 骨架约束');
  }
}

/// widget-snapshot.json 的解析结果（不可变）。
final class WidgetSnapshot {
  const WidgetSnapshot({
    required this.schemaVersion,
    required this.revision,
    required this.generatedAt,
    required this.today,
    required this.events,
    required this.todos,
  });

  /// 当前恒为 1（PimStore.cpp:778）；消费端按不等于 1 拒绝
  /// （PimWidgetService.qml:50-51）。
  final int schemaVersion;

  /// 存储修订号，每次写递增。
  final int revision;

  /// 生成时刻（epoch 毫秒，PimStore.cpp:780-781）。
  final int generatedAt;

  /// `yyyy-MM-dd`（生成端当日，PimStore.cpp:782）；用于筛"今日事件"
  /// （PimWidgetService.qml:66-73）。
  final String today;

  /// 今日起 8 天窗口内的事件发生次，<=16 条（PimStore.cpp:737-750）。
  final List<PimEvent> events;

  /// 未完成待办（openTodos），<=16 条，按 order/summary 排序
  /// （PimStore.cpp:752-775）。
  final List<PimTodo> todos;

  factory WidgetSnapshot.fromJson(Map<String, Object?> json) {
    // TODO: 实现任务补全 schemaVersion 校验与数组解析。
    throw UnimplementedError('WidgetSnapshot.fromJson: 见 TASK-00 骨架约束');
  }
}

/// 快照可用性状态（对齐 PimWidgetService.qml:27-30）。
enum WidgetSnapshotState {
  /// 启动初期，等待首次有效快照（<=5000ms 宽限）。
  loading,

  /// 至少解析成功一份有效快照。
  ready,

  /// 宽限期（5000ms）内未出现有效快照：服务未安装/未激活。
  unavailable,
}

/// 监听 `widget-snapshot.json` 的接口。
///
/// 实现对齐消费端语义：文件变化防抖 ~180ms reload + 30s 周期兜底
/// （PimWidgetService.qml:104-116）；解析失败保留上一份有效快照；
/// 服务上线自愈（unavailable → ready）。
abstract interface class WidgetSnapshotWatcher {
  /// 快照流：每次成功解析推送一份 [WidgetSnapshot]；不重复推送
  /// revision 未变的文件。
  Stream<WidgetSnapshot> get snapshots;

  /// 状态流（loading/ready/unavailable），带 5 秒可用性宽限期。
  Stream<WidgetSnapshotState> get states;

  /// 当前状态（同步可读）。
  WidgetSnapshotState get state;

  /// 开始监听；幂等。快照路径默认
  /// `$XDG_DATA_HOME/kos/pim/widget-snapshot.json`（环境变量缺失时
  /// `$HOME/.local/share`，对齐 PimWidgetService.qml:10-14）。
  void start();

  /// 停止监听并关闭流。
  void dispose();
}
