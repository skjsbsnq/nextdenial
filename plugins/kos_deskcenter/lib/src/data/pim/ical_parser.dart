/// iCalendar `calendar.ics` 的 VEVENT/VTODO 解析与序列化。
///
/// 事实来源（NextKde 仓库）：落盘格式 = KCalendarCore `ICalFormat`
/// （services/pim-service/src/PimStore.cpp:536-537 写、:577-581 读）。
/// KOS 私有字段走 X-props `X-KOS-*`（PimStore.cpp:40-47）：
/// `X-KOS-CALENDAR-ID/-LIST-ID/-PARENT-ID/-ORDER/-RECURRENCE-PRESET/
/// -LINKED-TODO-ID/-LINKED-EVENT-ID`。
///
/// 覆盖范围（任务卡 TASK-11 契约子集）：
/// - 行折叠：CRLF/LF + 空格/制表符续行（RFC 5545 §3.1）；
/// - `VALUE=DATE`/`TZID` 参数，`YYYYMMDD`/`YYYYMMDDTHHMMSS[Z]` 两种值；
/// - 转义 `\\n`/`\\,`/`\\;`/`\\\\`，序列化时反向转义 + 75 字节折行；
/// - `VEVENT`：`UID/DTSTART/DTEND/RRULE/SUMMARY/DESCRIPTION/LOCATION/
///   RECURRENCE-ID/X-KOS-*`；
/// - `VTODO`：`UID/DTSTART/DUE/RRULE/SUMMARY/DESCRIPTION/STATUS/
///   COMPLETED/PRIORITY/RECURRENCE-ID/RELATED-TO/X-KOS-*`；
/// - `VALARM` 只提取 `TRIGGER` 的 `-P...` 提前分钟（对齐
///   `reminderMinutes()`，PimStore.cpp:159-176 取首个 enabled alarm
///   的 startOffset/endOffset）。
///
/// 不覆盖：EXDATE/EXRULE/多 RRULE/VTIMEZONE 定义（TZID 只保留名字，
/// 时刻按本地时区解释——KCalendarCore MemoryCalendar 即以
/// `systemTimeZone` 为锚，PimStore.cpp:470）。
library;

/// 解析后的 VEVENT。
final class IcalEvent {
  const IcalEvent({
    required this.uid,
    required this.summary,
    required this.start,
    required this.end,
    required this.allDay,
    required this.timeZone,
    required this.calendarId,
    required this.rrule,
    required this.recurrencePreset,
    required this.recurrenceId,
    required this.reminderMinutes,
    required this.linkedTodoId,
    this.description = '',
    this.location = '',
  });

  final String uid;
  final String summary;
  final String description;
  final String location;

  /// 发生次锚点（本地 DateTime）；allDay 时分量为日零点。
  final DateTime start;

  /// 结束时刻；allDay 时为排他 end（RFC 5545：DTEND 不含当天）。
  final DateTime end;
  final bool allDay;

  /// `TZID` 参数原文；无时区信息为空串（对应 `timeZone` 字段，
  /// eventObject 写 `start.timeZone().id()`，PimStore.cpp:383）。
  final String timeZone;

  /// `X-KOS-CALENDAR-ID`；空 → 服务回放 `"personal"`（:384-387）。
  final String calendarId;

  /// `RRULE` 原文（`FREQ=...`），无规则为空串。
  final String rrule;

  /// `X-KOS-RECURRENCE-PRESET`；空时按 `rrule 非空 → custom 否则 none`
  /// 回放（PimStore.cpp:153-156）。
  final String recurrencePreset;

  /// `RECURRENCE-ID`（发生次实例标识）；非发生次实例为空串。
  final String recurrenceId;

  /// 提醒提前分钟，-1 = 无提醒（对齐 :159-176 首个有效 alarm）。
  final int reminderMinutes;

  /// `X-KOS-LINKED-TODO-ID`（反向链接由 todo 侧 `X-KOS-LINKED-EVENT-ID`
  /// /`RELATED-TO` 在 store 层补，PimStore.cpp:258-271）。
  final String linkedTodoId;
}

/// 解析后的 VTODO。
final class IcalTodo {
  const IcalTodo({
    required this.uid,
    required this.summary,
    required this.listId,
    required this.parentId,
    required this.order,
    required this.start,
    required this.due,
    required this.allDay,
    required this.priority,
    required this.completed,
    required this.completedAt,
    required this.rrule,
    required this.recurrencePreset,
    required this.recurrenceId,
    required this.reminderMinutes,
    required this.linkedEventId,
    this.description = '',
  });

  final String uid;
  final String summary;
  final String description;

  /// `X-KOS-LIST-ID`；空 → 服务回放 `"inbox"`（PimStore.cpp:407）。
  final String listId;

  /// `X-KOS-PARENT-ID`。
  final String parentId;

  /// `X-KOS-ORDER`（字符串 double，PimStore.cpp:409）。
  final double order;

  /// `DTSTART`；null = 未设（`hasStartDate()` false → 快照写 `""`，
  /// PimStore.cpp:410-411）。
  final DateTime? start;

  /// `DUE`；null = 未设（`hasDueDate()` false → 快照写 `""`，:412-413）。
  final DateTime? due;
  final bool allDay;

  /// `PRIORITY` 0-9（KCalendarCore 语义：0 未指定，1 最高，
  /// schema 行 120）。
  final int priority;
  final bool completed;

  /// `COMPLETED` 时刻；未完成/未记录为 null（快照写 `""`，:417-418）。
  final DateTime? completedAt;

  final String rrule;
  final String recurrencePreset;
  final String recurrenceId;
  final int reminderMinutes;

  /// `X-KOS-LINKED-EVENT-ID`，空时回退 `RELATED-TO`
  /// （`linkedEventId()`，PimStore.cpp:234-238）。
  final String linkedEventId;
}

/// 一份 `calendar.ics` 的解析结果。
final class IcalDocument {
  const IcalDocument({required this.events, required this.todos});

  final List<IcalEvent> events;
  final List<IcalTodo> todos;
}

/// 折叠展开后的内容行：`NAME;PARAM=VAL;...:value`。
final class _ContentLine {
  const _ContentLine(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;
}

/// iCalendar 解析器（无状态静态函数集合）。
abstract final class IcalParser {
  /// 解析 `calendar.ics` 全文。宽容解析：非 VEVENT/VTODO 组件、
  /// 未知属性一律跳过（与 KCalendarCore 容错语义一致，保证与
  /// NextKde 写的完整文件共存）。
  static IcalDocument parse(String text) {
    final events = <IcalEvent>[];
    final todos = <IcalTodo>[];

    // RFC 5545 §3.1 折叠：换行后紧跟空格/制表符 = 续行，去掉换行+首字符。
    // KCalendarCore 落盘用 CRLF；对 LF/CR 也宽容。
    final rawLines = text.split(RegExp('\r\n|\n|\r'));
    final lines = <String>[];
    for (final raw in rawLines) {
      if (raw.isEmpty) continue;
      if ((raw.startsWith(' ') || raw.startsWith('\t')) &&
          lines.isNotEmpty) {
        lines[lines.length - 1] += raw.substring(1);
      } else {
        lines.add(raw);
      }
    }

    // 组件栈：VEVENT/VTODO 内嵌 VALARM，VALARM 结束时弹回父块。
    final stack = <String>[];
    final block = <_ContentLine>[];
    String? alarmTrigger;

    void flushComponent(String name) {
      if (name == 'VEVENT') {
        final e = _parseVEvent(block, alarmTrigger);
        if (e != null) events.add(e);
        block.clear();
        alarmTrigger = null;
      } else if (name == 'VTODO') {
        final t = _parseVTodo(block, alarmTrigger);
        if (t != null) todos.add(t);
        block.clear();
        alarmTrigger = null;
      }
      // VALARM 等嵌套块结束不清 block——属性行属于父组件。
    }

    for (final line in lines) {
      if (line.startsWith('BEGIN:')) {
        stack.add(line.substring(6).trim().toUpperCase());
        continue;
      }
      if (line.startsWith('END:')) {
        final closing = line.substring(4).trim().toUpperCase();
        if (stack.isNotEmpty && stack.last == closing) {
          stack.removeLast();
          flushComponent(closing);
        }
        continue;
      }
      if (stack.isEmpty) continue;
      if (stack.last == 'VALARM') {
        // 只取第一个 TRIGGER（reminderMinutes 只读首个 enabled alarm，
        // PimStore.cpp:161-174）。
        if (line.startsWith('TRIGGER') && alarmTrigger == null) {
          alarmTrigger = _splitLine(line)?.value;
        }
        continue;
      }
      if (stack.last != 'VEVENT' && stack.last != 'VTODO') continue;
      final parsed = _splitLine(line);
      if (parsed != null) block.add(parsed);
    }
    return IcalDocument(events: events, todos: todos);
  }

  static _ContentLine? _splitLine(String line) {
    // 属性头/值边界 = 首个不在双引号参数值内的冒号（RFC 5545 §3.1：
    // 参数值允许引号串含 `:`/`;`，如 `ALTREP="cid:…"`、`CN="a;b"`）。
    // 同理参数列表按未引号 `;` 分割，引号内分号不当分隔符。
    var inQuotes = false;
    var colon = -1;
    for (var i = 0; i < line.length; i += 1) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ':' && !inQuotes) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;
    final head = line.substring(0, colon);
    final value = line.substring(colon + 1);
    // 按未引号 `;` 切分 `NAME;PARAM=VAL;...`（引号内 `;` 留在参数值里）。
    final segments = <String>[];
    final buf = StringBuffer();
    inQuotes = false;
    for (var i = 0; i < head.length; i += 1) {
      final c = head[i];
      if (c == '"') {
        inQuotes = !inQuotes;
        buf.write(c);
      } else if (c == ';' && !inQuotes) {
        segments.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    segments.add(buf.toString());
    final name = segments.first.trim().toUpperCase();
    if (name.isEmpty) return null;
    final params = <String, String>{};
    for (final p in segments.skip(1)) {
      final eq = p.indexOf('=');
      if (eq > 0) {
        var v = p.substring(eq + 1).trim();
        // 参数值去引号（RFC 5545 param-value 的 DQUOTE 包裹层）。
        if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
          v = v.substring(1, v.length - 1);
        }
        params[p.substring(0, eq).trim().toUpperCase()] = v;
      }
    }
    return _ContentLine(name, params, value);
  }

  static String _param(_ContentLine line, String key) =>
      line.params[key] ?? '';

  static bool _isDateOnly(_ContentLine line) =>
      _param(line, 'VALUE').toUpperCase() == 'DATE' ||
      !line.value.contains('T');

  /// `YYYYMMDD` / `YYYYMMDDTHHMMSS[Z]` → 本地 DateTime；非法返回 null。
  static DateTime? _parseDateValue(_ContentLine line) {
    final v = line.value.trim();
    if (v.length < 8) return null;
    final year = int.tryParse(v.substring(0, 4));
    final month = int.tryParse(v.substring(4, 6));
    final day = int.tryParse(v.substring(6, 8));
    if (year == null || month == null || day == null) return null;
    if (_isDateOnly(line) || v.length < 15) {
      return DateTime(year, month, day); // 日零点（allDay / VALUE=DATE）
    }
    final hour = int.tryParse(v.substring(9, 11)) ?? 0;
    final minute = int.tryParse(v.substring(11, 13)) ?? 0;
    final second = int.tryParse(v.substring(13, 15)) ?? 0;
    if (v.endsWith('Z')) {
      // UTC 时刻换算本地（KCalendarCore 以系统时区展示，PimStore.cpp:470）。
      return DateTime.utc(year, month, day, hour, minute, second).toLocal();
    }
    return DateTime(year, month, day, hour, minute, second);
  }

  static String _unescape(String v) => v
      .replaceAll('\\n', '\n')
      .replaceAll('\\N', '\n')
      .replaceAll('\\,', ',')
      .replaceAll('\\;', ';')
      .replaceAll('\\\\', '\\');

  /// TRIGGER 值 → 提前分钟（只认 `-P...` 负相对偏移；正偏移/绝对时间
  /// 与缺省 → -1）。对齐 reminderMinutes() 的 `-seconds/60`
  /// （PimStore.cpp:166-168）。
  static int _triggerMinutes(String? trigger) {
    if (trigger == null || !trigger.startsWith('-')) return -1;
    final body = trigger.substring(1);
    final dMatch = RegExp(r'(\d+)D').firstMatch(body);
    final hMatch = RegExp(r'T(\d+)H').firstMatch(body);
    final mMatch = RegExp(r'T(?:\d+H)?(\d+)M').firstMatch(body);
    var minutes = 0;
    if (dMatch != null) minutes += int.parse(dMatch.group(1)!) * 1440;
    if (hMatch != null) minutes += int.parse(hMatch.group(1)!) * 60;
    if (mMatch != null) minutes += int.parse(mMatch.group(1)!);
    return minutes;
  }

  static IcalEvent? _parseVEvent(
    List<_ContentLine> lines,
    String? alarmTrigger,
  ) {
    var uid = '';
    var summary = '';
    var description = '';
    var location = '';
    DateTime? start;
    DateTime? end;
    var allDay = false;
    var tzid = '';
    var calendarId = '';
    var rrule = '';
    var preset = '';
    var recurrenceId = '';
    var linkedTodoId = '';

    for (final line in lines) {
      switch (line.name) {
        case 'UID':
          uid = line.value.trim();
        case 'SUMMARY':
          summary = _unescape(line.value);
        case 'DESCRIPTION':
          description = _unescape(line.value);
        case 'LOCATION':
          location = _unescape(line.value);
        case 'DTSTART':
          start = _parseDateValue(line);
          allDay = _isDateOnly(line);
          tzid = _param(line, 'TZID');
        case 'DTEND':
          end = _parseDateValue(line);
        case 'RRULE':
          rrule = line.value.trim();
        case 'RECURRENCE-ID':
          recurrenceId = line.value.trim();
        case 'X-KOS-CALENDAR-ID':
          calendarId = line.value.trim();
        case 'X-KOS-RECURRENCE-PRESET':
          preset = line.value.trim();
        case 'X-KOS-LINKED-TODO-ID':
          linkedTodoId = line.value.trim();
      }
    }
    if (uid.isEmpty || start == null) return null;
    // DTEND 缺失：对齐 createEvent 的兜底（PimStore.cpp:916-917）
    // allDay +1 日 / timed +1 小时。
    final effectiveEnd = end ??
        (allDay
            ? start.add(const Duration(days: 1))
            : start.add(const Duration(hours: 1)));
    return IcalEvent(
      uid: uid,
      summary: summary,
      description: description,
      location: location,
      start: start,
      end: effectiveEnd,
      allDay: allDay,
      timeZone: tzid,
      calendarId: calendarId,
      rrule: rrule,
      recurrencePreset: preset.isEmpty
          ? (rrule.isNotEmpty ? 'custom' : 'none')
          : preset,
      recurrenceId: recurrenceId,
      reminderMinutes: _triggerMinutes(alarmTrigger),
      linkedTodoId: linkedTodoId,
    );
  }

  static IcalTodo? _parseVTodo(
    List<_ContentLine> lines,
    String? alarmTrigger,
  ) {
    var uid = '';
    var summary = '';
    var description = '';
    DateTime? start;
    DateTime? due;
    var allDay = false;
    var priority = 0;
    var completed = false;
    DateTime? completedAt;
    var listId = '';
    var parentId = '';
    var order = 0.0;
    var rrule = '';
    var preset = '';
    var recurrenceId = '';
    var linkedEventId = '';
    var relatedTo = '';

    for (final line in lines) {
      switch (line.name) {
        case 'UID':
          uid = line.value.trim();
        case 'SUMMARY':
          summary = _unescape(line.value);
        case 'DESCRIPTION':
          description = _unescape(line.value);
        case 'DTSTART':
          start = _parseDateValue(line);
          allDay = _isDateOnly(line);
        case 'DUE':
          due = _parseDateValue(line);
          // DTSTART 缺失时 allDay 由 DUE 的 VALUE=DATE 决定。
          if (start == null) allDay = _isDateOnly(line);
        case 'PRIORITY':
          priority = int.tryParse(line.value.trim()) ?? 0;
        case 'STATUS':
          completed = line.value.trim().toUpperCase() == 'COMPLETED';
        case 'COMPLETED':
          completedAt = _parseDateValue(line);
        case 'RRULE':
          rrule = line.value.trim();
        case 'RECURRENCE-ID':
          recurrenceId = line.value.trim();
        case 'RELATED-TO':
          relatedTo = line.value.trim();
        case 'X-KOS-LIST-ID':
          listId = line.value.trim();
        case 'X-KOS-PARENT-ID':
          parentId = line.value.trim();
        case 'X-KOS-ORDER':
          order = double.tryParse(line.value.trim()) ?? 0;
        case 'X-KOS-RECURRENCE-PRESET':
          preset = line.value.trim();
        case 'X-KOS-LINKED-EVENT-ID':
          linkedEventId = line.value.trim();
      }
    }
    if (uid.isEmpty) return null;
    return IcalTodo(
      uid: uid,
      summary: summary,
      description: description,
      listId: listId,
      parentId: parentId,
      order: order,
      start: start,
      due: due,
      allDay: allDay,
      priority: priority,
      completed: completed,
      completedAt: completedAt,
      rrule: rrule,
      recurrencePreset: preset.isEmpty
          ? (rrule.isNotEmpty ? 'custom' : 'none')
          : preset,
      recurrenceId: recurrenceId,
      reminderMinutes: _triggerMinutes(alarmTrigger),
      linkedEventId:
          linkedEventId.isNotEmpty ? linkedEventId : relatedTo,
    );
  }

  // ---------- 序列化 ----------

  static String _escape(String v) => v
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\n', '\\n');

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtDateTime(DateTime d) =>
      '${_fmtDate(d)}T${d.hour.toString().padLeft(2, '0')}'
      '${d.minute.toString().padLeft(2, '0')}'
      '${d.second.toString().padLeft(2, '0')}';

  /// RFC 5545 §3.1 折行：每行 ≤75 字节（octet），续行以空格开头。
  /// KCalendarCore 按字节折行；中文多字节字符不能在 UTF-8 序列中间断，
  /// 逐 rune 累计字节数再折。
  static List<String> _fold(String line) {
    const limit = 75;
    final chunks = <String>[];
    var current = StringBuffer();
    var currentBytes = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final size = _utf8Length(rune);
      // 续行首字符是空格也占 1 字节，按 74 预算折更稳。
      final budget = chunks.isEmpty ? limit : limit - 1;
      if (currentBytes + size > budget) {
        chunks.add(current.toString());
        current = StringBuffer()..write(char);
        currentBytes = size;
      } else {
        current.write(char);
        currentBytes += size;
      }
    }
    chunks.add(current.toString());
    return [
      chunks.first,
      for (var i = 1; i < chunks.length; i += 1) ' ${chunks[i]}',
    ];
  }

  static int _utf8Length(int rune) => rune < 0x80
      ? 1
      : rune < 0x800
          ? 2
          : rune < 0x10000
              ? 3
              : 4;

  /// [event] 序列化为 VEVENT 行（不含 BEGIN:VCALENDAR 外壳，
  /// 由 [serialize] 组装）。
  static List<String> eventLines(IcalEvent event) {
    final lines = <String>[
      'BEGIN:VEVENT',
      'UID:${event.uid}',
      if (event.allDay)
        'DTSTART;VALUE=DATE:${_fmtDate(event.start)}'
      else
        'DTSTART'
            '${event.timeZone.isNotEmpty ? ';TZID=${event.timeZone}' : ''}'
            ':${_fmtDateTime(event.start)}',
      if (event.allDay)
        'DTEND;VALUE=DATE:${_fmtDate(event.end)}'
      else
        'DTEND'
            '${event.timeZone.isNotEmpty ? ';TZID=${event.timeZone}' : ''}'
            ':${_fmtDateTime(event.end)}',
      'SUMMARY:${_escape(event.summary)}',
      if (event.description.isNotEmpty)
        'DESCRIPTION:${_escape(event.description)}',
      if (event.location.isNotEmpty)
        'LOCATION:${_escape(event.location)}',
      if (event.rrule.isNotEmpty) 'RRULE:${event.rrule}',
      if (event.recurrenceId.isNotEmpty)
        'RECURRENCE-ID:${event.recurrenceId}',
      if (event.calendarId.isNotEmpty)
        'X-KOS-CALENDAR-ID:${event.calendarId}',
      if (event.recurrencePreset.isNotEmpty &&
          event.recurrencePreset != 'none')
        'X-KOS-RECURRENCE-PRESET:${event.recurrencePreset}',
      if (event.linkedTodoId.isNotEmpty)
        'X-KOS-LINKED-TODO-ID:${event.linkedTodoId}',
      if (event.reminderMinutes >= 0) ...[
        'BEGIN:VALARM',
        'TRIGGER:-PT${event.reminderMinutes}M',
        'ACTION:DISPLAY',
        'END:VALARM',
      ],
      'END:VEVENT',
    ];
    return [for (final l in lines) ..._fold(l)];
  }

  /// [todo] 序列化为 VTODO 行。
  static List<String> todoLines(IcalTodo todo) {
    String fmt(DateTime d) => todo.allDay ? _fmtDate(d) : _fmtDateTime(d);
    final lines = <String>[
      'BEGIN:VTODO',
      'UID:${todo.uid}',
      'SUMMARY:${_escape(todo.summary)}',
      if (todo.description.isNotEmpty)
        'DESCRIPTION:${_escape(todo.description)}',
      if (todo.start != null)
        todo.allDay
            ? 'DTSTART;VALUE=DATE:${fmt(todo.start!)}'
            : 'DTSTART:${fmt(todo.start!)}',
      if (todo.due != null)
        todo.allDay
            ? 'DUE;VALUE=DATE:${fmt(todo.due!)}'
            : 'DUE:${fmt(todo.due!)}',
      if (todo.priority > 0) 'PRIORITY:${todo.priority}',
      if (todo.completed) 'STATUS:COMPLETED',
      if (todo.completedAt != null)
        'COMPLETED:${_fmtDateTime(todo.completedAt!.toUtc())}Z',
      if (todo.rrule.isNotEmpty) 'RRULE:${todo.rrule}',
      if (todo.recurrenceId.isNotEmpty)
        'RECURRENCE-ID:${todo.recurrenceId}',
      if (todo.linkedEventId.isNotEmpty) 'RELATED-TO:${todo.linkedEventId}',
      if (todo.listId.isNotEmpty) 'X-KOS-LIST-ID:${todo.listId}',
      if (todo.parentId.isNotEmpty) 'X-KOS-PARENT-ID:${todo.parentId}',
      'X-KOS-ORDER:${_fmtOrder(todo.order)}',
      if (todo.recurrencePreset.isNotEmpty &&
          todo.recurrencePreset != 'none')
        'X-KOS-RECURRENCE-PRESET:${todo.recurrencePreset}',
      if (todo.linkedEventId.isNotEmpty)
        'X-KOS-LINKED-EVENT-ID:${todo.linkedEventId}',
      if (todo.reminderMinutes >= 0) ...[
        'BEGIN:VALARM',
        'TRIGGER:-PT${todo.reminderMinutes}M',
        'ACTION:DISPLAY',
        'END:VALARM',
      ],
      'END:VTODO',
    ];
    return [for (final l in lines) ..._fold(l)];
  }

  static String _fmtOrder(double order) =>
      order == order.roundToDouble()
          ? order.toInt().toString()
          : order.toString();

  /// 整文档序列化（`BEGIN:VCALENDAR` 外壳 + CRLF 结尾）。
  static String serialize(IcalDocument doc) {
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//KOS//PimStore//CN',
      for (final e in doc.events) ...eventLines(e),
      for (final t in doc.todos) ...todoLines(t),
      'END:VCALENDAR',
    ];
    return '${lines.join('\r\n')}\r\n';
  }
}
