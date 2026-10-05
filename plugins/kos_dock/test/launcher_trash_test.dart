// TASK-04：启动器 / 垃圾桶图标 + 菜单 + 清空确认弹窗测试。
//
// 假 ShellServices / TrashService / DockPreferencesStore 全内存实现
// （CONSTRAINTS §10：无真实 socket/dbus/dart:io 依赖）；trashServiceProvider
// 与 dockPreferencesStoreProvider 注入假实现。
//
// 覆盖：launcher tap→toggleLauncher；trash tap→open；右键/长按→菜单两项；
// 清空→确认弹窗标题；取消不 empty；确认 empty 且关闭；空/非空图标状态；
// watch 事件更新；showLauncher/showTrash=false 即时隐藏；launcher/trash/
// pinned 在同一指针广播下缩放一致（TASK-04 坐标修正）。

import 'dart:async';
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
import 'package:kos_dock/kos_dock.dart' show KosDockPlugin;
import 'package:kos_dock/src/state/dock_settings.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_icon.dart';
import 'package:kos_dock/src/widgets/dock_shell.dart';
import 'package:kos_dock/src/widgets/launcher_icon.dart';
import 'package:kos_dock/src/widgets/trash_confirm_dialog.dart';
import 'package:kos_dock/src/widgets/trash_icon.dart';

// ── fakes ──────────────────────────────────────────────────────────────

class _MemoryDockPreferencesStore implements DockPreferencesStore {
  _MemoryDockPreferencesStore(this._prefs);
  DockPreferences _prefs;
  List<PinnedApplication>? written;
  final visibilityWrites = <({bool? showLauncher, bool? showTrash})>[];

  @override
  Future<DockPreferences> read() async => _prefs;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
    written = pins;
    _prefs = DockPreferences(
      pinned: pins,
      showLauncher: _prefs.showLauncher,
      showTrash: _prefs.showTrash,
    );
  }

  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {
    visibilityWrites.add((showLauncher: showLauncher, showTrash: showTrash));
    _prefs = DockPreferences(
      pinned: _prefs.pinned,
      showLauncher: showLauncher ?? _prefs.showLauncher,
      showTrash: showTrash ?? _prefs.showTrash,
    );
  }
}

class _FakeTrashService implements TrashService {
  TrashState state = TrashState.empty;
  final _changes = StreamController<TrashState>.broadcast();
  int openCalls = 0;
  int emptyCalls = 0;
  Object? emptyError;

  void emit(TrashState next) {
    state = next;
    _changes.add(next);
  }

  Future<void> dispose() => _changes.close();

  @override
  Future<bool> hasItems() async => state.hasItems;

  @override
  Future<int> count() async => state.count;

  @override
  Future<void> open() async => openCalls++;

  @override
  Future<void> empty() async {
    emptyCalls++;
    final error = emptyError;
    if (error != null) throw error;
    emit(TrashState.empty);
  }

  @override
  Stream<TrashState> watch() async* {
    yield state;
    yield* _changes.stream;
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
  int launcherToggles = 0;

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
  void toggleLauncher() => launcherToggles++;

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
  // 第二个应用：槽中心一致性/重排回归需要 ≥2 个 pinned 图标（TASK-04
  // 阻塞 2 回归）。
  LaunchableApplication(
    id: 'org.kde.dolphin',
    appId: 'dolphin',
    name: 'Dolphin',
    windowAppIds: ['dolphin'],
  ),
];

PinnedApplication _pin(LaunchableApplication app) =>
    PinnedApplication(id: app.id, appId: app.appId, name: app.name);

Widget _wrap(
  _FakeShellServices services,
  _MemoryDockPreferencesStore store,
  _FakeTrashService trash,
) => ProviderScope(
  overrides: [
    dockPreferencesStoreProvider.overrideWithValue(store),
    trashServiceProvider.overrideWithValue(trash),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: SizedBox(
        width: 800,
        // 真实 surface 高 = place() 条带厚度（dockHeight + 2×浮空边距 74）；
        // pill 高 60 且底部内缩 edgeMargin，用 60 高的盒子会被压到 53。
        height: KosDockPlugin.thickness,
        child: KosDockShell(services: services, monitorId: 0),
      ),
    ),
  ),
);

/// 有界推进：1 帧 + [frames]×16ms（≈[frames]×16ms 动画时间）。
///
/// **不使用 `pumpAndSettle()`**：它没有超时下限（默认 10 分钟），只要还有
/// 弹簧/交错计时器在驱动帧循环就会一直等下去，把整个 `flutter test` 挂住。
Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  // 入场交错 60ms×index + 弹簧 ≈ 300ms 内结束；40 帧 ≈ 640ms 有余量。
  await _pumpFrames(tester, 40);
}

/// 有界推进直到 [condition] 成立；超时 fail 并给出诊断（不空等）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String label,
  int maxFrames = 60,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (condition()) return;
  fail('$label：有界推进 ${maxFrames * 16}ms 后条件仍未满足');
}

/// 打开垃圾桶右键菜单（右键 → 150ms 入场播完）。
Future<void> _openTrashMenu(WidgetTester tester) async {
  await tester.tap(
    find.byType(TrashIcon),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 图标子树内最大 Transform scale（放大弹簧的手感量）。
double _maxScale(WidgetTester tester, Finder icon) {
  var scale = 1.0;
  for (final transform in tester.widgetList<Transform>(
    find.descendant(of: icon, matching: find.byType(Transform)),
  )) {
    scale = math.max(scale, transform.transform.getMaxScaleOnAxis());
  }
  return scale;
}

/// 图标子树内是否出现 hover 高亮（`_hovering` 的目标 opacity = 1）。
bool _hoverHighlightOn(WidgetTester tester, Finder icon) => tester
    .widgetList<AnimatedOpacity>(
      find.descendant(of: icon, matching: find.byType(AnimatedOpacity)),
    )
    .any((widget) => widget.opacity == 1.0);

/// 把 [icon] 的放大弹簧推进到**稳态**，返回稳态 scale。
///
/// 「稳态」= 连续 8 帧采样差 < 1e-4，且至少推进 12 帧（避免目标值还没在
/// 帧后回调里落地就误判为静止）。弹簧过冲区（≈2%）不会被当成峰值。
Future<double> _scaleAtRest(
  WidgetTester tester,
  Finder icon, {
  required String label,
  int maxFrames = 120,
  Duration step = const Duration(milliseconds: 16),
}) async {
  var previous = double.nan;
  var stable = 0;
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(step);
    final current = _maxScale(tester, icon);
    if (!previous.isNaN && (current - previous).abs() < 1e-4) {
      stable++;
      if (stable >= 8 && i >= 12) return current;
    } else {
      stable = 0;
    }
    previous = current;
  }
  fail('$label：放大弹簧未在 ${maxFrames * step.inMilliseconds}ms 内收敛（末值 $previous）');
}

/// 把指针移到全局 x（y 取 [y]）并推进到 [icon] 的放大稳态，返回稳态 scale。
Future<double> _hoverAndSettle(
  WidgetTester tester,
  TestGesture gesture,
  Finder icon,
  double x,
  double y, {
  required String label,
}) async {
  await gesture.moveTo(Offset(x, y));
  return _scaleAtRest(tester, icon, label: label);
}

/// 槽中心一致性回归（TASK-04 C 验收 / 阻塞 2）。
///
/// 断言 [icon] 的**实测**槽中心（`tester.getCenter`，即渲染后的几何）与
/// 图标内部用于广播判定的槽中心一致：
/// 1. 指针落在实测槽中心（及其 ±2px）时，稳态放大 = 满峰值
///    `kDockMagnificationMaxScale`（±0.01，稳态由 [_scaleAtRest] 判定，
///    不取弹簧过冲的瞬时值）；
/// 2. hover 触发边界两侧各 1px 钉住中心：实测中心 ∓(slotSize/2−1) 触发、
///    ∓(slotSize/2+1) 不触发 → 内部中心与实测中心偏差 < 1px（峰值平台
///    本身在 ±2px 内变化 < 1e-4，只有硬阈值边界能钉住中心）。
///
/// 一次性缓存槽中心的缺陷（入场/`showLauncher`/`showTrash`/重排后偏移
/// 数十 px）会让第 2 条必然失败、第 1 条偏离 → 返回稳态峰值供跨图标比较。
Future<double> _expectSlotCenterAligned(
  WidgetTester tester,
  TestGesture gesture,
  Finder icon, {
  required String label,
}) async {
  // 先让入场/位移动画走到稳态再测量槽位矩形（入场 `Transform.translate`
  // 会移动视觉位置，稳定后再测才不会把动画中间态当布局）。
  await _scaleAtRest(tester, icon, label: '$label（入场/位移稳态）');
  final centre = tester.getCenter(icon);
  // 方案 C：槽半宽取图标所在 DockMetricsScope 的反解值（随宽度/条目变），
  // 不是编译期常量。
  final edge = DockMetricsScope.of(tester.element(icon)).iconSlotSize / 2;

  double peak = 0;
  for (final dx in const <double>[0, -2, 2]) {
    final scale = await _hoverAndSettle(
      tester,
      gesture,
      icon,
      centre.dx + dx,
      centre.dy,
      label: '$label（槽中心 ${dx >= 0 ? '+' : ''}${dx}px 稳态）',
    );
    peak = math.max(peak, scale);
    if (dx == 0) {
      // 中心处必须满峰值（±0.01）。
      expect(
        scale,
        closeTo(kDockMagnificationMaxScale, 0.01),
        reason: '$label：指针在实测槽中心时应达到峰值 $kDockMagnificationMaxScale',
      );
      expect(
        _hoverHighlightOn(tester, icon),
        isTrue,
        reason: '$label：槽中心应触发 hover 高亮',
      );
    }
  }
  expect(
    peak,
    closeTo(kDockMagnificationMaxScale, 0.01),
    reason: '$label：槽中心 ±2px 峰值平台应达到 $kDockMagnificationMaxScale',
  );

  for (final side in const <double>[-1, 1]) {
    final inside = centre.dx + side * (edge - 1);
    await gesture.moveTo(Offset(inside, centre.dy));
    await _pumpUntil(
      tester,
      () => _hoverHighlightOn(tester, icon),
      label: '$label：槽内侧（${side < 0 ? '左' : '右'} 1px）应触发 hover',
    );
    final outside = centre.dx + side * (edge + 1);
    await gesture.moveTo(Offset(outside, centre.dy));
    await _pumpUntil(
      tester,
      () => !_hoverHighlightOn(tester, icon),
      label: '$label：槽外侧（${side < 0 ? '左' : '右'} 1px）不应触发 hover'
          '（槽中心必须按当前布局重测）',
    );
  }
  return peak;
}

ApplicationWindow _window(int id, String appId) => ApplicationWindow(
  id: id,
  appId: appId,
  title: 'w$id',
  active: false,
  minimized: false,
);

/// 按 appId 定位 pinned 图标。
Finder _pinnedIcon(String appId) => find.byWidgetPredicate(
  (widget) => widget is DockIcon && widget.appId == appId,
);

void main() {
  group('LauncherIcon', () {
    testWidgets('tap → services.toggleLauncher()', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      expect(find.byType(LauncherIcon), findsOneWidget);
      await tester.tap(find.byType(LauncherIcon));
      expect(services.launcherToggles, 1);
    });

    testWidgets('固定槽位 = metrics.iconSlotSize；icon 语义标签「应用程序」', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      expect(
        tester.getSize(find.byType(LauncherIcon)).width,
        // KosDockShell（800 宽、空 prefs）→ 与 shell 相同的反解槽宽。
        closeTo(
          DockMetrics.fromWidth(800).iconSlotSize,
          0.01,
        ),
      );
      final semantics = tester
          .widgetList<Semantics>(
            find.descendant(
              of: find.byType(LauncherIcon),
              matching: find.byType(Semantics),
            ),
          )
          .where((w) => w.properties.label == '应用程序');
      expect(semantics, isNotEmpty);
      expect(semantics.first.properties.button, isTrue);
    });
  });

  group('TrashIcon', () {
    testWidgets('tap → trashService.open()', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await tester.tap(find.byType(TrashIcon));
      await tester.pump();
      expect(trash.openCalls, 1);
    });

    testWidgets('空态 → assets/icons/trash.png；watch 非空 → trash_full.png',
        (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      Image image() => tester.widget<Image>(
        find.descendant(
          of: find.byType(TrashIcon),
          matching: find.byType(Image),
        ),
      );
      AssetImage asset() => image().image as AssetImage;

      // 旧实现的 Material 单色字形 + 空态半透已作废（KOS 只切 full/empty
      // 两枚图标，DockContainer.qml:586-588）。
      expect(asset().assetName, 'assets/icons/trash.png');
      expect(asset().package, 'kos_dock');
      expect(asset().keyName, 'packages/kos_dock/assets/icons/trash.png');
      // 原色渲染：**不 tint**（用户报告的「灰图标」缺陷回归防线）。
      expect(image().color, isNull);
      expect(image().colorBlendMode, isNull);
      expect(image().errorBuilder, isNotNull);
      expect(
        find.descendant(
          of: find.byType(TrashIcon),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );

      // watch 事件更新（StreamProvider → ref.watch 重建）。
      trash.emit(const TrashState(hasItems: true, count: 3));
      await tester.pump();
      await tester.pump();
      expect(asset().assetName, 'assets/icons/trash_full.png');
      expect(asset().keyName, 'packages/kos_dock/assets/icons/trash_full.png');
      expect(image().color, isNull);
      expect(image().colorBlendMode, isNull);

      // 清空后回到空态。
      trash.emit(TrashState.empty);
      await tester.pump();
      await tester.pump();
      expect(asset().assetName, 'assets/icons/trash.png');
    });

    testWidgets('右键 → 菜单两项（打开回收站 / 清空回收站）', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await _openTrashMenu(tester);
      expect(find.text(kDockTrashMenuOpenLabel), findsOneWidget);
      expect(find.text(kDockTrashMenuEmptyLabel), findsOneWidget);

      // 菜单「打开回收站」→ open()。
      await tester.tap(find.text(kDockTrashMenuOpenLabel));
      await tester.pump();
      expect(trash.openCalls, 1);
    });

    testWidgets('长按 → 菜单（KOS customContextMenu 长按入口）', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await tester.longPress(find.byType(TrashIcon));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDockTrashMenuOpenLabel), findsOneWidget);
      expect(find.text(kDockTrashMenuEmptyLabel), findsOneWidget);

      // 点外即关（140ms InCubic 退场后收 portal）。
      await tester.tapAt(const Offset(400, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDockTrashMenuOpenLabel), findsNothing);
    });

    testWidgets('菜单「清空回收站」→ 确认弹窗标题；取消不 empty', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await _openTrashMenu(tester);
      await tester.tap(find.text(kDockTrashMenuEmptyLabel));
      // 菜单 140ms 退场 + 弹窗打开。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDockConfirmTitle), findsOneWidget);
      expect(find.text(kDockConfirmBody), findsOneWidget);

      await tester.tap(find.text(kDockConfirmCancelLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(trash.emptyCalls, 0);
      expect(find.text(kDockConfirmTitle), findsNothing);
    });

    testWidgets('确认 → await empty() + 关闭；watch 驱动状态回落', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService()
        ..state = const TrashState(hasItems: true, count: 2);
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await _openTrashMenu(tester);
      await tester.tap(find.text(kDockTrashMenuEmptyLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDockConfirmTitle), findsOneWidget);

      await tester.tap(find.text(kDockConfirmEmptyLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(trash.emptyCalls, 1);
      expect(find.text(kDockConfirmTitle), findsNothing);
      // fake empty() emit 空态 → 图标回落到空态资产。
      expect(
        (tester
                .widget<Image>(
                  find.descendant(
                    of: find.byType(TrashIcon),
                    matching: find.byType(Image),
                  ),
                )
                .image as
            AssetImage)
            .assetName,
        'assets/icons/trash.png',
      );
    });

    testWidgets('确认失败 → debugPrint + 复位（弹窗仍在、可重试）', (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService()..emptyError = StateError('boom');
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      await _openTrashMenu(tester);
      await tester.tap(find.text(kDockTrashMenuEmptyLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text(kDockConfirmEmptyLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(trash.emptyCalls, 1);
      expect(find.text(kDockConfirmTitle), findsOneWidget);
      expect(find.text(kDockConfirmEmptyLabel), findsOneWidget);
    });
  });

  group('可见性开关', () {
    testWidgets('showLauncher/showTrash=false → 即时移除（写入 store）',
        (tester) async {
      final services = _FakeShellServices();
      final store = _MemoryDockPreferencesStore(const DockPreferences());
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);
      expect(find.byType(LauncherIcon), findsOneWidget);
      expect(find.byType(TrashIcon), findsOneWidget);

      final element = tester.element(find.byType(KosDockShell));
      final container = ProviderScope.containerOf(element, listen: false);
      await container
          .read(dockPreferencesProvider.notifier)
          .updateShowLauncher(false);
      await container
          .read(dockPreferencesProvider.notifier)
          .updateShowTrash(false);
      await tester.pump();
      expect(find.byType(LauncherIcon), findsNothing);
      expect(find.byType(TrashIcon), findsNothing);
      expect(
        store.visibilityWrites.any((w) => w.showLauncher == false),
        isTrue,
      );
      expect(
        store.visibilityWrites.any((w) => w.showTrash == false),
        isTrue,
      );
    });
  });

  group('magnification 指针广播（槽中心一致性回归）', () {
    testWidgets('入场结束后：launcher/trash/pinned 的槽中心峰值与 hover 触发 x 一致',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      // 入场（交错 60ms×index + 弹簧）有界推进到稳态，再探针。
      await _settle(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      final launcherPeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        find.byType(LauncherIcon),
        label: 'launcher',
      );
      final trashPeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        find.byType(TrashIcon),
        label: 'trash',
      );
      final katePeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('kate'),
        label: 'pinned[kate]',
      );
      final dolphinPeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('dolphin'),
        label: 'pinned[dolphin]',
      );

      // 四者在**各自**槽中心稳态下的峰值必须相同（同一指针广播）：
      // 逐个取稳态值比较，而不是把「指针停在别处时的当前值」当峰值比。
      for (final entry in <(String, double)>[
        ('trash', trashPeak),
        ('pinned[kate]', katePeak),
        ('pinned[dolphin]', dolphinPeak),
      ]) {
        expect(
          entry.$2,
          closeTo(launcherPeak, 0.01),
          reason: '${entry.$1} 的槽中心峰值应与 launcher 相同',
        );
      }
    });

    testWidgets('showLauncher/showTrash 切换（行水平位移）后 pinned 槽中心仍对齐',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(KosDockShell)),
        listen: false,
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      // 隐藏 trash：pill 少一个固定槽位（`Align.bottomCenter` 重新居中）→
      // 图标行整体左移（不是一整个槽位：左边界也跟着内缩）。方案 C 起槽宽/
      // pill 宽是 `DockMetrics.fromWidth` 的反解值；kate 中心 = 条带左边距 +
      // hpad + 固定槽位 + 图标区 Center 内缩 + slot/2，期望位移用同一组
      // metrics 字段按渲染几何现算（含 dockWidth↔自然宽的 ~0.5px 舍入余量）。
      double kateCenter(DockMetrics m, {required int slotsBefore}) {
        final s = m.iconSlotSize;
        // 固定槽位 launcher/trash 是等宽独立 Row 子节点，槽后无 itemSpacing
        // （itemSpacing 只烘进 pinned 条目之间与 divider margin）；kate 为
        // pinned 段首项，图标区 Center 内缩 0（content 宽 == dock.pinned 槽宽）。
        return (800 - m.dockWidth) / 2 + m.hPadding + slotsBefore * s + s / 2;
      }

      final beforeTrashToggle = tester.getCenter(_pinnedIcon('kate')).dx;
      await container
          .read(dockPreferencesProvider.notifier)
          .updateShowTrash(false);
      await _pumpUntil(
        tester,
        () => find.byType(TrashIcon).evaluate().isEmpty,
        label: 'showTrash=false 后 TrashIcon 应立即移除',
      );
      await _pumpFrames(tester, 30); // 行位移（入场）到稳态后再量几何
      expect(find.byType(TrashIcon), findsNothing);
      final afterTrashToggle = tester.getCenter(_pinnedIcon('kate')).dx;
      expect(afterTrashToggle, lessThan(beforeTrashToggle));
      final mTrashOn =
          DockMetrics.fromWidth(800, pinnedCount: 2); // launcher+trash 默认开
      final mTrashOff =
          DockMetrics.fromWidth(800, pinnedCount: 2, showTrash: false);
      expect(
        beforeTrashToggle - afterTrashToggle,
        closeTo(
          kateCenter(mTrashOn, slotsBefore: 2) -
              kateCenter(mTrashOff, slotsBefore: 1),
          0.5,
        ),
        reason: 'pill 少一个固定槽位并重新居中 → 图标行左移（位移由反解几何现算）',
      );
      final katePeakAfterTrash = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('kate'),
        label: 'pinned[kate]（showTrash=false 后）',
      );
      final launcherPeakAfterTrash = await _expectSlotCenterAligned(
        tester,
        gesture,
        find.byType(LauncherIcon),
        label: 'launcher（showTrash=false 后）',
      );
      expect(
        katePeakAfterTrash,
        closeTo(launcherPeakAfterTrash, 0.01),
        reason: '行位移后 pinned 峰值仍应与剩余 launcher 峰值相同',
      );

      // 再隐藏 launcher → icon 行继续左移（kate 之前只剩 pinned 段首项）。
      final beforeLauncherToggle = tester.getCenter(_pinnedIcon('kate')).dx;
      await container
          .read(dockPreferencesProvider.notifier)
          .updateShowLauncher(false);
      await _pumpUntil(
        tester,
        () => find.byType(LauncherIcon).evaluate().isEmpty,
        label: 'showLauncher=false 后 LauncherIcon 应立即移除',
      );
      await _pumpFrames(tester, 30);
      expect(find.byType(LauncherIcon), findsNothing);
      final afterLauncherToggle = tester.getCenter(_pinnedIcon('kate')).dx;
      expect(afterLauncherToggle, lessThan(beforeLauncherToggle));
      final mLauncherOff = DockMetrics.fromWidth(
        800,
        pinnedCount: 2,
        showLauncher: false,
        showTrash: false,
      );
      expect(
        beforeLauncherToggle - afterLauncherToggle,
        closeTo(
          kateCenter(mTrashOff, slotsBefore: 1) -
              kateCenter(mLauncherOff, slotsBefore: 0),
          0.5,
        ),
        reason: 'pill 再少一个固定槽位并重新居中 → 图标行继续左移（反解几何）',
      );
      final katePeakAfterLauncher = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('kate'),
        label: 'pinned[kate]（showLauncher=false 后）',
      );
      final dolphinPeakAfterLauncher = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('dolphin'),
        label: 'pinned[dolphin]（showLauncher=false 后）',
      );
      expect(
        katePeakAfterLauncher,
        closeTo(dolphinPeakAfterLauncher, 0.01),
        reason: '两次行位移后两个 pinned 图标的槽中心峰值仍应相同',
      );
    });

    testWidgets('重排（pinned 顺序写回）后 pinned 槽中心仍对齐', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      expect(
        tester.getCenter(_pinnedIcon('kate')).dx,
        lessThan(tester.getCenter(_pinnedIcon('dolphin')).dx),
      );

      // 等价「拖拽结束后框架回调 onReorder」：把第 0 项移到第 1 位。
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 1);
      // ReorderableListView 会以新 index 建 element → 行内入场动画重播，
      // 有界推进到稳态后再量几何（否则会把入场中间态当成布局中心）。
      await _pumpFrames(tester, 40);
      expect(
        tester.getCenter(_pinnedIcon('kate')).dx,
        greaterThan(tester.getCenter(_pinnedIcon('dolphin')).dx),
      );
      final katePeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('kate'),
        label: 'pinned[kate]（重排后）',
      );
      final dolphinPeak = await _expectSlotCenterAligned(
        tester,
        gesture,
        _pinnedIcon('dolphin'),
        label: 'pinned[dolphin]（重排后）',
      );
      expect(
        katePeak,
        closeTo(dolphinPeak, 0.01),
        reason: '重排后两个 pinned 图标的槽中心峰值仍应相同',
      );
    });
  });

  group('popup 单例（KOS DockModelService.activeDockPopup）', () {
    testWidgets('预览开着 → 右键 trash 开菜单：预览立即收，只剩一个 popup', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'kate')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      // hover pinned 300ms → kate 的窗口预览（卡标题 w1）。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(_pinnedIcon('kate')));
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('w1'), findsOneWidget);

      // 右键 trash → 菜单：KOS `openDockPopup` 先立即收掉 activeDockPopup
      // （不走预览 110ms 退场，故 2 帧内必须已消失）。
      await tester.tap(
        find.byType(TrashIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('w1'), findsNothing, reason: '预览必须被立即收起');
      expect(find.text(kDockTrashMenuOpenLabel), findsOneWidget);
      expect(find.text(kDockTrashMenuEmptyLabel), findsOneWidget);

      // 点外关闭 → 槽位释放，无残留 popup。
      await tester.tapAt(const Offset(400, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDockTrashMenuOpenLabel), findsNothing);
      expect(find.text('w1'), findsNothing);

      await gesture.removePointer();
      await tester.pump();
    });

    testWidgets('pinned 菜单开着 → 打开清空确认弹窗：菜单立即收，只剩确认弹窗',
        (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'kate')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      // 右键 pinned → 菜单（en locale 下文案 Open/New Window/Unpin）。
      await tester.tap(
        _pinnedIcon('kate'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New Window'), findsOneWidget);

      // 打开清空确认弹窗（等价 trash 菜单「清空回收站」→ openDockPopup）：
      // pinned 菜单必须被立即收起（不等 140ms 退场）。
      tester
          .state<TrashConfirmDialogState>(find.byType(TrashConfirmDialog))
          .open();
      await tester.pump();
      await tester.pump();
      expect(find.text(kDockConfirmTitle), findsOneWidget);
      expect(find.text('New Window'), findsNothing, reason: 'pinned 菜单必须被立即收起');

      // 取消 → 释放槽位：随后再开 pinned 菜单仍可用（无残留占用）。
      await tester.tap(find.text(kDockConfirmCancelLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(kDockConfirmTitle), findsNothing);
      await tester.tap(
        _pinnedIcon('kate'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New Window'), findsOneWidget);
    });

    testWidgets('预览开着 → tap launcher：先收 popup 再 toggleLauncher() 一次',
        (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(1, 'kate')];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      final trash = _FakeTrashService();
      addTearDown(trash.dispose);
      await tester.pumpWidget(_wrap(services, store, trash));
      await _settle(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(_pinnedIcon('kate')));
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('w1'), findsOneWidget);

      // KOS: dock/DockContainer.qml:560-563 —— launcher onActivate 先收
      // activeDockPopup 再 toggleLauncher()。
      await tester.tap(find.byType(LauncherIcon));
      await tester.pump();
      await tester.pump();
      expect(services.launcherToggles, 1);
      expect(find.text('w1'), findsNothing, reason: 'launcher tap 必须先收掉预览');

      await gesture.removePointer();
      await tester.pump();
    });
  });
}
