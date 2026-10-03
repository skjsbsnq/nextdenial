/// KOS DeskCenter 活动统计详情面板（TASK-17）：`kos-activity` 卡片点击的
/// DenialUI 重写，填入 `DeskPanelShell` 内容区。
///
/// 对齐 activity 卡（`KosActivityCard`，:1514-1647）的可视语义放大：
/// - 热力图放大（`uptimeByDay` 跨 60 日、10 列方格；悬停格改显
///   `key · 开机时长：x`，同 `_buildLeftPane` 表头语义）；
/// - 今日前台应用时长榜（`ActivityTracker.entries`，名称 + 图标 + 时长）；
/// - 总开机时长（`uptimeByDay[today]`）。
///
/// 数据源（任务卡 §契约）：
/// - `uptimeByDay`：`DeskPanelData.activity`（`ActivitySnapshot`，socket
///   通道）优先；插件内嵌无 socket 时容器以 ledger 合成的快照兜底；
/// - `todayApps`：`DeskPanelData.activityTracker as ActivityTracker`
///   （tracker 无流——面板以 `Timer.periodic(5s)` 轮询对齐卡片刷新节奏）；
///   无 tracker 时榜单空态（热力图照常）；
/// - 图标：`services.buildApplicationIcon(context, appId)`（SDK
///   `ShellApplicationServices`，经 `ShellServicesScope` 下钻），无 icon
///   用占位盒（同卡 `_AppUsageRow` 的空 `SizedBox` 语义）。
///
/// DenialUI：面板材质由 `DeskPanelShell` 提供；热力图格为半透明数据 viz
/// （`cellEmpty` 白-alpha + `cellFill` 随壳 `textPrimary` 明暗解析，同
/// `KosActivityCardColors`），榜单行：图标 + 名 `textPrimary` + 时长
/// `textSecondary`；其余前景/材质走 `context.shellTheme/shellColors`。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart'
    show ShellServicesScope;
import 'package:denial_flutter_sdk/shell_color_scheme.dart'
    show ShellColorScheme;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/widgets.dart';

import 'activity_card.dart';
import 'desk_panel_shell.dart';

/// `DeskPanelBuilder` 形态的活动统计面板入口。
Widget buildActivityPanel(DeskPanelRequest request, DeskPanelData data) =>
    ActivityPanel(request: request, data: data);

/// 注册 `kos-activity` 的面板内容构造器（装配层统一调用一次，幂等）。
void registerActivityPanel() {
  registerDeskPanelBuilder('kos-activity', buildActivityPanel);
}

/// 活动统计详情面板：热力图放大 + 今日应用时长榜 + 总开机时长。
class ActivityPanel extends StatefulWidget {
  const ActivityPanel({
    required this.request,
    required this.data,
    this.snapshot,
    this.tracker,
    super.key,
  });

  /// 卡片弹出请求（无参；仅面板路由契约）。
  final DeskPanelRequest request;

  /// 当帧数据快照与数据源（`activity`/`activityTracker`）。
  final DeskPanelData data;

  /// 直接注入的 `ActivitySnapshot`（测试/预览）；null 时经 [data.activity]
  /// 取。
  final ActivitySnapshot? snapshot;

  /// 直接注入的 `ActivityTracker`（测试/预览）；null 时经
  /// [data.activityTracker] 向下转型取。
  final ActivityTracker? tracker;

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  /// 悬停热力格（同 activity 卡 `_hoveredDay` 语义）。
  ({String key, double seconds})? _hoveredDay;

  /// tracker 轮询（无流——5s 周期 setState 重建，对齐卡片
  /// `_kActivityTick` 刷新节奏）。
  Timer? _poll;

  ActivityTracker? get _tracker =>
      widget.tracker ?? widget.data.activityTracker as ActivityTracker?;

  ActivitySnapshot? get _snapshot => widget.snapshot ?? widget.data.activity;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final cardColors = KosActivityCardColors.forShell(context.shellTheme);
    final snapshot = _snapshot;
    final tracker = _tracker;
    final now = DateTime.now();
    final todayKey = kosDayKey(now);
    final todayUptime = tracker?.uptimeByDay[todayKey] ??
        snapshot?.uptimeByDay[todayKey] ??
        0.0;
    final entries = tracker?.entries ?? snapshot?.todayApps ?? const [];
    final days = kosRecentUptimeDays(
      // uptimeByDay 合并：socket 快照为主，tracker 累计的当日桶合并
      // 进去（容器侧 socket 到达时以 socket 为准合并——面板只读当帧）。
      {
        ...?snapshot?.uptimeByDay,
        ...?tracker?.uptimeByDay,
      },
      60,
      now: now,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme, colors, todayUptime),
          const SizedBox(height: 14),
          _heatmap(theme, colors, cardColors, days),
          const SizedBox(height: 14),
          _appsList(theme, colors, cardColors, entries),
        ],
      ),
    );
  }

  /// 表头：总开机时长（今日）+ 悬停日详情（同卡 `_buildLeftPane` 表头
  /// 语义——`hoveredDay ? "key · 开机时长：x" : "已开机：今日"`）。
  Widget _header(
    ShellThemeData theme,
    ShellColorScheme colors,
    double todayUptime,
  ) {
    final hovered = _hoveredDay;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '已开机',
                style: ShellText.base.copyWith(
                  color: colors.textSecondary,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              Text(
                kosFormatDuration(todayUptime),
                style: ShellText.base.copyWith(
                  color: colors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
        if (hovered != null)
          Text(
            '${hovered.key} · 开机时长：${kosFormatDuration(hovered.seconds)}',
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 11.5,
              height: 1.3,
            ),
          ),
      ],
    );
  }

  /// 热力图放大（:1552-1587 同语义）：60 天 10 列方格，hover 显日详情。
  Widget _heatmap(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosActivityCardColors cardColors,
    List<({String key, double seconds})> days,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // :1570 cell 宽 = max(4,(w-27)/10)：10 格 + 9 个 spacing 3。
        final cell = math.max(6.0, (constraints.maxWidth - 27) / 10);
        return Column(
          children: [
            for (var row = 0; row < 6; row++) ...[
              if (row > 0) const SizedBox(height: 3),
              Row(
                children: [
                  for (var col = 0; col < 10; col++) ...[
                    if (col > 0) const SizedBox(width: 3),
                    SizedBox(
                      width: cell,
                      height: cell,
                      child: MouseRegion(
                        onEnter: (_) =>
                            setState(() => _hoveredDay = days[row * 10 + col]),
                        onExit: (_) => setState(() => _hoveredDay = null),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            color: _cellColor(
                              cardColors,
                              days[row * 10 + col].seconds,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// :1573-1577 格色：`level<=0 → cellEmpty`；否则 `cellFill` 按
  /// `0.22+0.72·level` alpha 叠加（同 `KosActivityCard._cellColor`）。
  Color _cellColor(KosActivityCardColors cardColors, double seconds) {
    final level = math.min(1.0, seconds / (8 * 3600));
    if (level <= 0) return cardColors.cellEmpty;
    final alpha = 0.22 + level * 0.72;
    return cardColors.cellFill.withValues(alpha: alpha);
  }

  /// 今日前台应用时长榜（:1590-1643 同语义，放大到行高 22、图标 14、
  /// 字号 12/11）。
  Widget _appsList(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosActivityCardColors cardColors,
    List<ActivityAppEntry> entries,
  ) {
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            '今日无前台应用记录',
            style: ShellText.base.copyWith(
              color: colors.textTertiary,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ),
      );
    }
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 3),
          _AppUsagePanelRow(
            entry: entries[i],
            colors: colors,
            cardColors: cardColors,
            icon: scope?.services.buildApplicationIcon(context, entries[i].id),
          ),
        ],
      ],
    );
  }
}

/// 一条面板级应用时长行：高 22，图标 14×14 + 名称 + 时长右。
class _AppUsagePanelRow extends StatelessWidget {
  const _AppUsagePanelRow({
    required this.entry,
    required this.colors,
    required this.cardColors,
    this.icon,
  });

  final ActivityAppEntry entry;
  final ShellColorScheme colors;
  final KosActivityCardColors cardColors;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: icon ?? const SizedBox.expand(), // 图标占位
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                entry.name.isNotEmpty ? entry.name : entry.id,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: ShellText.base.copyWith(
                  color: colors.textPrimary,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ),
          ),
          Text(
            kosFormatDuration(entry.seconds),
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 11,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
