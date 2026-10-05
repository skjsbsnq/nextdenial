// TASK-06：托盘区（DockTrayAccessory + DockBatteryCell）测试。
//
// 假 ShellServices / TrashService / DockPreferencesStore / DockWeatherProvider
// 全内存实现（CONSTRAINTS §10：无真实 socket/dbus/dart:io 依赖）；
// trayItemIds/battery/trayVisible 用可变 NotifierProvider 供维稳/折行/空态
// 用例在会话内翻转。挂 `KosDockShell` 的用例必须 override
// `dockWeatherProviderProvider`（默认四卡 order 会订阅天气快照流，默认实现
// 会 start() 真实 HttpClient + 状态文件 + 周期 Timer）。
//
// 覆盖：维稳排序（新 id 追加尾部 / 消失 id 移除 / 宿主重排不搬动）；折行
// 判定纯函数（twoRowThreshold=itemSize*2=52、itemCount>1）；wrap 调用参数
// （含 battery 计入 itemCount 驱动折行）与列宽约束；battery 格 unknown→
// 隐藏、有值→渲染 + 点击 openPowerSettings + 充电⚡ + 26px 槽命中区；
// 空托盘区 0 宽 shrink；空态时 tray 槽与 divider3 整段不渲染（hasTray =
// trayEstimateWidth > 0）；`fillColor` 语义色分档。

import 'dart:async';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/service_backends.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show bluetoothServiceProvider, networkServiceProvider;
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/kos_dock.dart' show KosDockPlugin;
import 'package:kos_dock/src/state/dock_settings.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_shell.dart';
import 'package:kos_dock/src/widgets/status_cells.dart';
import 'package:kos_dock/src/widgets/tray_accessory.dart';

// ── fakes ──────────────────────────────────────────────────────────────

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

class _FakeTrashService implements TrashService {
  @override
  Future<bool> hasItems() async => false;

  @override
  Future<int> count() async => 0;

  @override
  Future<void> open() async {}

  @override
  Future<void> empty() async {}

  @override
  Stream<TrashState> watch() => const Stream<TrashState>.empty();
}

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
  String batteryLine(String state, int capacity) => '$state $capacity';
  @override
  String numberValue(int value) => '$value';
  @override
  String workspaceLabel(int workspace) => '$workspace';
  @override
  String get batteryTitle => 'Battery';
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

/// 可变托盘状态：维稳排序用例在会话内翻转 id 列表。
class _TrayIdsNotifier extends Notifier<List<String>> {
  _TrayIdsNotifier(this.initial);
  final List<String> initial;
  @override
  List<String> build() => initial;
}

/// 可变电池状态：battery unknown→有数据 / 充电切换用例。
class _BatteryNotifier extends Notifier<BatteryStatus> {
  _BatteryNotifier(this.initial);
  final BatteryStatus initial;
  @override
  BatteryStatus build() => initial;
}

class _FakeShellServices implements ShellServices {
  _FakeShellServices({
    List<String> trayIds = const [],
    BatteryStatus batteryStatus = BatteryStatus.unknown,
  }) {
    // provider 实例必须缓存（getter 每次新建 provider 会把同一 notifier
    // 实例关联多个 provider → riverpod 抛 "already associated"）；notifier
    // 在闭包里新建并回存句柄，供 setTrayIds/setBattery 会话内翻转状态。
    _trayIdsProvider = NotifierProvider<_TrayIdsNotifier, List<String>>(() {
      return _trayIdsNotifier = _TrayIdsNotifier(trayIds);
    });
    _batteryProvider = NotifierProvider<_BatteryNotifier, BatteryStatus>(() {
      return _batteryNotifier = _BatteryNotifier(batteryStatus);
    });
  }

  late final NotifierProvider<_TrayIdsNotifier, List<String>> _trayIdsProvider;
  late final NotifierProvider<_BatteryNotifier, BatteryStatus> _batteryProvider;
  late _TrayIdsNotifier _trayIdsNotifier;
  late _BatteryNotifier _batteryNotifier;

  /// 会话内翻转托盘 id 列表 / 电池快照（须 provider 已实例化后调用）。
  void setTrayIds(List<String> ids) => _trayIdsNotifier.state = ids;
  void setBattery(BatteryStatus status) => _batteryNotifier.state = status;

  int powerSettingsCalls = 0;

  /// buildSystemTray 调用记录（wrap 标记 / itemIds 快照）。
  final trayCalls =
      <
        ({
          bool horizontal,
          bool wrap,
          Color? foregroundColor,
          List<String>? itemIds,
        })
      >[];

  /// 自绘托盘代理：每 id 一个 `item-<id>` 键的 22×22 方格（host 端
  /// `_SystemTrayButton` 同尺寸），单行时按钮间 4px spacing。
  Widget _buildTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  }) {
    trayCalls.add((
      horizontal: horizontal,
      wrap: wrap,
      foregroundColor: foregroundColor,
      itemIds: itemIds,
    ));
    final buttons = <Widget>[
      for (var i = 0; i < (itemIds ?? const <String>[]).length; i++) ...[
        if (i > 0 && !wrap) const SizedBox(width: 4),
        SizedBox.square(key: ValueKey('tray.${itemIds![i]}'), dimension: 22),
      ],
    ];
    return wrap
        ? Wrap(spacing: 8, runSpacing: 8, children: buttons)
        : Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  @override
  Widget buildSystemTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  }) => _buildTray(
    context,
    horizontal: horizontal,
    wrap: wrap,
    foregroundColor: foregroundColor,
    itemIds: itemIds,
  );

  @override
  ProviderListenable<bool> get trayVisible => Provider((_) => false);
  @override
  ProviderListenable<List<String>> get trayItemIds => _trayIdsProvider;

  @override
  ProviderListenable<BatteryStatus> get battery => _batteryProvider;

  @override
  void openPowerSettings() => powerSettingsCalls++;

  @override
  ProviderListenable<Color> get accent =>
      Provider((_) => const Color(0xFF4488FF));

  @override
  ProviderListenable<List<LaunchableApplication>> get applications =>
      Provider((_) => const <LaunchableApplication>[]);

  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) =>
      Provider((_) => const <ApplicationWindow>[]);

  @override
  void activateWindow(int id) {}

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async => true;

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      const SizedBox.shrink();

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) =>
      const SizedBox.shrink();

  @override
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) => () {};

  @override
  void toggleDesktop() {}

  @override
  ProviderListenable<bool> get desktopVisible => Provider((_) => false);

  @override
  void toggleLauncher() {}

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
  ProviderListenable<LoadSeries> get cpu => Provider((_) => LoadSeries.empty);

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
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path) =>
      Provider((_) => const AsyncData(null));

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  ShellStrings strings(BuildContext context) => _FakeShellStrings();
}

// ── helpers ────────────────────────────────────────────────────────────

/// TASK-08：`DockTrayAccessory`/`KosDockShell` 会 watch
/// `networkConnectivityProvider`/`bluetoothProvider`（wifi/bt 格能力门控）→
/// 必须注入假后端，否则默认 service provider 起真实 dbus 探测。
class _StubNetworkBackend implements NetworkBackend {
  @override
  Stream<NetworkSnapshot> get snapshots => const Stream.empty();
  @override
  NetworkSnapshot get currentSnapshot => const NetworkSnapshot.unavailable();
  @override
  Future<void> start() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> setWirelessEnabled(bool enabled) async {}
  @override
  Future<void> requestScan() async {}
  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> forget(WifiNetwork network) async {}
  @override
  Future<void> dispose() async {}
}

class _StubBluetoothBackend implements BluetoothBackend {
  @override
  Stream<BluetoothSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<BluetoothPairingRequest?> get pairingRequests => const Stream.empty();
  @override
  BluetoothSnapshot get currentSnapshot =>
      const BluetoothSnapshot.unavailable();
  @override
  BluetoothPairingRequest? get currentPairingRequest => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> setPowered(bool powered) async {}
  @override
  Future<void> startDiscovery() async {}
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> pair(BluetoothDeviceInfo device) async {}
  @override
  Future<void> setTrusted(BluetoothDeviceInfo device, bool trusted) async {}
  @override
  Future<void> connect(BluetoothDeviceInfo device) async {}
  @override
  Future<void> disconnect(BluetoothDeviceInfo device) async {}
  @override
  Future<void> remove(BluetoothDeviceInfo device) async {}
  @override
  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  }) {}
  @override
  Future<void> dispose() async {}
}

/// 本文件所有 ProviderScope 的公共 override 集。
List<Override> _netBtOverrides() => [
  networkServiceProvider.overrideWithValue(_StubNetworkBackend()),
  bluetoothServiceProvider.overrideWithValue(_StubBluetoothBackend()),
];

Widget _wrapTray(
  _FakeShellServices services, {
  Size size = const Size(800, 200),
}) => ProviderScope(
  overrides: _netBtOverrides(),
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox.fromSize(
          size: size,
          child: Center(child: DockTrayAccessory(services: services)),
        ),
      ),
    ),
  ),
);

/// 挂 `KosDockShell`：trayAccessory = 真 DockTrayAccessory（需要 provider
/// overrides，否则默认 store/天气会起真实 IO）。
Widget _wrapShell(
  _FakeShellServices services,
  _MemoryDockPreferencesStore store,
) => ProviderScope(
  overrides: [
    dockPreferencesStoreProvider.overrideWithValue(store),
    trashServiceProvider.overrideWithValue(_FakeTrashService()),
    dockWeatherProviderProvider.overrideWithValue(_FakeWeatherProvider()),
    ..._netBtOverrides(),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 800,
          height: KosDockPlugin.thickness,
          child: KosDockShell(
            services: services,
            monitorId: 0,
            trayAccessory: (_) => DockTrayAccessory(services: services),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('维稳排序（denial_taskbar tray.dart _orderedIds 范式）', () {
    testWidgets('新 id 追加尾部、消失 id 移除、宿主重排不搬动既有顺序', (tester) async {
      final services = _FakeShellServices(trayIds: ['a', 'b']);
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);

      expect(services.trayCalls.last.itemIds, ['a', 'b']);
      // 宿主把顺序倒过来 + 新增 c：维稳后应 [a, b, c]（重排不发生）。
      services.setTrayIds(['b', 'c', 'a']);
      await tester.pump();
      expect(services.trayCalls.last.itemIds, ['a', 'b', 'c']);

      // a 消失 → [b, c]。
      services.setTrayIds(['c', 'b']);
      await tester.pump();
      expect(services.trayCalls.last.itemIds, ['b', 'c']);

      // a 回归 → 追加尾部 [b, c, a]。
      services.setTrayIds(['c', 'a', 'b']);
      await tester.pump();
      expect(services.trayCalls.last.itemIds, ['b', 'c', 'a']);
    });
  });

  group('折行判定（KOS bar/SysTray.qml:74-77）', () {
    test('itemCount>1 且 availableHeight≥52 → 两行', () {
      expect(dockTrayTwoRows(itemCount: 2, availableHeight: 52), isTrue);
      expect(dockTrayTwoRows(itemCount: 5, availableHeight: 59), isTrue);
      // 阈值边界：51.9 < 52 → 单行；itemCount==1 → 单行。
      expect(dockTrayTwoRows(itemCount: 2, availableHeight: 51.9), isFalse);
      expect(dockTrayTwoRows(itemCount: 1, availableHeight: 100), isFalse);
      expect(dockTrayTwoRows(itemCount: 0, availableHeight: 100), isFalse);
    });

    test('估算宽：单行 n*26+(n-1)*6；两行 ceil(n/2) 列', () {
      expect(dockTrayEstimateWidth(itemCount: 0, twoRows: false), 0);
      expect(dockTrayEstimateWidth(itemCount: 1, twoRows: false), 26);
      expect(
        dockTrayEstimateWidth(itemCount: 3, twoRows: false),
        3 * 26 + 2 * 6,
      );
      // 两行 3 项 → 2 列：2*26 + 6 = 58；4 项 → 2 列同宽。
      expect(dockTrayEstimateWidth(itemCount: 3, twoRows: true), 58);
      expect(dockTrayEstimateWidth(itemCount: 4, twoRows: true), 58);
    });
    testWidgets('dockHeight≥52（默认 59）+ itemCount>1 → wrap:true', (
      tester,
    ) async {
      final services = _FakeShellServices(trayIds: ['a', 'b']);
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(services.trayCalls.last.wrap, isTrue);
      expect(services.trayCalls.last.horizontal, isTrue);
      // foregroundColor 须透传 shellTheme textPrimary（fake 记录参数；
      // fake 按钮 key 与宿主真实 key 不同属测试内部一致）。
      expect(
        services.trayCalls.last.foregroundColor,
        const ShellThemeData().colors.textPrimary,
      );

      // Wrap 总宽受 ceil(n/2) 列约束：2 托盘项（无 battery）→ 1 列 → 26。
      final wrap = tester.widget<Wrap>(find.byType(Wrap));
      expect(wrap.spacing, 8); // 宿主实现固定 8（≠KOS 6，记 deltas）。
      final wrapSize = tester.getSize(find.byType(Wrap));
      expect(wrapSize.width, lessThanOrEqualTo(kDockTrayItemSize + 8));
    });

    // battery 计入 itemCount 驱动折行：1 托盘项 + battery = 2 → wrap:true
    // （漏计 battery 时 itemCount=1 → 单行，此用例会挂）。
    testWidgets('1 托盘项 + battery → itemCount=2 → wrap:true', (tester) async {
      final services = _FakeShellServices(
        trayIds: ['a'],
        batteryStatus: const BatteryStatus(capacity: 88, charging: false),
      );
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(services.trayCalls.last.wrap, isTrue);
    });

    test('纯函数：单项不折行（itemCount=1 → twoRows false）', () {
      // KOS `twoRows: dockHosted && itemCount > 1 && availableHeight >=
      // twoRowThreshold`（bar/SysTray.qml:74-77）——单项本身不折行。
      expect(dockTrayTwoRows(itemCount: 1, availableHeight: 59), isFalse);
      expect(dockTrayTwoRows(itemCount: 2, availableHeight: 59), isTrue);
    });

    testWidgets('1 托盘项 + 控制中心格 → itemCount 2 → wrap:true', (tester) async {
      // TASK-09：控制中心格恒显示并计入 itemCount（KOS `allKeys` 同式）——
      // 「1 托盘项」不再是「单项」。
      final services = _FakeShellServices(trayIds: ['a']);
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(services.trayCalls.last.wrap, isTrue);
    });
  });

  group('battery 格（KOS bar/Battery.qml）', () {
    testWidgets('capacity null（unknown）→ 不挂载格', (tester) async {
      final services = _FakeShellServices(
        trayIds: ['a'],
        batteryStatus: BatteryStatus.unknown,
      );
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(find.byType(DockBatteryCell), findsNothing);
    });

    testWidgets('有电量 → 渲染格 + 点击调 openPowerSettings', (tester) async {
      final services = _FakeShellServices(
        trayIds: ['a'],
        batteryStatus: const BatteryStatus(capacity: 65, charging: false),
      );
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);

      expect(find.byType(DockBatteryCell), findsOneWidget);
      expect(find.text('⚡'), findsNothing);
      await tester.tap(find.byType(DockBatteryCell));
      expect(services.powerSettingsCalls, 1);
    });

    testWidgets('充电中 → 居中「⚡」', (tester) async {
      final services = _FakeShellServices(
        batteryStatus: const BatteryStatus(capacity: 40, charging: true),
      );
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(find.text('⚡'), findsOneWidget);
    });

    test('fillColor 语义色分档（KOS Battery.qml:111-118 的 §3 映射）', () {
      final colors = const ShellThemeData().colors;
      const accent = Color(0xFF4488FF);
      Color pick(int p) => dockBatteryFillColor(colors, p, accent: accent);
      expect(pick(96), accent); // >95 → accent（无 success 语义，记 deltas）
      expect(pick(95), colors.textPrimary);
      expect(pick(50), colors.textPrimary);
      expect(pick(15), colors.performanceWarning);
      expect(pick(14), colors.performanceBad);
    });
  });

  group('空态与 KosDockShell 集成', () {
    testWidgets('无托盘项且无 battery → 只剩控制中心格（26+6 宽）', (tester) async {
      // TASK-09：控制中心格恒显示 → 托盘区非空态，宽度 = 控制中心格槽 +
      // 格间 iconSpacing；宿主仍零调用（无托盘 id）。
      final services = _FakeShellServices();
      await tester.pumpWidget(_wrapTray(services));
      await _settle(tester);
      expect(
        tester.getSize(find.byType(DockTrayAccessory)).width,
        kDockTrayIconSpacing + kDockTrayItemSize,
      );
      expect(services.trayCalls, isEmpty); // 零项不打扰宿主
    });

    testWidgets('空托盘仍有控制中心格 → tray 槽与 divider3 渲染', (tester) async {
      // TASK-09：控制中心格恒显示 → hasTray（估算宽>0）为真，tray 槽与
      // divider3 都渲染（KOS `trailingAccessoryDividerVisible` 同语义，
      // DockContainer.qml:951）；宿主仍零调用。
      final services = _FakeShellServices();
      await tester.pumpWidget(
        _wrapShell(
          services,
          _MemoryDockPreferencesStore(const DockPreferences()),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('dock.tray')), findsOneWidget);
      expect(find.byKey(const ValueKey('dock.divider.tray')), findsOneWidget);
      expect(find.byType(DockControlCenterCell), findsOneWidget);
      expect(services.trayCalls, isEmpty);
    });

    testWidgets('托盘项出现时 tray 槽按估算宽回流 dockWidth', (tester) async {
      final services = _FakeShellServices(trayIds: ['a', 'b', 'c']);
      await tester.pumpWidget(
        _wrapShell(
          services,
          _MemoryDockPreferencesStore(const DockPreferences()),
        ),
      );
      await _settle(tester);
      // 3 托盘项（无 battery）：dockHeight≥52 → 两行 → 估算宽 =
      // dockTrayEstimateWidth(3, twoRows:true) = 2*26+6 = 58。
      // 槽宽 = max(iconSlotSize, 58)——回流进 dockWidth，内容不再外延。
      final traySlot = tester.getSize(find.byKey(const ValueKey('dock.tray')));
      expect(traySlot.width, greaterThanOrEqualTo(58));
      expect(find.byKey(const ValueKey('dock.divider.tray')), findsOneWidget);
      expect(services.trayCalls.last.itemIds, ['a', 'b', 'c']);
    });

    testWidgets('托盘项 + battery 在 pill 行尾渲染且不撑爆', (tester) async {
      final services = _FakeShellServices(
        trayIds: ['a', 'b', 'c'],
        batteryStatus: const BatteryStatus(capacity: 88, charging: false),
      );
      await tester.pumpWidget(
        _wrapShell(
          services,
          _MemoryDockPreferencesStore(const DockPreferences()),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('tray.a')), findsOneWidget);
      expect(find.byKey(const ValueKey('tray.c')), findsOneWidget);
      expect(find.byType(DockBatteryCell), findsOneWidget);
      expect(services.trayCalls.last.itemIds, ['a', 'b', 'c']);
      // 4 个格（3 托盘 + 1 battery）→ 两行 wrap。
      expect(services.trayCalls.last.wrap, isTrue);
    });
  });
}
