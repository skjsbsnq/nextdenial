// DeskCenter 配置持久化测试（TASK-05）。
//
// 对齐 DeskCenterConfigService.qml 语义：
// - schemaVersion 2（:29）：非 2 / 损坏 / 缺失一律回退默认序；
// - orderedIds（:38-54）：存储序滤未知/重复 + defaultOrder 补尾；
// - sizeFor/cycleSize/setSize（:69-93）：默认表 + normalizedSize 归一；
// - moveWidget（:56-67）：剔除 + clamp 插入；
// - hidden（AppearanceConfigService.hiddenDeskCenterWidgets，
//   DeskCenterWindow.qml:220）并入同一 JSON。
//
// IO（DeskCenterConfigStore）写临时文件 + rename 原子落盘，测试用
// `Directory.systemTemp` 下的临时目录验证序列化往返与损坏回退。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart';
import 'package:kos_deskcenter/src/state/desk_center_config.dart';
import 'package:kos_deskcenter/src/state/desk_center_config_io.dart';

void main() {
  group('DeskCenterConfig（纯模型）', () {
    test('默认值 = defaultOrder + 默认尺寸表 + 无隐藏', () {
      final config = DeskCenterConfig.defaults();
      expect(config.order, kosDeskCenterDefaultOrder);
      expect(config.sizeFor('clock'), WidgetSize.medium); // TASK-08 默认 medium
      expect(config.sizeFor('weather'), WidgetSize.medium);
      expect(config.hidden, isEmpty);
    });

    test('orderedIds 过滤未知 id、去重、按 defaultOrder 补尾（:38-54）', () {
      final config = DeskCenterConfig.fromJson({
        'schemaVersion': 2,
        'order': ['music', 'bogus', 'clock', 'music'],
      });
      // 存储序优先（music, clock），未知 'bogus' 与重复丢弃，其余补尾。
      expect(config.order, [
        'music',
        'clock',
        'weather',
        'calendar',
        'todo',
        'system',
        'activity',
      ]);
    });

    test('sizeFor 按存储值→默认表→medium 归一（:69-73）', () {
      final config = DeskCenterConfig.fromJson({
        'schemaVersion': 2,
        'sizes': {'clock': 'large', 'weather': 'huge', 'bogus': 'small'},
      });
      expect(config.sizeFor('clock'), WidgetSize.large);
      // 'huge' 经 normalizedSize 落 medium（WidgetLayout.mjs:13-15）。
      expect(config.sizeFor('weather'), WidgetSize.medium);
      // 未知 id 的条目被丢弃，未知 id 的查询落 medium。
      expect(config.sizeFor('bogus'), WidgetSize.medium);
    });

    test('cycleSize 按 sizeOrder 循环（:88-93）', () {
      var config = DeskCenterConfig.defaults(); // clock=medium（TASK-08）
      config = config.cycleSize('clock');
      expect(config.sizeFor('clock'), WidgetSize.large);
      config = config.cycleSize('clock');
      expect(config.sizeFor('clock'), WidgetSize.small);
      config = config.cycleSize('clock');
      expect(config.sizeFor('clock'), WidgetSize.medium); // 循环回绕
    });

    test('moveWidget 剔除后 clamp 插入（:56-67）', () {
      final config = DeskCenterConfig.defaults();
      // clock 移到 weather 的索引（indexOf('weather') = 1）。
      final moved = config.moveWidget('clock', 1);
      expect(moved.order.first, 'weather');
      expect(moved.order[1], 'clock');
      // 未知 id 不动（:59-60）。
      expect(config.moveWidget('nope', 0), config);
    });

    test('setVisible 隐藏/恢复（DeskCenterWindow.qml:564-566、443-445）', () {
      var config = DeskCenterConfig.defaults();
      config = config.setVisible('music', false);
      expect(config.isVisible('music'), isFalse);
      expect(config.isVisible('clock'), isTrue);
      config = config.setVisible('music', true);
      expect(config.isVisible('music'), isTrue);
      // 未知 id 不改配置。
      expect(
        config.setVisible('nope', false),
        config,
      );
    });
  });

  group('序列化往返（toJson/fromJson）', () {
    test('编辑后序列化→解析回等价配置', () {
      final config = DeskCenterConfig.defaults()
          .cycleSize('weather')
          .setVisible('todo', false)
          .moveWidget('music', 0);
      final roundTrip = DeskCenterConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())),
      );
      expect(roundTrip.order, config.order);
      expect(roundTrip.sizes, config.sizes);
      expect(roundTrip.hidden, config.hidden);
      expect(roundTrip, config);
    });

    test('toJson 顶层带 schemaVersion 2', () {
      expect(
        DeskCenterConfig.defaults().toJson()['schemaVersion'],
        kosDeskCenterConfigSchemaVersion,
      );
    });
  });

  group('损坏/缺失回退（source JSON.parse catch 语义）', () {
    test('非 Map / schemaVersion 非 2 → 默认', () {
      expect(
        DeskCenterConfig.fromJson('junk'),
        DeskCenterConfig.defaults(),
      );
      expect(
        DeskCenterConfig.fromJson({'schemaVersion': 1, 'order': ['music']}),
        DeskCenterConfig.defaults(),
      );
      expect(DeskCenterConfig.fromJson(null), DeskCenterConfig.defaults());
    });

    test('字段缺失逐项回退（order 缺 → defaultOrder 全量）', () {
      final config = DeskCenterConfig.fromJson({'schemaVersion': 2});
      expect(config.order, kosDeskCenterDefaultOrder);
      expect(config.sizes, isEmpty); // sizes 空 → 全走默认表
      expect(config.sizeFor('calendar'), WidgetSize.medium);
    });
  });

  group('DeskCenterConfigStore（dart:io 原子读写）', () {
    late Directory tempDir;
    late DeskCenterConfigStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('kos_deskcenter_test');
      store = DeskCenterConfigStore(
        path: '${tempDir.path}/kos_deskcenter/config.json',
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('缺失文件 → 默认配置', () async {
      expect(await store.load(), DeskCenterConfig.defaults());
    });

    test('写入→读取往返（含隐藏列表跨重启生效，验收 4）', () async {
      final config = DeskCenterConfig.defaults()
          .setVisible('weather', false)
          .cycleSize('clock');
      await store.save(config);
      // 新建 store 实例模拟重启重建。
      final reloaded = await DeskCenterConfigStore(path: store.path).load();
      expect(reloaded, config);
      expect(reloaded.isVisible('weather'), isFalse);
      expect(reloaded.sizeFor('clock'), WidgetSize.large);
    });

    test('损坏 JSON → 默认配置', () async {
      await File(store.path).parent.create(recursive: true);
      await File(store.path).writeAsString('{broken');
      expect(await store.load(), DeskCenterConfig.defaults());
    });

    test('写入是原子的：先写 .tmp 再 rename，目标文件始终完整', () async {
      final config = DeskCenterConfig.defaults();
      await store.save(config);
      // 落盘后临时文件已被 rename 消耗。
      expect(File('${store.path}.tmp').existsSync(), isFalse);
      final text = await File(store.path).readAsString();
      expect(jsonDecode(text), config.toJson());
    });
  });
}
