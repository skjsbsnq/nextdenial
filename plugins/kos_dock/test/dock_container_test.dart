// KosDockShell / DockDivider 容器布局测试（TASK-02）。
//
// 假 ShellServices 全接口内存实现（ProviderListenable 用
// `Provider((_)=>value)`），无真实 wayland/dbus/socket 依赖；
// dockPreferencesStoreProvider 注入内存假 store、trashServiceProvider 注入
// 假垃圾桶、dockWeatherProviderProvider 注入假天气（TASK-05 起
// `KosDockShell` 在默认四卡 order 下会订阅天气快照流）——与
// dock_icon_row_test.dart 同一 fake 范式，零真实 IO（CONSTRAINTS §10）。
//
// 覆盖：DockDivider 线宽/线高/hairline 色/胶囊半径；KosDockShell 槽位
// 左→右顺序与 divider 计数（方案 B：divider1(launchers|windows) 在图标区
// 内部、divider2(windows|info)/divider3(info|tray) 在外层 Row）；无
// infoCard/trayAccessory 时无外置 divider；divider2 按 KOS :912 规则
// （infoCard 且 pinned+running 非空，launcher/trash 不计入）；pinned
// 数量改变 pill 宽；transparencyMode off→blur 切换 ShellBackdropBlur.blur
//（含 glass）。

import 'dart:typed_data';

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/glass_configuration.dart'
    show ShellTransparencyMode;
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/kos_dock.dart' show KosDockPlugin;
import 'package:kos_dock/src/state/dock_settings.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_divider.dart';
import 'package:kos_dock/src/widgets/dock_icon.dart';
import 'package:kos_dock/src/widgets/dock_icons.dart';
import 'package:kos_dock/src/widgets/dock_shell.dart';
import 'package:kos_dock/src/widgets/launcher_icon.dart';
import 'package:kos_dock/src/widgets/trash_icon.dart';

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
    // 只改指定项，保留 pinned/可见性/其它信息卡字段（写回后内部状态同步，
    // 便于断言持久化）。
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

/// 垃圾桶假实现（无真实 IO；TrashIcon watch 需要）——空态。
class _FakeTrashService implements TrashService {
  int openCalls = 0;
  int emptyCalls = 0;

  @override
  Future<bool> hasItems() async => false;

  @override
  Future<int> count() async => 0;

  @override
  Future<void> open() async => openCalls++;

  @override
  Future<void> empty() async => emptyCalls++;

  @override
  Stream<TrashState> watch() => Stream.value(TrashState.empty);
}

/// 天气假实现：TASK-05 起 `KosDockShell` 在 `infoCardOrder` 含 weather（默认
/// 四卡）时会订阅 `dockWeatherSnapshotProvider`，其默认实现会
/// `start()` 真实 provider（HttpClient + 状态文件 + 周期 Timer）→ 必须注入
/// 假实现（CONSTRAINTS §10：测试无真实 IO）。`snapshots` 恒空 →
/// weatherAvailable false，与真实 provider 首帧（loading、无 ready 快照）等效。
class _FakeWeatherProvider implements DockWeatherProvider {
  @override
  DockWeatherSnapshot? get latest => null;

  @override
  Stream<DockWeatherSnapshot> get snapshots =>
      const Stream<DockWeatherSnapshot>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<DockWeatherSnapshot?> refresh() async => null;

  @override
  void dispose() {}
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
  LaunchableApplication(
    id: 'org.kde.konsole',
    appId: 'konsole',
    name: 'Konsole',
    windowAppIds: ['konsole'],
  ),
  LaunchableApplication(
    id: 'org.kde.falkon',
    appId: 'falkon',
    name: 'Falkon',
    windowAppIds: ['falkon'],
  ),
];

PinnedApplication _pin(LaunchableApplication app) =>
    PinnedApplication(id: app.id, appId: app.appId, name: app.name);

/// tray 占位槽：尺寸读 `DockMetricsScope`（方案 C 反解），与 kos_dock.dart
/// 的 `_MetricsSlot` 同式。测试内 infoCard/trayAccessory 必须经 scope 取
/// 尺寸——编译期槽宽常量已随方案 C 移除，硬编码会与 solver 预留槽宽错位。
class _TraySlot extends StatelessWidget {
  const _TraySlot({required this.slotKey});

  final String slotKey;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    return SizedBox(
      key: Key(slotKey),
      width: metrics.iconSlotSize,
      height: metrics.iconSlotSize,
    );
  }
}

/// info 占位槽：宽 = `metrics.infoSlotWidth`（4×iconSize）。
class _InfoSlot extends StatelessWidget {
  const _InfoSlot({required this.slotKey});

  final String slotKey;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    return SizedBox(
      key: Key(slotKey),
      width: metrics.infoSlotWidth,
      height: metrics.iconSlotSize,
    );
  }
}

Widget _slot(String key) => _TraySlot(slotKey: key);

Widget _wrap(
  _FakeShellServices services,
  _MemoryDockPreferencesStore store, {
  Widget? infoCard,
  Widget? trayAccessory,
  ShellThemeData theme = const ShellThemeData(),
  _FakeTrashService? trashService,
}) => ProviderScope(
  overrides: [
    dockPreferencesStoreProvider.overrideWithValue(store),
    trashServiceProvider.overrideWithValue(trashService ?? _FakeTrashService()),
    // TASK-05：`KosDockShell` 在 `infoCardOrder` 含 weather（默认四卡）时会订阅
    // `dockWeatherSnapshotProvider` → 必须注入假 provider，否则默认实现会
    // `start()` 真实 HttpClient/状态文件/周期 Timer（CONSTRAINTS §10）。
    dockWeatherProviderProvider.overrideWithValue(_FakeWeatherProvider()),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: theme,
      // 模拟 SDK 挂载：surface 高 = place() 条带厚度（tight 800×74）。
      // 注意 MaterialApp home 给的是 800×600 tight 约束，直接放 SizedBox
      // 会被强制撑满；套一层 Align 让子件拿到 loose 约束才真正 74 高。
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 800,
          height: KosDockPlugin.thickness,
          child: KosDockShell(
            services: services,
            monitorId: 0,
            infoCard: infoCard == null ? null : (_) => infoCard,
            trayAccessory: trayAccessory,
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// pill 本体：ShellBackdropBlur 子树里带 BoxDecoration gradient 的
/// DecoratedBox（divider 线也是 DecoratedBox，但它是 color-only）。
Finder _pill() => find.descendant(
  of: find.byType(ShellBackdropBlur),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).gradient != null,
  ),
);

// ── tests ──────────────────────────────────────────────────────────────

void main() {
  group('DockDivider', () {
    testWidgets('槽位 2+2*9，线宽 2、线高 60*0.45=27、hairline 色、胶囊半径',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ShellTheme(
            data: const ShellThemeData(),
            child: const Center(child: DockDivider()),
          ),
        ),
      );
      // 独立宿主 → DockMetricsScope.fallback 基准几何（方案 C）。
      final metrics = DockMetricsScope.fallback;
      final slot = tester.getSize(find.byType(DockDivider));
      expect(slot.width, metrics.dividerSlotWidth);
      expect(slot.height, metrics.dockHeight);

      final line = tester.widget<Container>(
        find.descendant(
          of: find.byType(DockDivider),
          matching: find.byType(Container),
        ),
      );
      expect(line.constraints?.maxWidth, kDockDividerWidth);
      expect(
        line.constraints?.maxHeight,
        closeTo(metrics.dockHeight * kDockDividerHeightRatio, 1e-9),
      );
      final decoration = line.decoration! as BoxDecoration;
      final colors = ShellThemeData().colors;
      expect(decoration.color, colors.hairline);
      expect(
        (decoration.borderRadius! as BorderRadius).topLeft.x,
        kDockDividerCapRadius,
      );
    });
  });

  group('KosDockShell', () {
    testWidgets('槽位顺序 launcher<trash<icons<divider<info<divider<tray（2 外置 divider）',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(
        _wrap(
          services,
          store,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
          trayAccessory: _slot('trayAccessory'),
        ),
      );
      await _settle(tester);

      // 无未 pin 运行条目 → 只有 divider2(windows|info) + divider3
      // (info|tray) 两条外置分割线；divider1(launchers|windows) 在图标区
      // 内部且 pinned+running 都非空才出现（KOS DockContainer.qml:856）。
      expect(find.byType(DockDivider), findsNWidgets(2));
      final order = [
        tester.getCenter(find.byType(LauncherIcon)).dx,
        tester.getCenter(find.byType(TrashIcon)).dx,
        tester.getCenter(find.byType(DockIconRow)).dx,
        tester.getCenter(find.byType(DockDivider).first).dx,
        tester.getCenter(find.byKey(const Key('infoCard'))).dx,
        tester.getCenter(find.byType(DockDivider).last).dx,
        tester.getCenter(find.byKey(const Key('trayAccessory'))).dx,
      ];
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]));
      }
    });

    testWidgets('无 infoCard/trayAccessory → 无 DockDivider', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);
      expect(find.byType(DockDivider), findsNothing);
    });

    testWidgets('pinned 1→4 时 pill 宽变大', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store1 = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store1));
      await _settle(tester);
      final width1 = tester.getSize(_pill()).width;

      final store4 = _MemoryDockPreferencesStore(
        DockPreferences(
          pinned: [_pin(_apps[0]), _pin(_apps[1]), _pin(_apps[2]), _pin(_apps[3])],
        ),
      );
      await tester.pumpWidget(_wrap(services, store4));
      await _settle(tester);
      final width4 = tester.getSize(_pill()).width;

      expect(width4, greaterThan(width1));
      // 方案 C：宽度差 = 两个配置各自反解的 dockWidth 之差（不再假设
      // 编译期 itemExtent——iconSize 可能随条目数变化）。各配置用与
      // KosDockShell 相同的 DockMetrics.fromWidth 输入推导期望宽。
      final m1 = DockMetrics.fromWidth(800, pinnedCount: 1);
      final m4 = DockMetrics.fromWidth(800, pinnedCount: 4);
      expect(width4 - width1, closeTo(m4.dockWidth - m1.dockWidth, 1.0));
    });

    testWidgets('divider2(windows|info) = infoCard 且 entryCount>0（launcher/trash 不计入）',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(
          pinned: [_pin(_apps[0])],
          showLauncher: false,
          showTrash: false,
        ),
      );
      await tester.pumpWidget(
        _wrap(
          services,
          store,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      // pinned 1 → entryCount=1 → divider2(windows|info) 插入（KOS
      // DockContainer.qml:912 `hasInfo && pinnedCount+windowCount > 0`）。
      expect(find.byType(DockDivider), findsOneWidget);

      // pinned 清空且无运行窗口 → entryCount=0 → divider2 不插（仅
      // infoCard 一侧有内容；launcher/trash 被隐藏不计入 window 计数）。
      final emptyStore = _MemoryDockPreferencesStore(
        const DockPreferences(showLauncher: false, showTrash: false),
      );
      await tester.pumpWidget(
        _wrap(
          services,
          emptyStore,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockDivider), findsNothing);

      // launcher/trash 可见同样不计入 divider2 的 window 计数（KOS :912
      // 只看 pinnedCount+windowCount）：pinned/运行皆空 → 仍无 divider。
      final launcherOnlyStore = _MemoryDockPreferencesStore(
        const DockPreferences(),
      );
      await tester.pumpWidget(
        _wrap(
          services,
          launcherOnlyStore,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockDivider), findsNothing);
    });

    testWidgets('transparencyMode off → blur false；blur/glass → blur true',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(const DockPreferences());

      await tester.pumpWidget(
        _wrap(
          services,
          store,
          theme: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.off,
          ),
        ),
      );
      await _settle(tester);
      expect(
        tester.widget<ShellBackdropBlur>(find.byType(ShellBackdropBlur)).blur,
        isFalse,
      );

      await tester.pumpWidget(
        _wrap(
          services,
          store,
          theme: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.blur,
          ),
        ),
      );
      await _settle(tester);
      expect(
        tester.widget<ShellBackdropBlur>(find.byType(ShellBackdropBlur)).blur,
        isTrue,
      );

      await tester.pumpWidget(
        _wrap(
          services,
          store,
          theme: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.glass,
          ),
        ),
      );
      await _settle(tester);
      expect(
        tester.widget<ShellBackdropBlur>(find.byType(ShellBackdropBlur)).blur,
        isTrue,
      );
    });

    testWidgets('pill 底边浮空 edgeMargin（不贴屏幕底边）', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);

      // 条带（= place() 的 bounds）贴屏幕底边、高 thickness；pill 高 =
      // 反解 dockHeight，底边内缩 edgeMargin（KOS: dock/DockWindow.qml:63-64
      // 的 edgeMargin，:177 的 `y: root.height - edgeMargin - height`）。
      // 方案 C：期望值取与 KosDockShell 相同的反解（800 宽、1 pinned）。
      final metrics = DockMetrics.fromWidth(800, pinnedCount: 1);
      final surface = tester.getRect(find.byType(KosDockShell));
      final pill = tester.getRect(_pill());
      expect(surface.height, KosDockPlugin.thickness);
      expect(pill.height, closeTo(metrics.dockHeight, 0.01));
      expect(
        surface.bottom - pill.bottom,
        closeTo(metrics.edgeMargin, 0.01),
        reason: 'pill 底边必须在屏幕底边之上 edgeMargin（回归：贴底 = 0）',
      );
      expect(
        surface.bottom - pill.bottom,
        greaterThan(0),
        reason: 'Align.bottomCenter 直接贴底是缺陷（pill 与屏幕边零浮空）',
      );
    });

    // ── 方案 B：KOS 分段 + launchers|windows 分割线（D-3）──
    // 图标区内部段序（DockIconRow 的 rowChildren）：pinned 段
    // ReorderableListView → divider1 → 运行段 Row；divider2/3 在外层
    // Row（KOS DockContainer.qml:847-857 :856, 859-862, 907-913 :912, :951）。

    testWidgets('pins + 运行条目 → 图标区内段序 [pinned][divider1][running]，'
        '外层 [running…][divider2][info][divider3][tray]', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          ApplicationWindow(
            id: 1,
            appId: 'firefox',
            title: 'ff',
            active: false,
            minimized: false,
          ),
        ];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(
        _wrap(
          services,
          store,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
          trayAccessory: _slot('trayAccessory'),
        ),
      );
      await _settle(tester);

      // divider1(图标区内 launchers|windows) + divider2(windows|info) +
      // divider3(info|tray) = 3 条 DockDivider。
      expect(
        find.byType(DockDivider),
        findsNWidgets(3),
        reason: 'pinned+running+info+tray 时应有 3 条分割线'
            '（launchers|windows、windows|info、info|tray）',
      );

      final pinnedBox =
          tester.getRect(find.byKey(const Key('dock.row.pinned')));
      final runningBox =
          tester.getRect(find.byKey(const Key('dock.row.running')));
      final d1 = tester.getCenter(find.byType(DockDivider).at(0));
      final d2 = tester.getCenter(find.byType(DockDivider).at(1));
      final d3 = tester.getCenter(find.byType(DockDivider).at(2));
      // 图标区内部：pinned 段 < divider1 < 运行段。
      expect(pinnedBox.right, lessThanOrEqualTo(d1.dx));
      expect(runningBox.left, greaterThanOrEqualTo(d1.dx));
      // 外层：运行段 < divider2 < info < divider3 < tray。
      expect(d2.dx, greaterThan(runningBox.right - 0.01));
      expect(
        tester.getCenter(find.byKey(const Key('infoCard'))).dx,
        greaterThan(d2.dx),
      );
      expect(
        d3.dx,
        greaterThan(tester.getCenter(find.byKey(const Key('infoCard'))).dx),
      );
      expect(
        tester.getCenter(find.byKey(const Key('trayAccessory'))).dx,
        greaterThan(d3.dx),
      );

      // pinned 段 = ReorderableListView（可重排）；运行段在其外。
      final listBox =
          tester.getRect(find.byType(ReorderableListView));
      expect(listBox.left, closeTo(pinnedBox.left, 0.01));
      expect(listBox.right, closeTo(pinnedBox.right, 0.01));
      // 运行段 DockIcon 不在 ReorderableDragStartListener 内。
      final runningIcon = find.descendant(
        of: find.byKey(const Key('dock.row.running')),
        matching: find.byType(DockIcon),
      );
      expect(runningIcon, findsOneWidget);
      expect(
        find.ancestor(
          of: runningIcon,
          matching: find.byType(ReorderableDragStartListener),
        ),
        findsNothing,
      );
    });

    testWidgets('divider1(launchers|windows) 仅 pinned+running 都非空时出现'
        '（pinned==0 或 running==0 不渲染）', (tester) async {
      // 只有运行条目（无 pin）：divider1 不出现；图标区里只有运行段。
      final runningOnly = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          ApplicationWindow(
            id: 1,
            appId: 'firefox',
            title: 'ff',
            active: false,
            minimized: false,
          ),
        ];
      final emptyStore = _MemoryDockPreferencesStore(const DockPreferences());
      await tester.pumpWidget(
        _wrap(
          runningOnly,
          emptyStore,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      // 仅 divider2(windows|info)：running>0 → hasInfo&&windowCount>0。
      expect(find.byType(DockDivider), findsOneWidget);
      expect(find.byKey(const Key('dock.row.pinned')), findsNothing);
      expect(find.byKey(const Key('dock.row.running')), findsOneWidget);

      // 只有 pinned（无运行窗口）：divider1 不出现；图标区里只有 pinned 段。
      final pinnedOnly = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(
        _wrap(
          pinnedOnly,
          store,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockDivider), findsOneWidget);
      expect(find.byKey(const Key('dock.row.pinned')), findsOneWidget);
      expect(find.byKey(const Key('dock.row.running')), findsNothing);

      // 两段都非空 → divider1 + divider2 = 2 条。
      final both = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          ApplicationWindow(
            id: 1,
            appId: 'firefox',
            title: 'ff',
            active: false,
            minimized: false,
          ),
        ];
      await tester.pumpWidget(
        _wrap(
          both,
          store,
          infoCard: _InfoSlot(slotKey: 'infoCard'),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockDivider), findsNWidgets(2));
      expect(find.byKey(const Key('dock.row.pinned')), findsOneWidget);
      expect(find.byKey(const Key('dock.row.running')), findsOneWidget);
    });

    // TASK-04b 方案 C（KOS iconSize 反解，AdaptiveMath.mjs:129-150）验收：
    // 取代方案 A/B 的「溢出滚动」兜底——反解保证内容宽恒 ≤ maxWidth，
    // 任何条目数下 ReorderableListView 不可滚（NeverScrollable）、无
    // Scrollable 溢出，pins+running 全部可见。800 是窄条带、1707 是宿主
    // 2560/1.5 逻辑宽；两档一起覆盖「反解收缩」与「舒适」两侧。
    for (final stripWidth in [800.0, 1707.0]) {
      for (var running = 1; running <= 4; running++) {
        testWidgets(
            '11 pins + $running 未 pin 运行应用 @${stripWidth.toInt()} → '
            'DockIcon==11+$running 全部可见且 maxScrollExtent==0（方案 C）',
            (tester) async {
          // cap 取 MediaQuery.sizeOf → 必须改测试 view 的逻辑宽，SizedBox
          // 宽度只是布局约束，不改 cap。DPR=1 → physical == logical。
          tester.view.physicalSize = Size(stripWidth, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final pins = List.generate(
            11,
            (i) => PinnedApplication(
              id: 'pin$i',
              appId: 'pin$i',
              name: 'P$i',
            ),
          );
          final services = _FakeShellServices()
            ..apps = [
              for (var i = 0; i < 11; i++)
                LaunchableApplication(
                  id: 'desktop:pin$i',
                  appId: 'pin$i',
                  name: 'P$i',
                  windowAppIds: ['pin$i'],
                ),
            ]
            ..windowsList = [
              for (var i = 0; i < running; i++)
                ApplicationWindow(
                  id: 100 + i,
                  appId: 'run$i',
                  title: 'r$i',
                  active: false,
                  minimized: false,
                ),
            ];
          final store = _MemoryDockPreferencesStore(
            DockPreferences(pinned: pins),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                dockPreferencesStoreProvider.overrideWithValue(store),
                trashServiceProvider.overrideWithValue(_FakeTrashService()),
                // 同上：假 weather provider，无真实 IO。
                dockWeatherProviderProvider.overrideWithValue(
                  _FakeWeatherProvider(),
                ),
              ],
              child: MaterialApp(
                home: ShellTheme(
                  data: const ShellThemeData(),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      width: stripWidth,
                      height: KosDockPlugin.thickness,
                      child: KosDockShell(
                        services: services,
                        monitorId: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await _settle(tester);

          // 全部 DockIcon 都构建且可见（方案 C：不再有运行段 ClipRect 收缩，
          // 不再有任何图标被裁出视口）。
          expect(
            find.byType(DockIcon),
            findsNWidgets(11 + running),
            reason: '方案 C：所有 pinned+running 图标都渲染，无裁剪兜底',
          );
          // 图标行不可滚：ReorderableListView 钉 NeverScrollable →
          // maxScrollExtent 恒 0（方案 A/B 的「条目超宽时段内自滚」已移除）。
          final scrollableState = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(ReorderableListView),
              matching: find.byType(Scrollable),
            ),
          );
          expect(
            scrollableState.position.maxScrollExtent,
            closeTo(0, 0.5),
            reason: '方案 C：iconSize 反解保证内容 ≤ maxWidth，图标行不可滚',
          );
          // pill 宽 ≤ 条带×0.98（maxWidth 上限，AdaptiveMath.mjs:30,148-149）。
          expect(
            tester.getSize(_pill()).width,
            lessThanOrEqualTo(stripWidth * kDockMaxWidthRatio + 0.5),
          );
        });
      }
    }
  });
}
