// TASK-10：Dock 图标弹跳反馈测试（launch bounce + hover 过冲弹簧）。
//
// 假 ShellServices 全接口内存实现（同 dock_icon_row_test.dart 的范式），
// 无真实 wayland/dbus/socket 依赖。
//
// 覆盖：
// - `_activate` 的 `windows.isEmpty` launch 分支触发单次弹跳（y 位移从 0
//   上升、最高 ~kDockLaunchBounceHeight，随后收敛回 `_liftFor(p)` 基线）；
// - 有窗 activate/多窗轮循**不**弹跳；重复点击在 `_launched` 锁内不叠加；
// - launcher/trash（`DockControlIcon`）tap 同样弹跳（内部 onTap 包装，
//   外部 callback 仍被调用）；
// - hover 稳态 scale/lift：`kDockHoverScale`=1.20 与 lift 基线不变
//   （`kDockHoverEaseDuration` 100ms OutCubic 的 bounded tween 回退路径；
//   TASK-11 起 hover 放大由行级高斯波接管，不再逐图标 spring——本组
//   只测「无容器指针时独立 hover」的回退分支）；
// - `MediaQuery.disableAnimations`（flutter_test 恒 true）下新 controller
//   不 forward/repeat：弹跳后 pump 不挂（无活动 ticker 拖挂收尾）。
//
// 注意：flutter_test 里 `disableAnimations` 恒 true → widget 层 bounce
// controller 永不 forward（走「直写终值」兜底）。弹跳数值路径经
// `_kosDockBounceLift`（与 widget 同一份 TweenSequence 定义）驱动独立
// controller 验证——它测的是「bounce 值曲线」本身（上升/峰值/落地回弹/
// 单次），widget 层只负责在 tap 时 forward 同一条曲线。

import 'dart:async';
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
import 'package:kos_dock/src/widgets/launcher_icon.dart' show DockControlIcon;

/// 驱动 `kosDockBounceLiftSequence`（实现侧单源常量，`dock_icon.dart`）的
/// 独立 controller：0 → kDockLaunchBounceHeight（220ms easeOutQuad）→
/// 0（340ms bounceOut），总时长 560ms 单次 forward。widget 内 controller
/// 在 disableAnimations 下不 forward，故数值曲线由此处同一常量驱动验证——
/// 不再是测试内复本，改实现即改断言输入。
Animation<double> _kosDockBounceLift(AnimationController controller) =>
    controller.drive(kosDockBounceLiftSequence);

// ── fakes（同 dock_icon_row_test.dart 的最小集） ──────────────────────────

class _MemoryDockPreferencesStore implements DockPreferencesStore {
  _MemoryDockPreferencesStore(this._prefs);
  DockPreferences _prefs;

  @override
  Future<DockPreferences> read() async => _prefs;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
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

  /// 非 null 时 `launchApplication` 挂起在它的 future 上（测试用：让
  /// `_launched` 锁保持 true，验证弹跳期连点不重发/不重启）。
  Completer<bool>? launchCompleter;

  @override
  ProviderListenable<List<LaunchableApplication>> get applications =>
      Provider((_) => apps);

  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) =>
      Provider((_) => windowsList);

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) {
    launched.add((id: id, monitorId: monitorId));
    return launchCompleter?.future ?? Future.value(true);
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
  }) =>
      const SizedBox.shrink();
}

// ── helpers ────────────────────────────────────────────────────────────

const _apps = [
  LaunchableApplication(
    id: 'org.kde.kate',
    appId: 'kate',
    name: 'Kate',
    windowAppIds: ['kate', 'org.kde.kate'],
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

Widget _wrap(Widget child, _FakeShellServices services) => ProviderScope(
      overrides: [
        dockPreferencesStoreProvider
            .overrideWithValue(_MemoryDockPreferencesStore(
          DockPreferences(pinned: [_pin(_apps[0])]),
        )),
      ],
      child: MaterialApp(
        home: ShellTheme(
          data: const ShellThemeData(),
          child: SizedBox(width: 800, height: kDockBaseHeight, child: child),
        ),
      ),
    );

Widget _iconRow(_FakeShellServices services) =>
    _wrap(DockIconRow(monitorId: 0, services: services), services);

/// 独立 `DockControlIcon`（launcher/trash 共用件的最小宿主）：自带
/// MagnificationPointer 缺席 → 走独立 hover 分支。
Widget _controlIcon(_FakeShellServices services, {VoidCallback? onTap}) =>
    _wrap(
      Center(
        child: DockControlIcon(
          services: services,
          semanticLabel: '测试图标',
          onTap: onTap ?? () {},
          child: const SizedBox.expand(),
        ),
      ),
      services,
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// 图标子树内槽内视觉层 `Transform.translate` 的 y 位移（storage[13]）。
///
/// 命中规则：槽内视觉 translate 是**唯一 child 为 `Transform.scale`** 的
/// Transform（`Transform.translate(offset: Offset(0, lift−bounce),
/// child: Transform.scale(...))`）；祖先入场 slide / popup overlay 层的
/// translate 都不在「icon 后代且孩子为 scale」这一形状上。无命中回退 0。
double _translateY(WidgetTester tester, Finder icon) {
  for (final transform in tester.widgetList<Transform>(
    find.descendant(of: icon, matching: find.byType(Transform)),
  )) {
    if (transform.child is Transform) {
      return transform.transform.storage[13];
    }
  }
  return 0.0;
}

/// 图标子树内最大 Transform scale（放大弹簧的手感量；含 bounce 不影响
/// scale——bounce 只走 translate.y）。
double _maxScale(WidgetTester tester, Finder icon) {
  var scale = 1.0;
  for (final transform in tester.widgetList<Transform>(
    find.descendant(of: icon, matching: find.byType(Transform)),
  )) {
    final s = transform.transform.getMaxScaleOnAxis();
    if (s > scale) scale = s;
  }
  return scale;
}

void main() {
  group('TASK-10 launch bounce（点击启动单次弹跳）', () {
    test('bounce 曲线：0→19 上升 220ms → 340ms bounceOut 落地，单次收敛回 0',
        () async {
      // 数值路径：实现侧单源 `kosDockBounceLiftSequence`（dock_icon.dart）——
      // 与 widget 内 `_bounceLift` 是同一常量，改实现即改本断言的输入。
      final controller = AnimationController(
        vsync: const TestVSync(),
        duration:
            kDockLaunchBounceRiseDuration + kDockLaunchBounceFallDuration,
      );
      addTearDown(controller.dispose);
      final lift = _kosDockBounceLift(controller);

      expect(lift.value, 0);
      unawaited(controller.forward());

      var peak = 0.0;
      var previous = -1.0;
      // 220ms 上升段：easeOutQuad 单调上行到 19px。
      for (var t = 0; t <= 220; t += 20) {
        controller.value = t / 560;
        peak = lift.value > peak ? lift.value : peak;
        expect(lift.value, greaterThanOrEqualTo(0));
        expect(lift.value, lessThanOrEqualTo(kDockLaunchBounceHeight + 1e-9));
        expect(
          lift.value,
          greaterThanOrEqualTo(previous),
          reason: 'easeOutQuad 上升段单调不减（t=$t）',
        );
        previous = lift.value;
      }
      // 峰值钉 19：easeOutQuad 在 220ms 处必达终值（非「>15」近似）。
      expect(peak, closeTo(kDockLaunchBounceHeight, 1e-6));
      controller.value = 220 / 560;
      expect(lift.value, closeTo(kDockLaunchBounceHeight, 1e-6));

      // 340ms 落地段：bounceOut 的「反弹」是位移回到 0 的多段递减反弹，
      // 位移本身恒 ≥0 不穿地；写反成两段曲线则此处不成立。
      controller.value = 300 / 560;
      expect(
        lift.value,
        lessThan(kDockLaunchBounceHeight * 0.9),
        reason: '落地段应已从峰值回落（bounceOut 前段快速下行）',
      );
      controller.value = 1.0;
      expect(lift.value, 0);
    });

    testWidgets('无窗口 pinned 图标 tap → launchApplication；有窗 → 不 launch',
        (tester) async {
      // disableAnimations 下 bounce 走「钉 0」兜底——widget 层断言落在
      // 「tap 分支行为正确、槽位尺寸不变、动画不留活动 ticker」上。
      final services = _FakeShellServices()..apps = _apps;
      await tester.pumpWidget(_iconRow(services));
      await _settle(tester);
      final icon = find.byType(DockIcon);
      expect(icon, findsOneWidget);
      final slot = tester.getSize(icon);

      // launch 分支（windows.isEmpty）。
      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      expect(services.launched.single.id, 'org.kde.kate');
      // 弹跳只发生在槽内 Transform：槽位尺寸/pill 布局不变。
      expect(tester.getSize(icon), slot);
      // disableAnimations 下 bounce 未 forward → y 位移保持基线 0。
      expect(_translateY(tester, icon), 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_translateY(tester, icon), 0); // 无残留 ticker / 无挂起
    });

    testWidgets(
        '真 tap（disableAnimations=false）触发弹跳：y 过冲峰值后收敛回 lift 基线',
        (tester) async {
      // 覆盖验收 4 的核心路径：widget 层 `_bounce.forward` 真实推进。
      // flutter_test 默认 disableAnimations=true，这里用显式 MediaQuery
      // 关闭它，让 `_activate` 走 forward 分支而非钉 0 兜底。
      final services = _FakeShellServices()..apps = _apps;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: _iconRow(services),
        ),
      );
      // _settle 的分帧泵推进 entrance 弹簧（60ms×index + Motion.snappy）。
      await _settle(tester);
      final icon = find.byType(DockIcon);
      expect(icon, findsOneWidget);
      final slot = tester.getSize(icon);
      // tap 前把 mouse 指针移到图标上 → 真实 `_hovering=true`（mouse kind
      // 的 tap 序列天然带 pointer hover）；记录 hover 稳态 lift 作基线。
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(icon));
      // 等 hover 弹簧完全收敛（Motion.bouncy 有 ~1.5% 过冲，settle 时间
      // 可能 >1s），再记 lift 基线——否则采样期弹簧还在收敛会污染基线。
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final baseY = _translateY(tester, icon);
      expect(baseY, lessThan(-1), reason: 'hover 稳态应有负 lift（≈−3.4px）');
      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      // TASK-11：槽位随高斯波可变——鼠标正 hover 在本图标上，槽位已被放大
      // 到 ~1.5×（不再是 tap 前静止的 `slot`）。断言的是「bounce 不再次改
      // 变槽位尺寸」：tap 后量取一次 hover 态尺寸，采样期间保持自一致。
      final hoverSlot = tester.getSize(icon);
      expect(hoverSlot.width, greaterThan(slot.width),
          reason: 'hover 高斯波应已把槽位撑开（TASK-11 可变槽位）');

      // 分帧采样 translate.y：16ms 粒度足以捕到 220ms 上升段的峰值。
      // bounce 位移是负 y（向上）叠加在 lift 基线 baseY 上 → 峰值 ≈
      // baseY − 19。
      var minY = baseY;
      var sawPeakNear19 = false;
      var sawFallBelowHalf = false;
      // 560ms 全程 + 余量：每 16ms 采一帧。
      for (var elapsed = 0; elapsed <= 700; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        final y = _translateY(tester, icon);
        if (y < minY) minY = y;
        if (y <= baseY - kDockLaunchBounceHeight + 2.0) {
          sawPeakNear19 = true;
        }
        // 落地段 bounceOut 前段快速下行：过半后应明显高于峰值（|y| 减半）。
        if (elapsed > 220 && y > baseY - kDockLaunchBounceHeight * 0.5) {
          sawFallBelowHalf = true;
        }
      }
      expect(
        sawPeakNear19,
        isTrue,
        reason: '上升段应出现 ≈−19px 过冲位移（实测 min=$minY, base=$baseY）',
      );
      expect(
        minY,
        closeTo(baseY - kDockLaunchBounceHeight, 3.0),
        reason: 'easeOutQuad 在 220ms 必达 19px（容差内含采样粒度+hover lift）',
      );
      expect(
        sawFallBelowHalf,
        isTrue,
        reason: 'bounceOut 落地段应回落到峰值一半以下',
      );
      // 收敛回基线：bounce 归 0 后 y 回到 hover lift（非 0）。
      expect(_translateY(tester, icon), closeTo(baseY, 1e-6));
      // TASK-11 可变槽位：bounce 只动槽内 translate，不再次改变已被高斯波
      // 放大的槽位尺寸（hoverSlot，非 tap 前静止的 slot）。
      expect(tester.getSize(icon), hoverSlot,
          reason: 'bounce 不改槽位尺寸');
    });

    testWidgets('弹跳进行中换树 dispose：无 ticker 泄漏、无异常',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: _iconRow(services),
        ),
      );
      await _settle(tester);
      final icon = find.byType(DockIcon);
      // hover + tap：确认 bounce 轨迹真实在推进。bounce 只在 forward 的
      // 560ms 内有值——等 _settle 完成后才开始采样，避免 hover 弹簧的
      // Motion.bouncy 过冲把 y 推负而误认成「弹跳进行中」。
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(icon));
      // 等 hover 弹簧完全收敛：bouncy 的 settle 可能 >1s，故用
      // pump-and-settle 而非定时长。
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final baseY = _translateY(tester, icon);
      expect(baseY, lessThan(-1), reason: 'hover 稳态 lift ≈ −3.4px');

      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      // 弹跳上升段中点（~112ms → bounce ≈ −14px 区间，叠加 baseY）。分
      // 16ms 步进：AnimationController 的 startTime 取首个 tick 的帧时间戳，
      // 单次大跨度 pump 会让那一帧成为动画起点（elapsed=0）采不到位移。
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final inFlightY = _translateY(tester, icon);
      expect(
        inFlightY,
        lessThan(baseY - 3),
        reason: '确认 bounce 已启动（|y−base|>3）再 unmount',
      );
      // 整树换掉 → dispose；收尾 pump 无「ticker 仍活动」异常即通过。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(find.byType(DockIcon), findsNothing);
    });

    testWidgets('弹跳期连点不叠加：_launched 锁内第二次 tap 不重启 bounce',
        (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        // launchApplication 挂起不返回 → _launched 锁保持 true。
        ..launchCompleter = Completer<bool>();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: _iconRow(services),
        ),
      );
      await _settle(tester);
      final icon = find.byType(DockIcon);
      // hover 使 lift 基线非零（负），bounce 叠加其上更易区分「重启」。
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(icon));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final baseY = _translateY(tester, icon);

      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1));
      // 推进到上升段中段（~112ms → bounce ≈ −14px，叠加 baseY）。分 16ms
      // 步进——单次大跨度 pump 会让首 tick 成为动画起点（elapsed=0）。
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final midY = _translateY(tester, icon);
      expect(midY, lessThan(baseY - 3), reason: '弹跳进行中');

      // 锁内第二次 tap：既不重发 launch，也不重启 bounce 轨迹。
      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(services.launched, hasLength(1), reason: '_launched 锁内不重发');
      await tester.pump(const Duration(milliseconds: 16));
      final afterSecondTap = _translateY(tester, icon);
      // bounce 按原轨迹继续上行（y 更负），而非从 baseY 重播（否则 y 会跳回
      // baseY 附近再起步——110ms 处 |y−base|≈10px，重播后 16ms 只能到 ~1px；
      // 断言 y 仍远离 baseY 即证明轨迹未被重启）。
      expect(
        afterSecondTap,
        lessThan(baseY - 3),
        reason: 'bounce 未被重启：y 继续原轨迹（mid=$midY → $afterSecondTap）',
      );
      // 收敛回基线。
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_translateY(tester, icon), closeTo(baseY, 1e-6));
    });

    testWidgets('有窗图标 tap → activateWindow（不弹跳；_launched 不涉及）',
        (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [_window(7, 'kate')];
      await tester.pumpWidget(_iconRow(services));
      await _settle(tester);
      await tester.tap(find.byType(DockIcon), kind: PointerDeviceKind.mouse);
      expect(services.activated, [7]);
      expect(services.launched, isEmpty);
      expect(_translateY(tester, find.byType(DockIcon)), 0);
    });
  });

  group('TASK-10 DockControlIcon（launcher/trash 共用）tap 弹跳', () {
    testWidgets('tap → onTap 被调用且 bounce 不挂（disableAnimations 钉 0）',
        (tester) async {
      final services = _FakeShellServices();
      var taps = 0;
      await tester.pumpWidget(_controlIcon(services, onTap: () => taps++));
      await _settle(tester);
      final icon = find.byType(DockControlIcon);
      expect(icon, findsOneWidget);
      final slot = tester.getSize(icon);

      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(taps, 1);
      // 弹跳不布局：槽位尺寸不变；disableAnimations 下 y 钉 0、无残留。
      expect(tester.getSize(icon), slot);
      expect(_translateY(tester, icon), 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_translateY(tester, icon), 0);
      // 再 tap 仍可（bounce 单次 forward(from:0)，非 _launched 锁——
      // launcher/trash 无「等待 launch 返回」语义，每次 tap 都重播）。
      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(taps, 2);
    });

    testWidgets('DockControlIcon tap 真弹跳（disableAnimations=false）',
        (tester) async {
      // launcher/trash 共用件同样走 `kosDockBounceLiftSequence`：真 tap →
      // y 在 lift 基线上过冲 ≈−19px 再收敛回基线。
      final services = _FakeShellServices();
      var taps = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: _controlIcon(services, onTap: () => taps++),
        ),
      );
      await _settle(tester);
      final icon = find.byType(DockControlIcon);
      // tap 前把 mouse 指针移到图标上 → 真实 `_hovering=true`（mouse kind
      // 的 tap 序列天然带 pointer hover）；记录 hover 稳态 lift 作基线。
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(icon));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final baseY = _translateY(tester, icon);
      expect(baseY, lessThan(-1), reason: 'hover 稳态应有负 lift（≈−3.4px）');

      await tester.tap(icon, kind: PointerDeviceKind.mouse);
      expect(taps, 1);

      var minY = baseY;
      var sawPeakNear19 = false;
      for (var elapsed = 0; elapsed <= 700; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        final y = _translateY(tester, icon);
        if (y < minY) minY = y;
        if (y <= baseY - kDockLaunchBounceHeight + 2.0) {
          sawPeakNear19 = true;
        }
      }
      expect(
        sawPeakNear19,
        isTrue,
        reason: 'DockControlIcon tap 应出现 ≈−19px 过冲（实测 min=$minY, base=$baseY）',
      );
      expect(
        minY,
        closeTo(baseY - kDockLaunchBounceHeight, 3.0),
      );
      expect(_translateY(tester, icon), closeTo(baseY, 1e-6));
    });
  });
  group('TASK-11 hover 稳态（kDockHoverScale=1.20 回退路径）', () {
    // TASK-10 的 `kDockHoverSpring`（Motion.bouncy hover 过冲弹簧）已随
    // TASK-11 移除：高斯波下各槽 scale 由 `dockWaveLayout` 每帧直算，
    // 不再经逐图标 spring 跟手（硬性约束①唯一缓动是振幅包络）。本组
    // 只测「无容器指针时独立 hover」的回退分支稳态值。
    testWidgets('hover 后稳态 scale/lift 不变（无过冲，直写终值）', (tester) async {
      final services = _FakeShellServices();
      await tester.pumpWidget(_controlIcon(services));
      await _settle(tester);
      final icon = find.byType(DockControlIcon);
      final slot = tester.getSize(icon);

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(icon));
      // 推进到稳态：disableAnimations 下 bounded tween 直写终值
      // （`_hover.value = target` 兜底），故稳态即是「目标值」——
      // 断言它没被 bounce/过冲改动（无 spring → 无过冲）。
      await _settle(tester);
      expect(_maxScale(tester, icon), closeTo(kDockHoverScale, 1e-6));
      // 独立 hover lift = −max(2, round(iconSize×0.08))（负 y 向上）。
      final metrics =
          DockMetricsScope.of(tester.element(icon));
      final expectedLift =
          -(metrics.iconSize * kDockHoverLiftRatio)
              .roundToDouble()
              .clamp(2.0, double.infinity);
      expect(
        _translateY(tester, icon),
        closeTo(expectedLift, 1e-6),
        reason: 'hover 稳态 lift 不因 bounce 改变',
      );
      expect(tester.getSize(icon), slot, reason: '独立 hover 不动布局尺寸');
    });
  });
}
