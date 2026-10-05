// TASK-03：hover 窗口预览 popup + 右键菜单测试。
//
// 复用 dock_icon_row_test.dart 的假 ShellServices 模式（全接口内存实现），
// 增加 emphasize/launch/activate/pin 记录。直接挂 DockIcon（内含
// DockPreviewAnchor + OverlayPortal），不经过 DockIconRow。
//
// 覆盖：300ms dwell 弹窗、130ms closeDelay 收窗、关闭中重入 handoff、
// 卡点击 activate+关、卡 hover 300ms emphasize + 离开释放、右键菜单
// open/new_window/unpin 且无 minimize/close、windows→空立即关。

import 'dart:typed_data';

import 'package:denial_sdk/system.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/dock_preview_popup.dart';
import 'package:kos_dock/src/widgets/dock_icon.dart';

// ── fakes（与 dock_icon_row_test.dart 同构，emphasize 加记录）───────────

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
  final emphasized = <int>[];
  final released = <int>[];

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
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) {
    emphasized.add(windowId);
    return () => released.add(windowId);
  }

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

ApplicationWindow _window(int id, String appId, {bool active = false}) =>
    ApplicationWindow(
      id: id,
      appId: appId,
      title: 'w$id',
      active: active,
      minimized: false,
    );

/// 挂单个 DockIcon 到屏幕底部（popup 在其上方展开）；`onTogglePin`
/// 计数验证 unpin 路径。
Widget _wrap(
  _FakeShellServices services,
  List<ApplicationWindow> windows,
  void Function() onTogglePin,
) => ProviderScope(
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: ShellServicesScope(
        services: services,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 60,
            child: Center(
              child: DockIcon(
                appId: 'kate',
                name: 'Kate',
                launchId: 'org.kde.kate',
                monitorId: 0,
                windows: windows,
                isActivated: windows.any((w) => w.active),
                monitorBounds: null,
                dragging: false,
                onTogglePin: () async => onTogglePin(),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// 两图标共享行级协调器（覆盖 DockModelService.qml:34-88 单例 popup
/// 语义）；`dragging`/`coordinator` 也由此注入。
Widget _wrap2(
  _FakeShellServices services, {
  List<ApplicationWindow> windowsA = const [],
  List<ApplicationWindow> windowsB = const [],
  bool draggingA = false,
  DockPopupCoordinator? coordinator,
}) => ProviderScope(
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: ShellServicesScope(
        services: services,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 60,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                DockIcon(
                  key: const ValueKey('A'),
                  appId: 'kate',
                  name: 'Kate',
                  launchId: 'org.kde.kate',
                  monitorId: 0,
                  windows: windowsA,
                  isActivated: windowsA.any((w) => w.active),
                  monitorBounds: null,
                  dragging: draggingA,
                  onTogglePin: () async {},
                  coordinator: coordinator,
                ),
                DockIcon(
                  key: const ValueKey('B'),
                  appId: 'dolphin',
                  name: 'Dolphin',
                  launchId: 'org.kde.dolphin',
                  monitorId: 0,
                  windows: windowsB,
                  isActivated: windowsB.any((w) => w.active),
                  monitorBounds: null,
                  dragging: false,
                  onTogglePin: () async {},
                  coordinator: coordinator,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

/// 指针悬停图标中心 → 等 300ms dwell + 16ms 预滚 + 入场动画播完。
Future<TestGesture> _hoverIcon(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.byType(DockIcon)));
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump(const Duration(milliseconds: 200));
  return gesture;
}

Finder get _cardTitle => find.text('w1');

/// 同 [_hoverIcon]，目标任意图标 finder（多图标场景）。
Future<TestGesture> _hoverIconAt(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump(const Duration(milliseconds: 200));
  return gesture;
}

void main() {
  group('DockPreviewAnchor 抑制/协调', () {
    testWidgets('拖拽中：dwell 不弹预览；已开预览立即关', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      final coordinator = DockPopupCoordinator();
      await tester.pumpWidget(
        _wrap2(services, windowsA: services.windowsList,
            coordinator: coordinator),
      );
      await tester.pump();

      // 拖拽中 → 300ms dwell 后仍无预览。
      await tester.pumpWidget(
        _wrap2(services, windowsA: services.windowsList,
            draggingA: true, coordinator: coordinator),
      );
      final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('A'))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_cardTitle, findsNothing);

      // 停止拖拽后指针已在槽内（onEnter 不重复触发）→ 移出再移入才
      // 重新 arm dwell（KOS previewDelay 也只在 entered 时 restart）。
      await tester.pumpWidget(
        _wrap2(services, windowsA: services.windowsList,
            coordinator: coordinator),
      );
      await gesture.moveTo(const Offset(20, 20));
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('A'))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_cardTitle, findsOneWidget);

      // 预览开着再进入拖拽 → didUpdateWidget → 立即关。
      await tester.pumpWidget(
        _wrap2(services, windowsA: services.windowsList,
            draggingA: true, coordinator: coordinator),
      );
      await tester.pump();
      await tester.pump();
      expect(_cardTitle, findsNothing);
      await gesture.removePointer();
    });

    testWidgets('图标 B 悬停 dwell → 立即收掉 A 的预览', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'dolphin')];
      final coordinator = DockPopupCoordinator();
      await tester.pumpWidget(
        _wrap2(
          services,
          windowsA: [_window(1, 'kate')],
          windowsB: [_window(2, 'dolphin')],
          coordinator: coordinator,
        ),
      );
      await tester.pump();

      // A 悬停 → 预览 w1 弹出。
      final gesture = await _hoverIconAt(
          tester, find.byKey(const ValueKey('A')));
      expect(_cardTitle, findsOneWidget);

      // 指针移到 B 悬停 300ms → A 的预览立即收（不等 130ms closeDelay）、
      // B 的预览 w2 弹出。
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('B'))));
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_cardTitle, findsNothing);
      expect(find.text('w2'), findsOneWidget);
      await gesture.removePointer();
    });

    testWidgets('图标 B 右键菜单 → 立即收掉 A 的预览', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'dolphin')];
      final coordinator = DockPopupCoordinator();
      await tester.pumpWidget(
        _wrap2(
          services,
          windowsA: [_window(1, 'kate')],
          windowsB: [_window(2, 'dolphin')],
          coordinator: coordinator,
        ),
      );
      await tester.pump();

      final gesture = await _hoverIconAt(
          tester, find.byKey(const ValueKey('A')));
      expect(_cardTitle, findsOneWidget);

      // B 右键 → A 预览立即收 + B 菜单开。
      await tester.tap(find.byKey(const ValueKey('B')),
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(_cardTitle, findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsOneWidget);
      await gesture.removePointer();
    });

    testWidgets('A 菜单开着 → B 悬停 dwell 不弹预览', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'dolphin')];
      final coordinator = DockPopupCoordinator();
      await tester.pumpWidget(
        _wrap2(
          services,
          windowsA: [_window(1, 'kate')],
          windowsB: [_window(2, 'dolphin')],
          coordinator: coordinator,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('A')),
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsOneWidget);

      // A 的 activeContextMenu 对行内可见 → B 的 previewDelay 不 arm。
      final pointer = TestPointer(9, PointerDeviceKind.mouse, 9);
      await tester.sendEventToBinding(
          pointer.addPointer(location: Offset.zero));
      await tester.sendEventToBinding(
          pointer.hover(tester.getCenter(find.byKey(const ValueKey('B')))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('w2'), findsNothing);
      await tester.sendEventToBinding(pointer.removePointer());
    });
  });
  group('DockPreviewAnchor 窗口预览', () {
    testWidgets('hover 300ms dwell → portal 展示预览卡', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      expect(_cardTitle, findsNothing);

      final gesture = await _hoverIcon(tester);
      // 工具条 appName + 卡标题都在。
      expect(find.text('Kate'), findsWidgets);
      expect(_cardTitle, findsOneWidget);

      // 收尾：移走指针 → 130ms closeDelay + 110ms retreat。
      await gesture.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 140));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_cardTitle, findsNothing);
    });

    testWidgets('离开 → 130ms closeDelay 后 retreat 关闭', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      final gesture = await _hoverIcon(tester);
      expect(_cardTitle, findsOneWidget);

      await gesture.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 100));
      // 130ms 未到：仍在。
      expect(_cardTitle, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      // closeDelay 已触发 retreat（110ms），再等播完。
      await tester.pump(const Duration(milliseconds: 150));
      expect(_cardTitle, findsNothing);
    });

    testWidgets('关闭中重入图标 → handoff 回弹不收窗', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      final gesture = await _hoverIcon(tester);
      expect(_cardTitle, findsOneWidget);

      // 离开触发 closeDelay（130ms）。注意 tester.pump 在中途只触发
      // Timer、收尾帧才让 ticker 起步——retreat 的 110ms 从本 pump 的末帧
      // 开始算，所以重入时它还停在起点（等价「关闭中」）。
      await gesture.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(tester.getCenter(find.byType(DockIcon)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_cardTitle, findsOneWidget);

      await gesture.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 140));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_cardTitle, findsNothing);
    });

    testWidgets('卡点击 → activateWindow + popup 关闭', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      final gesture = await _hoverIcon(tester);
      expect(find.text('w1'), findsOneWidget);
      expect(find.text('w2'), findsOneWidget);
      // 多窗工具条带计数后缀。
      expect(find.textContaining('Kate'), findsWidgets);

      // 指针已在 popup 桥带内（icon→card 移动由 popup MouseRegion 接住）。
      await gesture.moveTo(tester.getCenter(find.text('w1')));
      await tester.pump();
      await tester.tap(find.text('w1'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(services.activated, [1]);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('w1'), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('卡 hover 300ms → emphasizeWindow；离开 → release', (
      tester,
    ) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      final gesture = await _hoverIcon(tester);

      // 移到 w1 卡上 → 300ms 后 emphasize。
      await gesture.moveTo(tester.getCenter(find.text('w1')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(services.emphasized, isEmpty);
      await tester.pump(const Duration(milliseconds: 250));
      expect(services.emphasized, [1]);

      // 移到 w2 卡 → w1 release，w2 再计 300ms。
      await gesture.moveTo(tester.getCenter(find.text('w2')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(services.released, [1]);
      expect(services.emphasized, [1, 2]);
      // 移出 popup → 释放 + closeDelay（130ms）+ retreat（110ms）关窗
      // （timer 触发帧只让 ticker 起步，须再补一帧跑完退场）。
      await gesture.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 140));
      await tester.pump(const Duration(milliseconds: 150));
      expect(services.released, [1, 2]);
      expect(find.text('w1'), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('windows → 空：popup 立即关', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      var unpinned = 0;
      await tester.pumpWidget(
        _wrap(services, services.windowsList, () => unpinned++),
      );
      await tester.pump();
      final gesture = await _hoverIcon(tester);
      expect(_cardTitle, findsOneWidget);

      // 窗口消失 → onEffectiveWindowsChanged → dismissDockPopupImmediately。
      services.windowsList = [];
      await tester.pumpWidget(_wrap(services, const [], () => unpinned++));
      await tester.pump();
      await tester.pump();
      expect(_cardTitle, findsNothing);
      await gesture.removePointer();
    });
  });

  group('DockPreviewAnchor 右键菜单', () {
    testWidgets('右键 → 菜单含 打开/新建窗口/取消固定，无最小化/关闭项', (
      tester,
    ) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();

      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // KOS pinned 分支：open / new_window / unpin（中文 zh 文案在非 zh
      // locale 走英文；测试环境 locale=en）。
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('New Window'), findsOneWidget);
      expect(find.text('Unpin'), findsOneWidget);
      // CONSTRAINTS §5：无 minimize/close 项。
      expect(find.text('Minimize'), findsNothing);
      expect(find.textContaining('Close'), findsNothing);
      // 菜单开着时预览不弹。
      expect(find.text('w1'), findsNothing);
    });

    testWidgets('「打开」有窗 → activate MRU 首窗并关菜单', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate'), _window(2, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(services.activated, [1]); // MRU = windows.first
      // 140ms InCubic 菜单退场播完 portal 才 hide。
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('「新建窗口」→ launchApplication(launchId)', (tester) async {
      final services = _FakeShellServices()..windowsList = [];
      await tester.pumpWidget(_wrap(services, const [], () {}));
      await tester.pump();
      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('New Window'));
      await tester.pump();
      expect(services.launched.single.id, 'org.kde.kate');
      expect(services.launched.single.monitorId, 0);
    });

    testWidgets('「取消固定」→ onTogglePin 写回', (tester) async {
      final services = _FakeShellServices()..windowsList = [];
      var unpinned = 0;
      await tester.pumpWidget(
        _wrap(services, const [], () => unpinned++),
      );
      await tester.pump();
      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Unpin'));
      await tester.pump();
      expect(unpinned, 1);
    });

    testWidgets('菜单开着时不弹预览；点外即关', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();

      // 右键开菜单。
      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsOneWidget);

      // 菜单抑制预览：即使悬停图标，无预览卡。右键 tap 的鼠标指针
      // （device 1）一直活着（tap 只发 up、不发 removed），再 add 同
      // device 会撞 MouseTracker 断言——所以用 device 9 的裸 TestPointer
      // 发 add/hover/remove。
      final pointer = TestPointer(9, PointerDeviceKind.mouse, 9);
      await tester.sendEventToBinding(
        pointer.addPointer(location: Offset.zero),
      );
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(DockIcon))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('w1'), findsNothing);

      // 点外（空白处）→ 菜单关闭。touch tap 不经过 MouseTracker。
      await tester.tapAt(const Offset(400, 100));
      await tester.pump();
      // 140ms InCubic 菜单退场播完 portal 才 hide。
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsNothing);
      await tester.sendEventToBinding(pointer.removePointer());
    });
  });

    testWidgets('菜单关闭播 140ms InCubic 退场后才收 portal', (tester) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      await tester.tap(
        find.byType(DockIcon),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Open'), findsOneWidget);

      // 点外即关 → 140ms InCubic 退场；播完 portal 才 hide。
      await tester.tapAt(const Offset(400, 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('预览工具条「+」→ launchApplication(launchId) + 关预览', (
      tester,
    ) async {
      final services = _FakeShellServices()
        ..windowsList = [_window(1, 'kate')];
      await tester.pumpWidget(_wrap(services, services.windowsList, () {}));
      await tester.pump();
      final gesture = await _hoverIcon(tester);
      expect(_cardTitle, findsOneWidget);

      // 指针跨桥带进 popup 后点「+」。KOS: DockWindowPreview.qml:274-287
      // launchNewWindow 后关 popup。
      await gesture.moveTo(tester.getCenter(find.text('+')));
      await tester.pump();
      await tester.tap(find.text('+'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(services.launched.single.id, 'org.kde.kate');
      expect(services.launched.single.monitorId, 0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_cardTitle, findsNothing);
      await gesture.removePointer();
    });
}
