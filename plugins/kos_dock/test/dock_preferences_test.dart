// DockPreferences / FileDockPreferencesStore / DockOrder / 控制器测试
//（TASK-01；TASK-04 增补 showLauncher/showTrash 与 schema version 语义）。
//
// 覆盖：JSON 容错解析（合法/非法/去重/未知 key 保留）、showLauncher/showTrash
// 「仅显式 false 隐藏」语义、文件缺失→空、temp+rename 原子写往返、
// version:1 落盘、写路径保留 flags/未知 key、损坏 JSON 仍抛 FormatException、
// DockOrder pinned 顺序恢复与 reorder 语义、控制器串行写与未改字段保留。
// 真文件用 `Directory.systemTemp`（kos_deskcenter `zz_io_probe_test.dart`
// 已证 testWidgets fake-async 区内真 IO 可完成；本组用普通 `test`）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/dock_preferences_io.dart';
import 'package:kos_dock/src/state/dock_settings.dart';

/// 测试用 pin：`appId` 默认等于 `id`，使旧形状（`{kind:"app", desktopId}`）
/// 往返后 id 不变。
PinnedApplication _pin(String id, [String? appId, String? name]) =>
    PinnedApplication(id: id, appId: appId ?? id, name: name ?? id);

/// 用户真实 `~/.config/denial/plugins/kos_dock.json` 的逐字副本（旧 kos_dock
/// schemaVersion 1 文档：`options` + `pinned: [{kind:"app", desktopId}]`）。
/// 单测不得读真文件，故内联为 fixture。
const String _legacyUserDocument = '''
{
  "schemaVersion": 1,
  "options": {
    "enabled": true,
    "position": "bottom",
    "iconSize": 48,
    "magnification": true,
    "magnificationScale": 1.5,
    "autoHide": false,
    "launchBounce": true,
    "showIndicators": true,
    "showRecent": true,
    "showThumbnails": true,
    "previewSize": 160,
    "contextPinning": true
  },
  "pinned": [
    {"kind": "app", "desktopId": "dev.denial.Settings"},
    {"kind": "app", "desktopId": "org.gnome.Nautilus"},
    {"kind": "app", "desktopId": "kitty"},
    {"kind": "app", "desktopId": "io.missioncenter.MissionCenter"},
    {"kind": "app", "desktopId": "sparkle"},
    {"kind": "app", "desktopId": "firefox"}
  ]
}
''';

Iterable<File> _tempFiles(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.tmp'));

/// 内存 store：保留未指定字段，供控制器 flag/队列语义断言。
class _MemoryStore implements DockPreferencesStore {
  _MemoryStore(this.preferences);

  DockPreferences preferences;
  int writePinsCalls = 0;
  int writeVisibilityCalls = 0;
  int writeInfoCardsCalls = 0;

  @override
  Future<DockPreferences> read() async => preferences;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
    writePinsCalls++;
    preferences = DockPreferences(
      pinned: pins,
      showLauncher: preferences.showLauncher,
      showTrash: preferences.showTrash,
    );
  }

  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {
    writeVisibilityCalls++;
    preferences = DockPreferences(
      pinned: preferences.pinned,
      showLauncher: showLauncher ?? preferences.showLauncher,
      showTrash: showTrash ?? preferences.showTrash,
      infoCardOrder: preferences.infoCardOrder,
      infoCardAutoRotate: preferences.infoCardAutoRotate,
      infoCardMode: preferences.infoCardMode,
    );
  }

  @override
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  }) async {
    writeInfoCardsCalls++;
    // 只改指定项（null = 不改），保留 pinned/可见性/其它信息卡字段。
    preferences = DockPreferences(
      pinned: preferences.pinned,
      showLauncher: preferences.showLauncher,
      showTrash: preferences.showTrash,
      infoCardOrder: order ?? preferences.infoCardOrder,
      infoCardAutoRotate: autoRotate ?? preferences.infoCardAutoRotate,
      infoCardMode: mode ?? preferences.infoCardMode,
    );
  }
}

void main() {
  group('normalizeApplicationId', () {
    test('trim → lowercase → 去 .desktop 后缀', () {
      expect(normalizeApplicationId('  Foo.DESKTOP '), 'foo');
      expect(normalizeApplicationId('Firefox.desktop'), 'firefox');
      expect(normalizeApplicationId('org.kde.Kate'), 'org.kde.kate');
      expect(normalizeApplicationId(''), '');
    });
  });

  group('dockInfoCardNeedsWeather（天气订阅同源判据）', () {
    test('含 weather 或含 clock → 需要天气快照；其余 → 不需要', () {
      expect(dockInfoCardNeedsWeather(const ['weather']), isTrue);
      expect(dockInfoCardNeedsWeather(const ['clock', 'metrics']), isTrue);
      expect(dockInfoCardNeedsWeather(const ['metrics', 'weather']), isTrue);
      // clock 页的日出/日落读同一快照 → 不能被 weather-only 条件门控。
      expect(dockInfoCardNeedsWeather(const ['music', 'metrics']), isFalse);
      expect(dockInfoCardNeedsWeather(const <String>[]), isFalse);
    });
  });

  group('DockPreferences.fromJson', () {
    test('合法列表按序解析', () {
      final prefs = DockPreferences.fromJson({
        'pinnedApplications': [
          {'id': 'a', 'appId': 'a.desktop', 'name': 'A'},
          {'id': 'b', 'appId': 'b.desktop', 'name': 'B'},
        ],
      });
      expect(prefs.pinned.map((p) => p.id), ['a', 'b']);
      expect(prefs.pinned.first.appId, 'a.desktop');
    });

    test('非法条目跳过：非 Map、缺字段、空 id/appId、非 String name', () {
      final prefs = DockPreferences.fromJson({
        'pinnedApplications': [
          'junk',
          42,
          {'appId': 'x', 'name': 'X'}, // 缺 id
          {'id': '', 'appId': 'x', 'name': 'X'}, // 空 id
          {'id': 'ok', 'appId': '', 'name': 'X'}, // 空 appId
          {'id': 'ok2', 'appId': 'x', 'name': 3}, // 非 String name
          {'id': 'ok', 'appId': 'ok.desktop', 'name': 'OK'},
        ],
      });
      expect(prefs.pinned.map((p) => p.id), ['ok']);
    });

    test('按 id 去重（保留首个）', () {
      final prefs = DockPreferences.fromJson({
        'pinnedApplications': [
          {'id': 'a', 'appId': 'a1', 'name': 'first'},
          {'id': 'a', 'appId': 'a2', 'name': 'second'},
        ],
      });
      expect(prefs.pinned.length, 1);
      expect(prefs.pinned.single.appId, 'a1');
    });

    test('无 pinnedApplications / 非 List → 空', () {
      expect(const DockPreferences().pinned, isEmpty);
      expect(DockPreferences.fromJson(const {}).pinned, isEmpty);
      expect(
        DockPreferences.fromJson(const {'pinnedApplications': 'nope'}).pinned,
        isEmpty,
      );
    });

    test('showLauncher/showTrash 默认 true；仅显式 false 为 false', () {
      // 构造默认 + 缺失 key。
      expect(const DockPreferences().showLauncher, isTrue);
      expect(const DockPreferences().showTrash, isTrue);
      final missing = DockPreferences.fromJson(const {});
      expect(missing.showLauncher, isTrue);
      expect(missing.showTrash, isTrue);

      // KOS DockConfigService.qml:622-623 显式 false。
      final hidden = DockPreferences.fromJson(const {
        'showLauncher': false,
        'showTrash': false,
      });
      expect(hidden.showLauncher, isFalse);
      expect(hidden.showTrash, isFalse);

      // 显式 true 与「非 bool」都保留可见默认。
      final explicitTrue = DockPreferences.fromJson(const {
        'showLauncher': true,
        'showTrash': true,
      });
      expect(explicitTrue.showLauncher, isTrue);
      expect(explicitTrue.showTrash, isTrue);

      final malformed = DockPreferences.fromJson(const {
        'showLauncher': 'false',
        'showTrash': 0,
      });
      expect(malformed.showLauncher, isTrue);
      expect(malformed.showTrash, isTrue);
    });

    test('schemaVersion == 1', () {
      expect(DockPreferences.schemaVersion, 1);
    });
  });

  group('旧 kos_dock 文档兼容（D1-1 回归）', () {
    test('真实旧文档的 pinned 数组按序解析（旧实现全部丢弃 → 空图标行）', () {
      final prefs = DockPreferences.fromJson(
        jsonDecode(_legacyUserDocument) as Map<String, dynamic>,
      );
      expect(prefs.pinned.map((p) => p.id), [
        'dev.denial.Settings',
        'org.gnome.Nautilus',
        'kitty',
        'io.missioncenter.MissionCenter',
        'sparkle',
        'firefox',
      ]);
      // desktopId 同时作 launch id 与 icon appId；旧文档无 name → ''。
      expect(prefs.pinned.first.appId, 'dev.denial.Settings');
      expect(prefs.pinned.map((p) => p.name), everyElement(''));
      expect(prefs.showLauncher, isTrue);
      expect(prefs.showTrash, isTrue);
    });

    test('旧非 app kind（spacer/small-spacer/separator/folder/file）静默跳过', () {
      final prefs = DockPreferences.fromJson(const {
        'pinned': [
          {'kind': 'spacer', 'id': 'sp-1'},
          {'kind': 'small-spacer', 'id': 'sp-2'},
          {'kind': 'separator'},
          {'kind': 'folder', 'url': 'file:///home/wwt/文档'},
          {'kind': 'file', 'url': 'file:///home/wwt/a.png'},
          {'kind': 'app', 'desktopId': 'kitty'},
          {'kind': 'app', 'desktopId': 42}, // 非法 desktopId
          {'kind': 'app'}, // 缺 desktopId
          'junk',
        ],
      });
      expect(prefs.pinned.map((p) => p.id), ['kitty']);
    });

    test('两种形状混合：新键在前、旧键在后，按 normalizeApplicationId 去重', () {
      final prefs = DockPreferences.fromJson(const {
        'pinnedApplications': [
          {'id': 'Kitty', 'appId': 'kitty', 'name': 'Kitty'},
          {'id': 'firefox.desktop', 'appId': 'firefox', 'name': 'Firefox'},
        ],
        'pinned': [
          {'kind': 'app', 'desktopId': 'kitty'}, // 与 'Kitty' 归一化后同键
          {'kind': 'app', 'desktopId': 'org.gnome.Nautilus'},
        ],
      });
      expect(prefs.pinned.map((p) => p.id), [
        'Kitty',
        'firefox.desktop',
        'org.gnome.Nautilus',
      ]);
    });
  });

  group('FileDockPreferencesStore', () {
    late Directory dir;
    late File file;
    late FileDockPreferencesStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('kos_dock_prefs_');
      file = File('${dir.path}/kos_dock.json');
      store = FileDockPreferencesStore(file);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<Map<String, dynamic>> readJson() async =>
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;

    test('真实旧文档：writeVisibility 保留 options/未知 key，pinned 原样不丢', () async {
      await file.writeAsString(_legacyUserDocument);

      await store.writeVisibility(showTrash: false);

      final json = await readJson();
      expect(json['showTrash'], isFalse);
      // 旧文档不写这两个 key → 保持默认可见（KOS `!== false` 语义），
      // 写路径也不新增 `showLauncher`。
      expect(json['showLauncher'], isNull);
      expect(json['version'], DockPreferences.schemaVersion);
      expect(json['schemaVersion'], DockPreferences.schemaVersion);
      expect((json['options'] as Map<String, dynamic>)['iconSize'], 48);
      expect(json.containsKey('pinnedApplications'), isFalse);

      final pinned = json['pinned'] as List<dynamic>;
      expect(pinned.length, 6);
      expect(pinned.first, {'kind': 'app', 'desktopId': 'dev.denial.Settings'});
      expect(
        (pinned.first as Map<String, dynamic>).keys,
        ['kind', 'desktopId'],
      );
      expect(_tempFiles(dir), isEmpty);

      final prefs = await store.read();
      expect(prefs.pinned.map((p) => p.id), [
        'dev.denial.Settings',
        'org.gnome.Nautilus',
        'kitty',
        'io.missioncenter.MissionCenter',
        'sparkle',
        'firefox',
      ]);
      expect(prefs.showTrash, isFalse);
    });

    test('visibility 写路径把早期 pinnedApplications 形状迁成旧形状', () async {
      await file.writeAsString(
        '{"options":{"iconSize":48,"autoHide":false},"custom":{"x":1},'
        '"pinnedApplications":[{"id":"kitty","appId":"kitty","name":"Kitty"}]}\n',
      );

      await store.writeVisibility(showLauncher: false);

      final json = await readJson();
      expect(json.containsKey('pinnedApplications'), isFalse);
      expect(json['pinned'], [
        {'kind': 'app', 'desktopId': 'kitty'},
      ]);
      expect((json['options'] as Map<String, dynamic>)['autoHide'], isFalse);
      expect((json['custom'] as Map<String, dynamic>)['x'], 1);
      expect(json['showLauncher'], isFalse);

      final prefs = await store.read();
      expect(prefs.pinned.single.id, 'kitty');
      // 旧形状不带 name。
      expect(prefs.pinned.single.name, '');
    });

    test('writePins 落旧形状条目（kind/app desktopId）+ 保留 options', () async {
      await file.writeAsString(_legacyUserDocument);

      await store.writePins(const [
        PinnedApplication(id: 'kitty', appId: 'kitty', name: 'Kitty'),
        PinnedApplication(id: 'firefox', appId: 'firefox', name: 'Firefox'),
      ]);

      final json = await readJson();
      expect(json['pinned'], [
        {'kind': 'app', 'desktopId': 'kitty'},
        {'kind': 'app', 'desktopId': 'firefox'},
      ]);
      expect(json['schemaVersion'], DockPreferences.schemaVersion);
      expect((json['options'] as Map<String, dynamic>)['previewSize'], 160);
      expect(_tempFiles(dir), isEmpty);
    });

    test('读→写→读 往返不丢 pin（旧文档，两种写路径）', () async {
      await file.writeAsString(_legacyUserDocument);
      final before = await store.read();
      final ids = before.pinned.map((p) => p.id).toList();

      await store.writePins(before.pinned);
      expect((await store.read()).pinned.map((p) => p.id), ids);

      await store.writeVisibility(showTrash: false);
      final after = await store.read();
      expect(after.pinned.map((p) => p.id), ids);
      expect(after.showTrash, isFalse);
      expect(after.pinned.map((p) => p.appId), ids);
    });

    test('文件缺失 → 空偏好', () async {
      final prefs = await store.read();
      expect(prefs.pinned, isEmpty);
      expect(prefs.showLauncher, isTrue);
      expect(prefs.showTrash, isTrue);
    });

    test('writePins → read 顺序一致（temp+rename 原子写）', () async {
      await store.writePins([_pin('a'), _pin('b'), _pin('c')]);
      final prefs = await store.read();
      expect(prefs.pinned.map((p) => p.id), ['a', 'b', 'c']);
      // temp 文件清理干净。
      expect(_tempFiles(dir), isEmpty);
    });

    test('writePins 写 version:1 且保留 showLauncher/showTrash', () async {
      await file.writeAsString('{"showLauncher":false,"showTrash":true}\n');
      await store.writePins([_pin('a')]);

      final prefs = await store.read();
      expect(prefs.pinned.map((p) => p.id), ['a']);
      expect(prefs.showLauncher, isFalse);
      expect(prefs.showTrash, isTrue);

      final json = await readJson();
      expect(json['version'], DockPreferences.schemaVersion);
      expect(_tempFiles(dir), isEmpty);
    });

    test('writeVisibility 往返 + version:1 落盘 + 无 .tmp 残留', () async {
      await store.writeVisibility(showLauncher: false);
      var prefs = await store.read();
      expect(prefs.showLauncher, isFalse);
      expect(prefs.showTrash, isTrue);
      expect(prefs.pinned, isEmpty);

      await store.writeVisibility(showTrash: false);
      prefs = await store.read();
      expect(prefs.showLauncher, isFalse);
      expect(prefs.showTrash, isFalse);
      expect(prefs.pinned, isEmpty);

      final json = await readJson();
      expect(json['version'], DockPreferences.schemaVersion);
      expect(json['showLauncher'], isFalse);
      expect(json['showTrash'], isFalse);
      expect(_tempFiles(dir), isEmpty);
    });

    test('writeVisibility 只改指定 flag：保留 pinned/另一 flag/未知 key', () async {
      await file.writeAsString(
        '{"custom":{"x":1},"showLauncher":true,"showTrash":true,'
        '"pinned":[{"kind":"app","desktopId":"kitty"},'
        '{"kind":"spacer","id":"sp-1","small":false}]}\n',
      );
      await store.writeVisibility(showTrash: false);

      final prefs = await store.read();
      expect(prefs.showLauncher, isTrue);
      expect(prefs.showTrash, isFalse);
      expect(prefs.pinned.map((p) => p.id), ['kitty']);

      final text = await file.readAsString();
      expect(text, contains('"custom"'));
      // 旧键 `pinned` 原样保留：v1 不渲染的 spacer kind 不被写路径丢弃。
      expect(text, contains('"spacer"'));
      expect((await readJson())['version'], DockPreferences.schemaVersion);
      expect(_tempFiles(dir), isEmpty);
    });

    test('未知 JSON key writePins 写回后保留', () async {
      await file.writeAsString(
        '{"custom":{"x":1},"pinnedApplications":[{"id":"a","appId":"a","name":"A"}]}\n',
      );
      await store.writePins([_pin('b')]);
      final text = await file.readAsString();
      expect(text, contains('"custom"'));
      final prefs = await store.read();
      expect(prefs.pinned.map((p) => p.id), ['b']);
    });

    test('缺 version / 未知 version 读取不崩溃', () async {
      await file.writeAsString('{"showLauncher":false}\n');
      var prefs = await store.read();
      expect(prefs.showLauncher, isFalse);
      expect(prefs.showTrash, isTrue);

      await file.writeAsString('{"version":99,"showTrash":false}\n');
      prefs = await store.read();
      expect(prefs.showTrash, isFalse);
      expect(prefs.showLauncher, isTrue);
      expect(prefs.pinned, isEmpty);
    });

    test('损坏 JSON → read 抛 FormatException（不静默覆盖）', () async {
      await file.writeAsString('{broken');
      await expectLater(store.read(), throwsFormatException);
      await expectLater(store.writePins([_pin('a')]), throwsFormatException);
      await expectLater(
        store.writeVisibility(showLauncher: false),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken');
    });
  });

  group('DockPreferencesController', () {
    test('写串行且保留未改字段（updatePins/updateShowLauncher/updateShowTrash）', () async {
      final store = _MemoryStore(
        const DockPreferences(showLauncher: false, showTrash: false),
      );
      final container = ProviderContainer(
        overrides: [dockPreferencesStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(dockPreferencesProvider.notifier);
      await container.read(dockPreferencesProvider.future);

      // updatePins 不重置 flags（修复点）。
      await notifier.updatePins((pins) => [...pins, _pin('a')]);
      var state = container.read(dockPreferencesProvider).requireValue;
      expect(state.pinned.map((p) => p.id), ['a']);
      expect(state.showLauncher, isFalse);
      expect(state.showTrash, isFalse);
      expect(store.preferences.showLauncher, isFalse);
      expect(store.preferences.showTrash, isFalse);

      // 可见性写保留 pinned 与另一 flag。
      await notifier.updateShowLauncher(true);
      state = container.read(dockPreferencesProvider).requireValue;
      expect(state.showLauncher, isTrue);
      expect(state.showTrash, isFalse);
      expect(state.pinned.map((p) => p.id), ['a']);

      await notifier.updateShowTrash(true);
      state = container.read(dockPreferencesProvider).requireValue;
      expect(state.showLauncher, isTrue);
      expect(state.showTrash, isTrue);
      expect(state.pinned.map((p) => p.id), ['a']);

      expect(store.writePinsCalls, 1);
      expect(store.writeVisibilityCalls, 2);
    });
  });

  group('DockOrder', () {
    test('pinned 顺序恢复', () {
      final order = DockOrder();
      expect(order.update(['a', 'b']), ['a', 'b']);
      // 重启后 pinned 重排：update 同步新的相对顺序。
      expect(order.update(['b', 'a']), ['b', 'a']);
    });

    test('消失的键被丢弃、新 pin 追加', () {
      final order = DockOrder();
      order.update(['a', 'b']);
      expect(order.update(['b', 'c']), ['b', 'c']);
    });

    test('reorder 移动语义 + 越界安全', () {
      final order = DockOrder();
      order.update(['a', 'b', 'c']);
      expect(order.reorder(0, 2), ['b', 'c', 'a']);
      expect(order.reorder(-1, 0), ['b', 'c', 'a']);
      expect(order.reorder(0, 3), ['b', 'c', 'a']);
      expect(order.reorder(2, 0), ['a', 'b', 'c']);
    });
  });
}
