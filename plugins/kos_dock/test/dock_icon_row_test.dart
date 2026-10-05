// DockIconRow / DockIcon / magnification widget + 纯函数测试（TASK-01）。
//
// 假 ShellServices 全接口内存实现（ProviderListenable 用
// `Provider((_)=>value)`），无真实 wayland/dbus/socket 依赖；
// dockPreferencesStoreProvider 注入内存假 store。
//
// 覆盖：pinned 渲染数、dot 数=min(3,windowCount)、点击
// launch/activate/MRU 轮循、ReorderableListView 存在（方案 B：只含
// pinned 键，运行段在其后的普通 Row）、magnification 纯函数边界
// （d=0→scale 1.19/lift −0.04·iconSize；|d|≥radius→1.0/0；smoothstep
// 中点单调对称）、固定槽位宽不随 pointer 变化、未 pin 条目「固定此应用」
// 写回 pins。

import 'dart:typed_data';

import 'package:denial_sdk/system.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/state/dock_settings.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_icon.dart';
import 'package:kos_dock/src/widgets/dock_icons.dart';
import 'package:kos_dock/src/widgets/magnification.dart';

// ── fakes ──────────────────────────────────────────────────────────────

class _MemoryDockPreferencesStore implements DockPreferencesStore {
  _MemoryDockPreferencesStore(this._prefs);
  DockPreferences _prefs;
  List<PinnedApplication>? written;

  @override
  Future<DockPreferences> read() async => _prefs;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
    written = pins;
    // TASK-04：写 pins 保留可见性 flag。
    _prefs = DockPreferences(
      pinned: pins,
      showLauncher: _prefs.showLauncher,
      showTrash: _prefs.showTrash,
    );
  }

  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {
    _prefs = DockPreferences(
      pinned: _prefs.pinned,
      showLauncher: showLauncher ?? _prefs.showLauncher,
      showTrash: showTrash ?? _prefs.showTrash,
    );
  }

  @override
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  }) async {
    // 只改指定项，保留 pinned/可见性/其它信息卡字段（写回后内部状态同步）。
    _prefs = DockPreferences(
      pinned: _prefs.pinned,
      showLauncher: _prefs.showLauncher,
      showTrash: _prefs.showTrash,
      infoCardOrder: order ?? _prefs.infoCardOrder,
      infoCardAutoRotate: autoRotate ?? _prefs.infoCardAutoRotate,
      infoCardMode: mode ?? _prefs.infoCardMode,
    );
  }
}

class _FakeMediaCommands implements MediaCommands {
  @override
  MprisPlaybackState get current => MprisPlaybackState.unavailable();
  @override
  Future<void> previous() async {}
  @override
  Future<void> playPause() async {}
  @override
  Future<void> next() async {}
}

class _FakeShellStrings implements ShellStrings {
  @override
  String time(DateTime value) => '';
  @override
  String shortDate(DateTime value) => '';
  @override
  String batteryLine(String state, int capacity) => '';
  @override
  String numberValue(int value) => '$value';
  @override
  String workspaceLabel(int workspace) => '$workspace';
  @override
  String get batteryTitle => '';
  @override
  String get percentSign => '%';
  @override
  String get celsiusUnit => '';
  @override
  String get metricCpu => '';
  @override
  String get mediaControls => '';
  @override
  String get mediaNowPlaying => '';
  @override
  String get mediaPrevious => '';
  @override
  String get mediaNext => '';
  @override
  String get mediaPlay => '';
  @override
  String get mediaPause => '';
  @override
  String get workspaceOccupied => '';
  @override
  String get workspaceEmpty => '';
  @override
  String get workspaceActive => '';
}

class _FakeShellServices implements ShellServices {
  List<LaunchableApplication> apps = [];
  List<ApplicationWindow> windowsList = [];
  final launched = <({String id, int? monitorId})>[];
  final activated = <int>[];

  @override
  ProviderListenable<List<LaunchableApplication>> get applications =>
      Provider((_) => apps);

  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) =>
      Provider((_) => windowsList);

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async {
    launched.add((id: id, monitorId: monitorId));
    return true;
  }

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      const SizedBox.expand();

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) =>
      const SizedBox.shrink();

  @override
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) =>
      () {};

  @override
  void toggleDesktop() {}

  @override
  ProviderListenable<bool> get desktopVisible => Provider((_) => false);

  @override
  void toggleLauncher() {}

  @override
  void openPowerSettings() {}

  @override
  ProviderListenable<Rect?> monitorBounds(int monitorId) =>
      Provider((_) => null);

  @override
  ProviderListenable<bool> get workspacesEnabled => Provider((_) => false);

  @override
  ProviderListenable<WorkspaceStatus> workspace(int monitorId) =>
      Provider((_) => WorkspaceStatus(count: 1, active: 1, occupied: {1}));

  @override
  void switchWorkspace({required int monitorId, required int workspaceId}) {}

  @override
  ProviderListenable<BatteryStatus> get battery =>
      Provider((_) => BatteryStatus.unknown);

  @override
  ProviderListenable<LoadSeries> get cpu =>
      Provider((_) => LoadSeries.empty);

  @override
  ProviderListenable<List<GpuLoad>> get gpus =>
      Provider((_) => const <GpuLoad>[]);

  @override
  ProviderListenable<AsyncValue<DateTime>> get clock =>
      Provider((_) => AsyncData(DateTime(2026, 1, 1)));

  @override
  ProviderListenable<AsyncValue<MprisPlaybackState>> get media =>
      Provider((_) => AsyncData(MprisPlaybackState.unavailable()));

  @override
  ProviderListenable<MediaCommands> get mediaCommands =>
      Provider((_) => _FakeMediaCommands());

  @override
  ProviderListenable<Color> get accent =>
      Provider((_) => const Color(0xFF4488FF));

  @override
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path) =>
      Provider((_) => const AsyncData(null));

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  ShellStrings strings(BuildContext context) => _FakeShellStrings();

  @override
  ProviderListenable<bool> get trayVisible => Provider((_) => false);

  @override
  ProviderListenable<List<String>> get trayItemIds =>
      Provider((_) => const <String>[]);

  @override
  Widget buildSystemTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  }) => const SizedBox.shrink();
}

// ── helpers ────────────────────────────────────────────────────────────

const _apps = [
  LaunchableApplication(
    id: 'org.kde.kate',
    appId: 'kate',
    name: 'Kate',
    windowAppIds: ['kate', 'org.kde.kate'],
  ),
  LaunchableApplication(
    id: 'org.kde.dolphin',
    appId: 'dolphin',
    name: 'Dolphin',
    windowAppIds: ['dolphin'],
  ),
];

PinnedApplication _pin(LaunchableApplication app) =>
    PinnedApplication(id: app.id, appId: app.appId, name: app.name);

ApplicationWindow _window(int id, String appId, {bool active = false}) =>
    ApplicationWindow(
      id: id,
      appId: appId,
      title: 'w$id',
      active: active,
      minimized: false,
    );

Widget _wrap(
  _FakeShellServices services,
  _MemoryDockPreferencesStore store,
) => ProviderScope(
  overrides: [dockPreferencesStoreProvider.overrideWithValue(store)],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: SizedBox(
        width: 800,
        height: kDockBaseHeight,
        child: DockIconRow(monitorId: 0, services: services),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  // 入场交错 Timer 在第一段 pump 内 fire、spring 首 tick 落在下一帧——
  // 再补一段让 _DockEntrance 落到终态（方案 B：运行段 ClipRect 会把
  // 未收位的图标 hit 区裁出段外，点击断言必须先等入场完成）。
  await tester.pump(const Duration(seconds: 1));
}

int _dotCount(WidgetTester tester) =>
    tester
        .widgetList<Container>(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle,
          ),
        )
        .length;

// ── tests ──────────────────────────────────────────────────────────────

void main() {
  group('DockMagnification 纯函数', () {
    const iconSize = kDockIconSize; // ≈42.857 → radius = max(85.7,140) = 140
    final radius = DockMagnification.radius(iconSize);

    test('radius = max(iconSize*2, 140)', () {
      expect(radius, 140);
      expect(DockMagnification.radius(100), 200); // iconSize*2 > 140
    });

    test('d=0 → influence 1、scale 1.19、lift −0.04·iconSize', () {
      final influence = DockMagnification.influence(0, radius);
      expect(influence, 1.0);
      expect(DockMagnification.scale(influence), closeTo(1.19, 1e-9));
      expect(
        DockMagnification.lift(iconSize, influence),
        closeTo(-iconSize * 0.04, 1e-9),
      );
    });

    test('|d|≥radius → influence 0、scale 1.0、lift 0', () {
      for (final d in [radius, radius + 1, 300.0]) {
        final influence = DockMagnification.influence(d, radius);
        expect(influence, 0.0);
        expect(DockMagnification.scale(influence), 1.0);
        expect(DockMagnification.lift(iconSize, influence), 0.0);
      }
    });

    test('smoothstep 对称且在 (0,radius) 单调递减', () {
      var previous = 1.0;
      for (var d = 1.0; d < radius; d += 5) {
        final value = DockMagnification.influence(d, radius);
        expect(value, lessThan(previous));
        expect(value, greaterThan(0));
        previous = value;
        // 对称：f(d) == f(−d)
        expect(value, DockMagnification.influence(-d, radius));
      }
      // 中点 smoothstep(0.5)=0.5
      expect(
        DockMagnification.influence(radius / 2, radius),
        closeTo(0.5, 1e-9),
      );
    });
  });

  group('DockIconRow', () {
    testWidgets('渲染 pinned 图标 + ReorderableListView', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsNWidgets(2));
      expect(find.byType(ReorderableListView), findsOneWidget);
    });

    testWidgets('空 pinned → 不渲染图标（pill 仍由 dock_view 画）', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsNothing);
    });

    testWidgets('dot 数 = min(3, windowCount)，未运行不显示', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          _window(1, 'kate'),
          _window(2, 'kate'),
          _window(3, 'kate'),
          _window(4, 'kate'), // 4 窗 → 3 dots
          _window(5, 'dolphin'), // 1 窗 → 1 dot
          _window(9, 'firefox'), // 未 pin 的运行应用 → 追加一个条目（§5 修正）
        ];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      // kate + dolphin（pinned）+ firefox（运行中未 pin）。
      expect(find.byType(DockIcon), findsNWidgets(3));
      // 3(kate) + 1(dolphin) + 1(firefox) = 5 个圆点。
      expect(_dotCount(tester), 5);
    });

    testWidgets('windowAppIds 别名匹配到 pin', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'KATE')]; // normalize→kate ∈ windowAppIds
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(_dotCount(tester), 1);
    });

    testWidgets('window.appId == pin.id（launch id）直配，不在别名集仍关联',
        (tester) async {
      // pin 存 opaque LaunchableApplication.id='org.kde.kate'，但
      // pin.appId='kate'；catalog windowAppIds 不含 'org.kde.kate'（别名
      // 集外），窗口报 appId='org.kde.kate' 时仍应点亮 dot/activate。
      const app = LaunchableApplication(
        id: 'org.kde.kate',
        appId: 'kate',
        name: 'Kate',
        windowAppIds: ['kate'], // 别名集不含 launch id
      );
      final services = _FakeShellServices()
        ..apps = [app]
        ..windowsList = [_window(7, 'org.kde.kate', active: true)];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(app)]), // pin.id='org.kde.kate'
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      // dot 亮起（windows 非空）。
      expect(_dotCount(tester), 1);
      final icon = tester.widget<DockIcon>(find.byType(DockIcon));
      expect(icon.windows, hasLength(1));
      expect(icon.isActivated, isTrue);
      // 点击 → activate 而非 launch。
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [7]);
      expect(services.launched, isEmpty);
    });

    testWidgets('无窗口 app 点击 → launchApplication(launchId)', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final d = find.byType(DockIcon);
      await tester.tap(d, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      expect(services.launched.single.id, 'org.kde.kate');
      expect(services.launched.single.monitorId, 0);
      expect(services.activated, isEmpty);
    });

    testWidgets('1 窗点击 → activateWindow(id)', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(7, 'kate')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [7]);
      expect(services.launched, isEmpty);
    });

    testWidgets('多窗 MRU 轮循：有 active 窗 → 激活下一个；无 → 第一个', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          _window(1, 'kate', active: true),
          _window(2, 'kate'),
        ];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [2]); // active=1 → cycle → 2

      // 无 active → MRU 第一个。
      services.activated.clear();
      services.windowsList = [_window(1, 'kate'), _window(2, 'kate')];
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [1]);
    });

    testWidgets('槽位宽固定：pointerX 变化不改 itemExtent/槽宽，缩放只发生在槽内 Transform',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      final slot = tester.getSize(icons.first);
      // 独立宿主（无 KosDockShell）→ DockMetricsScope.fallback 基准几何。
      final fb = DockMetricsScope.fallback;
      expect(slot.width, closeTo(fb.iconSlotSize, 0.01));
      // 注入前相邻两 slot 中心的距离。
      double centerDistance() => (tester.getCenter(icons.at(0)) -
              tester.getCenter(icons.at(1)))
          .distance;
      final spacingBefore = centerDistance();

      // 指针移到第 0 个图标中心：槽宽/间距不变（视觉缩放只在槽内 Transform）。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      final targetCenter = tester.getCenter(icons.at(0));
      await gesture.moveTo(targetCenter);
      await tester.pump();
      expect(
        tester.getSize(icons.first).width,
        closeTo(fb.iconSlotSize, 0.01),
      );
      // 相邻 slot 中心距与注入前完全一致（槽宽/间距不受 pointer 影响）。
      expect(centerDistance(), closeTo(spacingBefore, 0.001));
      expect(
        spacingBefore,
        closeTo(fb.iconSlotSize + fb.itemSpacing, 0.01),
      );

      // 指针正下方图标的 Transform：scale>1 或 lift≠0（视觉缩放确实发生）。
      // 弹簧需要若干帧才离开静止值，逐帧推进直到 progress 显现。
      var scaled = false;
      for (var i = 0; i < 30 && !scaled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final transform in tester.widgetList<Transform>(
          find.descendant(of: icons.at(0), matching: find.byType(Transform)),
        )) {
          final scale = transform.transform.getMaxScaleOnAxis();
          final lift = transform.transform.storage[13]; // Matrix4 y 平移
          if (scale > 1.0 || lift != 0.0) scaled = true;
        }
      }
      expect(scaled, isTrue, reason: '指针正下方图标应产生 scale>1 或 lift≠0');

      await gesture.moveTo(Offset.zero);
      await tester.pump();
    });

  group('未 pin 的运行应用（KOS grouped；CONSTRAINTS §5 修正）', () {
    testWidgets('空 pinned + 有运行窗口 → 行非空（用户报告的场景）', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'kitty')];
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsOneWidget);
      final icon = tester.widget<DockIcon>(find.byType(DockIcon));
      expect(icon.isPinnedEntry, isFalse);
      expect(icon.windows, hasLength(1));
      // 运行中 → dot 亮起。
      expect(_dotCount(tester), 1);
    });

    testWidgets('目录命中的未 pin 运行应用：一应用一图标，pinned 在前', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          _window(1, 'kate', active: true),
          _window(2, 'kate'),
          _window(3, 'dolphin'),
          _window(4, 'dolphin'),
        ];
      final store = _MemoryDockPreferencesStore(
        // 只 pin kate：dolphin 未 pin 但在跑 → 排在 kate 之后。
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      expect(_dotCount(tester), 4); // kate 2 窗 + dolphin 2 窗
      final first = tester.widget<DockIcon>(icons.at(0));
      final second = tester.widget<DockIcon>(icons.at(1));
      expect(first.isPinnedEntry, isTrue);
      expect(first.name, 'Kate');
      // 目录命中的未 pin 条目用目录 name/appId/launch id（KOS
      // DockModelService.qml:164-171）。
      expect(second.isPinnedEntry, isFalse);
      expect(second.name, 'Dolphin');
      expect(second.appId, 'dolphin');
      expect(second.launchId, 'org.kde.dolphin');
      expect(
        tester.getCenter(icons.at(0)).dx,
        lessThan(tester.getCenter(icons.at(1)).dx),
      );
    });

    testWidgets('既 pin 又在跑 → 只出现一次（不重复）', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'kate'), _window(2, 'kate')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsOneWidget);
      expect(_dotCount(tester), 2);
    });

    testWidgets('未 pin 条目不可拖拽重排（无 ReorderableDragStartListener）', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(5, 'kitty')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      expect(
        find.ancestor(
          of: icons.at(0),
          matching: find.byType(ReorderableDragStartListener),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: icons.at(1),
          matching: find.byType(ReorderableDragStartListener),
        ),
        findsNothing,
      );
    });

    testWidgets('未 pin 图标点击 → activateWindow（1 窗）/ MRU 轮循（多窗）',
        (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(11, 'kitty')];
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [11]);
      expect(services.launched, isEmpty);

      services.activated.clear();
      services.windowsList = [
        _window(11, 'kitty', active: true),
        _window(12, 'kitty'),
      ];
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [12]); // active=11 → 轮循到 12
    });

    testWidgets('窗口全部关闭 → 未 pin 条目移除', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(3, 'kitty')];
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsOneWidget);

      services.windowsList = [];
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsNothing);
    });

    testWidgets('未 pin 条目右键菜单第三项「固定此应用」→ 写回 pins 尾部',
        (tester) async {
      // KOS: DockIcon.qml:921-927 window item 第三项为「固定此应用」；
      // 点击后追加进 pinned 尾部（_pinApp 幂等）。
      const kittyApp = LaunchableApplication(
        id: 'desktop:kitty',
        appId: 'kitty',
        name: 'Kitty',
        windowAppIds: ['kitty'],
      );
      final services = _FakeShellServices()
        ..apps = [..._apps, kittyApp]
        ..windowsList = [_window(5, 'kitty')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      // kate(pinned) + kitty(未 pin 运行) 两个图标；kitty 在运行段。
      expect(find.byType(DockIcon), findsNWidgets(2));
      final runningIcon = tester.widget<DockIcon>(find.byType(DockIcon).at(1));
      expect(runningIcon.isPinnedEntry, isFalse);

      // 右键运行段图标 → 菜单第三项 = 「固定此应用」（en → Keep in Dock）。
      await tester.tap(
        find.byType(DockIcon).at(1),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('New Window'), findsOneWidget);
      expect(find.text('Keep in Dock'), findsOneWidget);

      await tester.tap(find.text('Keep in Dock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await _settle(tester);
      // 写回：kitty 追加到 pinned 尾部（launch id 用 catalog id）。
      expect(store.written, hasLength(2));
      expect(store.written![1].id, 'desktop:kitty');
      expect(store.written![1].appId, 'kitty');
    });

  group('D-1：pinned launch id 反查 catalog（desktop: 前缀）', () {
    /// 迁移态 pin：id == appId == desktopId（旧 schema `_decodeLegacyPin`）。
    PinnedApplication migratedPin(String desktopId) =>
        PinnedApplication(id: desktopId, appId: desktopId, name: '');

    const kittyApp = LaunchableApplication(
      // 宿主 catalog id 形如 `desktop:<desktopFileId>`（denial_desktop
      // shell_plugin_services.dart:85-96 + application_recents_controller
      // .dart:9-12）。
      id: 'desktop:kitty',
      appId: 'kitty',
      name: 'Kitty',
      windowAppIds: ['kitty'],
    );

    testWidgets('迁移态 pin + 无窗口 → 点击 launchApplication(\'desktop:kitty\')',
        (tester) async {
      final services = _FakeShellServices()..apps = [kittyApp];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [migratedPin('kitty')]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      // 断言收到的具体 id：catalog 的 LaunchableApplication.id（带
      // `desktop:` 前缀），不是落盘 pin.id='kitty'。
      expect(services.launched, hasLength(1));
      expect(services.launched.single.id, 'desktop:kitty');
      expect(services.activated, isEmpty);
    });

    testWidgets('同一 pin 有窗口 → 走 activateWindow 不 launch', (tester) async {
      final services = _FakeShellServices()
        ..apps = [kittyApp]
        ..windowsList = [_window(9, 'kitty')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [migratedPin('kitty')]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [9]);
      expect(services.launched, isEmpty);
    });

    testWidgets('catalog 未命中 → 退化为 launchApplication(pin.id)，不崩',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps; // 无 kitty
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [migratedPin('kitty')]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      expect(services.launched.single.id, 'kitty');
    });

    testWidgets("local: scheme 迁移态 pin → 点击 launchApplication('local:myapp')",
        (tester) async {
      // 宿主 catalog 对本地应用用 `local:<id>`（denial_desktop
      // `application_recents_controller.dart:9-12`）；`_normalizeLaunchId`
      // 只剥 `desktop:` 时 bare pin.id='myapp' 与 'local:myapp' 判等
      // miss，且 appId/windowAppIds 不含 bare id → 退化 launch 'myapp'。
      const localApp = LaunchableApplication(
        id: 'local:myapp',
        appId: 'local-myapp',
        name: 'My App',
        windowAppIds: ['local-myapp'],
      );
      final services = _FakeShellServices()..apps = [localApp];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [migratedPin('myapp')]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      expect(services.launched.single.id, 'local:myapp');
      expect(services.activated, isEmpty);
    });
  });
  });
  });
}
