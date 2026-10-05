// TASK-08：Wi-Fi / 蓝牙状态格 + 玻璃面板测试。
//
// 覆盖：格显隐能力门控（wifiDeviceAvailable / BluetoothState.available）、
// 宽度回流计格（trayItemCount 含状态格 → wrap / 估算宽）、面板 toggle /
// 互斥（DockPopupCoordinator 单例）、`dockWifiSignalLevel` /
// `dockWifiRowSignalRings` / `dockWifiTooltip` / `dockWifiConnecting` 分档纯
// 函数、行点击调 controller。
//
// `networkConnectivityProvider`/`bluetoothProvider` 用 `overrideWith` 注入
// 假 controller（默认实现会经 `networkServiceProvider`/`bluetoothServiceProvider`
// 起真实 dbus 连接，CONSTRAINTS §10）。

import 'dart:async';
import 'dart:typed_data';
import 'package:denial_flutter_sdk/service_backends.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_bluetooth_panel.dart';
import 'package:kos_dock/src/widgets/dock_control_center_panel.dart';
import 'package:kos_dock/src/widgets/dock_status_panels.dart'
    show DockStatusPanelAnchorState;
import 'package:kos_dock/src/widgets/dock_wifi_panel.dart';
import 'package:kos_dock/src/widgets/status_cells.dart';
import 'package:kos_dock/src/widgets/tray_accessory.dart';

// ── fakes ──────────────────────────────────────────────────────────────

/// 假网络后端：`currentSnapshot` 可变、`requestScan/connect` 记调用。
class _FakeNetworkBackend implements NetworkBackend {
  _FakeNetworkBackend({NetworkSnapshot? snapshot})
    : _snapshot = snapshot ?? const NetworkSnapshot.unavailable();

  NetworkSnapshot _snapshot;
  final _snapshots = StreamController<NetworkSnapshot>.broadcast();

  int requestScanCalls = 0;
  int setWirelessCalls = 0;
  bool? lastWirelessEnabled;
  final connectCalls = <({WifiNetwork network, String? password})>[];
  int disconnectCalls = 0;
  int forgetCalls = 0;

  void emit(NetworkSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkSnapshot get currentSnapshot => _snapshot;

  @override
  Future<void> start() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    setWirelessCalls++;
    lastWirelessEnabled = enabled;
  }

  @override
  Future<void> requestScan() async {
    requestScanCalls++;
  }

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    connectCalls.add((network: network, password: password));
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    forgetCalls++;
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

/// 假蓝牙后端：`currentSnapshot` 可变、`refresh/connect/disconnect` 记调用。
class _FakeBluetoothBackend implements BluetoothBackend {
  _FakeBluetoothBackend({BluetoothSnapshot? snapshot})
    : _snapshot = snapshot ?? const BluetoothSnapshot.unavailable();

  BluetoothSnapshot _snapshot;
  final _snapshots = StreamController<BluetoothSnapshot>.broadcast();

  int refreshCalls = 0;
  int setPoweredCalls = 0;
  final connectCalls = <BluetoothDeviceInfo>[];
  final disconnectCalls = <BluetoothDeviceInfo>[];
  final pairCalls = <BluetoothDeviceInfo>[];

  void emit(BluetoothSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  @override
  Stream<BluetoothSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<BluetoothPairingRequest?> get pairingRequests =>
      const Stream<BluetoothPairingRequest?>.empty();

  @override
  BluetoothSnapshot get currentSnapshot => _snapshot;

  @override
  BluetoothPairingRequest? get currentPairingRequest => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> setPowered(bool powered) async {
    setPoweredCalls++;
  }

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> pair(BluetoothDeviceInfo device) async {
    pairCalls.add(device);
  }

  @override
  Future<void> setTrusted(BluetoothDeviceInfo device, bool trusted) async {}

  @override
  Future<void> connect(BluetoothDeviceInfo device) async {
    connectCalls.add(device);
  }

  @override
  Future<void> disconnect(BluetoothDeviceInfo device) async {
    disconnectCalls.add(device);
  }

  @override
  Future<void> remove(BluetoothDeviceInfo device) async {}

  @override
  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  }) {}

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

/// 最小 ShellServices（托盘挂件只需 trayItemIds/battery/accent/linkCursor/
/// strings/buildSystemTray）。
class _FakeShellServices implements ShellServices {
  const _FakeShellServices();

  @override
  ProviderListenable<List<String>> get trayItemIds =>
      Provider((_) => const <String>[]);

  @override
  ProviderListenable<BatteryStatus> get battery =>
      Provider((_) => BatteryStatus.unknown);

  @override
  ProviderListenable<Color> get accent =>
      Provider((_) => const Color(0xFF4488FF));

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  ShellStrings strings(BuildContext context) => _FakeStrings();

  @override
  Widget buildSystemTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final id in itemIds ?? const <String>[])
        SizedBox.square(key: ValueKey('tray.$id'), dimension: 22),
    ],
  );

  // 其余接口本任务用不到 → 最简实现。
  @override
  ProviderListenable<bool> get trayVisible => Provider((_) => false);
  @override
  void openPowerSettings() {}
  @override
  ProviderListenable<List<LaunchableApplication>> get applications =>
      Provider((_) => const []);
  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) =>
      Provider((_) => const []);
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
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) =>
      () {};
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
  ProviderListenable<List<GpuLoad>> get gpus => Provider((_) => const []);
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

class _FakeStrings implements ShellStrings {
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

// ── helpers ────────────────────────────────────────────────────────────

WifiNetwork wifiNetwork(
  String ssid, {
  int strength = 60,
  WifiSecurity security = WifiSecurity.wpaPersonal,
  bool connected = false,
  bool saved = false,
  bool available = true,
}) => WifiNetwork(
  ssid: ssid,
  ssidBytes: ssid.codeUnits,
  security: security,
  strength: strength,
  frequency: 2400,
  devicePath: '/dev/wifi0',
  networkPath: '/net/$ssid',
  savedNetworkPath: saved ? '/saved/$ssid' : null,
  connected: connected,
  available: available,
);

NetworkSnapshot networkSnapshot({
  bool wifiDeviceAvailable = true,
  bool wirelessEnabled = true,
  NetworkConnectivityStatus status = NetworkConnectivityStatus.online,
  List<WifiNetwork> networks = const [],
}) => NetworkSnapshot(
  serviceAvailable: true,
  wifiDeviceAvailable: wifiDeviceAvailable,
  wirelessHardwareEnabled: true,
  wirelessEnabled: wirelessEnabled,
  status: status,
  networks: networks,
  activeNetworkPath: null,
  devicePath: '/dev/wifi0',
  lastScan: 0,
  radioPermission: NetworkPermission.allowed,
  controlPermission: NetworkPermission.allowed,
  modifyPermission: NetworkPermission.allowed,
);

BluetoothSnapshot bluetoothSnapshot({
  bool available = true,
  bool powered = true,
  List<BluetoothDeviceInfo> devices = const [],
}) => BluetoothSnapshot(
  serviceAvailable: true,
  available: available,
  adapterPath: '/hci0',
  adapterName: 'hci0',
  powered: powered,
  discovering: false,
  pairable: true,
  devices: devices,
);

BluetoothDeviceInfo btDevice(
  String name, {
  bool connected = false,
  bool paired = true,
}) => BluetoothDeviceInfo(
  objectPath: '/dev/$name',
  adapterPath: '/hci0',
  address: 'AA:BB:CC:$name',
  name: name,
  icon: 'input-device',
  connected: connected,
  paired: paired,
  trusted: true,
  blocked: false,
  servicesResolved: true,
  signalStrength: -50,
);

/// 挂 `DockTrayAccessory`（含 wifi/bt 状态格）；providers 由参数注入。
Widget _wrapTray({
  required _FakeShellServices services,
  required _FakeNetworkBackend network,
  required _FakeBluetoothBackend bluetooth,
  Size size = const Size(800, 200),
}) => ProviderScope(
  overrides: [
    networkServiceProvider.overrideWithValue(network),
    bluetoothServiceProvider.overrideWithValue(bluetooth),
  ],
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

/// 挂独立 `DockBluetoothPanelAnchor`（蓝牙格已删，面板改由控制中心承载；
/// 本 helper 直接给 anchor 一个可点 child 以验证面板内行点击逻辑）。
Widget _wrapBluetoothAnchor({
  required _FakeShellServices services,
  required _FakeNetworkBackend network,
  required _FakeBluetoothBackend bluetooth,
  Size size = const Size(800, 200),
}) => ProviderScope(
  overrides: [
    networkServiceProvider.overrideWithValue(network),
    bluetoothServiceProvider.overrideWithValue(bluetooth),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox.fromSize(
          size: size,
          child: Center(
            child: DockBluetoothPanelAnchor(
              services: services,
              coordinator: null,
              child: Builder(
                builder: (context) => GestureDetector(
                  key: const ValueKey('bt.anchor.child'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      DockStatusPanelAnchorState.togglePanelOf(context),
                  child: const SizedBox(
                    width: 26,
                    height: 26,
                    child: ColoredBox(color: Color(0x00000000)),
                  ),
                ),
              ),
            ),
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
  group('格显隐（能力门控）', () {
    testWidgets('wifi/bt 能力缺失 → 格不挂载', (tester) async {
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(wifiDeviceAvailable: false),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      // KOS `trailingCells` 无独立蓝牙格（BarStatusArea.qml:28-33）；wifi 能力
      // 缺失不挂格，controlcenter 恒显示（TASK-09 无能力门控）。
      expect(find.byType(DockWifiCell), findsNothing);
      expect(find.byType(DockControlCenterCell), findsOneWidget);
      expect(find.byType(DockTrayAccessory), findsOneWidget);
    });

    testWidgets('wifi 可用 + bt 可用 → 两格挂载（battery 无数据不挡）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(wifiDeviceAvailable: true),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: true),
          ),
        ),
      );
      await _settle(tester);
      // wifi + controlcenter 两格（无独立蓝牙格）；battery 无数据不挂。
      expect(find.byType(DockWifiCell), findsOneWidget);
      expect(find.byType(DockControlCenterCell), findsOneWidget);
      expect(find.byType(DockBatteryCell), findsNothing);
    });
  });

  group('宽度回流计格', () {
    testWidgets('wifi+bt 计入 itemCount → 折行判定与估算宽', (tester) async {
      // 0 托盘项 + wifi + bt = itemCount 2 → dockHeight(默认60)≥52 → wrap。
      // 但托盘段无 id → 不 buildSystemTray；这里只验证格渲染与槽宽非零。
      final services = _FakeShellServices();
      await tester.pumpWidget(
        _wrapTray(
          services: services,
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(wifiDeviceAvailable: true),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: true),
          ),
        ),
      );
      await _settle(tester);
      // wifi + controlcenter 两格计入（无独立蓝牙格）。
      expect(find.byType(DockWifiCell), findsOneWidget);
      expect(find.byType(DockControlCenterCell), findsOneWidget);
      // 内容宽 = 2*(6+26)=64（无托盘段）。
      expect(
        tester.getSize(find.byType(DockTrayAccessory)).width,
        greaterThanOrEqualTo(2 * (kDockTrayIconSpacing + kDockTrayItemSize)),
      );
    });
  });

  group('面板 toggle / 互斥', () {
    testWidgets('点击 wifi 格 → 面板弹出；再点 → 收起', (tester) async {
      final network = _FakeNetworkBackend(
        snapshot: networkSnapshot(wifiDeviceAvailable: true),
      );
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: network,
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      // 打开面板：点击格（经 Builder → togglePanelOf）。
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPanel), findsOneWidget);
      // scan() 打开时触发一次。
      expect(network.requestScanCalls, 1);
      // 再点收起。
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPanel), findsNothing);
    });

    testWidgets('wifi 面板开着时点控制中心格 → wifi 收、控制中心开（互斥）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(wifiDeviceAvailable: true),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: true),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPanel), findsOneWidget);
      // 开控制中心 → 协调器收掉 wifi。注意：Overlay 单树模型下 fullScene
      // 屏障会先吃掉这次点击（KOS popup 是独立 surface、点击穿透到格
      // 无法复刻——偏差记 deltas），点格先关 wifi、再点一次才开控制中心。
      await tester.tap(find.byType(DockControlCenterCell), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPanel), findsNothing);
      expect(find.byType(DockControlCenterPanel), findsNothing);
      await tester.tap(find.byType(DockControlCenterCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockControlCenterPanel), findsOneWidget);
    });
  });

  group('分档纯函数', () {
    test('dockWifiSignalLevel：格图标档 <30/<60/≥60', () {
      int level({bool en = true, bool conn = true, int s = 0}) =>
          dockWifiSignalLevel(enabled: en, connected: conn, strength: s);
      expect(level(en: false), 0);
      expect(level(conn: false), 0);
      expect(level(s: -1), 0);
      expect(level(s: 0), 1);
      expect(level(s: 29), 1);
      expect(level(s: 30), 2);
      expect(level(s: 59), 2);
      expect(level(s: 60), 3);
      expect(level(s: 100), 3);
    });

    test('dockWifiRowSignalRings：行图标档 <25/<50/≥50', () {
      expect(dockWifiRowSignalRings(-1), 0);
      expect(dockWifiRowSignalRings(0), 1);
      expect(dockWifiRowSignalRings(24), 1);
      expect(dockWifiRowSignalRings(25), 2);
      expect(dockWifiRowSignalRings(49), 2);
      expect(dockWifiRowSignalRings(50), 3);
    });

    test('dockWifiTooltip：connected→SSID/已连接互联网；否则 connecting/未连接', () {
      final connected = dockWifiTooltip(
        connected: true,
        connecting: false,
        ssid: 'Home',
      );
      expect(connected.primary, 'Home');
      expect(connected.secondary, '已连接互联网');
      final idle = dockWifiTooltip(
        connected: false,
        connecting: false,
        ssid: null,
      );
      expect(idle.primary, '未连接网络');
      expect(idle.secondary, isNull);
      final joining = dockWifiTooltip(
        connected: false,
        connecting: true,
        ssid: null,
      );
      expect(joining.primary, '正在连接网络…');
    });

    test('dockWifiConnecting：仅 connecting 态', () {
      expect(
        dockWifiConnecting(NetworkConnectivityStatus.connecting),
        isTrue,
      );
      expect(dockWifiConnecting(NetworkConnectivityStatus.online), isFalse);
    });
  });

  group('行点击调用', () {
    testWidgets('wifi 行点击：saved/开放直连 connect', (tester) async {
      final open = wifiNetwork('Cafe', security: WifiSecurity.open);
      final network = _FakeNetworkBackend(
        snapshot: networkSnapshot(
          wifiDeviceAvailable: true,
          networks: [open],
        ),
      );
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: network,
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Cafe'));
      await tester.pump();
      expect(network.connectCalls.single.network.ssid, 'Cafe');
      expect(network.connectCalls.single.password, isNull);
    });

    testWidgets('蓝牙行点击：toggleConnection → connect（未连接已配对）', (
      tester,
    ) async {
      final device = btDevice('Mouse', paired: true, connected: false);
      final bluetooth = _FakeBluetoothBackend(
        snapshot: bluetoothSnapshot(available: true, devices: [device]),
      );
      // 蓝牙托盘格已删（KOS `trailingCells` 无 bluetooth）；面板入口改经
      // `DockBluetoothPanelAnchor` 直接挂占位 child（面板内行点击逻辑与控制中心
      // 蓝牙子页同源 `DockBluetoothDeviceListBody`，仍覆盖）。
      await tester.pumpWidget(
        _wrapBluetoothAnchor(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(wifiDeviceAvailable: false),
          ),
          bluetooth: bluetooth,
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('bt.anchor.child')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(bluetooth.refreshCalls, 1);
      await tester.tap(find.text('Mouse'));
      await tester.pump();
      // toggleConnection 内部链：paired → 跳过 pair → connect。
      expect(bluetooth.pairCalls, isEmpty);
      expect(bluetooth.connectCalls.single.name, 'Mouse');
    });
  });

  group('弹层渲染 / 密码分支（审查补强）', () {
    testWidgets('wifi 格内渲染 DockWifiSignalIcon', (tester) async {
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(
              wifiDeviceAvailable: true,
              networks: [wifiNetwork('Home', connected: true)],
            ),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockWifiSignalIcon), findsOneWidget);
    });

    testWidgets('wifi 格 hover → DockStatusTooltip 渲染（主行 SSID）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: _FakeNetworkBackend(
            snapshot: networkSnapshot(
              wifiDeviceAvailable: true,
              networks: [wifiNetwork('Home', connected: true)],
            ),
          ),
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockStatusTooltip), findsNothing);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(DockWifiCell)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(DockStatusTooltip), findsOneWidget);
      expect(find.text('Home'), findsWidgets);
    });

    testWidgets('加密无档行 → 密码框 → 输入 + 确认 → connect(password)', (
      tester,
    ) async {
      final secured = wifiNetwork('Safe', security: WifiSecurity.wpaPersonal);
      final network = _FakeNetworkBackend(
        snapshot: networkSnapshot(
          wifiDeviceAvailable: true,
          networks: [secured],
        ),
      );
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: network,
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Safe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPasswordDialog), findsOneWidget);
      expect(network.connectCalls, isEmpty);
      // 空密码确认 → 报错、不 connect。
      await tester.tap(find.text('✓'));
      await tester.pump();
      expect(find.text('请输入 Wi-Fi 密码'), findsOneWidget);
      expect(network.connectCalls, isEmpty);
      // 填密码后确认 → connect(password)。
      await tester.enterText(find.byType(EditableText), 'secret');
      await tester.tap(find.text('✓'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(network.connectCalls.single.network.ssid, 'Safe');
      expect(network.connectCalls.single.password, 'secret');
    });

    testWidgets('已连接网络行 → 确认弹层仅关闭、不 connect', (tester) async {
      final network = _FakeNetworkBackend(
        snapshot: networkSnapshot(
          wifiDeviceAvailable: true,
          networks: [wifiNetwork('Home', connected: true)],
        ),
      );
      await tester.pumpWidget(
        _wrapTray(
          services: _FakeShellServices(),
          network: network,
          bluetooth: _FakeBluetoothBackend(
            snapshot: bluetoothSnapshot(available: false),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(DockWifiCell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Home'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPasswordDialog), findsOneWidget);
      // 行内已连接 ✓ 与弹层确认 ✓ 同字 → 限定在弹层内点确认。
      await tester.tap(
        find.descendant(
          of: find.byType(DockWifiPasswordDialog),
          matching: find.text('✓'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockWifiPasswordDialog), findsNothing);
      expect(network.connectCalls, isEmpty);
    });
  });
}
