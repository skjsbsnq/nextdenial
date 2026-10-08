/// TASK-18：activity / uptime 持久化（`ActivityLedger`）。
///
/// 源端 kos-data-service 把 `uptimeByDay`/前台应用时长跨进程结算并写盘
/// （docs/TASK-18-activity-persistence.md）；插件内嵌后由本 store 补回这份
/// 持久化——`ActivityTracker` 的 `uptimeByDay` + `entries` 周期 debounce 落盘，
/// 启动时读回恢复历史天数与当日 app 秒数。
///
/// JSON schema（`activity-ledger.json`，自描述；损坏/schemaVersion 不符 →
/// 空态不抛）：
/// ```json
/// {
///   "schemaVersion": 1,
///   "uptimeByDay": {"yyyy-MM-dd": 秒数},
///   "apps": [{"id": "…", "name": "…", "icon": "…", "day": "yyyy-MM-dd",
///             "seconds": 秒数}]
/// }
/// ```
/// `apps` 记录的是[ActivityLedgerAppEntry.day]（`yyyy-MM-dd`）这一天的前台
/// 应用时长；恢复时按当日 `kosDayKey` 过滤（跨日榜单源端无语义，只恢复
/// 当日条目进 `ActivityTracker`）。
///
/// 接缝对齐 `pim_store.dart`/`desk_center_config_io.dart` 范式：
/// [ActivityLedgerStorage] 抽象（read/write String）+
/// [FileActivityLedgerStorage]（dart:io，`*.tmp`+rename 原子写）+
/// [MemoryActivityLedgerStorage]（测试/预览）。写请求经 [ActivityLedger.update]
/// 标记 dirty + `saveDebounce`（~1.2s）合并落盘；[ActivityLedger.dispose]
/// 时 flush 尾部变更。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条持久化的前台应用时长记录（schema `apps[]` 条目）。
final class ActivityLedgerAppEntry {
  const ActivityLedgerAppEntry({
    required this.id,
    this.name = '',
    this.icon = '',
    this.day = '',
    this.seconds = 0.0,
  });

  /// 桌面应用 id（`ActivityAppEntry.id`）。
  final String id;

  /// 显示名；空时消费端回退 `id`。
  final String name;

  /// 图标名（保留未渲染，对齐 `ActivityAppEntry.icon`）。
  final String icon;

  /// 记录归属日（`yyyy-MM-dd`）；恢复时按调用方的「今日」过滤。
  final String day;

  /// 累计前台秒数。
  final double seconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'day': day,
    'seconds': seconds,
  };

  static ActivityLedgerAppEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final seconds = raw['seconds'];
    return ActivityLedgerAppEntry(
      id: id,
      name: raw['name']?.toString() ?? '',
      icon: raw['icon']?.toString() ?? '',
      day: raw['day']?.toString() ?? '',
      seconds: seconds is num && seconds.isFinite ? seconds.toDouble() : 0.0,
    );
  }
}

/// ledger 持久化 IO 注入点：读返回 null 表示缺失/不可读；写须原子
/// （`tmp + rename`），失败自行吞掉。
abstract interface class ActivityLedgerStorage {
  /// 读 ledger 文本；文件缺失/不可读返回 null。
  Future<String?> read();

  /// 原子写（实现须 `tmp + rename` 语义；失败自行吞掉）。
  Future<void> write(String contents);
}

/// `dart:io` 实现（生产路径）：`[path]` + `.tmp` rename 原子写；
/// 目录缺失先创建。
final class FileActivityLedgerStorage implements ActivityLedgerStorage {
  const FileActivityLedgerStorage(this.path);

  /// ledger 文件路径（默认见 [defaultActivityLedgerPath]）。
  final String path;

  @override
  Future<String?> read() async {
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String contents) async {
    try {
      await File(path).parent.create(recursive: true);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(contents, flush: true);
      await tmp.rename(path);
    } on Object {
      // 落盘失败不阻断内存态（对齐 DeskCenterConfigStore/PimStore 语义）。
    }
  }
}

/// 默认 ledger 路径：`$XDG_STATE_HOME/denial/kos_deskcenter/
/// activity-ledger.json`（同 `config.json` 的目录约定，
/// desk_center_config_io.dart:33-38）；XDG_STATE_HOME 缺失时
/// `$HOME/.local/state/...`。[environment] 可注入便于测试。
String defaultActivityLedgerPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final stateHome =
      env['XDG_STATE_HOME'] ?? '${env['HOME'] ?? ''}/.local/state';
  return '$stateHome/denial/kos_deskcenter/activity-ledger.json';
}

/// 内存实现（测试/预览）：`testWidgets` 的 fake-async 区不驱动真实文件
/// IO（await 会永不完成）——widget 测试一律注入本实现。
final class MemoryActivityLedgerStorage implements ActivityLedgerStorage {
  /// 已写入的最新文本（null = 从未写入/读缺失）。
  String? contents;

  /// 写调用计数（debounce 合并断言用）。
  int writeCount = 0;

  @override
  Future<String?> read() async => contents;

  @override
  Future<void> write(String contents) async {
    writeCount += 1;
    this.contents = contents;
  }
}

/// activity/uptime 持久化 store。
///
/// 用法：`await ledger.load()` 后读 [uptimeByDay]/[apps] 恢复 tracker 与
/// 快照；容器每次活动 tick 后调 [update] 提交最新内存态，写请求经
/// `saveDebounce` 合并落盘。
final class ActivityLedger {
  ActivityLedger({ActivityLedgerStorage? storage, Duration? saveDebounce})
    : _storage =
          storage ?? FileActivityLedgerStorage(defaultActivityLedgerPath()),
      _saveDebounce = saveDebounce ?? const Duration(milliseconds: 1200);

  final ActivityLedgerStorage _storage;
  final Duration _saveDebounce;

  Timer? _saveTimer;
  bool _dirty = false;
  bool _disposed = false;

  Map<String, double> _uptimeByDay = const {};
  List<ActivityLedgerAppEntry> _apps = const [];

  /// 落盘 schema 版本（不符/缺失 → 空态）。
  static const int schemaVersion = 1;

  /// 保留窗口（天）：day key 为 `yyyy-MM-dd`，字典序即日期序；uptime 与
  /// app 条目只留最近 90 天（UI 热力图 `kosRecentUptimeDays` 取 60 天，留
  /// 余量避免 socket 恢复的历史被 ledger 裁短），防跨天/跨 app 无界增长。
  static const int _retainedDays = 90;

  /// 是否已有内存态（load 后有内容或 update 被调过）。
  bool get hasData => _uptimeByDay.isNotEmpty || _apps.isNotEmpty;

  /// 当前 `uptimeByDay`（`yyyy-MM-dd` → 秒，不可变视图）。
  Map<String, double> get uptimeByDay => Map.unmodifiable(_uptimeByDay);

  /// 当前 app 条目（不可变视图）。
  List<ActivityLedgerAppEntry> get apps => List.unmodifiable(_apps);

  /// 读盘恢复；文件缺失/损坏/schemaVersion 不符 → 空态不抛
  /// （对齐 `DeskCenterConfigStore.load` 的兜底链）。重复调用重新读盘。
  Future<void> load() async {
    final uptime = <String, double>{};
    final apps = <ActivityLedgerAppEntry>[];
    try {
      final text = await _storage.read();
      final decoded = text == null ? null : jsonDecode(text);
      if (decoded is Map && decoded['schemaVersion'] == schemaVersion) {
        if (decoded['uptimeByDay'] case final Map raw) {
          for (final entry in raw.entries) {
            final value = entry.value;
            // 非有限值/非正值丢键（NaN/Infinity 不进入热力图，对齐
            // ActivitySnapshot.fromJson 的容错语义）。
            if (value is num && value.isFinite && value > 0) {
              uptime[entry.key.toString()] = value.toDouble();
            }
          }
        }
        if (decoded['apps'] case final List raw) {
          for (final item in raw) {
            final entry = ActivityLedgerAppEntry.fromJson(item);
            if (entry != null) apps.add(entry);
          }
        }
      }
    } on Object {
      // JSON 损坏 → 空态（只读失败不覆写坏盘）。
    }
    _uptimeByDay = uptime;
    _apps = apps;
    _prune();
  }

  /// 提交最新内存态并调度 debounce 落盘（多次调用合并为一次写）。
  ///
  /// [uptimeByDay] 非 null 时**逐键 max 合并**（历史键不回退；restore 未
  /// 完成的早期 tick 里 tracker 只有当日新累计，直接覆盖会清掉 ledger 已
  /// load 的历史天数）；[apps] 非 null 时**按 `(day,id)` 合并取 max**——
  /// 前台 app，直接全量覆盖会把 ledger 里当日已恢复的历史 app 清空；合并使
  /// 当日条目不丢、跨日条目（其它 day）保留。`apps` 为 null 只触发调度。
  /// load 前的 update 也允许——内存态为权威，load 完成会覆盖之（容器先
  /// load 再接线 tick）。
  void update({
    Map<String, double>? uptimeByDay,
    List<ActivityLedgerAppEntry>? apps,
  }) {
    if (_disposed) return;
    if (uptimeByDay != null) {
      // 逐键 max 合并而非全量替换：restore 尚未完成的早期 tick 里 tracker
      // 只有当日新累计，直接覆盖会把 ledger 已 load 的历史天数清掉。
      final merged = <String, double>{..._uptimeByDay};
      for (final entry in uptimeByDay.entries) {
        final prev = merged[entry.key] ?? 0;
        merged[entry.key] = entry.value > prev ? entry.value : prev;
      }
      _uptimeByDay = Map<String, double>.unmodifiable(merged);
    }
    if (apps != null) {
      // (day,id) → 合并条目；同键取较大 seconds（tracker 重启后新累计
      // 小于 ledger 已存值时不回退），name/icon 以新条目为准。
      final merged = <String, ActivityLedgerAppEntry>{
        for (final a in _apps) '${a.day} ${a.id}': a,
      };
      for (final next in apps) {
        final key = '${next.day} ${next.id}';
        final prev = merged[key];
        merged[key] = (prev == null || next.seconds >= prev.seconds)
            ? next
            : prev;
      }
      _apps = List<ActivityLedgerAppEntry>.unmodifiable(merged.values);
    }
    _prune();
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(flush()));
  }

  /// 裁剪到最近 [_retainedDays] 天：以全部 day key（uptime 键 ∪ app.day）
  /// 排序取后 N 个为保留集，uptime 删窗口外键、apps 删窗口外条目。
  void _prune() {
    final days = <String>{
      ..._uptimeByDay.keys,
      for (final app in _apps) app.day,
    }.toList()..sort();
    if (days.length <= _retainedDays) return;
    final retained = days.sublist(days.length - _retainedDays).toSet();
    _uptimeByDay = Map<String, double>.unmodifiable({
      for (final entry in _uptimeByDay.entries)
        if (retained.contains(entry.key)) entry.key: entry.value,
    });
    _apps = List<ActivityLedgerAppEntry>.unmodifiable([
      for (final app in _apps)
        if (retained.contains(app.day)) app,
    ]);
  }

  /// 立即落盘（防抖窗口内的尾部变更一并写入）。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_disposed || !_dirty) return;
    _dirty = false;
    await _storage.write(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'uptimeByDay': _uptimeByDay,
        'apps': [for (final app in _apps) app.toJson()],
      }),
    );
  }

  /// 停表并 flush 尾部变更（fake-async 兼容：仅 Timer + Future，无流）。
  Future<void> dispose() async {
    try {
      await flush();
    } on Object {
      // 落盘失败不阻塞销毁（内存态随实例释放）。
    }
    _disposed = true;
    _saveTimer?.cancel();
    _saveTimer = null;
  }
}
