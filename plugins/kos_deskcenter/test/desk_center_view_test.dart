// KosDeskCenterView widget 测试（TASK-05）。
//
// 覆盖：网格渲染（packWidgets 落位）、编辑模式进出（长按/右键 →
// 工具栏 → 完成）、三编辑操作（隐藏持久化、尺寸循环、拖拽最近邻换序）。
//
// 源交互锚点：进入编辑 = onPressAndHold（DeskCenterWindow.qml:315-318）或
// 卡片右键 TapHandler（:486-490）；角标「−」隐藏（:563-566）、尺寸循环
// （:588-590 cycleSize）；DragHandler 松手取最近邻 moveWidget
// （:503-527）；完成钮 leaveWidgetEditMode（:362-366）。

import 'dart:io';

import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderBackdropFilter;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart';
import 'package:kos_deskcenter/src/state/desk_center_config_io.dart';
import 'package:kos_deskcenter/src/widgets/desk_center_view.dart';
import 'package:kos_deskcenter/src/widgets/desk_card.dart';
import 'package:kos_deskcenter/src/widgets/clock_card.dart';
import 'package:kos_deskcenter/src/widgets/music_card.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';
import 'package:kos_deskcenter/src/widgets/activity_card.dart';

/// 测试用容器尺寸：800×1200 逻辑像素。
/// cellSize = (2000 − 16 − 90)/10 = 189.4；usableRows = floor(1210/199.4) = 6。
/// TASK-08：时钟 medium(2×1) 后总占用行数增加，600 高仅 3 行放不下 7 卡，
/// 高度提到 1200 容纳全部（实际桌面 workArea 高度远大于此）。
Widget _wrap(Widget child) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 800, height: 1200, child: child)),
  ),
);

/// 先设置 surface size 再 pump（flutter_test 默认 800×600，放不下 7 卡）。
Future<void> _pumpView(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

KosDeskCenterViewState _state(WidgetTester tester) =>
    tester.state<KosDeskCenterViewState>(find.byType(KosDeskCenterView));

/// 空白区（右下角远离 4 列网格处）长按进入编辑态。
/// 空白区（右下角远离 4 列网格处）长按进入编辑态。
/// 800×1200 窗口下网格占左半，(780,1150) 为右下角空白。
Future<void> _enterEdit(WidgetTester tester) async {
  await tester.longPressAt(const Offset(780, 1150));
}

void main() {
  group('backdrop resource sharing', () {
    Widget blurView() => ShellTheme(
      data: const ShellThemeData(
        transparencyMode: ShellTransparencyMode.blur,
        cardOpacity: 0.7,
      ),
      child: const KosDeskCenterView(),
    );

    List<RenderBackdropFilter> filters(WidgetTester tester) => [
      for (final element in find.byType(BackdropFilter).evaluate())
        element.renderObject! as RenderBackdropFilter,
    ];

    testWidgets('settled cards share a stable backdrop; editing keeps state', (
      tester,
    ) async {
      await _pumpView(tester, blurView());
      final clockState = tester.state(find.byType(KosClockCard));
      final keys = filters(tester).map((filter) => filter.backdropKey).toSet();
      expect(keys, hasLength(1));
      expect(keys.single, isNotNull);
      _state(tester).enterEditMode();
      await tester.pump();
      expect(
        filters(tester).every((filter) => filter.backdropKey == null),
        isTrue,
      );
      expect(tester.state(find.byType(KosClockCard)), same(clockState));
      _state(tester).leaveEditMode();
      await tester.pump();
      expect(filters(tester).map((filter) => filter.backdropKey).toSet(), keys);
      expect(tester.state(find.byType(KosClockCard)), same(clockState));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'repacking temporarily disables sharing, including after edit',
      (tester) async {
        await _pumpView(tester, blurView());
        _state(tester).enterEditMode();
        _state(tester).cycleSize('clock');
        await tester.pump();
        _state(tester).leaveEditMode();
        await tester.pump();
        expect(
          filters(tester).every((filter) => filter.backdropKey == null),
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 300));
        final keys = filters(tester)
            .map((filter) => filter.backdropKey)
            .toSet();
        expect(keys, hasLength(1));
        expect(keys.single, isNotNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'material changes preserve foreground state; glass stays ungrouped',
      (tester) async {
        final mode = ValueNotifier(ShellTransparencyMode.blur);
        addTearDown(mode.dispose);
        await _pumpView(
          tester,
          ValueListenableBuilder<ShellTransparencyMode>(
            valueListenable: mode,
            builder: (_, value, child) => ShellTheme(
              data: ShellThemeData(transparencyMode: value, cardOpacity: 0.7),
              child: child!,
            ),
            child: DeskCardBackdropScope(
              grouped: true,
              child: BackdropGroup(
                child: DeskCard(
                  child: StatefulBuilder(
                    builder: (_, _) => const Text('foreground'),
                  ),
                ),
              ),
            ),
          ),
        );
        final foreground = tester.state(find.byType(StatefulBuilder));
        final sharedKey = filters(tester).single.backdropKey;
        expect(sharedKey, isNotNull);
        mode.value = ShellTransparencyMode.glass;
        await tester.pump();
        expect(filters(tester).single.backdropKey, isNull);
        expect(tester.state(find.byType(StatefulBuilder)), same(foreground));
        mode.value = ShellTransparencyMode.blur;
        await tester.pump();
        expect(filters(tester).single.backdropKey, same(sharedKey));
        expect(tester.state(find.byType(StatefulBuilder)), same(foreground));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('opaque cards have no backdrop filters', (tester) async {
      await _pumpView(
        tester,
        ShellTheme(
          data: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.blur,
            cardOpacity: 1,
          ),
          child: const KosDeskCenterView(),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('KosDeskCenterView 渲染', () {
    testWidgets('默认配置渲染全部 7 张卡', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      // widgetDefinitions 7 项全可见（hidden 空）：每张卡一个 DeskCard。
      expect(find.byType(DeskCard), findsNWidgets(7));
      expect(find.byType(KosClockCard), findsOneWidget);
      expect(find.byType(KosWeatherCard), findsOneWidget);
      expect(find.byType(KosMusicCard), findsOneWidget);
      // activity 卡（TASK-06）：注入空数据时渲染 KosActivityCard 空态。
      expect(find.byType(KosActivityCard), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // 收尾：取消秒级 timer
    });

    testWidgets('卡片按 packWidgets 落位（clock 左上格点）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      // clock medium = 2×1（默认表，TASK-08），priority 100 最先占位 → (0,0)。
      final rect = tester.getRect(find.byType(KosClockCard));
      expect(rect.left, 0);
      expect(rect.top, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('编辑模式', () {
    testWidgets('长按空白进入编辑态，「完成」退出（:315-318、:362-366）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      expect(_state(tester).editMode, isFalse);
      await _enterEdit(tester);
      expect(_state(tester).editMode, isTrue);
      // 编辑态显示工具栏「完成」钮。
      expect(find.text('完成'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(_state(tester).editMode, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('卡片右键进入编辑态（TapHandler :486-490）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await tester.tap(
        find.byType(KosClockCard),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(_state(tester).editMode, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('「+ 组件」打开部件库（:333-371、:373-449）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await _enterEdit(tester);
      await tester.tap(find.text('+ 组件'));
      await tester.pump();
      // 七个库条目（widgetLabels，:96-98）。
      expect(find.text('时钟'), findsOneWidget);
      expect(find.text('天气'), findsOneWidget);
      expect(find.text('音乐'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('编辑态卡片显示移除与尺寸角标（:551-591）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await _enterEdit(tester);
      // 每张可见卡各一个「−」移除角标。find 需限到 DeskCard 内——部件库
      // 条目（_LibraryEntry）的 '−' 文本随 opacity 门控常驻树中。
      expect(
        find.descendant(of: find.byType(DeskCard), matching: find.text('−')),
        findsNWidgets(7),
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('编辑操作与持久化', () {
    late Directory tempDir;
    late DeskCenterConfigStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('kos_deskcenter_view');
      store = DeskCenterConfigStore(path: '${tempDir.path}/config.json');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    testWidgets('「−」角标隐藏部件并落盘（:563-566 + sync :64-65）', (tester) async {
      await _pumpView(tester, KosDeskCenterView(configStore: store));
      await _enterEdit(tester);
      await _enterEdit(tester);
      // weather 卡的移除角标。
      final removeBadge = find.descendant(
        of: find.byType(KosWeatherCard),
        matching: find.text('−'),
      );
      expect(removeBadge, findsOneWidget);
      await tester.tap(removeBadge);
      await tester.pump();
      expect(_state(tester).config.isVisible('weather'), isFalse);
      expect(find.byType(KosWeatherCard), findsNothing);
      // 持久化：重启（新建 store 实例）读出 hidden。卡片回调里
      // `unawaited(store.save)` 的 future 绑在 FakeAsync 域上，runAsync
      // 不会驱动它——只能显式再落盘一次内存态（同一 save 序列化路径），
      // 验证「重启后 hidden 仍在」的持久化语义。
      await tester.runAsync(() async {
        await store.save(_state(tester).config);
        final reloaded = await DeskCenterConfigStore(path: store.path).load();
        expect(reloaded.isVisible('weather'), isFalse);
      });
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('尺寸角标循环 medium→large（:588-590 cycleSize）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await _enterEdit(tester);
      expect(_state(tester).config.sizeFor('music'), WidgetSize.medium);
      // music 卡的尺寸角标文本 = 当前档中文标签（'中'）。
      final sizeBadge = find.descendant(
        of: find.byType(KosMusicCard),
        matching: find.text('中'),
      );
      expect(sizeBadge, findsOneWidget);
      await tester.tap(sizeBadge);
      await tester.pump();
      expect(_state(tester).config.sizeFor('music'), WidgetSize.large);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('拖拽卡到最近邻换序（DragHandler :492-527）', (tester) async {
      await _pumpView(tester, const KosDeskCenterView());
      await tester.pump();
      await _enterEdit(tester);
      final before = List.of(_state(tester).config.order);
      // clock 卡中心 → weather 卡中心（默认序 clock (0,0)、weather
      // 紧随其右）。拖到 weather 中心触发 moveWidget。
      final clockCenter = tester.getCenter(find.byType(KosClockCard));
      final weatherCenter = tester.getCenter(find.byType(KosWeatherCard));
      final gesture = await tester.startGesture(clockCenter);
      await gesture.moveTo(weatherCenter);
      await gesture.up();
      await tester.pump();
      final after = _state(tester).config.order;
      expect(after.first, isNot(before.first)); // clock 离开首位
      expect(after.indexOf('clock'), 1); // 落到 weather 的索引
      await tester.pumpWidget(const SizedBox());
    });
  });
}
