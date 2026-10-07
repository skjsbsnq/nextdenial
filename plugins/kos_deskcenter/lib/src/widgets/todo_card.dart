/// KOS DeskCenter 待办小部件（`KosTodoCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 todo 分支（Loader
/// :2027-2169）：
/// - 顶部红色标题带 `Canvas`（:2055-2082）：高 `min(42, h*0.28)`、
///   `#ff5d66`、上缘两角 `min(card.radius, height)` 圆角，仅
///   `!onBackdrop` 绘制（:2059-2065）——TASK-09 起卡片统一吃 Denial
///   ShellTheme 材质（等价 material/onBackdrop），自绘标题带层删除；
/// - 标题「提醒事项」（:2083-2088）：左/顶 14、13px Bold；
/// - small 档（`sizeFor("todo")==="small"`，:2034-2035）中部显示待办
///   计数 38px DemiBold（:2089-2096）+ 底部「项待办」10px（:2097-2103）；
/// - 非 small 档列表（:2104-2166）：左/右 14、顶 50、底 10、行距 4；
///   每行 13px 圆环（透明底、1.5px 描边，`accent(primary,"#ff5d66",0.7)`
///   :2117-2122）+ 标题 11px Medium `#303038`（:2123-2129）+ 截止日期
///   9px（:2130-2140），行点击 → `launchById("kos-todo", ["--item", id])`
///   （:2141-2148）；
/// - 整卡点击 → `launchById("kos-todo", ["--view","today"])`
///   （:2045-2050）→ `onLaunchApp`；
/// - 截止日期着色规则（:2134-2138）：`due < today`（字符串前 10 位比较，
///   `PimWidgetService.today` 为 `yyyy-MM-dd`）→ `#e23d52` 逾期红，
///   其余 `#7b7b84` 灰；onBackdrop 形态走 glassContentColor/0.6——本端
///   按 `context.shellTheme` 色板取 accent 语义红 / `textSecondary`；
/// - 空态文案（:2151-2164）：ready→「今天已全部完成」、loading→
///   「正在载入待办…」、unavailable→「未连接待办服务」
///   （PimWidgetService.qml:27-31）。
///
/// 数据：构造注入 `WidgetSnapshot?`（`pendingTodos` 语义
/// PimWidgetService.qml:75-82：滤 `completed`，medium 3 条、large 6 条，
/// :2036-2037）；空态按 [state] 区分。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../theme/backdrop_content.dart';

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';

import '../data/widget_snapshot_watcher.dart';
import '../layout/widget_layout.dart' show WidgetSize;
import 'calendar_card.dart' show KosLaunchAppCallback;
import 'desk_card.dart';

/// 待办卡内容色板：逐项对应源 `AppearanceTokens.content.ink/accent` 取值。
/// TASK-09 起 `showPaintedPanels`/onBackdrop 分叉删除——明暗合并按
/// `context.shellTheme` 角色解析（[KosTodoColors.forShell]）。
final class KosTodoColors {
  const KosTodoColors({
    this.headerText = const Color(0xFF1D1B20), // :2086 ink(\"white\") 板上近似
    this.titleInk = const Color(0xFF303038), // :2126 ink(\"#303038\")
    this.countInk = const Color(0xFF33333A), // :2094 ink(\"#33333a\")
    this.countSubInk = const Color(
      0x99686873,
    ), // :2101 ink(\"#686873\",0.6) 静态近似
    this.checkboxRing = const Color(
      0xB3FF5D66,
    ), // :2121 accent(primary,\"#ff5d66\",0.7)
    this.dueOverdue = const Color(0xFFE23D52), // :2138 \"#e23d52\" 逾期红
    this.dueFuture = const Color(0xFF7B7B84), // :2138 \"#7b7b84\" 未来灰
    this.emptyInk = const Color(0x996C6C75), // :2163 ink(\"#6c6c75\",0.6) 静态近似
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosTodoColors forShell(ShellThemeData theme) {
    return KosTodoColors(
      headerText: backdropInk(theme),
      titleInk: backdropInk(theme),
      countInk: backdropInk(theme),
      countSubInk: backdropSecondaryInk(theme),
      dueFuture: backdropSecondaryInk(theme),
      emptyInk: backdropSecondaryInk(theme),
    );
  }

  /// 标题「提醒事项」色（:2086 `ink(\"white\")` 的明暗合并结果 → shell
  /// `textPrimary`）。
  final Color headerText;

  /// 行标题 `ink("#303038")`（:2126）。
  final Color titleInk;

  /// small 档计数数字 `ink("#33333a")`（:2094）。
  final Color countInk;

  /// small 档「项待办」`ink("#686873", 0.6)`（:2101）静态近似。
  final Color countSubInk;

  /// 圆环描边 `accent(colors.primary, "#ff5d66", 0.7)`（:2121）：
  /// material → primary@0.7 角色，静态近似 #ff5d66@0.7。
  final Color checkboxRing;

  /// 逾期截止色 `#e23d52`（:2138 `due < today` 分支）；语义警示色保留
  /// 源值，不走壳色板。
  final Color dueOverdue;

  /// 未逾期截止色（:2138 另一分支 `#7b7b84` / onBackdrop 白@0.6 合并 →
  /// shell `textSecondary`）。
  final Color dueFuture;

  /// 空态文案 `ink("#6c6c75", 0.6)`（:2163）静态近似。
  final Color emptyInk;
}

/// DeskCenter 待办小部件卡片（`modelData.id === "todo"`）。
class KosTodoCard extends StatelessWidget {
  const KosTodoCard({
    super.key,
    this.snapshot,
    this.state = WidgetSnapshotState.loading,
    this.today,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onLaunchApp,
    this.onRemove,
    this.onCycleSize,
  });

  /// PIM 快照；null → 按 [state] 渲染空态（对应 PimWidgetService
  /// loading/unavailable）。给非 null `WidgetSnapshot` 即 ready。
  final WidgetSnapshot? snapshot;

  /// 快照可用性状态（PimWidgetService.qml:27-31）；仅在 [snapshot]
  /// 为 null 时生效。
  final WidgetSnapshotState state;

  /// 「今日」`yyyy-MM-dd` 键；对应 `PimWidgetService.today`
  /// （PimWidgetService.qml:17、54，快照 `today` 字段或本地当日）。
  /// null 时用 [snapshot?.today]，再缺则 `DateTime.now()` 当日。
  final String? today;

  /// 内容色板；null → build 时按 `context.shellTheme` 解析
  /// （[KosTodoColors.forShell]）。
  final KosTodoColors? colors;

  /// 尺寸档位（`DeskCenterConfigService.sizeFor("todo")`，:2034-2035）：
  /// small 显示计数、medium 3 条、large 6 条（:2036-2037）。
  final WidgetSize size;

  /// 编辑模式角标（透传 [DeskCard.editMode]）。
  final bool editMode;

  /// 启动回调：整卡 `('kos-todo', ['--view','today'])`（:2048-2049），
  /// 行点击 `('kos-todo', ['--item', id])`（:2144-2147）；null 不响应。
  /// 默认实现由容器层注入 `services.launchApplication` 适配。
  final KosLaunchAppCallback? onLaunchApp;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  @override
  Widget build(BuildContext context) {
    final todayKey = today ?? snapshot?.today ?? _ymd(DateTime.now());
    // :2036-2039 itemLimit + pendingTodos(limit)：滤 completed、取前 N。
    final itemLimit = switch (size) {
      WidgetSize.large => 6,
      WidgetSize.medium => 3,
      WidgetSize.small => 0, // :2037 small→0，走计数分支
    };
    final all = <PimTodo>[
      if (snapshot != null)
        for (final t in snapshot!.todos)
          if (!t.completed) t, // PimWidgetService.qml:75-82
    ];
    final tasks = all.take(itemLimit == 0 ? all.length : itemLimit).toList();
    final isSmall = size == WidgetSize.small;
    final colors = this.colors ?? KosTodoColors.forShell(context.shellTheme);

    return DeskCard(
      size: size,
      editMode: editMode,
      onRemove: onRemove,
      onCycleSize: onCycleSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // :2045-2050 整卡 MouseArea → launchById("kos-todo",
        // ["--view","today"])。
        onTap: onLaunchApp == null
            ? null
            : () => onLaunchApp!('kos-todo', ['--view', 'today']),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 红色标题带（:2055-2082）仅 !onBackdrop 画——TASK-09 后统一
            // Denial 材质（等价 onBackdrop），自绘带层删除；标题按亮度取色。
            // 标题「提醒事项」（:2083-2088）：左/顶 14、13px Bold。
            // 色 :2086 ink("white")：!onBackdrop（红带上）→ 白；
            // onBackdrop → glassContentColor() 白系——明暗合并 →
            // shell `textPrimary`。
            Positioned(
              left: 14,
              top: 14,
              child: Text(
                '提醒事项', // :2085
                style: TextStyle(
                  color: colors.headerText,
                  fontSize: 13, // :2087
                  fontWeight: FontWeight.bold, // :2087 Font.Bold
                  height: 1,
                ),
              ),
            ),
            // small 档：中央待办计数 + 底部「项待办」（:2089-2103）。
            if (isSmall) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 24),
                  // :2092 verticalCenterOffset:12 —— 计数相对中心
                  // 下移 12；padding 12 近似（中心偏上 12 的 Padding
                  // 让计数向下偏）。
                  child: Text(
                    '${all.length}', // :2093 String(pendingTodos(99).length)
                    style: TextStyle(
                      color: colors.countInk,
                      fontSize: 38, // :2095
                      fontWeight: FontWeight.w600, // DemiBold
                      height: 1,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 14, // :2099 bottomMargin:14
                child: Center(
                  child: Text(
                    '项待办', // :2100
                    style: TextStyle(
                      color: colors.countSubInk,
                      fontSize: 10, // :2102
                      height: 1,
                    ),
                  ),
                ),
              ),
            ] else
              // 非 small：列表（:2104-2166）：左/右 14、顶 50、底 10、
              // 行距 4；空态按 state 区分（:2159-2162）。
              Positioned(
                left: 14,
                right: 14,
                top: 50, // :2106 topMargin:50
                bottom: 10, // :2106 bottomMargin:10
                child: tasks.isEmpty
                    ? Center(
                        child: Text(
                          // :2159-2162 三态文案。
                          switch (state) {
                            WidgetSnapshotState.ready => '今天已全部完成', // :2160
                            WidgetSnapshotState.loading =>
                              '正在载入待办…', // :2161-2162
                            WidgetSnapshotState.unavailable =>
                              '未连接待办服务', // :2162
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.emptyInk,
                            fontSize: 11, // :2164
                            height: 1.3,
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < tasks.length; i++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  top: i == 0 ? 0 : 4, // :2107 spacing:4
                                ),
                                child: _TodoRow(
                                  todo: tasks[i],
                                  today: todayKey,
                                  colors: colors,
                                  onLaunchApp: onLaunchApp,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 单行待办（:2110-2148 delegate）：圆环 + 标题 + 截止。
class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.todo,
    required this.today,
    required this.colors,
    this.onLaunchApp,
  });

  final PimTodo todo;
  final String today;
  final KosTodoColors colors;

  final KosLaunchAppCallback? onLaunchApp;

  @override
  Widget build(BuildContext context) {
    // :2133 —— text = due.slice(0,10)；空串→""（源 value(...,"due","")）。
    final due = todo.due.length >= 10 ? todo.due.substring(0, 10) : todo.due;
    // :2134-2138 着色规则：
    // !onBackdrop → `due < today` 逾期红 "#e23d52"、其余 "#7b7b84"；
    // onBackdrop → glassContentColor()（逾期）/ glassContentColor(0.6)。
    // 明暗合并：逾期保留语义红 `dueOverdue`，其余 → shell `textSecondary`。
    // 注意：源对「今天到期」判为不逾期（due == today → false），与任务卡
    // 「今日橙」描述不同——源码无橙档，以源码为准（见 docs/visual-deltas）。
    final overdue = due.isNotEmpty && due.compareTo(today) < 0;
    final dueColor = overdue ? colors.dueOverdue : colors.dueFuture;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // :2144-2147 行点击 → launchById("kos-todo",["--item", id||seriesId])：
      // 源 value(m,"id", value(m,"seriesId",""))——widget 快照的
      // todoObject 不写 seriesId（仅 todoOccurrenceObject 写，
      // PimStore.cpp:400-424 vs :432），故本端恒取 id，seriesId 字段仅作
      // 对齐占位（见 widget_snapshot_watcher.dart PimTodo.seriesId 与
      // docs/visual-deltas.md §6）。
      onTap: onLaunchApp == null
          ? null
          : () => onLaunchApp!('kos-todo', [
              '--item',
              todo.id.isNotEmpty ? todo.id : todo.seriesId,
            ]),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 13px 圆环（:2116-2122）：透明底、1.5px 描边。
          Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colors.checkboxRing, width: 1.5),
            ),
          ),
          // 标题（:2123-2129）：左 22（环 13+9 间距），11px Medium，
          // 截断 ElideRight。
          const SizedBox(width: 9), // :2124 leftMargin:22 - 13 = 9
          Expanded(
            child: Text(
              todo.title.isEmpty ? '未命名任务' : todo.title, // :2125
              maxLines: 1,
              overflow: TextOverflow.ellipsis, // :2127
              style: TextStyle(
                color: colors.titleInk,
                fontSize: 11, // :2128
                fontWeight: FontWeight.w500, // :2128 Font.Medium
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 8), // :2124 rightMargin:8
          // 截止（:2130-2140）：右对齐、9px、逾期/未来着色。
          if (due.isNotEmpty)
            Text(
              due,
              style: TextStyle(
                color: dueColor,
                fontSize: 9, // :2139
                height: 1.2,
              ),
            ),
        ],
      ),
    );
  }
}
