// TASK-05：信息卡偏好的归一化/持久化测试。
//
// 纯函数 + 内存 store + FileDockPreferencesStore 真实 IO（systemTemp，
// 与 trash_service_io_test.dart 同范式）；无 socket/dbus 依赖。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/dock_preferences_io.dart';
import 'package:kos_dock/src/state/dock_settings.dart';

class _MemoryStore implements DockPreferencesStore {
  _MemoryStore(this.prefs);

  DockPreferences prefs;

  @override
  Future<DockPreferences> read() async => prefs;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
    prefs = DockPreferences(
      pinned: pins,
      showLauncher: prefs.showLauncher,
      showTrash: prefs.showTrash,
      infoCardOrder: prefs.infoCardOrder,
      infoCardAutoRotate: prefs.infoCardAutoRotate,
      infoCardMode: prefs.infoCardMode,
    );
  }

  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {
    prefs = DockPreferences(
      pinned: prefs.pinned,
      showLauncher: showLauncher ?? prefs.showLauncher,
      showTrash: showTrash ?? prefs.showTrash,
      infoCardOrder: prefs.infoCardOrder,
      infoCardAutoRotate: prefs.infoCardAutoRotate,
      infoCardMode: prefs.infoCardMode,
    );
  }

  @override
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  }) async {
    prefs = DockPreferences(
      pinned: prefs.pinned,
      showLauncher: prefs.showLauncher,
      showTrash: prefs.showTrash,
      infoCardOrder: order ?? prefs.infoCardOrder,
      infoCardAutoRotate: autoRotate ?? prefs.infoCardAutoRotate,
      infoCardMode: mode ?? prefs.infoCardMode,
    );
  }
}

void main() {
  group('normalizeDockInfoCardOrder', () {
    test('temperature→metrics、未知 id 丢弃、去重、保持入参相对顺序', () {
      expect(
        normalizeDockInfoCardOrder([
          'temperature',
          'bogus',
          'clock',
          'clock',
          'music',
          42,
        ]),
        ['metrics', 'clock', 'music'],
      );
      // 返回不可变列表（防调用方就地改）。
      expect(
        () => normalizeDockInfoCardOrder(['clock']).add('music'),
        throwsUnsupportedError,
      );
    });
  });

  group('DockPreferences.fromJson · 信息卡字段', () {
    test('infoCardOrder 键缺失 → 默认四卡；键存在（含空数组）→ 原样保留', () {
      expect(
        DockPreferences.fromJson(const {}).infoCardOrder,
        DockPreferences.kDockInfoCardOrderDefault,
      );
      // 空数组 = 「删光信息卡」→ info 区隐藏（KOS 零项即隐藏，
      // normalizedInfoCardOrder([]) 保持 []），不得复活默认四卡。
      expect(
        DockPreferences.fromJson(const {'infoCardOrder': <String>[]})
            .infoCardOrder,
        isEmpty,
      );
      // 非 List/String 的坏值 → 按缺失处理（默认四卡）。
      expect(
        DockPreferences.fromJson(const {'infoCardOrder': 42}).infoCardOrder,
        DockPreferences.kDockInfoCardOrderDefault,
      );
    });


    test('infoCardOrder 单 String 也接受（归一化）', () {
      expect(
        DockPreferences.fromJson(const {'infoCardOrder': 'temperature'})
            .infoCardOrder,
        ['metrics'],
      );
    });

    test('infoCardAutoRotate 用 !== false 语义', () {
      expect(DockPreferences.fromJson(const {}).infoCardAutoRotate, isTrue);
      expect(
        DockPreferences.fromJson(const {'infoCardAutoRotate': true})
            .infoCardAutoRotate,
        isTrue,
      );
      expect(
        DockPreferences.fromJson(const {'infoCardAutoRotate': 'nope'})
            .infoCardAutoRotate,
        isTrue,
      );
      expect(
        DockPreferences.fromJson(const {'infoCardAutoRotate': false})
            .infoCardAutoRotate,
        isFalse,
      );
    });
  });

  group('updateInfoCardOrder（controller 写路径）', () {
    test('归一化后落盘，且 state 保留 pinned/show*', () async {
      final store = _MemoryStore(
        const DockPreferences(
          pinned: [
            PinnedApplication(id: 'kate', appId: 'kate', name: 'Kate'),
          ],
          showLauncher: false,
        ),
      );
      final container = ProviderContainer(
        overrides: [dockPreferencesStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(dockPreferencesProvider.future);

      await container
          .read(dockPreferencesProvider.notifier)
          .updateInfoCardOrder((_) => ['temperature', 'junk', 'music']);

      expect(store.prefs.infoCardOrder, ['metrics', 'music']);
      final state = container.read(dockPreferencesProvider).requireValue;
      expect(state.infoCardOrder, ['metrics', 'music']);
      expect(state.pinned.single.id, 'kate');
      expect(state.showLauncher, isFalse);
    });
  });

  group('FileDockPreferencesStore.writeInfoCards（真实 IO）', () {
    test('只改指定项，保留 pinned/show*/未知 key 与其它信息卡字段', () async {
      final dir = Directory.systemTemp.createTempSync('kos_dock_info_prefs_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/kos_dock.json');
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'pinned': [
            {'kind': 'app', 'desktopId': 'kate'},
          ],
          'showLauncher': false,
          'showTrash': true,
          'infoCardOrder': ['music', 'clock'],
          'infoCardAutoRotate': true,
          'infoCardMode': 'carousel',
          'customUnknownKey': {'a': 1},
        }),
      );
      final store = FileDockPreferencesStore(file);

      await store.writeInfoCards(order: ['weather', 'metrics']);

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['infoCardOrder'], ['weather', 'metrics']);
      // 未指定项不动。
      expect(raw['infoCardAutoRotate'], isTrue);
      expect(raw['infoCardMode'], 'carousel');
      // pinned / 可见性 / 未知 key 保留。
      expect(raw['showLauncher'], false);
      expect(raw['showTrash'], true);
      expect(raw['pinned'], [
        {'kind': 'app', 'desktopId': 'kate'},
      ]);
      expect(raw['customUnknownKey'], {'a': 1});

      final prefs = await store.read();
      expect(prefs.infoCardOrder, ['weather', 'metrics']);
      expect(prefs.showLauncher, isFalse);
      expect(prefs.pinned.single.id, 'kate');
    });

    test('autoRotate 写路径不动 order', () async {
      final dir = Directory.systemTemp.createTempSync('kos_dock_info_prefs_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/kos_dock.json');
      await file.writeAsString(
        jsonEncode({'infoCardOrder': ['clock', 'weather']}),
      );
      final store = FileDockPreferencesStore(file);

      await store.writeInfoCards(autoRotate: false);

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['infoCardAutoRotate'], false);
      expect(raw['infoCardOrder'], ['clock', 'weather']);
    });

    test('删光信息卡（写空 order）→ 重启读回仍为空（不复活四卡）', () async {
      final dir = Directory.systemTemp.createTempSync('kos_dock_info_prefs_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/kos_dock.json');
      final store = FileDockPreferencesStore(file);
      // 用户删掉最后一张卡：写路径允许空。
      await store.writeInfoCards(order: const <String>[]);
      expect(
        jsonDecode(await file.readAsString())['infoCardOrder'],
        isEmpty,
      );
      // 重启（重新 read）后仍是空 order → hasInfo=false（info 区隐藏）。
      expect((await store.read()).infoCardOrder, isEmpty);
    });
  });
}
