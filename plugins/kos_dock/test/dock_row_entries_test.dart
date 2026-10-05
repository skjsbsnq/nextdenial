// dock_row_entries 纯函数测试（TASK-04b 方案 A 单一事实来源 + D-1 launch id）。
//
// 覆盖：条目数 = pinned + 未 pin 运行段聚合数；pinned 段顺序 =
// prefs.pinned 顺序；未 pin 段按 canonical appId 聚合、首次出现顺序；
// 「既 pin 又在跑」只出现一次；catalog 命中的 pinned 条目 launchId =
// LaunchableApplication.id（D-1），未命中退化为 pin.id。

import 'package:denial_flutter_sdk/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/dock_preferences.dart';
import 'package:kos_dock/src/state/dock_row_entries.dart';

LaunchableApplication _app(
  String id,
  String appId, {
  String? name,
  List<String>? windowAppIds,
}) => LaunchableApplication(
  id: id,
  appId: appId,
  name: name ?? appId,
  windowAppIds: windowAppIds ?? [appId],
);

/// 迁移态 pin：id == appId == desktopId（`_decodeLegacyPin` 形状）。
PinnedApplication _legacyPin(String desktopId) =>
    PinnedApplication(id: desktopId, appId: desktopId, name: '');

ApplicationWindow _window(int id, String appId) =>
    ApplicationWindow(
      id: id,
      appId: appId,
      title: 'w$id',
      active: false,
      minimized: false,
    );

void main() {
  group('dockRowEntries', () {
    test('空 pinned + 无窗口 → 空', () {
      expect(
        dockRowEntries(
          prefs: const DockPreferences(),
          catalog: const [],
          windows: const [],
        ),
        isEmpty,
      );
    });

    test('pinned 段顺序 = prefs.pinned 顺序；无窗时 windows 空', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(
          pinned: [_legacyPin('b'), _legacyPin('a')],
        ),
        catalog: [
          _app('desktop:b', 'b'),
          _app('desktop:a', 'a'),
        ],
        windows: const [],
      );
      expect(entries.map((e) => e.key), ['app:b', 'app:a']);
      expect(entries.every((e) => e.isPinned), isTrue);
      expect(entries.every((e) => e.windows.isEmpty), isTrue);
    });

    test('未 pin 窗口按 canonical appId 聚合 + 首次出现顺序', () {
      final entries = dockRowEntries(
        prefs: const DockPreferences(),
        catalog: const [],
        windows: [
          _window(1, 'firefox'),
          _window(2, 'kitty'),
          _window(3, 'firefox'), // 同 appId 聚到 firefox 组
        ],
      );
      expect(entries.length, 2);
      expect(entries[0].key, 'run:firefox');
      expect(entries[0].windows.map((w) => w.id), [1, 3]);
      expect(entries[1].key, 'run:kitty');
      expect(entries[1].windows.map((w) => w.id), [2]);
      expect(entries.every((e) => !e.isPinned), isTrue);
    });

    test('既 pin 又在跑 → 只出现一次（pinned 段，窗口挂到 pin）', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('kitty')]),
        catalog: [_app('desktop:kitty', 'kitty')],
        windows: [_window(1, 'kitty'), _window(2, 'kitty')],
      );
      expect(entries.length, 1);
      expect(entries.single.isPinned, isTrue);
      expect(entries.single.key, 'app:kitty');
      expect(entries.single.windows.map((w) => w.id), [1, 2]);
    });

    test('windowAppIds 别名匹配到 pin（不重复进运行段）', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('org.kde.kate')]),
        catalog: [
          _app(
            'desktop:org.kde.kate',
            'kate',
            name: 'Kate',
            windowAppIds: ['kate'],
          ),
        ],
        windows: [_window(7, 'KATE')],
      );
      expect(entries.length, 1);
      expect(entries.single.isPinned, isTrue);
      expect(entries.single.windows.map((w) => w.id), [7]);
    });

    test('D-1：catalog 命中 → launchId = LaunchableApplication.id（带 desktop: 前缀）',
        () {
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('kitty')]),
        catalog: [_app('desktop:kitty', 'kitty', name: 'kitty')],
        windows: const [],
      );
      expect(entries.single.launchId, 'desktop:kitty');
      expect(entries.single.appId, 'kitty');
    });

    test('D-1：catalog 未命中 → launchId 退化为 pin.id（不崩）', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('ghost')]),
        catalog: [_app('desktop:kitty', 'kitty')],
        windows: const [],
      );
      expect(entries.single.launchId, 'ghost');
    });

    test('D-1：local: scheme 迁移态 pin → launchId = local:myapp（剥 local: 前缀判等）',
        () {
      // 宿主 catalog 对本地应用用 `local:<id>`（denial_desktop
      // `application_recents_controller.dart:9-12`）；迁移态 pin 只有
      // bare id='myapp'，不剥 `local:` scheme 会 launch-key miss，且
      // appId/windowAppIds 同样不含 bare id → 退化为 pin.id 直接 launch
      // 'myapp'（宿主不识别），丢 `local:` 前缀。
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('myapp')]),
        catalog: [
          _app('local:myapp', 'local-myapp', name: 'My App'),
        ],
        windows: const [],
      );
      expect(entries.single.launchId, 'local:myapp');
      expect(entries.single.appId, 'local-myapp');
      expect(entries.single.name, 'My App');
    });

    test('D-1：同 launch key 多个 catalog 条目 → 不取 first，落 pin.appId 唯一反查',
        () {
      // `desktop:dup` 与 `local:dup` 剥 scheme 后同 launch key 'app:dup'；
      // firstOrNull 会静默取第一个（'desktop:dup'，错误的 appId），唯一性
      // 检查则落下一层 `dockCatalogFor(pin.appId)` 唯一命中第二条目。
      final entries = dockRowEntries(
        prefs: const DockPreferences(
          pinned: [
            PinnedApplication(id: 'dup', appId: 'dup-app', name: ''),
          ],
        ),
        catalog: [
          _app('desktop:dup', 'other-app'),
          _app('local:dup', 'dup-app'),
        ],
        windows: const [],
      );
      expect(entries.single.launchId, 'local:dup');
      expect(entries.single.appId, 'dup-app');
    });

    test('D-1：同 launch key 多命中且 appId 也不唯一 → 退化 pin.id', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(pinned: [_legacyPin('dup')]),
        catalog: [
          _app('desktop:dup', 'app-a'),
          _app('local:dup', 'app-b'),
        ],
        windows: const [],
      );
      expect(entries.single.launchId, 'dup');
    });

    test('混合：2 pinned + 2 未 pin 运行 → 4 条目，pinned 在前', () {
      final entries = dockRowEntries(
        prefs: DockPreferences(
          pinned: [_legacyPin('kate'), _legacyPin('dolphin')],
        ),
        catalog: [
          _app('desktop:kate', 'kate', name: 'Kate'),
          _app('desktop:dolphin', 'dolphin', name: 'Dolphin'),
        ],
        windows: [
          _window(1, 'kate'),
          _window(2, 'firefox'),
          _window(3, 'dolphin'),
          _window(4, 'kitty'),
        ],
      );
      expect(entries.map((e) => e.key), [
        'app:kate',
        'app:dolphin',
        'run:firefox',
        'run:kitty',
      ]);
      expect(entries[0].windows.map((w) => w.id), [1]);
      expect(entries[1].windows.map((w) => w.id), [3]);
      expect(entries[2].appId, 'firefox');
      expect(entries[3].appId, 'kitty');
    });
  });
}
