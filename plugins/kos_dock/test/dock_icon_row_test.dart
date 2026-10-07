// DockIconRow / DockIcon / magnification widget + 纯函数测试（TASK-01;
// TASK-11 起 magnification 换 quickshell 高斯波）。
//
// 假 ShellServices 全接口内存实现（ProviderListenable 用
// `Provider((_)=>value)`），无真实 wayland/dbus/socket 依赖；
// dockPreferencesStoreProvider 注入内存假 store。
//
// 覆盖：pinned 渲染数、dot 数=min(3,windowCount)、点击
// launch/activate/MRU 轮循、ReorderableListView 存在（方案 B：只含
// pinned 键，运行段在其后的普通 Row）、dockWaveLayout 纯函数边界
// （无指针→全 scale=1 等距；指针在 i 号槽中心→i 号 scale=maxScale、
// 邻居 exp 衰减；amplitude 线性缩放峰值；pointer 越界/NaN→scale=1）、
// 固定槽位宽不随 pointer 变化（无指针时）/连续变化（有指针时）、
// 未 pin 条目「固定此应用」写回 pins。

import 'dart:math' as math;
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
    home: MediaQuery(
      // flutter_test 无障碍语义：disableAnimations=true → 振幅包络直写终
      // 值（约束③兜底路径），波形「稳态」一帧即达。
      data: const MediaQueryData(disableAnimations: true),
      child: ShellTheme(
        data: const ShellThemeData(),
        child: SizedBox(
          width: 800,
          height: kDockBaseHeight,
          child: DockIconRow(monitorId: 0, services: services),
        ),
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
    find.byKey(const ValueKey('dock.runningIndicator')).evaluate().length;

// ── tests ──────────────────────────────────────────────────────────────
void main() {
  group('dockWaveLayout 纯函数（TASK-11 高斯波）', () {
    const size = 40.0;
    const gap = 4.0;
    const weights = [1.0, 1.0, 1.0];

    test('无指针 → 全 scale=1 等距', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: null,
        maxScale: 1.5,
        amplitude: 0,
      );
      expect(slots, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(slots[i].size, closeTo(size, 1e-9));
        // 末槽 trailingGap=false → span=size（无尾随 gap）；其余 size+gap。
        expect(
          slots[i].span,
          closeTo(i == 2 ? size : size + gap, 1e-9),
        );
        // center = 静止槽区中心（含尾随 gap）：(size+gap)·i + (size+gap)/2，
        // 对齐 magnification.dart:147 `baseCursor + baseSpan/2`（baseSpan =
        // size·weight+gap）。指针落此中心时该槽 scale 才达峰值 M。
        expect(
          slots[i].center,
          closeTo((size + gap) * i + (size + gap) / 2, 1e-9),
        );
      }
    });

    test('指针在 1 号槽中心 → 1 号 scale=maxScale、邻居 exp 衰减', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: (size + gap) * 1 + (size + gap) / 2, // 1 号槽中心
        maxScale: 1.5,
        amplitude: 1,
      );
      expect(slots[1].size, closeTo(size * 1.5, 1e-9));
      expect(slots[0].size, lessThan(slots[1].size));
      expect(slots[2].size, lessThan(slots[1].size));
      expect(slots[0].size, closeTo(slots[2].size, 1e-6)); // 对称
    });

    test('amplitude 线性缩放峰值', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: (size + gap) / 2, // 0 号槽中心 → d=0 → scale 满幅
        maxScale: 1.5,
        amplitude: 0.5,
      );
      expect(slots[0].size, closeTo(size * (1 + 0.5 * 0.5), 1e-9));
    });

    test('pointer 越界/NaN → scale=1', () {
      for (final x in [null, double.nan, -9999.0, double.infinity]) {
        final slots = dockWaveLayout(
          weights: weights,
          size: size,
          gap: gap,
          padding: 0,
          pointerX: x,
          maxScale: 1.5,
          amplitude: 1,
        );
        for (final s in slots) {
          expect(s.size, closeTo(size, 1e-9), reason: 'pointerX=$x');
        }
      }
    });

    test('unscaled 槽位 scale=1（divider 不缩放）', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: size / 2,
        maxScale: 1.5,
        amplitude: 1,
        unscaled: {0},
      );
      expect(slots[0].size, closeTo(size, 1e-9));
      expect(slots[1].size, greaterThan(size)); // 邻居仍被推
    });

    test('span 总和 = Σspan（连续推开）', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: size / 2,
        maxScale: 1.5,
        amplitude: 1,
      );
      final total = slots.fold(0.0, (s, slot) => s + slot.span);
      expect(total, closeTo(slots.last.start + slots.last.span, 1e-9));
    });

    test('dockWaveInsertionIndex：x < 中线 → 槽位下标', () {
      final slots = dockWaveLayout(
        weights: weights,
        size: size,
        gap: gap,
        padding: 0,
        pointerX: null,
        maxScale: 1.5,
        amplitude: 0,
      );
      expect(dockWaveInsertionIndex(slots, 0), 0);
      expect(dockWaveInsertionIndex(slots, size + gap + 1), 1);
      expect(dockWaveInsertionIndex(slots, 9999), 3);
    });

    test('dockWavePreviewOrder：移除后插入', () {
      expect(dockWavePreviewOrder(3, 0, 0), [0, 1, 2]); // 原地
      expect(dockWavePreviewOrder(3, 0, 1), [0, 1, 2]); // 原地（gap=source+1）
      expect(dockWavePreviewOrder(3, 0, 2), [1, 0, 2]); // 移到 1 号位
      expect(dockWavePreviewOrder(3, 0, 3), [1, 2, 0]); // 移到尾
    });

    test('dockWaveDropTarget：移除前 gap → 移除后目标', () {
      expect(dockWaveDropTarget(0, 0), 0);
      expect(dockWaveDropTarget(0, 1), 0);
      expect(dockWaveDropTarget(0, 2), 1);
      expect(dockWaveDropTarget(2, 0), 0);
      expect(dockWaveDropTarget(2, 3), 2);
    });
  });

  group('DockIconRow', () {
    testWidgets('渲染 pinned 图标（自绘槽位布局，无 ReorderableListView）', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsNWidgets(2));
      // TASK-11：ReorderableListView 已移除，槽位由 Stack+Positioned 自绘。
      expect(find.byType(ReorderableListView), findsNothing);
    });

    testWidgets('空 pinned → 不渲染图标（pill 仍由 dock_view 画）', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockIcon), findsNothing);
    });

    testWidgets('每个运行应用显示一个横条', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          _window(1, 'kate'),
          _window(2, 'kate'),
          _window(3, 'kate'),
          _window(4, 'kate'), // 多窗 → 两层横条
          _window(5, 'dolphin'), // 单窗 → 一层横条
          _window(9, 'firefox'), // 未 pin 的运行应用 → 追加一个条目（§5 修正）
        ];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      // kate + dolphin（pinned）+ firefox（运行中未 pin）。
      expect(find.byType(DockIcon), findsNWidgets(3));
      // 三个运行应用各有一个横条绘制区域。
      expect(_dotCount(tester), 3);
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

    testWidgets('槽位宽随指针连续变化（TASK-11 高斯波）：无指针固定/有指针推开邻居',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      // 独立宿主（无 KosDockShell）→ DockMetricsScope.fallback 基准几何。
      final fb = DockMetricsScope.fallback;
      // 无指针时槽宽 = iconSlotSize（静止布局，约束④）。
      expect(
        tester.getSize(icons.first).width,
        closeTo(fb.iconSlotSize, 0.01),
      );
      double centerDistance() => (tester.getCenter(icons.at(0)) -
              tester.getCenter(icons.at(1)))
          .distance;
      final spacingBefore = centerDistance();
      // TASK-11 槽距语义：gap 烘在每槽 span 尾部；TASK-12 起槽位列经
      // OverflowBox(bottomCenter) 底锚摆放，相邻槽**视觉中心距** =
      // span_i = slotSize + gap（被测两槽为非末槽/末槽组合，实测几何下
      // 中心距等于首槽 span）。旧「Center 居中 → slotSize + gap/2」的
      // 公式随底锚改版不再适用。
      expect(
        spacingBefore,
        closeTo(fb.iconSlotSize + fb.itemSpacing, 0.01),
      );

      // 指针移到第 0 个图标中心：槽宽连续变化（被推开的邻居间距增大）。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      final targetCenter = tester.getCenter(icons.at(0));
      await gesture.moveTo(targetCenter);
      // 指针 x 经帧后回调喂振幅包络（disableAnimations 直写终值 1），
      // 需第二帧 build 才把 amplitude=1 落到槽位 scale。
      await tester.pump();
      await tester.pump();
      // 槽宽本身随 scale 变（TASK-11 核心）：被指图标槽位 span 增大。
      expect(
        tester.getSize(icons.first).width,
        greaterThan(fb.iconSlotSize + 1),
        reason: '指针在 0 号槽中心时该槽位 span 应连续增大（推开邻居）',
      );
      // 相邻槽中心距随指针连续变化（不再是固定 iconSlotSize+spacing）。
      expect(
        centerDistance(),
        greaterThan(spacingBefore + 0.5),
        reason: '指针滑过时相邻槽位被连续推开，中心距应变大',
      );

      await gesture.moveTo(Offset.zero);
      await tester.pump();

    });

    testWidgets('TASK-12 底部锚定抬起：放大图标底锚带底、顶缘上移', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      final fb = DockMetricsScope.fallback;
      // 无指针（静止）：槽位列高 = iconSlotSize，rect 底缘 = 带底。
      final resting = tester.getRect(icons.at(0));
      expect(resting.height, closeTo(fb.iconSlotSize, 0.01));
      final restingBottom = resting.bottom;
      final restingTop = resting.top;

      // 指针移到 0 号图标中心 → 波形放大该槽（dy/dsize = −1：底不动顶上移）。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(icons.at(0)));
      await tester.pump();
      await tester.pump();

      final magnified = tester.getRect(icons.at(0));
      expect(
        magnified.height,
        greaterThan(fb.iconSlotSize + 1),
        reason: '指针在槽中心 → 槽位列高随 scale 增大',
      );
      // 底部锚定：放大后底缘不离开带底（不是槽内上下对称长）。
      expect(
        magnified.bottom,
        closeTo(restingBottom, 0.5),
        reason: 'macOS lift：美术盒底锚带底，放大只向上生长',
      );
      // 顶缘上移 = 放大增量全部向上（抬起量 = Δsize，dy/dsize = −1）。
      expect(
        restingTop - magnified.top,
        closeTo(magnified.height - resting.height, 0.5),
        reason: '抬起是纯几何 dy/dsize=−1：顶缘上移量 = 高度增量',
      );
      // 放大后顶缘高于静止顶缘（向上「抬」出原槽顶）。
      expect(magnified.top, lessThan(restingTop));

      await gesture.moveTo(Offset.zero);
      await tester.pump();
    });

    testWidgets('TASK-12 缺陷1/2：美术盒 = iconSize·scale、底边距 pill 底恒定',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      final icons = find.byType(DockIcon);
      expect(icons, findsNWidgets(2));
      final fb = DockMetricsScope.fallback;
      // 美术盒 = ExcludeSemantics 下 iconSize·iconScale 的 SizedBox。
      Finder artwork(Finder icon) {
        final ex = find.descendant(
          of: icon,
          matching: find.byType(ExcludeSemantics),
        );
        return find.descendant(
          of: ex,
          matching: find.byWidgetPredicate(
            (w) =>
                w is SizedBox &&
                w.width != null &&
                w.width!.isFinite &&
                w.width == w.height,
          ),
        );
      }

      // 静止：美术盒边长 = iconSize（缺陷1 回归：旧式把 weight≈1.2 折进
      // 美术盒，静止画 iconSlotSize≈50.4 而非 iconSize≈42）。
      final resting = tester.getRect(artwork(icons.at(0)));
      expect(
        resting.width,
        closeTo(fb.iconSize, 0.01),
        reason: '静止美术盒边长应为 iconSize（不折 weight）',
      );
      // 缺陷2：美术盒底边距带底（=pill 底）恒定 margin = (dockHeight−iconSize)/2。
      final band = find.byKey(const Key('dock.pinned'));
      // 独立宿主无 'dock.pinned' 键——用图标带底缘 = DockIconRow 底部。
      final bandBottom = band.evaluate().isNotEmpty
          ? tester.getRect(band).bottom
          : tester.getRect(find.byType(DockIconRow)).bottom;
      final margin = (fb.dockHeight - fb.iconSize) / 2;
      expect(
        bandBottom - resting.bottom,
        closeTo(margin, 0.5),
        reason: '静止美术盒底边距带底 = (dockHeight−iconSize)/2',
      );

      // 放大：美术盒 = iconSize·scale（scale>1），底边 margin 不变。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(icons.at(0)));
      await tester.pump();
      await tester.pump();
      final slotRect = tester.getRect(icons.at(0));
      final scale = slotRect.height / fb.iconSlotSize;
      expect(scale, greaterThan(1.05));
      final mag = tester.getRect(artwork(icons.at(0)));
      expect(
        mag.width,
        closeTo(fb.iconSize * scale, 0.5),
        reason: '放大美术盒 = iconSize·scale（非 slotSize·scale）',
      );
      // 放大态下指针在槽上 → TASK-10 hover lift 叠加 −max(2,round(iconSize×0.08))
      // 位移（bounce 链路原样保留的 hover 负 y 反馈）；底边 margin 在其上恒定。
      final hoverLift = math.max(
        2.0,
        (fb.iconSize * kDockHoverLiftRatio).roundToDouble(),
      );
      expect(
        bandBottom - mag.bottom,
        closeTo(margin + hoverLift, 0.5),
        reason: '放大后美术盒底边 margin 恒定（+ hover lift 位移，向上长）',
      );

      await gesture.moveTo(Offset.zero);
      await tester.pump();
    });

    testWidgets('TASK-12 复审缺陷1：指针离开后放大不瞬时归零（包络驱动塌回）',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      // 需要真动画：包络塌回是 animateTo(0)（220ms easeOutCubic + 80ms 退出
      // 防抖）——flutter_test 默认 disableAnimations=true 下 `_amplitudeTo`
      // 直写终值无塌回过程可断言；`_DockEntrance` 同式直落终态。
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dockPreferencesStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: false),
              child: ShellTheme(
                data: const ShellThemeData(),
                child: SizedBox(
                  width: 800,
                  height: kDockBaseHeight,
                  child: DockIconRow(monitorId: 0, services: services),
                ),
              ),
            ),
          ),
        ),
      );
      // `_DockEntrance`（60ms×index + snappy spring）与后续包络衰减都要分
      // 帧推进——flutter_test 的虚拟时钟需要逐帧 pump 驱动 ticker。
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final icons = find.byType(DockIcon);
      final fb = DockMetricsScope.fallback;

      // 指针放 0 号槽中心 → 包络 animateTo(1) 220ms 到满幅放大。
      // `_amplitudeTo(1)` 走 postFrame——先一帧触发调度，再分帧推 220ms。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(icons.at(0)));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final magnified = tester.getRect(icons.at(0)).height;
      expect(magnified, greaterThan(fb.iconSlotSize + 1));

      // 指针离开容器：pointerX 瞬时变 null，包络经 80ms 退出防抖后才
      // animateTo(0)——缺陷1 回归：scale 塌回唯一经 amplitude 项衰减，
      // 防抖期内槽高必须仍接近放大值而非瞬回 iconSlotSize。
      await gesture.moveTo(const Offset(-4000, -4000));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.getRect(icons.at(0)).height,
        greaterThan(fb.iconSlotSize + 1),
        reason: 'onExit 后 50ms（80ms 退出防抖期内）槽高不能瞬回静止值——'
            '`_lastLocalX` 保留最后指针位喂高斯峰，塌回由 amplitude 包络驱动',
      );
      // 防抖 80ms 过后 + 220ms 包络衰减中（再推 ~150ms 分帧）：仍在塌回
      // 途中——介于满幅与静止之间（瞬时归零会立即等于 iconSlotSize）。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final midDecay = tester.getRect(icons.at(0)).height;
      expect(midDecay, lessThan(magnified));
      expect(
        midDecay,
        greaterThan(fb.iconSlotSize + 0.5),
        reason: 'easeOutCubic 塌回中途：槽高介于放大值与静止值之间',
      );
      // 衰减完毕 → 回到静止（`_lastLocalX` 随包络触底惰性清空）。
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.getRect(icons.at(0)).height,
        closeTo(fb.iconSlotSize, 0.01),
      );
      await gesture.removePointer();
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
      expect(_dotCount(tester), 2); // kate 与 dolphin 各有一个横条绘制区域
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

    testWidgets('未 pin 条目不可拖拽重排（仅 pinned 槽位可发起拖拽）', (tester) async {
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
      // TASK-11：ReorderableListView 已移除，拖拽重排手写——只有 pinned
      // 槽位可发起拖拽（Listener 收 PointerDown → `_dragStart` 记源槽；
      // running/leading 槽位按下直接 return，无 `_dragStart`）。
      // 验证方式：运行段图标长按后无拖拽预览（`_dragPreview` 不置位），
      // pinned 图标长按后出现拖拽浮层（OverlayPortal 有子树）。
      // 简化断言：运行段图标长按不触发 `_dragPreview`（无浮层），
      // pinned 图标长按后 `_dragProxy` 有内容（Opacity 占位 + 浮层）。
      final runningIcon = tester.widget<DockIcon>(icons.at(1));
      expect(runningIcon.isPinnedEntry, isFalse);
      // 运行段图标无拖拽源（`_dragStart` 不记）——长按后无预览。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: tester.getCenter(icons.at(1)));
      await tester.pump(const Duration(milliseconds: 200));
      // 未 pin 条目按下不进入 reorder 态：`_dragPreview` 不置位 → 无
      // Opacity(0.35) 半透明占位（拖拽源槽位的占位视觉；`_dragProxy` 是常驻
      // OverlayPortal，不能直接查 OverlayPortal 存在性——popup 协调器/
      // 预览也用 OverlayPortal，恒有实例）。
      expect(
        find.byWidgetPredicate(
          (w) => w is Opacity && w.opacity == 0.35,
        ),
        findsNothing,
        reason: '未 pin 运行条目不可拖拽（无 _dragStart → 无预览占位）',
      );
      await gesture.removePointer();
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
