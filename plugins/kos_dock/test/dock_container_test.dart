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
import 'package:denial_flutter_sdk/service_backends.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show bluetoothServiceProvider, networkServiceProvider;
import 'package:denial_sdk/system.dart';
import 'package:flutter/gestures.dart';
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

/// TASK-08：`trayAccessory` 非空时 `KosDockShell` 会 watch
/// `networkConnectivityProvider`/`bluetoothProvider`（估算托盘宽度要计入
/// wifi/bt 格）→ 必须注入假后端，否则默认 service provider 起真实 dbus 探测
/// （4s pending Timer → `A Timer is still pending`）。
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
  // 恒非空：shell 的 hasTray = trayEstimateWidth>0（托盘项数或 battery 格），
  // 占位槽用例需要 tray 槽在场才有 divider3；给一个常驻托盘项。
  ProviderListenable<List<String>> get trayItemIds =>
      Provider((_) => const <String>['stub']);

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
    // TASK-08：`trayAccessory` 非空 → shell watch 网络/蓝牙 provider，注入假
    // 后端防止真实 dbus 探测留下 pending Timer。
    networkServiceProvider.overrideWithValue(_StubNetworkBackend()),
    bluetoothServiceProvider.overrideWithValue(_StubBluetoothBackend()),
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
            trayAccessory:
                trayAccessory == null ? null : (_) => trayAccessory,
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

    testWidgets('TASK-12 缺陷3：指针放大图标时 pill 宽随当帧 Σspan 对称外扩',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);

      final band = find.byKey(const Key('dock.pinned'));
      final pillRest = tester.getRect(_pill());
      final bandRest = tester.getRect(band);

      // 指针移到首槽中心（带内局部坐标 = 静止槽中心；pill 外扩是居中重排，
      // 带内局部 x 与 Σspan 无关，瞄局部坐标钉住高斯峰）。
      final icon = find.byType(DockIcon).first;
      final localCenter =
          tester.getCenter(icon).dx - bandRest.left;
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      // 反复「等带宽收敛 → 按新带左缘重瞄局部中心」：pill 每扩一次带左缘
      // 左移，全局指针要跟着重钉到同一局部 x（≤4 轮，每轮 220ms 包络）。
      var lastGlobal = double.nan;
      for (var round = 0; round < 4; round++) {
        final globalX = tester.getRect(band).left + localCenter;
        if ((globalX - lastGlobal).abs() < 0.01) break;
        lastGlobal = globalX;
        await gesture.moveTo(Offset(globalX, tester.getCenter(icon).dy));
        // 等带盒宽（=max(静止,Σspan)）收敛：连续 8 帧差 <1e-4。
        var prev = double.nan;
        var stable = 0;
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final w = tester.getSize(band).width;
          if (!prev.isNaN && (w - prev).abs() < 1e-4) {
            stable++;
            if (stable >= 8 && i >= 12) break;
          } else {
            stable = 0;
          }
          prev = w;
        }
      }

      final pillMag = tester.getRect(_pill());
      final bandMag = tester.getRect(band);

      // pill 宽随放大增长（缺陷3 回归：不再恒为静止 dockWidth）。
      expect(
        pillMag.width,
        greaterThan(pillRest.width + 1),
        reason: '图标带放大 → pill 宽跟随当帧 Σspan 外扩',
      );
      // 带层宽 = 当帧 Σspan ≥ 静止宽。
      expect(bandMag.width, greaterThan(bandRest.width + 1));
      // 对称外扩：pill 中心保持在条带中心（800/2=400），左右各扩 Δ/2。
      expect(
        pillMag.center.dx,
        closeTo(400, 0.5),
        reason: 'pill 对称外扩 → 中心不变（Align.bottomCenter 居中重排）',
      );
      // 左缘左移量 ≈ 右缘右移量 = Δ/2（±1px 帧末残差）。
      final dW = pillMag.width - pillRest.width;
      expect(
        pillRest.left - pillMag.left,
        closeTo(dW / 2, 1.0),
        reason: '左缘左移 Δ/2',
      );
      expect(
        pillMag.right - pillRest.right,
        closeTo(dW / 2, 1.0),
        reason: '右缘右移 Δ/2',
      );
      // 放大槽位仍留在 pill 内（不遮 divider/info/tray）：带右缘 ≤ pill 内容
      // 右缘（pill 右缘 − hPadding）。hPadding = round(iconSize*0.4)。
      final metrics = DockMetrics.fromWidth(800, pinnedCount: 2);
      expect(
        bandMag.right,
        lessThanOrEqualTo(pillMag.right - metrics.hPadding + 1.0),
        reason: '图标带右缘不越出 pill 内容区（不遮 divider/info/tray）',
      );

      await gesture.moveTo(const Offset(-4000, 0));
      await tester.pump();
    });

    testWidgets('TASK-12 复审缺陷1：空行后 pill 宽退回静止反解宽（不再停在旧 Σspan）',
        (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final pinnedStore = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, pinnedStore));
      await _settle(tester);
      final pillPinned = tester.getSize(_pill()).width;
      expect(pillPinned, greaterThan(0));

      // 切到「pinned 清空 + launcher/trash 隐藏 + 无运行窗口」→
      // DockIconRow totalCount==0 → AnimatedBuilder 连同 postFrame 上报整棵
      // 卸载。缺陷1 回归：`_iconRowLayoutWidth` 必须被清零（空行分支主动
      // 上报 0），否则 shell `iconRowWidth = max(resting, reported)` 停在旧
      // 大值 → pill 保持放大宽不回退。
      final emptyStore = _MemoryDockPreferencesStore(
        const DockPreferences(showLauncher: false, showTrash: false),
      );
      await tester.pumpWidget(_wrap(services, emptyStore));
      await _settle(tester);

      final pillEmpty = tester.getSize(_pill()).width;
      // restingIconRowWidth=0 时 pill 宽 = 2*hPadding（空行、无 info/tray/
      // divider 的非图标区宽为 0）；用同输入反解的期望宽断言。
      final expected = DockMetrics.fromWidth(
        800,
        pinnedCount: 0,
        runningCount: 0,
        showLauncher: false,
        showTrash: false,
      );
      expect(
        pillEmpty,
        closeTo(2 * expected.hPadding, 1.0),
        reason: '空行 → pill 宽退回 2·hPadding（reported Σspan 清零）',
      );
      expect(
        pillEmpty,
        lessThan(pillPinned),
        reason: '空行后 pill 宽必须小于有条目时（缺陷1：不再停在旧 Σspan）',
      );
    });

    testWidgets('TASK-12 复审缺陷3：激活底斑/hover 高亮是 iconSlotSize/iconSize'
        '方块（不被拉满 dockHeight）', (tester) async {
      final services = _FakeShellServices()
        ..apps = _apps
        ..windowsList = [
          ApplicationWindow(
            id: 1,
            appId: 'kate',
            title: 'kate',
            active: true,
            minimized: false,
          ),
        ];
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);

      final metrics = DockMetrics.fromWidth(800, pinnedCount: 1);
      // 缺陷3 回归：激活底斑的外层 SizedBox 必须是 iconSlotSize² 方块
      // （底对 pill 区），不是被 tight dockHeight 高拉成的长条。用
      // 「SizedBox 边长」断言（accent 0.22 alpha 后色值不再是字面量，
      // 不比 decoration 色）。
      final icon = find.byType(DockIcon).first;
      final squareBadge = find.descendant(
        of: icon,
        matching: find.byWidgetPredicate(
          (w) =>
              w is SizedBox &&
              w.width == metrics.iconSlotSize &&
              w.height == metrics.iconSlotSize,
        ),
      );
      expect(
        squareBadge,
        findsWidgets,
        reason: '激活底斑必须是 iconSlotSize² 方块（复审缺陷3：不拉满 dockHeight）',
      );
      // 反证：DockIcon 内不应有「宽 = iconSlotSize 且高 = dockHeight」的
      // 拉满长条 SizedBox（旧 tight-height 缺陷形态；iconSlotSize 与
      // dockHeight 不同值时才构成反证）。
      final stretched = find.descendant(
        of: icon,
        matching: find.byWidgetPredicate(
          (w) =>
              w is SizedBox &&
              w.width == metrics.iconSlotSize &&
              w.height == metrics.dockHeight &&
              metrics.iconSlotSize != metrics.dockHeight,
        ),
      );
      expect(
        stretched,
        findsNothing,
        reason: '底斑不可被拉成 dockHeight 高的长条',
      );
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

    testWidgets('TASK-12 复审缺陷2/3(a)：带层在 ClipRRect 子树之外、'
        '热区厚度恒 = dockHeight', (tester) async {
      final services = _FakeShellServices()..apps = _apps;
      final store = _MemoryDockPreferencesStore(
        DockPreferences(pinned: [_pin(_apps[0]), _pin(_apps[1])]),
      );
      await tester.pumpWidget(_wrap(services, store));
      await _settle(tester);

      // 缺陷2：dock.pinned 带层必须是 ShellBackdropBlur 的**兄弟**而非
      // 后代——SDK 末端 ClipRRect 跟子树尺寸走，带层在其内则放大探出
      // pill 顶缘的部分被 59px 高的圆角框裁掉（绘制+命中双裁）。
      final band = find.byKey(const Key('dock.pinned'));
      expect(band, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ShellBackdropBlur),
          matching: band,
        ),
        findsNothing,
        reason: '图标带层必须移出 ShellBackdropBlur/ClipRRect 子树',
      );

      // 缺陷3(a)：带层 MouseRegion 的热区厚度恒 = dockHeight——
      // quickshell `DockItem.qml:190-199` pointerArea 显式排除 headroom：
      // headroom 空白不吃 hover（放大图标探入的部分仍可命中，那是图标自
      // 身的 hit 而非 region 空白）。
      final metrics = DockMetrics.fromWidth(
        800,
        pinnedCount: 2,
      );
      final regionRect = tester.getRect(
        find.ancestor(
          of: band,
          matching: find.byWidgetPredicate(
            (w) => w is MouseRegion && w.onExit != null,
          ),
        ),
      );
      expect(
        regionRect.height,
        closeTo(metrics.dockHeight, 0.01),
        reason: '带层 MouseRegion 热区厚度必须恒 = dockHeight（非 '
            'dockHeight+headroom）',
      );
      // 底缘贴 pill 底（Positioned bottom:0）。
      final pill = tester.getRect(_pill());
      expect(regionRect.bottom, closeTo(pill.bottom, 0.5));
      // 带内容（OverflowBox 后的 dock.pinned 盒）比热区高 = headroom：
      // 视觉通路向上放 headroom，hit 盒不收。
      expect(
        tester.getRect(band).height,
        greaterThan(metrics.dockHeight),
        reason: '带内容盒 = dockHeight+headroom（视觉通路），大于 hit 盒',
      );
      expect(
        tester.getRect(band).bottom,
        closeTo(pill.bottom, 0.5),
      );
    });

    // ── 方案 B → TASK-11：KOS 分段 + launchers|windows 分割线（D-3）──
    // 图标区内部段序（DockIconRow 自绘槽位带）：leading(launcher/trash) →
    // pinned 段 → divider1 → 运行段——统一进同一 dockWaveLayout 波形带
    // （ReorderableListView 已弃：槽宽随高斯 scale 连续变，固定 itemExtent
    // 表达不了）；divider2/3 在外层 Row
    // （KOS DockContainer.qml:847-857 :856, 859-862, 907-913 :912, :951）。
    // 「pinned 段 < divider1 < 运行段」的断言改用 DockIcon.isPinnedEntry
    // 谓词区分两段（旧 dock.row.pinned/dock.row.running 容器 key 已随
    // 固定槽位段容器一起移除）。

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

      // TASK-11：自绘槽位带不再给 pinned/运行段容器挂 key——用
      // DockIcon.isPinnedEntry 谓词区分两段几何（pinned=true → pinned 槽位，
      // pinned=false → 未 pin 运行槽位），旧 dock.row.* key 已移除。
      Finder pinnedIcons() => find.byWidgetPredicate(
        (w) => w is DockIcon && w.isPinnedEntry,
      );
      Finder runningIcons() => find.byWidgetPredicate(
        (w) => w is DockIcon && !w.isPinnedEntry,
      );
      expect(pinnedIcons(), findsNWidgets(2));
      expect(runningIcons(), findsOneWidget);
      // pinned 段右缘 = 最后一条 pinned 槽位的实测右缘；运行段左缘 =
      // 第一条 running 槽位的实测左缘。
      final pinnedRight = tester
          .getRect(pinnedIcons().last)
          .right;
      final pinnedLeft = tester.getRect(pinnedIcons().first).left;
      final runningBox = tester.getRect(runningIcons().first);
      // TASK-12：divider1 在图标带层（DockIconRow 波形带内），divider2/3 在
      // 玻璃层 Row——两者分属 Stack 不同层，find 顺序不再等同于视觉左→右。
      // 故 divider1 经「DockIconRow 后代」限定、外层两条经 at(0)/at(1) 取。
      final d1 = tester.getCenter(
        find.descendant(
          of: find.byType(DockIconRow),
          matching: find.byType(DockDivider),
        ),
      );
      // 外层两条（divider2/3）：取「非 DockIconRow 后代」的 DockDivider，
      // 按中心 x 左→右排序取前两条。
      final outerRects = find
          .byType(DockDivider)
          .evaluate()
          .where(
            (e) => find
                .descendant(
                  of: find.byType(DockIconRow),
                  matching: find.byWidgetPredicate(
                    (d) => identical(d, e.widget),
                  ),
                )
                .evaluate()
                .isEmpty,
          )
          .map((e) => tester.getCenter(find.byWidget(e.widget)))
          .toList()
        ..sort((a, b) => a.dx.compareTo(b.dx));
      final d2 = outerRects[0];
      final d3 = outerRects[1];
      // 图标区内部：pinned 段 < divider1 < 运行段。
      // TASK-11 高斯波槽位：pinned 末槽 widget 右缘与 divider1 槽中心的间距
      // 只剩亚像素（槽位 span 含尾随 gap、icon 视觉边长/槽位/rounding 共同
      // 决定实测 rect），故容差放宽到 0.5px——语义「pinned 段在 divider1
      // 左侧」不变。
      // TASK-12 底锚槽位列（OverflowBox）下 icon 左缘可再外溢 ~1px，
      // 容差放宽到 1.5px——语义「运行段在 divider1 右侧」不变（仍以
      // 槽中心几何判定，非亚像素级紧贴）。
      expect(pinnedRight, lessThanOrEqualTo(d1.dx + 0.5));
      expect(runningBox.left, greaterThanOrEqualTo(d1.dx - 1.5));
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

      // TASK-11：ReorderableListView/ReorderableDragStartListener 已移除——
      // 拖拽重排是行级 Listener + dockWaveInsertionIndex 手写；运行段不可
      // 拖拽由「hit-test 只认 pinned 槽位」保证（无框架拖拽 listener 可查，
      // 语义断言在 dock_icon_row_test 的「未 pin 条目不可拖拽」用例）。
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      // launcher/trash 与 pinned 段在同一连续波形带内（leading 槽位在
      // pinned 槽位左侧）。
      expect(
        tester.getCenter(find.byType(LauncherIcon)).dx,
        lessThan(pinnedLeft),
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
      // TASK-11：旧 dock.row.pinned/dock.row.running 容器 key 随固定槽位段
      // 容器移除——段存在性改用 DockIcon.isPinnedEntry 谓词判定。
      bool hasPinned() => find
          .byWidgetPredicate((w) => w is DockIcon && w.isPinnedEntry)
          .evaluate()
          .isNotEmpty;
      bool hasRunning() => find
          .byWidgetPredicate((w) => w is DockIcon && !w.isPinnedEntry)
          .evaluate()
          .isNotEmpty;
      expect(hasPinned(), isFalse);
      expect(hasRunning(), isTrue);

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
      expect(hasPinned(), isTrue);
      expect(hasRunning(), isFalse);

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
      expect(hasPinned(), isTrue);
      expect(hasRunning(), isTrue);
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
          // TASK-11：ReorderableListView 已移除 → 图标行不再含 Scrollable；
          // 方案 C 反解保证内容 ≤ maxWidth，自绘槽位带恒为静止自然宽
          // （无指针 → amplitude=0 → 全槽 scale=1）。以「无 Scrollable」+
          // pill 宽上限为不变量，替代旧 maxScrollExtent==0 断言。
          expect(
            find.descendant(
              of: find.byType(DockIconRow),
              matching: find.byType(Scrollable),
            ),
            findsNothing,
            reason: '方案 C+TASK-11：图标行自绘槽位不可滚（无 Scrollable）',
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
