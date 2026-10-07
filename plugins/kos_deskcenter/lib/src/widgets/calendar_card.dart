/// KOS DeskCenter 日历小部件（`KosCalendarCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 calendar 分支（Loader
/// :2171-2347）：左栏大日期 + 今日事件列表，右栏浅色面板内的月历网格
/// （周一至周日列头、今日高亮圆点）。
///
/// 布局逐项对应源码锚点（同文件行号）：
/// - 整卡点击 → `AppActionService.launchById("kos-calendar", ["--date",
///   yyyy-MM-dd])`（:2193-2199）→ `onLaunchApp` 回调；
/// - 右侧浅色面板 `Rectangle`（:2201-2209）与顶部红色标题带 `Canvas`
///   （:2210-2235）源端仅 `!onBackdrop`（glass+色艺卡）绘制——TASK-09 起
///   卡片统一吃 Denial ShellTheme 材质（等价 material/onBackdrop），
///   自绘面板层删除；
/// - 42% 处 1px 竖分隔线（:2236-2240），色 `accent(outlineVariant,
///   rgba(0,0,0,0.10), 0.28)`（:2239）——material 取 outlineVariant@0.28
///   角色，静态近似 rgba(0,0,0,0.10)；
/// - 标题 `yyyy年M月`（:2242-2248）居中于 38 高标题带、15px Bold；
/// - 左栏：`d日` 32px DemiBold（:2249-2254，左 15、顶 headerHeight+7）；
///   `ddd · 农历` 10px DemiBold（:2255-2260，左 16、顶 headerHeight+46）
///   ——农历经 `lunarDate` 回调注入，默认空串时退化显示「农历日期」
///   兜底文案（:131-133 源 catch 分支）；
/// - 今日事件列表（:2261-2285）：非 small 且 eventsForToday 非空时逐条
///   `• 标题` 9px；服务 unavailable 且空时显「未连接日历服务」（:2277-2284）；
/// - 月历网格（:2286-2344）：左缘 42%+10、右 10、顶 headerHeight+6、
///   底 7；列头「一二三四五六日」15 高 10px Bold、周末列
///   （索引>=5）`#e95a63`、其余 `#5d5d65`（:2293-2302）；网格自顶 15 起，
///   weekCount 行 × 7 列；今日格 16px 圆、material 取 primary 角色、
///   静态近似 `ink("#ef5661",0.22)`（:2322-2325），今日数字白色 Bold、
///   其余 `#29292f` DemiBold（:2335-2339）。
///
/// 数据：构造注入 `WidgetSnapshot?`（或 watch [widgetSnapshotProvider]，
/// TASK-04/05 接线，当前默认 null）；空态按源语义区分
/// loading/ready/unavailable（PimWidgetService.qml:27-31）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../theme/backdrop_content.dart';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/widget_snapshot_watcher.dart';
import '../layout/widget_layout.dart' show WidgetSize;
import 'desk_card.dart';

/// 打开日历应用的回调；对应源 `AppActionService.launchById("kos-calendar",
/// ["--date", yyyy-MM-dd])`（DeskCenterWindow.qml:2193-2199）。
/// [date] 为点击时卡面显示的当日日期；[itemId] 为 null 表示整卡点击，
/// 非 null 携带待办/事件 id（本卡不消费，保留给对齐用参）。
typedef KosLaunchAppCallback = void Function(String appId, List<String> args);

/// 农历日期文案回调；对应 `root.lunarDate(date)`（:125-134，经 ICU
/// `zh-CN-u-ca-chinese` 格式化）。本卡不内置农历算法，由调用方注入；
/// 返回空串时界面退化显示源 catch 分支兜底「农历日期」（:132）。
typedef KosLunarDate = String Function(DateTime date);

/// PIM 快照数据源 provider 占位（TASK-04/05 接实现）：`null` = 尚无快照，
/// 小部件按 `state` 参数渲染载入/不可用空态。容器层可
/// `ref.watch(widgetSnapshotProvider)` 后把值传给构造参数。
final widgetSnapshotProvider = Provider<WidgetSnapshot?>(
  (ref) => null,
  isAutoDispose: true,
);

/// 日历卡内容色板：逐项对应源 `AppearanceTokens.content.ink/accent` 取值。
/// TASK-09 起卡片统一吃 Denial ShellTheme 材质（等价 material/onBackdrop），
/// 红标题带与右侧浅色面板仅 `!onBackdrop`（色艺卡）画（:2208/:2218-2219），
/// 本端不画——`showPaintedPanels`/`headerBand`/`rightPane`/`_TopBandPainter`
/// 全删。色板由 [KosCalendarColors.forShell] 按 `context.shellTheme`
/// 解析（亮壳→深色墨系、暗壳→白系；插件表面下没有 MaterialApp/Theme 祖先，
/// Theme.of 恒回退 light 基线）。
final class KosCalendarColors {
  const KosCalendarColors({
    this.headerText = const Color(0xFF1D1B20), // :2246 surfaceForeground 近似
    this.separator = const Color(0x1A000000), // :2239 rgba(0,0,0,0.10)
    this.dayNumber = const Color(0xFF15151A), // :2252 ink(\"#15151a\")
    this.weekdayLunar = const Color(
      0xBD4D4D55,
    ), // :2258 ink(\"#4d4d55\",0.74) 静态近似
    this.weekendHeader = const Color(0xFFE95A63), // :2300 \"#e95a63\"
    this.weekdayHeader = const Color(0xFF5D5D65), // :2300 \"#5d5d65\"
    this.gridInk = const Color(0xFF29292F), // :2338 ink(\"#29292f\")
    this.todayFill = const Color(
      0x38EF5661,
    ), // :2324 ink(\"#ef5661\",0.22) 静态近似
    this.todayForeground = const Color(0xFFFFFFFF), // :2337 白 on primary
    this.eventInk = const Color(0xFF4D4D55), // :2272 深色近似
    this.unavailableInk = const Color(
      0x8C9A9AA2,
    ), // :2281 ink(\"#9a9aa2\",0.55) 静态近似
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosCalendarColors forShell(ShellThemeData theme) {
    return KosCalendarColors(
      weekendHeader: usesBackdropInk(theme)
          ? backdropInk(theme)
          : const Color(0xFFE95A63),
      headerText: backdropInk(theme),
      separator: backdropHairline(theme),
      dayNumber: backdropInk(theme),
      weekdayLunar: backdropSecondaryInk(theme),
      weekdayHeader: backdropSecondaryInk(theme),
      gridInk: backdropInk(theme),
      todayFill: theme.accent.withValues(alpha: 0.22),
      todayForeground: backdropInk(theme),
      eventInk: backdropSecondaryInk(theme),
      unavailableInk: backdropSecondaryInk(theme),
    );
  }

  /// 月份标题 `yyyy年M月` 色（:2246 `pick(surfaceForeground,\"white\")`
  /// 的明暗合并结果 → shell `textPrimary`）。
  final Color headerText;

  /// 42% 处竖分隔线：material 取 `accent(outlineVariant, ·, 0.28)`（:2239）
  /// → outlineVariant@0.28 角色；静态近似 rgba(0,0,0,0.10)。
  final Color separator;

  /// 左栏大日期 `d日` 色 `ink("#15151a")`（:2252）。
  final Color dayNumber;

  /// `ddd · 农历` 色 `ink("#4d4d55", 0.74)`（:2258）：onBackdrop 时取
  /// glassContentColor(0.74)，此处静态近似 #4d4d55@0.74。
  final Color weekdayLunar;

  /// 列头周末列（索引>=5）`#e95a63`（:2300）。
  final Color weekendHeader;

  /// 列头工作日列 `#5d5d65`（:2300）。
  final Color weekdayHeader;

  /// 普通日期数字 `ink("#29292f")`（:2338）。
  final Color gridInk;

  /// 今日圆底：material → `surface.pick(colors.primary, ink("#ef5661",0.22))`
  /// （:2322-2325）；静态近似 #ef5661@0.22，运行时 primary 角色待注入。
  final Color todayFill;

  /// 今日数字：`pick(primaryForeground, "white")`（:2335-2337）白。
  final Color todayForeground;

  /// 今日事件行色（:2272 pick(surfaceVariantForeground,\"white\") 合并 →
  /// shell `textSecondary`）。
  final Color eventInk;

  /// 空态「未连接日历服务」`ink("#9a9aa2", 0.55)`（:2281）静态近似。
  final Color unavailableInk;
}

/// DeskCenter 日历小部件卡片（`modelData.id === "calendar"`）。
final class KosCalendarCard extends ConsumerWidget {
  const KosCalendarCard({
    super.key,
    this.clock,
    this.snapshot,
    this.state = WidgetSnapshotState.loading,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.lunarDate,
    this.onLaunchApp,
    this.onRemove,
    this.onCycleSize,
  });

  /// 时钟数据源：与 [KosClockCard] 共用 `clock`/`calendarClock.dayDate`
  /// 语义（DeskCenterWindow.qml:2178-2186 等都读它）。null 时经
  /// `ShellServicesScope` 取 `services.telemetry.clock`。
  final ProviderListenable<AsyncValue<DateTime>>? clock;

  /// PIM 快照数据注入。null → 按 [state] 渲染空态；给非 null
  /// `WidgetSnapshot` 即等价于服务 ready（PimWidgetService.qml:57
  /// applySnapshot 置 ready）。watcher 由 TASK-04/05 接线，本卡只消费
  /// 注入值。
  final WidgetSnapshot? snapshot;

  /// 快照可用性状态（对齐 PimWidgetService.qml:27-31
  /// loading/ready/unavailable）；仅在 [snapshot] 为 null 时生效。
  final WidgetSnapshotState state;

  /// 内容色板；null 时 build 内按 `context.shellTheme` 取
  /// [KosCalendarColors.forShell]（亮壳→深色墨系、暗壳→白系）。
  final KosCalendarColors? colors;

  /// 尺寸档位（源 :2188-2189 `DeskCenterConfigService.sizeFor("calendar")`）；
  final WidgetSize size;

  /// 编辑模式角标（透传 [DeskCard.editMode]）。
  final bool editMode;

  /// 农历文案注入；null 时以源 catch 兜底「农历日期」（:132）。
  final KosLunarDate? lunarDate;

  /// 整卡点击 → `launchById("kos-calendar", ["--date", yyyy-MM-dd])`
  /// （:2196-2198）；null 时不响应。默认实现由容器层注入
  /// `services.launchApplication` 适配。
  final KosLaunchAppCallback? onLaunchApp;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // D4：clock 为 null 且 ShellServicesScope 缺失时不再抛 StateError——
    // 回退 DateTime.now()；scope 存在时保留 telemetry.clock 优先级。
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    final listenable = clock ?? scope?.services.clock;
    final now =
        (listenable != null ? ref.watch(listenable).value : null) ??
        DateTime.now();
    final snap = snapshot;

    // :2178-2186 —— 月历网格参数。firstWeekday：周一为首列
    // （:2180-2182 注释「Monday-first month layout」）。
    final year = now.year;
    final month = now.month; // 源 getMonth() 0-based；本实现一律 1-based。
    final firstWeekday = (DateTime(year, month, 1).weekday - 1) % 7; // :2182
    final daysInMonth = DateTime(year, month + 1, 0).day; // :2183
    // :2186 —— 不留第六行空周：5 周月份用满面板高度。
    final weekCount = ((firstWeekday + daysInMonth) / 7).ceil();
    const headerHeight = 38.0; // :2187

    // :2190-2191 —— eventsForToday(limit)：small→0（不显示）、medium→1、
    // large→3；仅筛 start 前缀为 today 的记录（PimWidgetService.qml:66-73）。
    final limit = switch (size) {
      WidgetSize.large => 3,
      WidgetSize.medium => 1,
      WidgetSize.small => 0,
    };
    final todayKey = _ymd(now);
    final events = <PimEvent>[
      if (snap != null)
        for (final e in snap.events)
          if (e.start.length >= 10 && e.start.substring(0, 10) == todayKey) e,
    ].take(limit).toList();

    final isSmall = size == WidgetSize.small;
    final title = '$year年$month月'; // :2244 "yyyy年M月"

    final colors =
        this.colors ?? KosCalendarColors.forShell(context.shellTheme);
    return DeskCard(
      size: size,
      editMode: editMode,
      onRemove: onRemove,
      onCycleSize: onCycleSize,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // :2193-2199 整卡 MouseArea → launchById("kos-calendar")。
            onTap: onLaunchApp == null
                ? null
                : () => onLaunchApp!('kos-calendar', ['--date', todayKey]),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 42% 竖分隔线（:2236-2240）：左 42%、顶 headerHeight、
                // 宽 1、底边距 8。
                Positioned(
                  left: w * 0.42,
                  top: headerHeight,
                  bottom: 8,
                  width: 1,
                  child: ColoredBox(color: colors.separator),
                ),
                // 月份标题（:2242-2248）：居中于 38 高标题带，15px Bold。
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: headerHeight,
                  child: Center(
                    child: Text(
                      title,
                      textAlign: TextAlign.center, // :2245 AlignHCenter
                      style: TextStyle(
                        // :2246 pick(surfaceForeground,\"white\") → shell
                        // textPrimary（亮壳深墨 / 暗壳白系自动解析）。
                        color: colors.headerText,
                        fontSize: 15, // :2247
                        fontWeight: FontWeight.bold, // :2247 Font.Bold
                        height: 1,
                      ),
                    ),
                  ),
                ),
                // 左栏大日期 `d日`（:2249-2254）：左 15、顶 38+7、32px
                // DemiBold、SF Pro Display 字族（源 family 字段）。
                Positioned(
                  left: 15,
                  top: headerHeight + 7,
                  child: Text(
                    '${now.day}日', // :2251 "d日"
                    style: TextStyle(
                      color: colors.dayNumber,
                      fontSize: 32, // :2253
                      fontWeight: FontWeight.w600, // :2253 Font.DemiBold
                      height: 1,
                    ),
                  ),
                ),
                // 左栏 `ddd · 农历`（:2255-2260）：左 16、顶 38+46、10px
                // DemiBold。
                Positioned(
                  left: 16,
                  top: headerHeight + 46,
                  child: Text(
                    '${_weekdayAbbrev(now.weekday)} · '
                    '${(lunarDate?.call(now) ?? '').isEmpty ? '农历日期' : lunarDate!(now)}',
                    // :2257 "ddd" + " · " + lunarDate；农历注入缺失时落
                    // 源 catch 兜底文案（:131-133）。
                    style: TextStyle(
                      color: colors.weekdayLunar,
                      fontSize: 10, // :2259
                      fontWeight: FontWeight.w600, // :2259 Font.DemiBold
                      height: 1,
                    ),
                  ),
                ),
                // 今日事件列表（:2261-2285）：非 small 且有今日事件时
                // 逐条 "• 标题" 9px；空态仅 unavailable 显「未连接日历服务」。
                if (!isSmall)
                  Positioned(
                    left: 16, // :2264 leftMargin:16
                    // right: monthGrid.left + rightMargin:8（:2264）→
                    // 右缘 = 42%+10 再回退 8，即距卡右 w-(w*0.42+2)。
                    right: w - (w * 0.42 + 10) + 8,
                    bottom: 10, // :2264 bottomMargin:10
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in events)
                          Text(
                            '• ${e.title.isEmpty ? '日程' : e.title}',
                            // :2271 "• " + title（fallback "日程"）
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis, // :2273
                            style: TextStyle(
                              // :2272 pick(surfaceVariantForeground,\"white\")
                              // → shell textSecondary。
                              color: colors.eventInk,
                            ),
                          ),
                        if (events.isEmpty &&
                            state == WidgetSnapshotState.unavailable)
                          Text(
                            '未连接日历服务', // :2280
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.unavailableInk,
                              fontSize: 9, // :2283
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                // 月历网格（:2286-2344）：左 42%+10、右 10、顶 38+6、底 7。
                Positioned(
                  left: w * 0.42 + 10, // :2288 leftMargin: 42%+10
                  right: 10, // :2288 rightMargin:10
                  top: headerHeight + 6, // :2288 topMargin: 38+6
                  bottom: 7, // :2288 bottomMargin:7
                  child: Column(
                    children: [
                      // 列头行高 15（:2291）。
                      SizedBox(
                        height: 15,
                        child: Row(
                          children: [
                            for (var i = 0; i < 7; i++)
                              Expanded(
                                child: Text(
                                  _kWeekHeaders[i], // :2293 一二三四五六日
                                  textAlign: TextAlign.center, // :2299
                                  style: TextStyle(
                                    color: i >= 5
                                        ? colors
                                              .weekendHeader // :2300
                                        : colors.weekdayHeader,
                                    fontSize: 10, // :2301
                                    fontWeight: FontWeight.bold, // Bold
                                    height: 1,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // 网格自列头下 15 起（:2306 topMargin:15），
                      // weekCount 行 × 7 列（:2307-2309）。
                      Expanded(
                        child: Column(
                          children: [
                            for (var week = 0; week < weekCount; week++)
                              Expanded(
                                child: Row(
                                  children: [
                                    for (var col = 0; col < 7; col++)
                                      Expanded(
                                        child: _DayCell(
                                          day:
                                              week * 7 +
                                              col -
                                              firstWeekday +
                                              1, // :2314
                                          isToday:
                                              (week * 7 +
                                                  col -
                                                  firstWeekday +
                                                  1) ==
                                              now.day, // :2315-2316
                                          daysInMonth: daysInMonth,
                                          colors: colors,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// `yyyy-MM-dd`（对齐 Qt `formatDate(clock.date,"yyyy-MM-dd")`，:2197）。
  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Qt `ddd` 缩略星期：zh 语境对齐源显示，取「周一…周日」单字缩略
  /// （源 9px 列头与 :2257 `ddd` 同为缩略名；差异记 visual-deltas）。
  static String _weekdayAbbrev(int weekday) => '周${_kWeekHeaders[weekday - 1]}';

  static const _kWeekHeaders = ['一', '二', '三', '四', '五', '六', '日']; // :2293
}

/// 月历单格（:2310-2341 delegate）：16px 今日圆底 + 10px 数字。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.daysInMonth,
    required this.colors,
  });

  final int day;
  final bool isToday;
  final int daysInMonth;
  final KosCalendarColors colors;

  @override
  Widget build(BuildContext context) {
    // :2329 —— 跨月格不绘制数字（visible: day>0 && day<=daysInMonth）。
    if (day <= 0 || day > daysInMonth) {
      return const SizedBox.expand();
    }
    return Center(
      child: SizedBox(
        width: 16, // :2319
        height: 16, // :2320
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle, // :2321 radius:8 = 圆
            color: isToday ? colors.todayFill : const Color(0x00000000),
          ),
          child: Center(
            child: Text(
              '$day',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isToday ? colors.todayForeground : colors.gridInk,
                fontSize: 10, // :2339
                fontWeight: isToday
                    ? FontWeight
                          .bold // :2339 今日 Bold
                    : FontWeight.w600, // :2339 其余 DemiBold
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
