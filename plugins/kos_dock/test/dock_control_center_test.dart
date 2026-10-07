// TASK-09：控制中心格 + 弹层面板测试。
//
// 覆盖：控制中心格恒显示与 toggle、面板入场动画进度、wifi/bt pill 开关调用
// （provider）、媒体卡 prev/play/next 调用、亮度/音量滑条 commit 调用
// （`displayBrightnessProvider.commitLevel` / `audioService.apply`）、子页
// crossfade 导航、五个快捷按钮恢复、勿扰切换和会话确认。
//
// 依赖注入（CONSTRAINTS §10）：
// - `networkServiceProvider`/`bluetoothServiceProvider` → 假后端（同 TASK-08）；
// - `denialBridgeProvider` → 假 `DenialBridge`（音频/亮度流与写入全在内存，
//   不触真实平台通道）；
// - `displayLayoutProvider` → 假 controller（避免真 bridge 的 display 布局
//   重试 Timer 留在 FakeAsync 里）。
import 'dart:async';
import 'dart:convert';

import 'package:denial_flutter_sdk/platform.dart'
    show DenialBridge, DenialBrightnessState;
import 'package:denial_flutter_sdk/service_backends.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/theme/dock_tokens.dart';
import 'package:kos_dock/src/widgets/dock_backdrop_blur.dart';
import 'package:kos_dock/src/widgets/dock_control_center_panel.dart';
import 'package:kos_dock/src/widgets/dock_status_panels.dart';
import 'package:kos_dock/src/widgets/dock_wifi_panel.dart';
import 'package:kos_dock/src/widgets/status_cells.dart';
import 'package:kos_dock/src/widgets/tray_accessory.dart';

class _FakeSessionPower extends SessionPowerController {
  @override
  SessionPowerState build() => SessionPowerState.initial();
}

// ── fakes ──────────────────────────────────────────────────────────────

/// 假网络后端：快照可变、`requestScan/setWirelessEnabled` 记调用。
class _FakeNetworkBackend implements NetworkBackend {
  _FakeNetworkBackend({NetworkSnapshot? snapshot})
    : _snapshot = snapshot ?? const NetworkSnapshot.unavailable();
  NetworkSnapshot _snapshot;
  final _snapshots = StreamController<NetworkSnapshot>.broadcast();

  void emit(NetworkSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  int requestScanCalls = 0;
  final wireless = <bool>[];

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkSnapshot get currentSnapshot => _snapshot;

  @override
  Future<void> start() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setWirelessEnabled(bool enabled) async => wireless.add(enabled);

  @override
  Future<void> requestScan() async => requestScanCalls++;

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(WifiNetwork network) async {}

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

/// 假蓝牙后端：`setPowered`/`refresh` 记调用；快照可在会话内翻转
/// （能力位翻转用例，TASK-08 审查 N1）。
class _FakeBluetoothBackend implements BluetoothBackend {
  _FakeBluetoothBackend({BluetoothSnapshot? snapshot})
    : _snapshot = snapshot ?? const BluetoothSnapshot.unavailable();

  BluetoothSnapshot _snapshot;
  final _snapshots = StreamController<BluetoothSnapshot>.broadcast();

  int setPoweredCalls = 0;
  int refreshCalls = 0;

  /// 会话内翻转蓝牙快照（能力位出现/消失）。
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

  /// 非 null → `refresh()` 挂起不返回（`refreshing` 保持 true，N2 用例）。
  Completer<void>? refreshGate;

  @override
  BluetoothPairingRequest? get currentPairingRequest => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> refresh() async {
    refreshCalls++;
    // 非 null → 挂起不返回（`refreshing` 保持 true，N2 用例）。
    final gate = refreshGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> setPowered(bool powered) async => setPoweredCalls++;

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
  Future<void> dispose() async {
    await _snapshots.close();
  }
}

/// 假 `DenialBridge`：音频/亮度流与写入全部走内存（测试断言用）。
class _FakeBridge extends DenialBridge {
  _FakeBridge() : super();

  final _audioStateStream = StreamController<AudioLevelState>.broadcast();
  final _appStreamStream = StreamController<List<AppAudioStream>>.broadcast();
  final _deviceStream = StreamController<List<AudioOutputDevice>>.broadcast();
  final _brightnessStream = StreamController<DenialBrightnessState>.broadcast();

  double? level = 0.42;
  int appStreamRequests = 0;
  int deviceRequests = 0;

  /// `apply(percent)` 收到的音量百分比。
  final appliedVolumes = <int>[];

  /// `setBrightness(level:)` 收到的倍率（0.01-1.0）。
  final appliedBrightness = <double>[];

  final appliedAppLevels = <({int id, int percent})>[];
  final selectedDevices = <String>[];

  @override
  Stream<AudioLevelState> get audioStates => _audioStateStream.stream;

  @override
  Stream<List<AppAudioStream>> get audioStreamStates => _appStreamStream.stream;

  @override
  Stream<List<AudioOutputDevice>> get audioDeviceStates => _deviceStream.stream;

  @override
  Stream<DenialBrightnessState> get brightnessStates =>
      _brightnessStream.stream;

  @override
  Future<double?> readAudioLevel() async => level;

  @override
  void setAudioLevel(int percent, {required int requestSerial}) =>
      appliedVolumes.add(percent);

  @override
  void requestAudioStreams() => appStreamRequests++;

  @override
  void requestAudioDevices() => deviceRequests++;

  @override
  void setAudioStreamLevel(int streamId, int percent) =>
      appliedAppLevels.add((id: streamId, percent: percent));

  @override
  void setAudioDevice(String name) => selectedDevices.add(name);

  /// 模拟服务端推送：应用流 / 音量回显（`requestSerial` 由调用方给）。
  void emitAppStreams(List<AppAudioStream> streams) =>
      _appStreamStream.add(streams);

  void emitAudioLevel(AudioLevelState state) => _audioStateStream.add(state);
  void emitOutputDevices(List<AudioOutputDevice> devices) =>
      _deviceStream.add(devices);

  @override
  Future<double?> readBrightnessLevel({
    required int monitorId,
    required String connector,
  }) async => 0.72;

  @override
  bool setBrightness({
    required int monitorId,
    required String connector,
    required double level,
  }) {
    appliedBrightness.add(level);
    return true;
  }
}

/// 假 display layout provider：直接返回给定布局（不起真 bridge 重试 Timer）。
class _FakeDisplayLayout extends DisplayLayoutController {
  _FakeDisplayLayout(this.layout);

  final DisplayLayout layout;

  @override
  DisplayLayout? build() => layout;
}

/// 假媒体控制：`calls` 记录 previous/playPause/next。
/// 假媒体控制：`calls` 记录 previous/playPause/next。
class _FakeMediaCommands implements MediaCommands {
  _FakeMediaCommands(this.state);

  final MprisPlaybackState state;
  final calls = <String>[];

  @override
  MprisPlaybackState get current => state;

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> playPause() async => calls.add('playPause');

  @override
  Future<void> next() async => calls.add('next');
}

/// 最小 ShellServices（托盘挂件所需 + 媒体卡所需 media/mediaCommands）。
class _FakeShellServices implements ShellServices {
  _FakeShellServices({MprisPlaybackState? media})
    : mediaState = media ?? MprisPlaybackState.unavailable(),
      commands = _FakeMediaCommands(media ?? MprisPlaybackState.unavailable());

  final MprisPlaybackState mediaState;
  final _FakeMediaCommands commands;

  /// `imageBytes(path)` 收到的 path（专辑图 `file:` 剥前缀断言用）。
  final imageBytesPaths = <String>[];

  /// 注入封面字节（null → 保持占位路径）。
  Uint8List? artworkBytes;
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
  }) => const SizedBox.shrink();

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
  ProviderListenable<List<GpuLoad>> get gpus => Provider((_) => const []);
  @override
  ProviderListenable<AsyncValue<DateTime>> get clock =>
      Provider((_) => AsyncData(DateTime(2026, 1, 1)));
  @override
  ProviderListenable<AsyncValue<MprisPlaybackState>> get media =>
      Provider((_) => AsyncData(mediaState));
  @override
  ProviderListenable<MediaCommands> get mediaCommands =>
      Provider((_) => commands);
  @override
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path) {
    imageBytesPaths.add(path);
    return Provider((_) => AsyncData(artworkBytes));
  }

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;
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

NetworkSnapshot networkSnapshot({
  bool wifiDeviceAvailable = true,
  bool wirelessEnabled = true,
}) => NetworkSnapshot(
  serviceAvailable: true,
  wifiDeviceAvailable: wifiDeviceAvailable,
  wirelessHardwareEnabled: true,
  wirelessEnabled: wirelessEnabled,
  status: NetworkConnectivityStatus.online,
  networks: const [],
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

MprisPlaybackState playingMedia({String artUrl = ''}) => MprisPlaybackState(
  serviceName: 'org.mpris.MediaPlayer2.test',
  identity: 'Test',
  title: '曲目',
  artists: const ['艺术家'],
  album: '专辑',
  artUrl: artUrl,
  length: const Duration(minutes: 3),
  position: Duration.zero,
  observedAt: DateTime(2026, 1, 1),
  status: MprisPlaybackStatus.playing,
  canGoNext: true,
  canGoPrevious: true,
  canPlay: true,
  canPause: true,
);

DisplayLayout layoutWithOutput() => DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: const Size(1920, 1080),
  pixelSize: const Size(1920, 1080),
  engineScale: 1,
  tickerMonitorId: 1,
  systemBarMonitorId: 1,
  systemBarMonitorIds: const [1],
  systemBarSide: PanelEdge.top,
  outputs: const [
    DisplayOutput(
      monitorId: 1,
      name: 'eDP-1',
      logicalRect: Rect.fromLTWH(0, 0, 1920, 1080),
      pixelSize: Size(1920, 1080),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);

/// 挂 `DockTrayAccessory`（含控制中心格 + 面板 anchor），底对齐 800×700。
///
/// 面板高 460（`kDockControlCenterBoxHeight`）→ 需要约 470px 的条带上方空间；
/// 故测试面底对齐（否则 anchor 的屏内 clamp 会把面板裁成窄条，卡不可点）。
Widget _wrapTray({
  required _FakeShellServices services,
  required _FakeNetworkBackend network,
  required _FakeBluetoothBackend bluetooth,
  required _FakeBridge bridge,
}) => ProviderScope(
  overrides: [
    notificationPolicyStoreProvider.overrideWithValue(null),
    sessionPowerProvider.overrideWith(_FakeSessionPower.new),
    networkServiceProvider.overrideWithValue(network),
    bluetoothServiceProvider.overrideWithValue(bluetooth),
    denialBridgeProvider.overrideWithValue(bridge),
    displayLayoutProvider.overrideWith(
      () => _FakeDisplayLayout(layoutWithOutput()),
    ),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: SizedBox.fromSize(
        size: const Size(800, 700),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: DockTrayAccessory(services: services),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _pillDisc(String pillKey) => find.descendant(
  of: find.byKey(ValueKey<String>(pillKey)),
  matching: find.byKey(const ValueKey<String>('cc.pill.disc')),
);

Finder _pillPage(String pillKey) => find.descendant(
  of: find.byKey(ValueKey<String>(pillKey)),
  matching: find.byKey(const ValueKey<String>('cc.pill.page')),
);

/// 面板入场 reveal 进度（anchor 施加的最内层 `Opacity`）。
double _reveal(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.byType(DockControlCenterPanel),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

/// 页 crossfade 进度由各表面独立消费，不再把玻璃放进整页 Opacity。
double _revealOf(WidgetTester tester, String key) => tester
    .widget<DockStatusPanelFade>(
      find
          .ancestor(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(DockStatusPanelFade),
          )
          .first,
    )
    .opacity;

/// 打开控制中心面板（点格 → 等入场播完）。
Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byType(DockControlCenterCell));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(DockControlCenterPanel), findsOneWidget);
}

/// 主页面卡片数（KOS 主页面 v1 可见卡：2 pill + 媒体 + 亮度条 + 音量条）。
int _mainCardCount(WidgetTester tester) => tester
    .widgetList<DockStatusPanelSurface>(find.byType(DockStatusPanelSurface))
    .length;

void main() {
  testWidgets('控制中心格恒显示（无 wifi/bt 能力也渲染）', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(
          snapshot: networkSnapshot(wifiDeviceAvailable: false),
        ),
        bluetooth: _FakeBluetoothBackend(
          snapshot: bluetoothSnapshot(available: false),
        ),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    // 控制中心格无能力门控（面板是 Flutter 侧自绘）：wifi/bt 格都不挂载时
    // 它仍在。
    expect(find.byType(DockWifiCell), findsNothing);
    expect(find.byType(DockControlCenterCell), findsOneWidget);
    // 点击 → 面板弹出（KOS `panelToggleRequested`）。
    await _openPanel(tester);
  });

  testWidgets('点击格 → 面板开；再点格 → 面板收（toggle）', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    expect(find.byType(DockControlCenterPanel), findsNothing);
    await _openPanel(tester);
    // 再点格（在面板外 → 走 anchor 屏障关闭；KOS 由 BarStatusArea toggle）。
    await tester.tap(find.byType(DockControlCenterCell), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockControlCenterPanel), findsNothing);
  });

  testWidgets('面板入场动画：reveal 0→1（150ms OutCubic）', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await tester.tap(find.byType(DockControlCenterCell));
    await tester.pump();
    // KOS: common/AnimatedPopupWindow.qml:16-18 — opacity = revealProgress
    // （开 150ms OutCubic，AppearanceTokens.qml:514-516）。
    expect(_reveal(tester), 0);
    await tester.pump(const Duration(milliseconds: 30));
    expect(_reveal(tester), greaterThan(0));
    expect(_reveal(tester), lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_reveal(tester), 1);
  });

  testWidgets('wifi pill 圆盘点 → setWirelessEnabled(!enabled)', (tester) async {
    final bridge = _FakeBridge();
    final network = _FakeNetworkBackend(snapshot: networkSnapshot());
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: network,
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // KOS: ControlCenterPanel.qml:615-616 — `setWifiEnabled(!wifiEnabled)`。
    await tester.tap(_pillDisc('cc.wifiPill'));
    await tester.pump();
    expect(network.wireless, [false]);
  });

  testWidgets('蓝牙 pill 圆盘点 → togglePower', (tester) async {
    final bridge = _FakeBridge();
    final bluetooth = _FakeBluetoothBackend(snapshot: bluetoothSnapshot());
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: bluetooth,
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // KOS: :795 附近 — 点盘 `setBluetoothEnabled()`。
    await tester.tap(_pillDisc('cc.btPill'));
    await tester.pump();
    expect(bluetooth.setPoweredCalls, 1);
  });

  testWidgets('媒体卡：prev/play-pause/next → mediaCommands', (tester) async {
    final bridge = _FakeBridge();
    final services = _FakeShellServices(media: playingMedia());
    await tester.pumpWidget(
      _wrapTray(
        services: services,
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    expect(find.byKey(const ValueKey<String>('cc.mediaCard')), findsOneWidget);
    // KOS: :883-905 — prev / play-pause / next → DockMprisService。
    await tester.tap(find.byKey(const ValueKey<String>('cc.media.previous')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('cc.media.toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('cc.media.next')));
    await tester.pump();
    expect(services.commands.calls, ['previous', 'playPause', 'next']);
  });

  testWidgets('音量滑条 commit → audioService.apply(percent)', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // KOS: :1282-1285 — `commitRequested → setVolume(round(v*100))`；
    // 滑条中点 = 50%。
    await tester.tap(find.byKey(const ValueKey<String>('cc.volumeSlider')));
    await tester.pump();
    expect(bridge.appliedVolumes, [50]);
  });

  testWidgets('亮度滑条 commit → displayBrightness.commitLevel', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // KOS: :1186-1189 — `commitRequested → setBrightness(round(v*100))`；
    // 滑条中点 = 0.5 → `BrightnessService.apply` 折算 level 0.5。
    await tester.tap(find.byKey(const ValueKey<String>('cc.brightnessSlider')));
    await tester.pump();
    expect(bridge.appliedBrightness, [0.5]);
  });

  testWidgets('子页导航：pill 页区 → wifi 子页（crossfade）→ 返回主页面', (tester) async {
    final bridge = _FakeBridge();
    final network = _FakeNetworkBackend(snapshot: networkSnapshot());
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: network,
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // KOS: :644-657 — 点圆盘以外区域 `networkRequested → openSubmenu("wifi")`。
    await tester.tap(_pillPage('cc.wifiPill'));
    await tester.pump();
    // crossfade 首帧 progress=0 → 入场页尚未显示（KOS `pageFactor` 同式）。
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const ValueKey<String>('cc.page.wifi')), findsOneWidget);
    // 入场页 opacity = progress < 1（scale 0.96→1，KOS :347-353）。
    expect(_revealOf(tester, 'cc.page.wifi'), lessThan(1));
    expect(_revealOf(tester, 'cc.page.wifi'), greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    // KOS: :96-98 — `openSubmenu("wifi")` → `refreshWifiNetworks()`。
    expect(network.requestScanCalls, 1);
    // 返回钮（KOS: :1933-1938 `closeSubmenu()`）。
    await tester.tap(find.byKey(const ValueKey<String>('cc.page.back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('cc.page.wifi')), findsNothing);
  });

  testWidgets('子页导航：wifi 子页开关球 → setWirelessEnabled', (tester) async {
    final bridge = _FakeBridge();
    final network = _FakeNetworkBackend(snapshot: networkSnapshot());
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: network,
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await tester.tap(_pillPage('cc.wifiPill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // KOS: :1993-1999 — 右侧 38×22 开关球 → `setWifiEnabled(!wifiEnabled)`。
    await tester.tap(find.byKey(const ValueKey<String>('cc.page.toggle')));
    await tester.pump();
    expect(network.wireless, [false]);
  });

  testWidgets('快捷按钮恢复，勿扰切换，夜灯显示不可用提示', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    expect(_mainCardCount(tester), 10);
    for (final id in ['cc.wifiPill', 'cc.btPill']) {
      final surface = tester.widget<DockStatusPanelSurface>(
        find.descendant(
          of: find.byKey(ValueKey<String>(id)),
          matching: find.byType(DockStatusPanelSurface),
        ),
      );
      expect(surface.clipBackdropToRadius, isTrue);
      final backdrop = tester.widget<DockBackdropBlur>(
        find.descendant(
          of: find.byKey(ValueKey<String>(id)),
          matching: find.byType(DockBackdropBlur),
        ),
      );
      expect(backdrop.glassBlendMode, BlendMode.srcOver);
    }
    for (final id in ['screenshot', 'theme', 'power', 'dnd', 'nightlight']) {
      expect(find.byKey(ValueKey<String>('cc.$id')), findsOneWidget);
    }
    final night = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('cc.nightlight')),
    );
    expect(night.onPressed, isNull);
    expect(night.tooltip, contains('SDK 不支持'));
    final context = tester.element(find.byType(DockControlCenterPanel));
    final container = ProviderScope.containerOf(context);
    final before = container.read(desktopNotificationsProvider).doNotDisturb;
    await tester.tap(find.byKey(const ValueKey<String>('cc.dnd')));
    await tester.pump();
    expect(container.read(desktopNotificationsProvider).doNotDisturb, !before);
    expect(find.text('显示亮度'), findsOneWidget);
    expect(find.text('声音'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('cc.power')));
    await _settle(tester);
    expect(find.text('电源与会话'), findsOneWidget);
    final sessionTile = tester.element(
      find.byKey(const ValueKey<String>('cc.session.logout')),
    );
    expect(Material.maybeOf(sessionTile), isNotNull);
    final material = sessionTile.findAncestorWidgetOfExactType<Material>()!;
    expect(material.type, MaterialType.transparency);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey<String>('cc.session.logout')));
    await tester.pump();
    expect(
      container.read(sessionPowerProvider).confirmationAction,
      SessionPowerAction.logout,
    );
    expect(
      find.byKey(const ValueKey<String>('cc.session.confirm')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(sessionPowerProvider).confirmationAction, isNull);
    expect(find.text('电源与会话'), findsOneWidget);
  });

  for (final unmountScope in [false, true]) {
    testWidgets(
      unmountScope ? '会话确认中卸载 ProviderScope 无生命周期异常' : '直接关闭面板清除会话确认',
      (tester) async {
        await tester.pumpWidget(
          _wrapTray(
            services: _FakeShellServices(),
            network: _FakeNetworkBackend(snapshot: networkSnapshot()),
            bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
            bridge: _FakeBridge(),
          ),
        );
        await _settle(tester);
        await _openPanel(tester);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(DockControlCenterPanel)),
        );
        await tester.tap(find.byKey(const ValueKey<String>('cc.power')));
        await _settle(tester);
        await tester.tap(
          find.byKey(const ValueKey<String>('cc.session.logout')),
        );
        await tester.pump();
        expect(
          container.read(sessionPowerProvider).confirmationAction,
          SessionPowerAction.logout,
        );
        if (unmountScope) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.tap(find.byType(DockControlCenterCell));
          await _settle(tester);
          expect(
            container.read(sessionPowerProvider).confirmationAction,
            isNull,
          );
        }
        await tester.pump();
        expect(find.byType(DockControlCenterPanel), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  // ── TASK-09/09 审查缺陷回归（B1/B2/N1/N3/N4/N5/N6）───────────────────

  testWidgets('应用音量 commit → applyAppStream(id, percent)（0..1 ×100，B1）', (
    tester,
  ) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await _openSubPage(tester, 'cc.volumeHot');
    // 服务侧推一条应用流（level 0.3 → 30%）。
    bridge.emitAppStreams(const [
      AppAudioStream(id: 42, name: '浏览器', level: 0.3, muted: false),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('浏览器'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    final slider = find.descendant(
      of: find.byKey(const ValueKey<String>('cc.app.42')),
      matching: find.byType(DockControlCenterSlider),
    );
    await _tapSlider(tester, slider, 0.7);
    // 修复前 `next.round()` 把 0..1 当 percent → applyAppStream(42, 1)。
    expect(bridge.appliedAppLevels, [(id: 42, percent: 70)]);
    expect(find.text('70%'), findsOneWidget);
  });

  testWidgets('声音子页：主音量滑条 commit + 输出设备列表点击', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await _openSubPage(tester, 'cc.volumeHot');
    expect(find.text('主音量'), findsOneWidget);
    expect(find.text('输出设备'), findsOneWidget);
    expect(find.text('应用音量'), findsOneWidget);
    // 主音量滑条 0.7 → `apply(70)`（同音量条口径）。
    await _tapSlider(
      tester,
      find.byKey(const ValueKey<String>('cc.sound.volume')),
      0.7,
    );
    expect(bridge.appliedVolumes, [70]);
    // 输出设备真列表（SDK 增强）：点非 active 行 → `selectOutputDevice`。
    bridge.emitOutputDevices(const [
      AudioOutputDevice(
        name: 'alsa_output.pci',
        description: '内置扬声器',
        active: true,
        available: true,
      ),
      AudioOutputDevice(
        name: 'bluez_sink.hp',
        description: '蓝牙耳机',
        active: false,
        available: true,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('内置扬声器'), findsOneWidget);
    expect(find.text('蓝牙耳机'), findsOneWidget);
    await tester.tap(find.text('蓝牙耳机'));
    await tester.pump();
    expect(bridge.selectedDevices, ['bluez_sink.hp']);
  });

  testWidgets('亮度子页：每显示器行 + 滑条 commit', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await _openSubPage(tester, 'cc.brightnessHot');
    expect(
      find.byKey(const ValueKey<String>('cc.page.brightness')),
      findsOneWidget,
    );
    // 逐显示器行（label = 输出名，KOS :2554）。
    expect(find.text('eDP-1'), findsOneWidget);
    await _tapSlider(tester, find.byType(DockControlCenterSlider), 0.5);
    expect(bridge.appliedBrightness.last, 0.5);
  });

  testWidgets('蓝牙子页：刷新中已配对列表不消失（N2）', (tester) async {
    final bluetooth = _FakeBluetoothBackend(
      snapshot: bluetoothSnapshot(
        available: true,
        devices: [btDevice('Mouse', paired: true)],
      ),
    );
    // 打开面板时 `refresh()` 挂起 → `refreshing` 全程为 true。
    bluetooth.refreshGate = Completer<void>();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: bluetooth,
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await tester.tap(_pillPage('cc.btPill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('设备'), findsOneWidget);
    // KOS BluetoothPanel.qml:151-168 — 刷新指示是叠在列表上的 label，
    // 列表恒渲染；本端空态只在列表为空时出（修复前整列表被换成「正在刷新…」）。
    expect(find.text('Mouse'), findsOneWidget);
    expect(find.text('正在刷新…'), findsNothing);
    bluetooth.refreshGate!.complete();
    await tester.pump();
  });

  testWidgets('蓝牙子页：空列表 + 刷新中 → 头部「正在刷新…」不重复（N2）', (tester) async {
    final bluetooth = _FakeBluetoothBackend(
      snapshot: bluetoothSnapshot(available: true),
    );
    bluetooth.refreshGate = Completer<void>();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: bluetooth,
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await tester.tap(_pillPage('cc.btPill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 刷新态翻转落在上一帧之后 → 再 pump 一帧让头部「正在刷新…」渲染出来。
    await tester.pump();
    expect(find.text('正在刷新…'), findsOneWidget);
    expect(find.text('未发现已配对设备'), findsNothing);

    bluetooth.refreshGate!.complete();
    await tester.pump();
  });

  testWidgets('音量回显抑制：自身 serial 不回灌、其它 serial 回灌', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await _tapSlider(
      tester,
      find.byKey(const ValueKey<String>('cc.volumeSlider')),
      0.5,
    );
    expect(bridge.appliedVolumes, [50]);
    expect(find.text('50\u00a0%'), findsOneWidget);
    // 自身回写（serial 命中最近一次 apply）→ 跳过，不被拉回。
    bridge.emitAudioLevel(const AudioLevelState(level: 0.1, requestSerial: 1));
    await tester.pump();
    await tester.pump();
    expect(find.text('50\u00a0%'), findsOneWidget);
    // 外部改动（serial 不同）→ 回灌。
    bridge.emitAudioLevel(const AudioLevelState(level: 0.1, requestSerial: 2));
    await tester.pump();
    await tester.pump();
    expect(find.text('10\u00a0%'), findsOneWidget);
  });

  testWidgets('声音子页周期刷新：1.8s 重发应用流 + 服务值回灌（N4）', (tester) async {
    final bridge = _FakeBridge();
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await _openSubPage(tester, 'cc.volumeHot');
    bridge.emitAppStreams(const [
      AppAudioStream(id: 7, name: '播放器', level: 0.2, muted: false),
    ]);
    await tester.pump();
    await tester.pump();
    // KOS `audioApplicationsTimer` 1.8s（ControlCenterService:437-440）。
    final before = bridge.appStreamRequests;
    await tester.pump(kDockControlCenterAppRefreshInterval);
    expect(bridge.appStreamRequests, greaterThan(before));
    // 拖到 0.7 提交 → 本地预览 70%。
    final slider = find.descendant(
      of: find.byKey(const ValueKey<String>('cc.app.7')),
      matching: find.byType(DockControlCenterSlider),
    );
    await _tapSlider(tester, slider, 0.7);
    expect(find.text('70%'), findsOneWidget);
    // 服务侧回灌新真值 → 本地预览不永久遮蔽（KOS 1.8s 重建 delegate 同效）。
    bridge.emitAppStreams(const [
      AppAudioStream(id: 7, name: '播放器', level: 0.9, muted: false),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('90%'), findsOneWidget);
    // 3s 档：输出设备请求重发。
    final beforeDevices = bridge.deviceRequests;
    await tester.pump(kDockControlCenterRefreshInterval);
    expect(bridge.deviceRequests, greaterThan(beforeDevices));
  });

  testWidgets('能力位翻转（wifi 上线）不销毁已开面板（N1 固定 key）', (tester) async {
    final bluetooth = _FakeBluetoothBackend(
      snapshot: bluetoothSnapshot(available: false),
    );
    final network = _FakeNetworkBackend(
      snapshot: networkSnapshot(wifiDeviceAvailable: false),
    );
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: network,
        bluetooth: bluetooth,
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // wifi 能力位上线（false→true）：Row 内格数变化；无 key 时按下标复用
    // Element 会把控制中心 anchor 卸掉 → 已开面板被销毁。
    network.emit(networkSnapshot(wifiDeviceAvailable: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockWifiCell), findsOneWidget);
    expect(find.byType(DockControlCenterPanel), findsOneWidget);
  });

  testWidgets('pill busy 档：glyph 隐藏 + 21px 旋转弧（N5）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShellTheme(
          data: const ShellThemeData(),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: kDockControlCenterPillWidth,
                height: kDockControlCenterPillHeight,
                child: DockControlCenterPill(
                  title: 'Wi-Fi',
                  subtitle: '未连接',
                  checked: true,
                  available: true,
                  busy: true,
                  cursor: SystemMouseCursors.click,
                  buildDiscGlyph: (context, checked) => const SizedBox.square(
                    key: ValueKey<String>('test.discGlyph'),
                    dimension: kDockControlCenterPillGlyphSize,
                  ),
                  onToggle: () {},
                  onOpenPage: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // KOS :570-617 — busy 时 glyph opacity 0 + 21px 弧（900ms/圈）。
    expect(
      find.byKey(const ValueKey<String>('cc.pill.spinner')),
      findsOneWidget,
    );
    final glyphFade = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('test.discGlyph')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(glyphFade.opacity, 0);
    expect(
      tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey<String>('cc.pill.spinner')),
      ),
      isA<AnimatedOpacity>(),
    );
    await tester.pump(kDockControlCenterBusySpinDuration);
  });

  testWidgets('Esc 分步：子页 → 主页面 → 关面板（N6）', (tester) async {
    final network = _FakeNetworkBackend(snapshot: networkSnapshot());
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: network,
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    await tester.tap(_pillPage('cc.wifiPill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('cc.page.wifi')), findsOneWidget);
    // KOS ControlCenterPanel.qml:512-524 — 第一级 Esc 退回主页面。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockControlCenterPanel), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cc.page.wifi')), findsNothing);
    // 第二级 Esc（已在主页面）→ 关整面板。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockControlCenterPanel), findsNothing);
  });

  testWidgets('协调器互斥：控制中心开着点 wifi 格 → 先关控制中心再开 wifi 面板', (tester) async {
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // Overlay 单树模型：fullScene 屏障先吃掉这次点击（偏差已记 deltas）。
    await tester.tap(find.byType(DockWifiCell), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockControlCenterPanel), findsNothing);
    expect(find.byType(DockWifiPanel), findsNothing);
    await tester.tap(find.byType(DockWifiCell));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DockWifiPanel), findsOneWidget);
  });

  testWidgets('入场动画中途 dispose：无异常、无挂起 Timer', (tester) async {
    await tester.pumpWidget(
      _wrapTray(
        services: _FakeShellServices(),
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byType(DockControlCenterCell));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('专辑图：`file://` 剥成路径喂 imageBytes；http(s) 走占位（B2）', (tester) async {
    final bridge = _FakeBridge();
    final services = _FakeShellServices(
      media: playingMedia(artUrl: 'file:///tmp/cover.png'),
    );
    services.artworkBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
    );
    await tester.pumpWidget(
      _wrapTray(
        services: services,
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: bridge,
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // SDK 只保证 artUrl 是 URI（mpris_playback_protocol.dart:200-207），
    // 而 imageBytes 是裸路径加载器 → 必须剥 `file:`（修复前恒 null → 占位）。
    // 每次 build 都重新取 provider → 断言去重后的 path 集合。
    expect(services.imageBytesPaths.toSet(), {'/tmp/cover.png'});
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('♫'), findsNothing);
  });

  testWidgets('专辑图：http(s) 不喂 imageBytes、渲染「♫」占位（B2）', (tester) async {
    final services = _FakeShellServices(
      media: playingMedia(artUrl: 'https://cdn.example/cover.png'),
    );
    await tester.pumpWidget(
      _wrapTray(
        services: services,
        network: _FakeNetworkBackend(snapshot: networkSnapshot()),
        bluetooth: _FakeBluetoothBackend(snapshot: bluetoothSnapshot()),
        bridge: _FakeBridge(),
      ),
    );
    await _settle(tester);
    await _openPanel(tester);
    // 本端不抓网络图（记 deltas）→ 不走 `imageBytes`（否则恒 null）。
    expect(services.imageBytesPaths, isEmpty);
    expect(find.text('♫'), findsOneWidget);
  });
}

/// 打开音量/亮度条顶部的子页热区（KOS :1166-1172 / :1228-1234）。
Future<void> _openSubPage(WidgetTester tester, String hotKey) async {
  await tester.tap(find.byKey(ValueKey<String>(hotKey)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 把滑条拖到 `fraction`（0..1）：中点计算与 `_preview` 同式
/// （`value = (dx − thumb/2) / (width − thumb)`），tap 触发 preview + commit。
Future<void> _tapSlider(
  WidgetTester tester,
  Finder slider,
  double fraction,
) async {
  final rect = tester.getRect(slider);
  final span = rect.width - kDockControlCenterThumbWidth;
  await tester.tapAt(
    Offset(
      rect.left + kDockControlCenterThumbWidth / 2 + span * fraction,
      rect.center.dy,
    ),
  );
  await tester.pump();
}
