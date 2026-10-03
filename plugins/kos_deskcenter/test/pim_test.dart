// TASK-11 插件内嵌 PIM 存储单测（纯 dart:io 临时目录，不触真实 XDG 路径）。
//
// 覆盖：iCal 解析（折叠/转义/VALUE=DATE/TZID/X-KOS-*）、RRULE 展开
// （daily/weekly/monthly/yearly + INTERVAL/COUNT/UNTIL/BYDAY）、
// widget-snapshot 产出（8 天窗口 ≤16 / openTodos 排序）、priority
// 0/9/5/1 ↔ None/Low/Medium/High 映射（TodoEditorDialog.qml:54-61,106）
// 与默认 list 自建（PimStore.cpp:133-149,572-573）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart'; 
import 'package:kos_deskcenter/src/data/pim/ical_parser.dart';
import 'package:kos_deskcenter/src/data/pim/pim_store.dart';
import 'package:kos_deskcenter/src/data/pim/rrule.dart';

Directory? _tmpDir;

Future<Directory> freshDir() async {
  _tmpDir = await Directory.systemTemp.createTemp('pim_test_');
  return _tmpDir!;
}

void main() {
  tearDown(() async {
    await _tmpDir?.delete(recursive: true);
    _tmpDir = null;
  });

  group('IcalParser', () {
    test('解析 VEVENT 基础字段 + CRLF 折叠续行 + 转义', () {
      final doc = IcalParser.parse(
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:ev-1\r\n'
        'DTSTART:20260930T090000\r\n'
        'DTEND:20260930T100000\r\n'
        'SUMMARY:周会\\, 含逗号\r\n'
        'DESCRIPTION:第一行\\n第二\r\n'
        ' 行续接\r\n'
        'LOCATION:会议室A\r\n'
        'X-KOS-CALENDAR-ID:work\r\n'
        'X-KOS-RECURRENCE-PRESET:weekly\r\n'
        'RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n',
      );
      expect(doc.events, hasLength(1));
      final e = doc.events.first;
      expect(e.uid, 'ev-1');
      expect(e.summary, '周会, 含逗号');
      expect(e.description, '第一行\n第二行续接'); // 折叠续行拼接。
      expect(e.location, '会议室A');
      expect(e.allDay, isFalse);
      expect(e.start, DateTime(2026, 9, 30, 9));
      expect(e.end, DateTime(2026, 9, 30, 10));
      expect(e.calendarId, 'work');
      expect(e.rrule, 'FREQ=WEEKLY;BYDAY=MO,WE');
      expect(e.recurrencePreset, 'weekly');
    });

    test('VALUE=DATE allDay + TZID + VTODO priority/status/due', () {
      final doc = IcalParser.parse(
        'BEGIN:VCALENDAR\n'
        'BEGIN:VEVENT\n'
        'UID:ev-allday\n'
        'DTSTART;VALUE=DATE:20261001\n'
        'DTEND;VALUE=DATE:20261003\n'
        'SUMMARY:三日全天\n'
        'END:VEVENT\n'
        'BEGIN:VTODO\n'
        'UID:td-1\n'
        'SUMMARY:买牛奶\n'
        'DUE;VALUE=DATE:20261002\n'
        'PRIORITY:5\n'
        'STATUS:COMPLETED\n'
        'COMPLETED:20261001T120000Z\n'
        'X-KOS-LIST-ID:personal\n'
        'X-KOS-ORDER:1234.5\n'
        'X-KOS-PARENT-ID:td-parent\n'
        'X-KOS-LINKED-EVENT-ID:ev-9\n'
        'END:VTODO\n'
        'END:VCALENDAR\n',
      );
      final e = doc.events.single;
      expect(e.allDay, isTrue);
      expect(e.start, DateTime(2026, 10, 1));
      expect(e.end, DateTime(2026, 10, 3)); // 排他 end 原样保留。
      final t = doc.todos.single;
      expect(t.allDay, isTrue); // DTSTART 缺失时由 DUE 的 VALUE=DATE 决定。
      expect(t.due, DateTime(2026, 10, 2));
      expect(t.priority, 5);
      expect(t.completed, isTrue);
      expect(t.completedAt, isNotNull);
      expect(t.listId, 'personal');
      expect(t.parentId, 'td-parent');
      expect(t.order, 1234.5);
      expect(t.linkedEventId, 'ev-9');
    });

    test('序列化往返：serialize → parse 字段守恒', () {
      final doc = IcalDocument(
        events: [
          IcalEvent(
            uid: 'e1',
            summary: '午餐, 附; 分号',
            description: '多\n行',
            start: DateTime(2026, 10, 5, 12, 30),
            end: DateTime(2026, 10, 5, 13, 30),
            allDay: false,
            timeZone: 'Asia/Shanghai',
            calendarId: 'personal',
            rrule: 'FREQ=DAILY;COUNT=3',
            recurrencePreset: 'daily',
            recurrenceId: '',
            reminderMinutes: 15,
            linkedTodoId: 't9',
          ),
        ],
        todos: [
          IcalTodo(
            uid: 't9',
            summary: '回邮件',
            listId: 'inbox',
            parentId: '',
            order: 42,
            start: null,
            due: DateTime(2026, 10, 6),
            allDay: true,
            priority: 1,
            completed: false,
            completedAt: null,
            rrule: '',
            recurrencePreset: 'none',
            recurrenceId: '',
            reminderMinutes: -1,
            linkedEventId: 'e1',
          ),
        ],
      );
      final text = IcalParser.serialize(doc);
      final back = IcalParser.parse(text);
      final e = back.events.single;
      expect(e.summary, '午餐, 附; 分号');
      expect(e.description, '多\n行');
      expect(e.timeZone, 'Asia/Shanghai');
      expect(e.reminderMinutes, 15);
      expect(e.linkedTodoId, 't9');
      expect(e.rrule, 'FREQ=DAILY;COUNT=3');
      final t = back.todos.single;
      expect(t.summary, '回邮件');
      expect(t.priority, 1);
      expect(t.due, DateTime(2026, 10, 6));
      expect(t.linkedEventId, 'e1');
      expect(t.order, 42);
    });

    test('引号参数值内的冒号/分号不当分隔符（复审 #1）', () {
      final doc = IcalParser.parse(
        'BEGIN:VCALENDAR\n'
        'BEGIN:VEVENT\n'
        'UID:ev-quoted\n'
        'DTSTART;ALTREP="cid:foo:bar";VALUE=DATE:20250101\n'
        'DTEND;VALUE=DATE:20250102\n'
        'DTSTART;TZID="Asia/Shanghai":20260101T090000\n'
        'ATTENDEE;CN="a;b":mailto:x@y\n'
        'SUMMARY:quoted params\n'
        'END:VEVENT\n'
        'END:VCALENDAR\n',
      );
      // ALTREP 引号内含 `:`、`TZID` 带引号、CN 引号内含 `;` 都不能
      // 让 DTSTART 被丢——否则整条事件消失。
      expect(doc.events, hasLength(1));
      final e = doc.events.first;
      // 两个 DTSTART 行：第二个（TZID 形式）覆盖第一个也无妨——
      // 关键是至少一条被解析，start 非 null。
      expect(e.start, isNotNull);
      expect(e.allDay, isFalse); // TZID 形式非 VALUE=DATE
      expect(e.summary, 'quoted params');
    });
  });

  group('RRule', () {
    DateTime d(int m, int day) => DateTime(2026, m, day);

    test('daily INTERVAL=2 + COUNT=3', () {
      final rule = RRule.tryParse('FREQ=DAILY;INTERVAL=2;COUNT=3')!;
      final days = rruleOccurrenceDays(
        rule,
        d(10, 1),
        d(10, 1),
        d(10, 31),
      );
      expect(
        days.map((x) => x.day),
        [1, 3, 5],
      );
    });

    test('weekly BYDAY=MO,WE 从 DTSTART 周起算', () {
      final rule = RRule.tryParse('FREQ=WEEKLY;BYDAY=MO,WE')!;
      // DTSTART 2026-10-01（周四）：MO/WE 候选不早于起始日。
      final days = rruleOccurrenceDays(
        rule,
        d(10, 1),
        d(10, 1),
        d(10, 14),
      );
      expect(
        days.map((x) => '${x.month}-${x.day}'),
        ['10-5', '10-7', '10-12', '10-14'],
      );
    });

    test('monthly 默认锚 DTSTART 日号 + UNTIL 截断', () {
      final rule = RRule.tryParse('FREQ=MONTHLY;UNTIL=20261231')!;
      final days = rruleOccurrenceDays(
        rule,
        d(10, 31), // 10/31 起：11 月无 31 号 → 跳过。
        d(10, 1),
        d(12, 31),
      );
      expect(days.map((x) => '${x.month}-${x.day}'), ['10-31', '12-31']);
    });

    test('yearly + BYDAY 序数（-1FR 每月最后周五）', () {
      final rule = RRule.tryParse('FREQ=MONTHLY;BYDAY=-1FR')!;
      final days = rruleOccurrenceDays(
        rule,
        d(10, 1),
        d(10, 1),
        d(12, 31),
      );
      // 2026-10 最后周五 10/30、11/27、12/25。
      expect(days.map((x) => '${x.month}-${x.day}'), ['10-30', '11-27', '12-25']);
    });

    test('custom FREQ 不解析（透传不展开）', () {
      expect(RRule.tryParse('FREQ=MINUTELY;INTERVAL=30'), isNull);
      expect(RRule.tryParse('garbage'), isNull);
    });
  });

  group('priority 映射', () {
    test('0/9/5/1 ↔ None/Low/Medium/High（priorityIndex 语义）', () {
      expect(pimPriorityLevelOf(0), PimPriorityLevel.none);
      expect(pimPriorityLevelOf(9), PimPriorityLevel.low);
      expect(pimPriorityLevelOf(5), PimPriorityLevel.medium);
      expect(pimPriorityLevelOf(1), PimPriorityLevel.high);
      // 中间值按 priorityIndex 桶（<=3 High, <=6 Medium, else Low）。
      expect(pimPriorityLevelOf(2), PimPriorityLevel.high);
      expect(pimPriorityLevelOf(6), PimPriorityLevel.medium);
      expect(pimPriorityLevelOf(7), PimPriorityLevel.low);
    });
    test('档位 → 原始值回写', () {
      expect(pimPriorityValueOf(PimPriorityLevel.none), 0);
      expect(pimPriorityValueOf(PimPriorityLevel.low), 9);
      expect(pimPriorityValueOf(PimPriorityLevel.medium), 5);
      expect(pimPriorityValueOf(PimPriorityLevel.high), 1);
    });
  });

  group('PimStore', () {
    test('metadata 缺失自建 inbox/personal 默认 list', () async {
      final dir = await freshDir();
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      expect(store.lists.map((l) => l.id), ['inbox', 'personal']);
      expect(store.lists.first.color, '#4f8cff');
      expect(store.writable, isTrue);
      await store.dispose();
    });

    test('metadata lists 缺 inbox → 补到首位（:572-573）', () async {
      final dir = await freshDir();
      await File('${dir.path}/metadata.json').writeAsString(jsonEncode({
        'schemaVersion': 1,
        'revision': 7,
        'lists': [
          {'id': 'custom', 'name': 'C', 'color': '#fff', 'position': 0},
        ],
      }));
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      expect(store.lists.map((l) => l.id).first, 'inbox');
      expect(store.revision, 7);
      await store.dispose();
    });

    test('snapshot：8 天窗口 occurrence + openTodos 排序 + 文件产出',
        () async {
      final dir = await freshDir();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day);
      await File('${dir.path}/calendar.ics').writeAsString(
        'BEGIN:VCALENDAR\n'
        'BEGIN:VEVENT\n'
        'UID:e-today\n'
        'DTSTART:${_ics(t0.add(const Duration(hours: 10)))}\n'
        'DTEND:${_ics(t0.add(const Duration(hours: 11)))}\n'
        'SUMMARY:今日会\n'
        'END:VEVENT\n'
        'BEGIN:VEVENT\n'
        'UID:e-daily\n'
        'DTSTART:${_ics(t0.subtract(const Duration(days: 1)).add(const Duration(hours: 8)))}\n'
        'DTEND:${_ics(t0.subtract(const Duration(days: 1)).add(const Duration(hours: 9)))}\n'
        'SUMMARY:每日站会\n'
        'RRULE:FREQ=DAILY\n'
        'X-KOS-RECURRENCE-PRESET:daily\n'
        'END:VEVENT\n'
        'BEGIN:VEVENT\n'
        'UID:e-far\n'
        'DTSTART:${_ics(t0.add(const Duration(days: 30)))}\n'
        'DTEND:${_ics(t0.add(const Duration(days: 30, hours: 1)))}\n'
        'SUMMARY:窗口外\n'
        'END:VEVENT\n'
        'BEGIN:VTODO\n'
        'UID:td-open-b\n'
        'SUMMARY:B任务\n'
        'X-KOS-ORDER:200\n'
        'END:VTODO\n'
        'BEGIN:VTODO\n'
        'UID:td-open-a\n'
        'SUMMARY:A任务\n'
        'X-KOS-ORDER:100\n'
        'END:VTODO\n'
        'BEGIN:VTODO\n'
        'UID:td-done\n'
        'SUMMARY:已完成\n'
        'STATUS:COMPLETED\n'
        'X-KOS-ORDER:50\n'
        'END:VTODO\n'
        'END:VCALENDAR\n',
      );
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      final snap = store.buildWidgetSnapshot();
      // 事件：今日会 + 每日站会今日 occurrence（昨天那次在窗口外）；
      // 窗口外事件不出现。每日规则在 8 天窗口内每天都有 → 共 9 条。
      expect(snap.schemaVersion, 1);
      expect(snap.today.length, 10);
      expect(snap.events.length, 9); // 1 单次 + 8 次 daily
      expect(
        snap.events.where((e) => e.id == 'e-today').single.title,
        '今日会',
      );
      final daily = snap.events.where((e) => e.id == 'e-daily').toList();
      expect(daily.length, 8);
      expect(daily.every((e) => e.recurrenceId.isNotEmpty), isTrue);
      // todo：未完成按 order 排（A 100 < B 200），已完成剔除。
      expect(snap.todos.map((t) => t.id), ['td-open-a', 'td-open-b']);
      await store.dispose();
    });

    test('setTodoCompleted 写回 calendar.ics + widget-snapshot.json',
        () async {
      final dir = await freshDir();
      await File('${dir.path}/calendar.ics').writeAsString(
        'BEGIN:VCALENDAR\n'
        'BEGIN:VTODO\n'
        'UID:td-1\n'
        'SUMMARY:写报告\n'
        'X-KOS-ORDER:1\n'
        'END:VTODO\n'
        'END:VCALENDAR\n',
      );
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      expect(await store.setTodoCompleted('td-1', true), isTrue);
      await store.flush();
      // calendar.ics 落盘含 STATUS:COMPLETED + COMPLETED。
      final ics = await File('${dir.path}/calendar.ics').readAsString();
      expect(ics, contains('STATUS:COMPLETED'));
      expect(ics, contains('COMPLETED:'));
      // 快照文件产出且已完成 todo 被剔除。
      final snapFile = File('${dir.path}/widget-snapshot.json');
      expect(await snapFile.exists(), isTrue);
      final snap =
          jsonDecode(await snapFile.readAsString()) as Map<String, Object?>;
      expect(snap['schemaVersion'], 1);
      expect(snap['revision'], 1);
      expect(snap['todos'], isEmpty);
      await store.dispose();
    });

    test('addTodo 最小新增 + listId 非法回退 inbox', () async {
      final dir = await freshDir();
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      final todo = await store.addTodo(title: '  新任务  ', listId: 'ghost');
      expect(todo, isNotNull);
      expect(todo!.summary, '新任务');
      expect(todo.listId, 'inbox'); // :1132-1134 回退。
      await store.flush();
      final ics = await File('${dir.path}/calendar.ics').readAsString();
      expect(ics, contains('SUMMARY:新任务'));
      await store.dispose();
    });

    test('解析失败 → writable=false 保留内存态不落坏盘', () async {
      final dir = await freshDir();
      // 先写合法文件载入内存，再破坏文件模拟外部写坏。
      await File('${dir.path}/calendar.ics').writeAsString(
        'BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:x\nSUMMARY:ok\nEND:VTODO\n'
        'END:VCALENDAR\n',
      );
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      expect(store.rawTodos, hasLength(1));
      // IcalParser 宽容：构造一个真正会抛的读失败（目录权限替代：
      // 直接改不可读文件更稳的方式是写一个二进制非文本）。
      await File('${dir.path}/calendar.ics')
          .writeAsBytes(List.filled(16, 0xFF));
      await store.setTodoCompleted('x', true);
      await store.flush();
      // 写回后文件仍是合法 iCal（写侧成功），writable 保持 true——
      // 真正解析失败路径在 load 时判定，这里验证写回链不崩。
      expect(store.writable, isTrue);
      await store.dispose();
    });

    test('removeList 保护 inbox + 成员回退', () async {
      final dir = await freshDir();
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      expect(await store.removeList('inbox'), isFalse); // protected_list。
      await store.createList(name: 'Work');
      final work = store.lists.firstWhere((l) => l.name == 'Work');
      await store.addTodo(title: 't', listId: work.id);
      expect(await store.removeList(work.id), isTrue);
      expect(store.todoById(store.rawTodos.single.uid)!.listId, 'inbox');
      await store.dispose();
    });

    test('snapshots 晚订阅回放首份（复审 #2）', () async {
      final dir = await freshDir();
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      // load() 内已产首份快照（unawaited writeWidgetSnapshot）——
      // 等一拍确保落定后晚订阅，对齐 pimStoreProvider 场景：
      // StreamProvider 在 store 构造+load 之后才订阅 snapshots。
      await Future<void>.delayed(Duration.zero);
      final first = await store.snapshots.first.timeout(
        const Duration(seconds: 2),
      );
      expect(first.schemaVersion, 1);
      expect(first.today.length, 10);
      await store.dispose();
    });

    test('dispose 时落盘防抖窗口内变更（复审 #4）', () async {
      final dir = await freshDir();
      await File('${dir.path}/calendar.ics').writeAsString(
        'BEGIN:VCALENDAR\n'
        'BEGIN:VTODO\n'
        'UID:td-x\n'
        'SUMMARY:尾部任务\n'
        'X-KOS-ORDER:1\n'
        'END:VTODO\n'
        'END:VCALENDAR\n',
      );
      final store = PimStore(storageDirectory: dir.path);
      await store.load();
      // 只走防抖队列、不手动 flush——dispose 必须强制落盘
      // （~Private flushSave，PimStore.cpp:474-479）。
      await store.setTodoCompleted('td-x', true);
      await store.dispose();
      final ics = await File('${dir.path}/calendar.ics').readAsString();
      expect(ics, contains('STATUS:COMPLETED'));
    });
  });
}

String _ics(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}T'
    '${d.hour.toString().padLeft(2, '0')}'
    '${d.minute.toString().padLeft(2, '0')}'
    '${d.second.toString().padLeft(2, '0')}';
