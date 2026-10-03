/// RRULE 解析与发生次展开（`daily/weekly/monthly/yearly` + `custom` 透传）。
///
/// 事实来源（NextKde 仓库）：
/// - 预设写入：services/pim-service/src/PimStore.cpp:211-231
///   （`applyRecurrence`：`daily/weekly/monthly/yearly` → `set*(1)`，
///   `recurrenceCount`/`recurrenceUntil` → `setDuration`/`setEndDate`，
///   `custom` 不经 `applyRecurrence`、RRULE 原文透传）；
/// - 预设回放：PimStore.cpp:151-157（`recurrencePreset`：存了
///   `X-KOS-RECURRENCE-PRESET` 用预设值，否则 `recurs()` → `custom`，
///   无重复 → `none`）。
///
/// 展开语义对齐 KCalendarCore `OccurrenceIterator` 的基础子集：
/// `INTERVAL`/`COUNT`/`UNTIL`/`BYDAY`（weekday 或 `{-N}DOW` 序数写法，
/// `BYMONTH`/`BYMONTHDAY` 只过滤步进后日期，不改步进单位）；不在子集内
/// 的键（`BYHOUR`/`BYSETPOS`/…）不拒绝、按 FREQ 默认步进近似——与
/// `custom` 不重写的约束一致（本展开只读，不回写规则）。
///
/// 日期运算全部用 `DateTime.utc` 纯日算术，避免 DST 抖动；日期时间事件
/// 的墙钟时刻由调用方在展开结果上重新叠加（见 `pim_store.dart`）。
library;

/// 周日记法（RFC 5545 两字母缩写 → `DateTime.weekday`）。
const Map<String, int> _kWeekdayCodes = {
  'MO': DateTime.monday,
  'TU': DateTime.tuesday,
  'WE': DateTime.wednesday,
  'TH': DateTime.thursday,
  'FR': DateTime.friday,
  'SA': DateTime.saturday,
  'SU': DateTime.sunday,
};

/// `BYDAY` 单项（`MO` 或 `-1FR` 等序数写法）。
final class RRuleByDay {
  const RRuleByDay({required this.weekday, this.ordinal});

  /// `DateTime.monday`..`DateTime.sunday`。
  final int weekday;

  /// 月内序数（非 null 时仅 `monthly`/`yearly` 语义下生效；
  /// `-1` = 倒数第一个）。
  final int? ordinal;
}

/// 一条 RRULE 的解析结果（不可变）。
final class RRule {
  const RRule({
    required this.freq,
    this.interval = 1,
    this.count,
    this.until,
    this.byDay = const [],
    this.byMonth = const [],
    this.byMonthDay = const [],
  });

  /// `daily|weekly|monthly|yearly`（小写归一）。
  final String freq;
  final int interval;

  /// 发生次数上限（`applyRecurrence` 的 `setDuration`，PimStore.cpp:223-225）。
  final int? count;

  /// 截止时刻（本地）；纯日期 UNTIL 存该日 23:59:59 使「当天发生次仍算」。
  final DateTime? until;

  /// `BYDAY` 项；空时按 FREQ 默认锚（weekly → DTSTART weekday，
  /// monthly/yearly → DTSTART 月日）。
  final List<RRuleByDay> byDay;

  /// `BYMONTH` 过滤项（1-12）。
  final List<int> byMonth;

  /// `BYMONTHDAY` 过滤项（-31..31，负值 = 月末倒数）。
  final List<int> byMonthDay;

  /// 解析 `RRULE:` 值体（`FREQ=...;INTERVAL=...`）。
  ///
  /// 返回 null 的两种形态：
  /// - `raw` 非法/空 → 无规则（调用方按 `none` 处理）；
  /// - `FREQ` 不在 daily/weekly/monthly/yearly 子集 → `custom`：本端
  ///   不重写也不近似展开（任务卡约束），由 `pim_store` 走
  ///   「custom 不展开」分支。
  static RRule? tryParse(String raw) {
    final freqMatch = RegExp(r'(?:^|;)FREQ=([A-Z]+)').firstMatch(raw);
    if (freqMatch == null) return null;
    final freq = switch (freqMatch.group(1)!) {
      'DAILY' => 'daily',
      'WEEKLY' => 'weekly',
      'MONTHLY' => 'monthly',
      'YEARLY' => 'yearly',
      _ => 'custom',
    };
    if (freq == 'custom') return null;

    int? intParam(String name) {
      final m = RegExp('(?:^|;)$name=(-?\\d+)').firstMatch(raw);
      return m == null ? null : int.tryParse(m.group(1)!);
    }

    List<int> intListParam(String name) {
      final m = RegExp('(?:^|;)$name=([-0-9,]+)').firstMatch(raw);
      if (m == null) return const [];
      return [
        for (final part in m.group(1)!.split(','))
          ?int.tryParse(part),
      ];
    }

    DateTime? until;
    final untilMatch = RegExp(r'(?:^|;)UNTIL=([0-9TZ]{8,16})').firstMatch(raw);
    if (untilMatch != null) {
      final u = untilMatch.group(1)!;
      final year = int.tryParse(u.substring(0, 4));
      final month = int.tryParse(u.substring(4, 6));
      final day = int.tryParse(u.substring(6, 8));
      if (year != null && month != null && day != null) {
        if (u.contains('T')) {
          final hour = int.tryParse(u.substring(9, 11)) ?? 0;
          final minute = int.tryParse(u.substring(11, 13)) ?? 0;
          final second = int.tryParse(u.substring(13, 15)) ?? 0;
          // 带 Z 的 UNTIL 是 UTC 时刻（RFC 5545 §3.3.10 强制），换算本地。
          until = u.endsWith('Z')
              ? DateTime.utc(year, month, day, hour, minute, second).toLocal()
              : DateTime(year, month, day, hour, minute, second);
        } else {
          // 纯日期 UNTIL 含当天发生次（RFC 5545：UNTIL 含界）。
          until = DateTime(year, month, day, 23, 59, 59);
        }
      }
    }

    final byDay = <RRuleByDay>[
      for (final token in RegExp(r'(?:^|;)BYDAY=([-+0-9A-Z,]+)')
              .firstMatch(raw)
              ?.group(1)
              ?.split(',') ??
          const <String>[])
        ?_byDayOf(token),
    ];

    final interval = intParam('INTERVAL') ?? 1;
    return RRule(
      freq: freq,
      interval: interval > 0 ? interval : 1,
      count: intParam('COUNT'),
      until: until,
      byDay: byDay,
      byMonth: intListParam('BYMONTH'),
      byMonthDay: intListParam('BYMONTHDAY'),
    );
  }

  static RRuleByDay? _byDayOf(String token) {
    if (token.isEmpty) return null;
    final m = RegExp(r'^([-+]?\d*)([A-Z]{2})$').firstMatch(token);
    if (m == null) return null;
    final weekday = _kWeekdayCodes[m.group(2)];
    if (weekday == null) return null;
    final ordinalText = m.group(1)!;
    final ordinal = ordinalText.isEmpty ? null : int.tryParse(ordinalText);
    return RRuleByDay(weekday: weekday, ordinal: ordinal);
  }
}

/// [rule] 在 `[rangeStartDay, rangeEndDay]`（闭区间，本地日零点）内
/// 命中的发生次日期（去 `dtStart` 的日期分量基准展开，时刻由调用方叠加）。
///
/// [seriesStartDay] 是 DTSTART 的日期分量（发生次序列的第一项——对应
/// KCalendarCore 从 `dtStart` 起算）。`COUNT`/`UNTIL` 对齐
/// `setDuration`/`setEndDate`（PimStore.cpp:223-229）。
///
/// 非 VEVENT 的重复语义差异（VTODO 以 due 为锚）由调用方决定传
/// `dtStart` 还是 `due` 的日期分量；本函数只管「从某个起始日起重复哪些日」。
///
/// 返回的日期是 UTC 日零点（纯日容器），调用方用 `year/month/day` 分量
/// 重建成带墙钟的本地 DateTime。
List<DateTime> rruleOccurrenceDays(
  RRule rule,
  DateTime seriesStartDay,
  DateTime rangeStartDay,
  DateTime rangeEndDay,
) {
  DateTime dayUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  final startDay = dayUtc(seriesStartDay);
  final lo = dayUtc(rangeStartDay);
  final hi = dayUtc(rangeEndDay);
  final untilUtc = rule.until == null ? null : dayUtc(rule.until!);

  final results = <DateTime>[];
  var emitted = 0;
  // 保护上限：applyRecurrence 把 COUNT 钳到 10000（:223-225）。
  const maxIterations = 10000;
  var stop = false;

  bool emit(DateTime day) {
    if (stop) return false;
    // COUNT 判定必须在窗口过滤之前：COUNT 数的是规则生成的发生次，
    // 不是窗口内命中的次数（RFC 5545）。
    emitted += 1;
    if (rule.count != null && emitted > rule.count!) {
      stop = true;
      return false;
    }
    if (untilUtc != null && day.isAfter(untilUtc)) {
      stop = true;
      return false;
    }
    if (day.isBefore(startDay)) return true;
    if (day.isBefore(lo) || day.isAfter(hi)) return true;
    if (!_passesFilters(rule, day)) return true;
    results.add(day);
    return true;
  }

  var iterations = 0;
  bool budget() => ++iterations <= maxIterations && !stop;

  switch (rule.freq) {
    case 'daily':
      for (var day = startDay; !day.isAfter(hi) && budget(); ) {
        emit(day);
        day = day.add(Duration(days: rule.interval));
      }
    case 'weekly':
      // BYDAY 空 → DTSTART 的 weekday（RFC 5545/KCalendarCore 默认）。
      final days = rule.byDay.isEmpty
          ? [RRuleByDay(weekday: seriesStartDay.weekday)]
          : rule.byDay;
      var weekStart = startDay.subtract(Duration(days: startDay.weekday - 1));
      while (!weekStart.isAfter(hi) && budget()) {
        // 候选按周内序发射，保证 COUNT 消耗顺序与 RFC 一致。
        final candidates = [
          for (final d in days) weekStart.add(Duration(days: d.weekday - 1)),
        ]..sort();
        for (final day in candidates) {
          if (!emit(day)) break;
        }
        weekStart = weekStart.add(Duration(days: 7 * rule.interval));
      }
    case 'monthly':
      for (var month = DateTime.utc(startDay.year, startDay.month);
          !month.isAfter(hi) && budget();
          month = DateTime.utc(month.year, month.month + rule.interval)) {
        for (final day in _monthlyCandidates(rule, month, startDay)) {
          if (!emit(day)) break;
        }
      }
    case 'yearly':
      for (var year = startDay.year;
          !DateTime.utc(year, 1, 1).isAfter(hi) && budget();
          year += rule.interval) {
        for (final day in _yearlyCandidates(rule, year, startDay)) {
          if (!emit(day)) break;
        }
      }
  }
  return results;
}

bool _passesFilters(RRule rule, DateTime day) {
  if (rule.byMonth.isNotEmpty && !rule.byMonth.contains(day.month)) {
    return false;
  }
  if (rule.byMonthDay.isNotEmpty) {
    final monthDays = DateTime.utc(day.year, day.month + 1, 0).day;
    final match = rule.byMonthDay.any(
      (d) => d > 0 ? day.day == d : day.day == monthDays + d + 1,
    );
    if (!match) return false;
  }
  return true;
}

/// `monthly` 在 [month]（UTC 日零点）内的候选日集合（升序）。
///
/// 优先级：`BYDAY 全序数写法`（`-1FR`）> `BYDAY 普通写法`（月内所有
/// 该 weekday）> 默认 = DTSTART 的日号（KCalendarCore `setMonthly(1)`
/// 的默认 `byMonthDay = DTSTART.day`）。`BYMONTHDAY` 已在过滤器处理。
List<DateTime> _monthlyCandidates(
  RRule rule,
  DateTime month,
  DateTime startDay,
) {
  if (rule.byDay.isNotEmpty) {
    if (rule.byDay.every((d) => d.ordinal != null)) {
      final days = [
        for (final d in rule.byDay)
          ?_nthWeekdayOfMonth(month.year, month.month, d.weekday, d.ordinal!),
      ]..sort();
      return days;
    }
    final lastDay = DateTime.utc(month.year, month.month + 1, 0).day;
    return [
      for (var day = 1; day <= lastDay; day += 1)
        if (rule.byDay.any(
          (d) => DateTime.utc(month.year, month.month, day).weekday
              == d.weekday,
        ))
          DateTime.utc(month.year, month.month, day),
    ];
  }
  final lastDay = DateTime.utc(month.year, month.month + 1, 0).day;
  final dom = startDay.day;
  return [if (dom <= lastDay) DateTime.utc(month.year, month.month, dom)];
}

/// `yearly` 在 [year] 内的候选日集合（升序）。默认 = DTSTART 的月日；
/// `BYMONTH` 存在时锚到列表首月（与 BYDAY 序数组合表示「第 n 个 x」）。
List<DateTime> _yearlyCandidates(RRule rule, int year, DateTime startDay) {
  final months = rule.byMonth.isNotEmpty ? rule.byMonth : [startDay.month];
  if (rule.byDay.isNotEmpty && rule.byDay.every((d) => d.ordinal != null)) {
    final days = [
      for (final month in months)
        for (final d in rule.byDay)
          ?_nthWeekdayOfMonth(year, month, d.weekday, d.ordinal!),
    ]..sort();
    return days;
  }
  final days = [
    for (final month in months)
      if (startDay.day <= DateTime.utc(year, month + 1, 0).day)
        DateTime.utc(year, month, startDay.day),
  ]..sort();
  return days;
}

/// [month] 内第 [n] 个 [weekday]（n > 0 = 正数第 n，n < 0 = 倒数第 -n）。
DateTime? _nthWeekdayOfMonth(int year, int month, int weekday, int n) {
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  final days = [
    for (var d = 1; d <= lastDay; d += 1)
      if (DateTime.utc(year, month, d).weekday == weekday)
        DateTime.utc(year, month, d),
  ];
  if (n > 0) return n <= days.length ? days[n - 1] : null;
  final index = days.length + n;
  return index >= 0 ? days[index] : null;
}
