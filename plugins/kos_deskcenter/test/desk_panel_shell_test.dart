// DeskPanelShell / 卡片点击 → 面板 surface widget 测试（TASK-12 §9.4 方案 B）。
//
// 覆盖：
// - `KosDeskCenterPanelSurface` 契约：id、layer=`desktopControls`、`place()` 的
//   bounds/occupiesDesktop/visible 与主输出/非主输出门控；
// - `DeskPanelShell` 渲染：标题栏、关闭钮（×，key `desk-panel-close`）、
//   ShellBackdropBlur+Material 材质链；
// - `KosDeskCenterView` 非编辑态整卡 tap → 写入跨 surface 会话 provider
//   （`deskPanelSessionProvider`），由 `DeskPanelSurfaceHost`（`desktopControls`
//   层）渲染 `DeskPanelShell`；`services` 为 null 也能弹；
// - 输入区：面板打开时 `shellInteractionRegistryProvider` 出现 `keyboardPolicy
//   == capture` 的交互面（bounds 覆盖工作区），关闭后移除；
// - 关闭路径：关闭钮 / 点遮罩 / Esc 关闭；点面板卡片内部不关闭；
// - 同卡重复打开覆盖同一会话；编辑态整卡 tap 不弹面板。
//
// 宿主：真实 shell 里 `KosDeskCenterPlugin`（容器）与 `KosDeskCenterPanelSurface`
// （面板）是两个独立 `ShellSurface`，挂在同一个 `ProviderScope` 下。测试用
// `Stack[KosDeskCenterView, ShellInputClip(DeskPanelSurfaceHost)]` 复刻层序
// （面板画在容器之上，且带 output 级输入裁剪，等价 `ShellSurfacePlane`）。

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/kos_deskcenter.dart' show KosDeskCenterPanelSurface;
import 'package:kos_deskcenter/src/widgets/clock_card.dart';
import 'package:kos_deskcenter/src/widgets/desk_center_view.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_surface.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';

/// 测试视口（= 模拟的工作区，`ShellInputClip` 边界与实际 shell 的
/// `output.logicalRect` 同语义）。
const Size _viewport = Size(800, 1200);
const Rect _workArea = Rect.fromLTWH(0, 0, 800, 1200);

/// 800×1200 容器 + ProviderScope；面板 surface 画在容器之上，并以
/// `ShellInputClip` 提供 output 级输入裁剪（复刻 `ShellSurfacePlane`）。
Widget _wrap(Widget child) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SizedBox(
            width: _viewport.width,
            height: _viewport.height,
            child: child,
          ),
        ),
        const ShellInputClip(
          bounds: _workArea,
          child: DeskPanelSurfaceHost(),
        ),
      ],
    ),
  ),
);

Future<void> _pumpView(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(_viewport);
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

/// 当前会话 provider 的容器（与 `KosDeskCenterView` 内 `_providerContainer` 同一
/// 对象）。面板 surface 与容器 surface 共享它。
ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(KosDeskCenterView)),
  listen: false,
);

/// 当前注册到 native 输入路由的 `keyboardPolicy: capture` 交互面。
List<ShellInteractionSurface> _capturingSurfaces(WidgetTester tester) =>
    _container(tester)
        .read(shellInteractionRegistryProvider)
        .surfaces
        .values
        .where((s) => s.keyboardPolicy == ShellKeyboardPolicy.capture)
        .toList();

/// 面板标题栏文本（限 DeskPanelShell 子树——部件库条目/hover 提示可能
/// 复用同名 label）。
Finder _panelTitle(String text) => find.descendant(
  of: find.byType(DeskPanelShell),
  matching: find.text(text),
);

/// 构造 `ShellSurfaceEnvironment`（只覆盖本用例关心的字段）。
ShellSurfaceEnvironment _env({
  bool isMainOutput = true,
  bool locked = false,
  bool wallpaperSelectorVisible = false,
  Rect workArea = _workArea,
}) => ShellSurfaceEnvironment(
  output: const DisplayOutput(
    monitorId: 0,
    name: 'test-output',
    logicalRect: _workArea,
    pixelSize: Size(800, 1200),
    scale: 1,
    refreshRate: 60,
  ),
  workArea: workArea,
  isMainOutput: isMainOutput,
  workspaceId: 1,
  fullscreen: false,
  overview: false,
  desktopVisible: true,
  wallpaperSelectorVisible: wallpaperSelectorVisible,
  locked: locked,
  settings: const ShellSettings(),
  defaultOutputSelected: true,
);

void main() {
  group('KosDeskCenterPanelSurface', () {
    test('id 与 layer 契约', () {
      const surface = KosDeskCenterPanelSurface();
      expect(surface.id, 'kos_deskcenter.panel');
      expect(surface.layer, ShellSurfaceLayer.desktopControls);
    });

    test('place：主输出 → 铺满 workArea，不占桌面，可见', () {
      const area = Rect.fromLTWH(40, 30, 1000, 700);
      final placement = const KosDeskCenterPanelSurface().place(
        _env(workArea: area),
      );
      expect(placement, isNotNull);
      expect(placement!.bounds, area);
      expect(placement.occupiesDesktop, isFalse);
      expect(placement.visible, isTrue);
    });

    test('place：非主输出 → null', () {
      expect(
        const KosDeskCenterPanelSurface().place(_env(isMainOutput: false)),
        isNull,
      );
    });

    test('place：锁屏 / 壁纸选择器 → visible:false', () {
      expect(
        const KosDeskCenterPanelSurface().place(_env(locked: true))!.visible,
        isFalse,
      );
      expect(
        const KosDeskCenterPanelSurface()
            .place(_env(wallpaperSelectorVisible: true))!
            .visible,
        isFalse,
      );
    });

    test('place：空 workArea → null', () {
      expect(
        const KosDeskCenterPanelSurface().place(_env(workArea: Rect.zero)),
        isNull,
      );
    });
  });

  group('DeskPanelShell', () {
    testWidgets('标题栏 + 关闭钮 + 面板材质渲染', (tester) async {
      var closed = false;
      // 直接泵进 host 下：面板容器本身的渲染检查（材质/标题/关闭钮）。
      await tester.pumpWidget(
        _wrap(
          DeskPanelShell(
            title: '天气',
            onClose: () => closed = true,
            child: const Text('placeholder'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('天气'), findsOneWidget);
      expect(find.text('×'), findsOneWidget);
      expect(find.byKey(const ValueKey('desk-panel-close')), findsOneWidget);
      expect(find.text('placeholder'), findsOneWidget);
      // 关闭钮触发 onClose（等价会话 close()）。
      await tester.tap(find.byKey(const ValueKey('desk-panel-close')));
      expect(closed, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('卡片点击 → 面板 surface', () {
    testWidgets('weather 卡 tap 写入会话并渲染面板（argv `--location` 透传占位体）', (
      tester,
    ) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsNothing);
      expect(_container(tester).read(deskPanelSessionProvider), isNull);

      await tester.tap(find.byType(KosWeatherCard));
      await tester.pump();

      // 会话已写入（新机制：非 ShellPopupHost popup 列表）。
      final session = _container(tester).read(deskPanelSessionProvider);
      expect(session, isNotNull);
      expect(session!.request.appId, 'kos-weather');
      // 面板出现在场景中（由 DeskPanelSurfaceHost 渲染）。
      expect(find.byType(DeskPanelShell), findsOneWidget);
      expect(_panelTitle('天气'), findsOneWidget);
      expect(find.textContaining('待 TASK-'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('clock 卡 tap 弹面板（无参，容器层 tap 回调）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      expect(_panelTitle('时钟'), findsOneWidget);
      expect(
        _container(tester).read(deskPanelSessionProvider)!.request.appId,
        'kos-clock',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('同卡重复打开覆盖同一会话，不堆叠', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      // 再次以同 appId 打开（等价重复点击路径）：仍只有一个面板。
      _container(tester)
          .read(deskPanelSessionProvider.notifier)
          .open(
            const DeskPanelRequest(appId: 'kos-clock'),
            const DeskPanelData(),
          );
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('打开时注册 capture 交互面（bounds 覆盖工作区），关闭后移除', (
      tester,
    ) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      // 休息态无 capture 面。
      expect(_capturingSurfaces(tester), isEmpty);

      await tester.tap(find.byType(KosClockCard));
      await tester.pump(); // 会话写入 + active 置位
      await tester.pump(); // post-frame 完成注册
      final registered = _capturingSurfaces(tester);
      expect(registered, hasLength(1));
      expect(registered.single.bounds, _workArea);

      await tester.tap(find.byKey(const ValueKey('desk-panel-close')));
      await tester.pump(); // active 置否
      await tester.pump(); // post-frame 完成移除
      expect(_capturingSurfaces(tester), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('关闭钮 close() 移除面板', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desk-panel-close')));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsNothing);
      expect(_container(tester).read(deskPanelSessionProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('点遮罩（面板外）关闭', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      // 左上角落在遮罩上（面板居中，远端不被卡片覆盖）。
      await tester.tapAt(const Offset(12, 12));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('点面板卡片内部（非关闭钮）不关闭', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      // 标题栏文本落在卡片内：遮罩在卡片之下，命中被卡片吸收 → 不关闭。
      await tester.tap(_panelTitle('时钟'));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      expect(_container(tester).read(deskPanelSessionProvider), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Esc 关闭面板（面板获焦时）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(find.byType(KosClockCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsOneWidget);
      // 等焦点 post-frame 移入面板。
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('编辑态整卡 tap 不弹面板（TASK-12 §约束）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      // 空白长按进编辑态（:315-318）。
      await tester.longPressAt(const Offset(780, 1150));
      expect(
        tester
            .state<KosDeskCenterViewState>(find.byType(KosDeskCenterView))
            .editMode,
        isTrue,
      );
      await tester.tap(find.byType(KosWeatherCard));
      await tester.pump();
      expect(find.byType(DeskPanelShell), findsNothing);
      expect(_container(tester).read(deskPanelSessionProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
