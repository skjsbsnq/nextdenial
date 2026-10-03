/// KOS DeskCenter 活动统计小部件（`KosActivityCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 activity 分支（Loader
/// :1514-1647）——左右双栏：左侧「已开机」标签 + 60 日开机时长热力图
/// （悬停改显 `key · 开机时长：x`），右侧今日前台应用时长榜（前 8 条）。
/// 数据对齐 `ActivityUsageService.qml`（活动区读 `activity.snapshot`
/// `result.activity` 的 `uptimeByDay`/`todayApps`，前台应用经
/// `activity.active-app` 上报给服务端结算）。
///
/// Denial 侧数据源（docs/widgets/activity.md）：
/// - 开机时长热力图：`KosDataClient` `activity.snapshot` →
///   [ActivitySnapshot] 注入（uptimeByDay 由服务端 journald 结算，跨进程
///   准确）；
/// - 应用时长榜：SDK `ShellWindowServices.windows(monitorId)` 只给当前
///   窗口快照（services.dart:64-77），无事件流也无累计时长——本端以
///   [ActivityTracker] 周期轮询取 `active` 窗口累计近似（widget 生命周期
///   内有效）。服务侧 `activity.active-app` 上报接口已就绪但当前未接线：
///   kos-data.sock 服务于 Denial 会话中不可达（socket 缺失），且插件的
///   surface 生命周期短于会话，上报会与服务端结算重复（见
///   docs/visual-deltas.md §9）。轮询不可行（services/monitorId 缺失）时
///   榜单空态，仅剩热力图——降级项已记 deltas。
///
/// 布局逐项（源行号锚点，根
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 内容体（:1522-1526）：四边 15 内边距，clip；
/// - 左栏（:1528-1588）：宽 `(bodyW − 20)/2`（paneGap 20，:1526）；表头
///   高 0.3h 内 `Text` 垂直居中——悬停日 `key · 开机时长：x` 否则
///   「已开机：今日秒数」（:1541-1551）；热力图（:1552-1587）10 列、
///   行列间距 3、方格 `max(4, (w − 27)/10)`、radius 2、level=
///   `min(1, seconds/28800)` 控色；
/// - 右栏（:1590-1643）：同左栏宽，垂直居中 Column、行距 2、行高 16：
///   图标 12×12 + 名称（10px、elide、icon+6/duration−6）+ 时长
///   （9px 右对齐）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';

import '../layout/widget_layout.dart' show WidgetSize;
import 'desk_card.dart';

/// `activity.snapshot` `result.activity` 投影（data-service main.go:73-89
/// `Activity` 结构 + ActivityUsageService.qml:30-35 读取键
/// `uptimeByDay`/`todayApps`）。
final class ActivitySnapshot {
  const ActivitySnapshot({
    this.uptimeByDay = const {},
    this.todayApps = const [],
  });

  /// `uptimeByDay`：`yyyy-MM-dd` → 当日开机秒数（main.go:85
  /// `map[string]float64`）。
  final Map<String, double> uptimeByDay;

  /// `todayApps` 按 `seconds` 降序的条目表（对齐 `todayApps()`，
  /// ActivityUsageService.qml:44-47）。
  final List<ActivityAppEntry> todayApps;

  /// 解包后的 `activity` 对象解析（容器层负责取 `result.activity`——对齐
  /// `response.result?.activity ?? response.result`，:32）。键名与
  /// main.go:73-89 JSON tag 逐项一致；`todayAppsDay`/`journalSeeded`/
  /// `active`/`activeApp` 为服务端记账字段，卡面不读故不投影。
  factory ActivitySnapshot.fromJson(Map<String, Object?> activity) {
    double numOrZero(Object? v) => switch (v) {
      // NaN/Infinity 一并归零，与 uptimeByDay 的 isFinite 门一致。
      final num n when n.isFinite => n.toDouble(),
      _ => 0.0,
    };
    final uptime = <String, double>{};
    // :58 `Number(uptimeByDay[key]) || 0` 的等价容错：非数值及
    // NaN/Infinity（JS Number 语义下 `NaN||0 → 0`，Dart 侧直接丢弃该键，
    // 避免 NaN 进入 kosFormatDuration/_cellColor）键值丢弃。
    if (activity['uptimeByDay'] case final Map raw) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is num && value.isFinite) {
          uptime[entry.key.toString()] = value.toDouble();
        }
      }
    }
    final apps = <ActivityAppEntry>[];
    // `todayAppsById` 是 id → {name, icon, seconds} 映射（main.go:81），
    // `todayApps()` 展开为 {id, ...} 再按 seconds 降序（:44-47）。
    if (activity['todayApps'] case final Map raw) {
      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final value = entry.value as Map;
        apps.add(
          ActivityAppEntry(
            id: entry.key.toString(),
            name: value['name']?.toString() ?? '',
            icon: value['icon']?.toString() ?? '',
            seconds: numOrZero(value['seconds']),
          ),
        );
      }
    }
    apps.sort((a, b) => b.seconds.compareTo(a.seconds)); // :46
    return ActivitySnapshot(
      uptimeByDay: Map.unmodifiable(uptime),
      todayApps: List.unmodifiable(apps),
    );
  }
}

/// 一条前台应用时长记录：`{id, name, icon, seconds}`（:1596 行渲染字段 +
/// main.go:73-77 `AppUsage`）。`icon` 为源端主题图标名/路径，当前无 SDK
/// 图标通道，保留字段未渲染（deltas §9）。
final class ActivityAppEntry {
  const ActivityAppEntry({
    required this.id,
    this.name = '',
    this.icon = '',
    this.seconds = 0.0,
  });

  /// 桌面应用 id（源 `desktopId`；Denial 侧为 `ApplicationWindow.appId`）。
  final String id;

  /// 显示名；空时行内显 `id`（:1635 `modelData.name || modelData.id`）。
  final String name;

  /// 图标（源 IconImage source，:1614）；保留未渲染。
  final String icon;

  /// 累计前台秒数。
  final double seconds;
}

/// 窗口投影条目的轻量等价物（`ApplicationWindow` 中活动跟踪所需的字段
/// 子集，services.dart:22-40）。`ActivityWindowReader` 返回此形态而非
/// SDK 类型，保持 tracker 契约可在纯 Dart 测试中以假窗口驱动。
final class ActivityWindowRow {
  const ActivityWindowRow({
    required this.id,
    required this.appId,
    required this.title,
    required this.active,
    this.minimized = false,
  });

  /// 窗口 id（`ApplicationWindow.id`）。
  final int id;

  /// 应用 id（`ApplicationWindow.appId`）。
  final String appId;

  /// 窗口标题（`ApplicationWindow.title`；源端取 `identity.name`，
  /// ActivityUsageService.qml:66）。
  final String title;

  /// 是否前台（`ApplicationWindow.active`）。
  final bool active;

  /// 是否最小化（`ApplicationWindow.minimized`）。
  final bool minimized;
}

/// 窗口列表读取回调：`services.windows(monitorId)` 当前值的投影。
typedef ActivityWindowReader = List<ActivityWindowRow> Function();

/// 应用名解析回调：`appId` → 显示名；null/未匹配回退 `appId`
/// （对齐 :1635 `name || id`）。
typedef ActivityAppNameResolver = String? Function(String appId);

/// `formatDuration`（DeskCenterWindow.qml:144-149）逐行移植：
/// `max(0, round(s))` → `h>0 ? "$h小时[min分]" : "$min分"`。
/// 本端补 `<1分` 档：<60 秒的非零时长显示「<1分」而非「0分」——源端
/// uptime 由服务端按启动会话累计（天然 ≥1 分钟量级），插件侧 tracker 从
/// surface 起算、首个周期常为几十秒，直接归 0 会让热力图/榜单看似空数据。
String kosFormatDuration(num seconds) {
  final total = math.max(0, seconds.round());
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (hours <= 0 && minutes <= 0 && total > 0) return '<1分';
  return hours > 0 ? '$hours小时${minutes > 0 ? '$minutes分' : ''}' : '$minutes分';
}

/// `dayKey`（ActivityUsageService.qml:25-27 `Qt.formatDate("yyyy-MM-dd")`）。
String kosDayKey(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}-'
    '${time.month.toString().padLeft(2, '0')}-'
    '${time.day.toString().padLeft(2, '0')}';

/// `recentUptimeDays`（ActivityUsageService.qml:49-61）：从今天 0 点往前
/// 取 [count] 天（含今天），每天 `{key, seconds}`，缺日补 0。
List<({String key, double seconds})> kosRecentUptimeDays(
  Map<String, double> uptimeByDay,
  int count, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final start = DateTime(
    today.year,
    today.month,
    today.day,
  ).subtract(Duration(days: count - 1));
  return [
    for (var i = 0; i < count; i++)
      (() {
        final date = start.add(Duration(days: i));
        final key = kosDayKey(date);
        return (key: key, seconds: uptimeByDay[key] ?? 0.0);
      })(),
  ];
}

/// 前台应用时长跟踪器：SDK 无窗口事件流与累计时长
/// （`ShellWindowServices.windows` 只给当前快照，services.dart:66），本类
/// 以周期轮询累计近似——每次 [tick] 读窗口表，把距上次 tick 的实耗时长
/// 记给 `active && !minimized` 窗口的 appId（显示名取
/// `resolveName(appId)`，对齐源端上报 `{appID,name,icon}` 的键语义，
/// ActivityUsageService.qml:63-83）。
///
/// 精度差异（docs/visual-deltas.md §9）：粒度 = tick 周期（5s），周期内
/// 的窗口切换记到采样时刻的前台；插件 surface 生命周期外的时长不累计
/// （源端由 kos-data-service 跨进程结算）；无前台窗口的周期不归属任何
/// 应用（对齐源端 `appID==""` 停止归属，:77-78 注释）。
/// 使用方式二选一：
/// - 外部驱动（本插件）：周期调用 [tick]，自带时钟推进，不启动内部
///   Timer——便于测试注入假时钟，也便于容器 tick 后 setState；
/// - 内部驱动：[start]/[stop] 以 `Timer.periodic(tickPeriod)` 调 [tick]
///   （`scheduleTick` 注入时改由注入方调度）。
///
/// TASK-18：本 tracker 同时累计按日分桶的开机时长（[tick] 按 `_clock`
/// 差分计入 [uptimeByDay]，跨天翻转拆到各自桶；`stop()` 时段不计——与
/// 源端「插件存活期累计」语义一致）。[seedUptimeByDay]/[seedFromEntries]
/// 为 ledger 恢复接缝：历史天数直接灌桶（当日键取较大值防回退），
/// 当日 app 秒数按 id 灌回（之后 tick 在其上续计）。
class ActivityTracker {
  // （_scheduleTick 为私有字段，private 命名参数不能作 initializing
  //  formal——手工赋值；prefer_initializing_formals 用行内 ignore。）
  ActivityTracker({
    required this.windows,
    this.resolveName,
    this.tickPeriod = const Duration(seconds: 5),
    DateTime Function()? clock,
    // 排程注入（测试）；null → Timer.periodic。
    void Function(Duration period, void Function() body)? scheduleTick,
  }) : _clock = clock ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _scheduleTick = scheduleTick;

  /// 窗口表读取（容器侧绑定 `services.windows(monitorId)` 当前值投影）。
  final ActivityWindowReader windows;

  /// 应用显示名解析（默认 `appId`）。
  final ActivityAppNameResolver? resolveName;

  /// 轮询周期（注入便于测试）。任务卡约定 5s。
  final Duration tickPeriod;

  final DateTime Function() _clock;
  final void Function(Duration period, void Function() body)? _scheduleTick;
  Timer? _timer;
  bool _running = true; // 外部驱动模式默认处于累计态（tick 直接可用）
  bool _scheduled = false;
  DateTime? _lastTick;
  String? _activeAppId;
  final Map<String, ActivityAppEntry> _apps = {};

  /// 按日分桶的开机秒数（`yyyy-MM-dd` → 秒；TASK-18）。stop() 时段不计。
  final Map<String, double> _uptimeByDay = {};
  /// 排序后的榜单（`seconds` 降序；对齐 `todayApps()` :44-47）。
  List<ActivityAppEntry> get entries {
    final list = _apps.values.toList()
      ..sort((a, b) => b.seconds.compareTo(a.seconds));
    return List.unmodifiable(list);
  }

  /// 按日分桶的开机时长（`yyyy-MM-dd` → 秒，不可变视图；TASK-18）。
  /// 容器 tick 时按 `_clock` 差分续计；`stop()` 时段不计。
  Map<String, double> get uptimeByDay => Map.unmodifiable(_uptimeByDay);

  /// TASK-18 恢复接缝：灌入持久化的开机分桶。当日（按 `_clock` 判定）
  /// 的键取 `max(已有, 灌入)`——tracker 自 tick 起已在当日桶续计，
  /// ledger 恢复到的值不得回退；非当日键直接覆盖（tracker 只新增当日）。
  void seedUptimeByDay(Map<String, double> uptimeByDay) {
    final todayKey = kosDayKey(_clock());
    for (final entry in uptimeByDay.entries) {
      if (!entry.value.isFinite || entry.value <= 0) continue;
      if (entry.key == todayKey) {
        _uptimeByDay[entry.key] = math.max(
          _uptimeByDay[entry.key] ?? 0,
          entry.value,
        );
      } else {
        _uptimeByDay[entry.key] = entry.value;
      }
    }
  }

  /// TASK-18 恢复接缝：把持久化的当日 app 秒数灌回榜（同 id 覆盖
  /// seconds，保留灌入的 name/icon；之后 tick 在其上续计）。
  void seedFromEntries(List<ActivityAppEntry> entries) {
    for (final entry in entries) {
      if (entry.id.isEmpty || !entry.seconds.isFinite) continue;
      _apps[entry.id] = ActivityAppEntry(
        id: entry.id,
        name: entry.name.isNotEmpty ? entry.name : entry.id,
        icon: entry.icon,
        seconds: entry.seconds,
      );
    }
  }

  /// 最近一次 tick 观察到的前台应用 id（无 → null）。
  String? get activeAppId => _activeAppId;

  /// 启动内部轮询（幂等；stop 后再调可恢复累计）。外部驱动用法不需要
  /// 调用——tracker 默认即处于累计态，外部直接调 [tick]。
  void start() {
    if (_scheduled) return;
    _scheduled = true;
    _running = true;
    _lastTick ??= _clock();
    if (_scheduleTick != null) {
      _scheduleTick(tickPeriod, tick);
    } else {
      _timer = Timer.periodic(tickPeriod, (_) => tick());
    }
  }

  /// 停止累计（dispose 语义）。置 [_running]=false 使注入的
  /// `scheduleTick` 继续回调 [tick] 时也成为空转——注入调度器不受
  /// `_timer.cancel()` 控制，只能靠 tick 守卫截停。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _scheduled = false; // 允许 start() 重新武装调度
    _lastTick = null;
  }

  /// 一次采样：把距上次 tick 的实耗时长记给当前前台窗口的 appId，
  /// 返回当前前台 appId（无 → null）。首次调用仅建立基准时刻不计时。
  /// [stop] 之后为空操作（覆盖注入 `scheduleTick` 持有的 tick 回调）。
  String? tick() {
    if (!_running) return _activeAppId;
    final now = _clock();
    final last = _lastTick;
    _lastTick = now;
    final active = _activeWindow();
    final appId = active?.appId;
    if (last != null) {
      final elapsed = now.difference(last).inMilliseconds / 1000.0;
      if (elapsed > 0) {
        // TASK-18：开机时长按日分桶——无论是否有前台应用都计入
        // （源端 uptime 由服务端跨进程结算；插件侧 tracker 存活期近似，
        // 跨天翻转拆到各自桶）。
        _uptimeByDay[kosDayKey(now)] =
            (_uptimeByDay[kosDayKey(now)] ?? 0) + elapsed;
        if (appId != null && appId.isNotEmpty) {
          final previous = _apps[appId];
          // 显示名回退链：resolver → 已记录名 → appId（:1635 `name||id`）。
          _apps[appId] = ActivityAppEntry(
            id: appId,
            name: resolveName?.call(appId) ?? previous?.name ?? appId,
            icon: previous?.icon ?? '',
            seconds: (previous?.seconds ?? 0) + elapsed,
          );
        }
      }
    }
    _activeAppId = appId;
    return appId;
  }

  /// `WindowService.windowById(activeWindowId)`（:64）的轮询等价：
  /// 快照中 `active && !minimized` 的首个窗口。
  ActivityWindowRow? _activeWindow() {
    for (final row in windows()) {
      if (row.active && !row.minimized) return row;
    }
    return null;
  }
}

/// activity 卡内容色板：`content.ink`/`glassContentColor` 分支的注入形式。
/// TASK-09 起卡片统一吃 Denial ShellTheme 材质（等价 material/onBackdrop），
/// `onBackdrop`/色艺 `cellFillBase` 分叉删除；明暗色板按
/// `context.shellTheme` 解析（[KosActivityCardColors.forShell]——插件表面下
/// 没有 MaterialApp/Theme 祖先，Theme.of 恒回退 light 基线，真实亮度/墨色
/// 走 shell `textPrimary`/`textSecondary`）。
final class KosActivityCardColors {
  const KosActivityCardColors({
    this.headerInk = const Color(0xDB49454F), // ink(_,0.86) :1548 近似（回退常量）
    this.appNameInk = const Color(0xC749454F), // ink(_,0.78) :1637 近似
    this.appDurationInk = const Color(0x7549454F), // ink(_,0.46) :1630 近似
    this.cellEmpty = const Color(0x14FFFFFF), // rgba(1,1,1,0.08) :1574
    this.cellFill = const Color(0xFFFFFFFF), // 热力格基色白（:1576 白系 ramp）
  });

  /// 按 ShellTheme 取默认色板：
  /// - 表头/应用名 → shell `textPrimary`；
  /// - 时长 → shell `textSecondary`；
  /// - `cellEmpty`（无开机格底）保留 rgba(1,1,1,0.08) 白-alpha——热力格恒为
  ///   半透明卡面上的浅色叠加，亮壳下同样可读（热图是数据 viz，不走文字
  ///   墨色）；`cellFill`（level>0 格填充基色）→ `textPrimary`，明暗壳随
  ///   卡面文字同调。
  static KosActivityCardColors forShell(ShellThemeData theme) {
    final colors = theme.colors;
    return KosActivityCardColors(
      headerInk: colors.textPrimary, // :1548 ink → textPrimary
      appNameInk: colors.textPrimary, // :1637 ink → textPrimary
      appDurationInk: colors.textSecondary, // :1630 ink → textSecondary
      cellFill: colors.textPrimary, // :1576 白系 ramp 基色 → textPrimary
    );
  }

  /// 表头文字色（:1548 `ink(rgba(1,1,1,0.86),0.86)` → shell `textPrimary`）。
  final Color headerInk;

  /// 应用名色（:1637 `ink(rgba(1,1,1,0.78),0.78)` → shell `textPrimary`）。
  final Color appNameInk;

  /// 时长色（:1630 `ink(rgba(1,1,1,0.46),0.46)` → shell `textSecondary`）。
  final Color appDurationInk;

  /// 无开机时长格底色（:1574 `rgba(1,1,1,0.08)`；白-alpha 叠加，明暗壳通用）。
  final Color cellEmpty;

  /// level>0 热力格填充基色（:1576 onBackdrop 白系 ramp → shell
  /// `textPrimary`；`0.22+level*0.72` alpha 由 `_cellColor` 施加）。
  final Color cellFill;
}
/// 应用行左侧 12×12 图标的解析回调（`IconImage`，:1610-1625）：返回
/// null 时卡内渲染空占位盒。
typedef ActivityIconBuilder = Widget? Function(
  BuildContext context,
  ActivityAppEntry entry,
);

/// DeskCenter 活动统计卡（`modelData.id === "activity"`，:1514-1647）。
///
/// [snapshot]/[apps] 均为注入数据：snapshot 经 `activity.snapshot`，
/// apps 由容器侧 `ActivityTracker.entries` 供给（可能为空——窗口源不可
/// 用时榜单空态，热力图照常渲染）。
class KosActivityCard extends StatefulWidget {
  const KosActivityCard({
    super.key,
    this.snapshot,
    this.apps = const [],
    this.iconBuilder,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onRemove,
    this.onCycleSize,
    this.clock,
  });

  /// `activity.snapshot` 投影；null → uptimeByDay 空、热力图全 0 档
  /// （对齐源端 `ready=false` 前的空对象读取，:33-37）。
  final ActivitySnapshot? snapshot;

  /// 今日前台应用榜（全量；截 8 在 build 内做，对齐 :1596 `slice(0,8)`）。
  final List<ActivityAppEntry> apps;

  /// 应用图标构建器；null 用占位盒。
  final ActivityIconBuilder? iconBuilder;

  /// 内容色板；null → build 时按 `context.shellTheme` 解析
  /// （[KosActivityCardColors.forShell]）。
  final KosActivityCardColors? colors;

  /// 尺寸档位（透传 [DeskCard.size]）。
  final WidgetSize size;


  /// 编辑模式角标。
  final bool editMode;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  /// 「今天」判定的时钟注入（测试用）；默认 `DateTime.now()`。
  final DateTime Function()? clock;

  @override
  State<KosActivityCard> createState() => _KosActivityCardState();
}

class _KosActivityCardState extends State<KosActivityCard> {
  /// `uptimeHeatmap.hoveredDay`（:1558）：悬停格，null 时表头显今日累计。
  ({String key, double seconds})? _hoveredDay;

  /// paneGap（:1526）。
  static const double _kPaneGap = 20;

  /// build 内解析的实效色板（[KosActivityCard.colors] 显式注入优先，否则
  /// 按 `context.shellTheme`）——供 `_buildLeftPane`/`_buildRightPane`/
  /// `_cellColor` 在 LayoutBuilder 回调外复用。
  late KosActivityCardColors _resolvedColors;

  @override
  Widget build(BuildContext context) {
    _resolvedColors =
        widget.colors ?? KosActivityCardColors.forShell(context.shellTheme);
    return DeskCard(
      size: widget.size,
      editMode: widget.editMode,
      onRemove: widget.onRemove,
      onCycleSize: widget.onCycleSize,
      child: Padding(
        // activityBody margins 15（:1524）。
        padding: const EdgeInsets.all(15),
        child: ClipRect(
          // :1525 `clip: true`
          child: LayoutBuilder(
            builder: (context, body) {
              final paneWidth =
                  (body.maxWidth - _kPaneGap) / 2; // :1532、:1592-1594
              return Row(
                children: [
                  SizedBox(
                    width: paneWidth,
                    height: body.maxHeight,
                    child: _buildLeftPane(body.maxHeight),
                  ),
                  const SizedBox(width: _kPaneGap),
                  SizedBox(
                    width: paneWidth,
                    height: body.maxHeight,
                    child: _buildRightPane(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 左栏（:1528-1588）：表头 0.3h + 热力图填满余下高度。
  Widget _buildLeftPane(double height) {
    final snapshot = widget.snapshot;
    final now = (widget.clock ?? DateTime.now)();
    final todaySeconds = snapshot?.uptimeByDay[kosDayKey(now)] ?? 0.0;
    final hovered = _hoveredDay;
    // :1541-1548 表头文案：hoveredDay ? "key · 开机时长：x" : "已开机：今日"。
    final header = hovered != null
        ? '${hovered.key} · 开机时长：${kosFormatDuration(hovered.seconds)}'
        : '已开机：${kosFormatDuration(todaySeconds)}';
    final days = kosRecentUptimeDays(
      snapshot?.uptimeByDay ?? const {},
      60, // recentUptimeDays(60)（:1567）
      now: now,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height * 0.3, // activityUptimeHeader（:1540）
          child: Align(
            // :1542 `anchors.verticalCenter`
            alignment: Alignment.centerLeft,
            child: Text(
              header,
              style: TextStyle(
                color: _resolvedColors.headerInk,
                fontFamily: 'SF Pro Display', // :1549
                fontSize: 14, // :1549
                fontWeight: FontWeight.w600, // Font.DemiBold
                height: 1,
              ),
            ),
          ),
        ),
        Expanded(
          // uptimeHeatmap（:1552-1587）：10 列 Grid、row/columnSpacing 3、
          // 方格 `max(4,(w-27)/10)`、radius 2。
          // F2 修复：显式 6 行 × 10 列的 Column/Row 取代 Wrap——Wrap 贪心
          // 换行在 `cell=(w−27)/10` 浮点 ulp 下可能某行只放 9 格造成坍行。
          child: LayoutBuilder(
            builder: (context, heat) {
              // :1570 cell 宽 = max(4,(w−27)/10)：10 格 + 9 个 spacing 3。
              final cell = math.max(4.0, (heat.maxWidth - 27) / 10);
              Widget cellAt(int index) => SizedBox(
                width: cell,
                height: cell, // :1571 `height: width`
                child: MouseRegion(
                  // :1578-1583 hoverEnabled + onEntered/onExited。
                  onEnter: (_) => setState(() => _hoveredDay = days[index]),
                  onExit: (_) => setState(() => _hoveredDay = null),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2), // :1572
                      color: _cellColor(days[index].seconds),
                    ),
                  ),
                ),
              );
              return Column(
                children: [
                  for (var row = 0; row < 6; row++) ...[
                    if (row > 0) const SizedBox(height: 3), // rowSpacing（:1564）
                    Row(
                      children: [
                        for (var col = 0; col < 10; col++) ...[
                          if (col > 0)
                            const SizedBox(width: 3), // columnSpacing（:1565）
                          cellAt(row * 10 + col),
                        ],
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// :1573-1577 格色：`level<=0 → cellEmpty`（rgba(1,1,1,0.08)）；否则
  /// `cellFill`（:1576 onBackdrop 白系 ramp → shell `textPrimary`）按
  /// `0.22+0.72·level` alpha 叠加。热图格为半透明卡面上的浅色数据 viz，
  /// 不走文字墨色。
  Color _cellColor(double seconds) {
    final level = math.min(1.0, seconds / (8 * 3600)); // :1573
    if (level <= 0) return _resolvedColors.cellEmpty;
    final alpha = 0.22 + level * 0.72;
    return _resolvedColors.cellFill.withValues(alpha: alpha); // :1576
  }

  /// 右栏（:1590-1643）：`todayApps().slice(0,8)` 行列表，垂直居中。
  Widget _buildRightPane() {
    final entries = widget.apps.take(8).toList(); // :1596
    return Center(
      // appUsageList `anchors.verticalCenter`（:1601），spacing 2（:1602）。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            _AppUsageRow(
              entry: entries[i],
              colors: _resolvedColors,
              iconBuilder: widget.iconBuilder,
            ),
          ],
        ],
      ),
    );
  }
}

/// 一条应用时长行（:1605-1640）：高 16，图标 12×12 左 + 名称中（elide，
/// 左 6 右 6）+ 时长右。
class _AppUsageRow extends StatelessWidget {
  const _AppUsageRow({
    required this.entry,
    required this.colors,
    this.iconBuilder,
  });

  final ActivityAppEntry entry;
  final KosActivityCardColors colors;
  final ActivityIconBuilder? iconBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16, // :1609
      child: Row(
        children: [
          SizedBox(
            width: 12, // :1612
            height: 12, // :1613
            child:
                iconBuilder?.call(context, entry) ??
                const SizedBox.expand(), // 图标占位（IconImage 空 source 等价）
          ),
          Expanded(
            // :1633-1638 名称：left/rightMargin 6、ElideRight、10px。
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                entry.name.isNotEmpty ? entry.name : entry.id, // :1635
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: colors.appNameInk,
                  fontSize: 10, // :1638
                  height: 1,
                ),
              ),
            ),
          ),
          Text(
            kosFormatDuration(entry.seconds), // :1629
            style: TextStyle(
              color: colors.appDurationInk,
              fontFamily: 'SF Pro Display', // :1631
              fontSize: 9, // :1631
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
