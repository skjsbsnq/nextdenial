// TASK-05：信息卡区 carousel / 四卡降级 / 详情 popup 测试。
//
// 注入假数据源（假 ShellServices + 假 weather/metrics provider + 内存
// store），无 socket/dbus/真实文件依赖。页可见性经 `_SlidingCard` 的
// `IgnorePointer.ignoring` 观测（非当前页 ignoring=true）。

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
import 'package:kos_dock/src/widgets/cards/clock_card.dart';
import 'package:kos_dock/src/widgets/cards/metrics_card.dart';
import 'package:kos_dock/src/widgets/cards/music_card.dart';
import 'package:kos_dock/src/widgets/cards/weather_card.dart';
import 'package:kos_dock/src/widgets/dock_info_popup.dart';
import 'package:kos_dock/src/widgets/dock_preview_popup.dart'
    show DockPopup, DockPopupCoordinator;
import 'package:kos_dock/src/widgets/dock_shell.dart';
import 'package:kos_dock/src/widgets/info_carousel.dart';

// ── fakes ───────────────────────────────────────────────────────────────

class _MemoryStore implements DockPreferencesStore {
  _MemoryStore(this.prefs);
  DockPreferences prefs;

  @override
  Future<DockPreferences> read() async => prefs;

  @override
  Future<void> writePins(List<PinnedApplication> pins) async {}

  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {}

  @override
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  }) async {
    prefs = DockPreferences(
      pinned: prefs.pinned,
      showLauncher: prefs.showLauncher,
      showTrash: prefs.showTrash,
      infoCardOrder: order ?? prefs.infoCardOrder,
      infoCardAutoRotate: autoRotate ?? prefs.infoCardAutoRotate,
      infoCardMode: mode ?? prefs.infoCardMode,
    );
  }
}

class _FakeWeatherProvider implements DockWeatherProvider {
  _FakeWeatherProvider(this._latest);
  final DockWeatherSnapshot? _latest;

  @override
  DockWeatherSnapshot? get latest => _latest;

  @override
  Stream<DockWeatherSnapshot> get snapshots => _latest == null
      ? const Stream<DockWeatherSnapshot>.empty()
      : Stream.value(_latest);

  @override
  Future<void> start() async {}

  @override
  Future<DockWeatherSnapshot?> refresh() async => _latest;

  @override
  void dispose() {}
}

class _FakeMetricsCollector implements DockMetricsCollector {
  _FakeMetricsCollector(this._latest);
  final DockMetricsSnapshot? _latest;

  @override
  DockMetricsSnapshot? get latest => _latest;

  @override
  Stream<DockMetricsSnapshot> get snapshots => _latest == null
      ? const Stream<DockMetricsSnapshot>.empty()
      : Stream.value(_latest);

  @override
  void start() {}

  @override
  Future<DockMetricsSnapshot?> sample() async => _latest;

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

/// 可变 media 状态（C1 页集增长 / E-4 页集收缩用例）：`NotifierProvider`
/// 让 media 在会话内翻转，`_FakeShellServices.media` 经 select 读它。
class _MediaNotifier extends Notifier<MprisPlaybackState> {
  @override
  MprisPlaybackState build() => MprisPlaybackState.unavailable();
}

final _mediaStateProvider =
    NotifierProvider<_MediaNotifier, MprisPlaybackState>(_MediaNotifier.new);

ProviderListenable<AsyncValue<MprisPlaybackState>> get _mutableMedia =>
    _mediaStateProvider.select(
      (state) => AsyncData<MprisPlaybackState>(state),
    );

/// 垃圾桶假实现（无真实 IO；`TrashIcon` watch 需要）——空态。
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
  Stream<TrashState> watch() => Stream.value(TrashState.empty);
}

class _FakeShellServices implements ShellServices {
  _FakeShellServices({this.mediaState, this.mediaValue});

  final MprisPlaybackState? mediaState;

  /// 会话内可变 media 源（优先于 [mediaState]）。
  final ProviderListenable<AsyncValue<MprisPlaybackState>>? mediaValue;

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
  ProviderListenable<LoadSeries> get cpu => Provider((_) => LoadSeries.empty);

  @override
  ProviderListenable<List<GpuLoad>> get gpus =>
      Provider((_) => const <GpuLoad>[]);

  @override
  ProviderListenable<AsyncValue<DateTime>> get clock =>
      // `services.clock` 恒无值（无 tick）→ carousel 自建 1Hz Timer 兜底。
      Provider<AsyncValue<DateTime>>(
        (_) => const AsyncLoading<DateTime>(),
      );

  @override
  ProviderListenable<AsyncValue<MprisPlaybackState>> get media =>
      mediaValue ??
      Provider<AsyncValue<MprisPlaybackState>>(
        (_) => AsyncData(mediaState ?? MprisPlaybackState.unavailable()),
      );

  @override
  ProviderListenable<MediaCommands> get mediaCommands =>
      Provider((_) => _FakeMediaCommands());

  @override
  ProviderListenable<Color> get accent =>
      Provider((_) => const Color(0xFF4488FF));

  @override
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path) =>
      Provider<AsyncValue<Uint8List?>>((_) => const AsyncData(null));

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

class _OtherPopup implements DockPopup {
  @override
  void dismissDockPopupImmediately() {}
}

// ── fixtures ────────────────────────────────────────────────────────────

MprisPlaybackState _playingState() => MprisPlaybackState(
  serviceName: 'org.mpris.MediaPlayer2.spotify',
  identity: 'Spotify',
  title: 'Song',
  artists: const ['Artist'],
  album: 'Album',
  artUrl: '',
  length: const Duration(minutes: 3),
  position: Duration.zero,
  observedAt: DateTime(2026, 1, 1),
  status: MprisPlaybackStatus.playing,
  canGoNext: true,
  canGoPrevious: true,
  canPlay: true,
  canPause: true,
);

const _readyWeather = DockWeatherSnapshot(
  status: 'ready',
  cityName: '长沙',
  currentTemp: 20,
  apparentTemp: 19,
  relativeHumidity: 60,
  windSpeed: 5,
  weatherCode: 0,
  isDay: true,
  sunrise: '06:00',
  sunset: '18:30',
);

const _metricsSnapshot = DockMetricsSnapshot(
  currentMilliC: 42000,
  maximum5MinuteMilliC: 51000,
  memoryUsedBytes: 4,
  memoryTotalBytes: 8,
  diskUsedBytes: 1,
  diskTotalBytes: 4,
);

// ── harness ─────────────────────────────────────────────────────────────

/// 基准几何（info 槽在场）：与 KosDockShell 的 DockMetrics.fromWidth 同源，
/// 使卡内 rowWidth 为正（hasInfo=false 时 infoUnits=0 会让卡宽塌成负）。
final DockMetrics _metrics = DockMetrics.fromWidth(
  800,
  pinnedCount: 2,
  hasInfo: true,
);

Widget _wrapCarousel({
  required ShellServices services,
  required DockPreferences prefs,
  DockWeatherSnapshot? weather,
  DockMetricsSnapshot? metrics,
  DockPopupCoordinator? coordinator,
  DockPreferencesStore? store,
  DockMetrics? scopeMetrics,
}) => ProviderScope(
  overrides: [
    dockPreferencesStoreProvider.overrideWithValue(
      store ?? _MemoryStore(prefs),
    ),
    dockWeatherProviderProvider.overrideWithValue(
      _FakeWeatherProvider(weather),
    ),
    dockMetricsCollectorProvider.overrideWithValue(
      _FakeMetricsCollector(metrics),
    ),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: ShellServicesScope(
        services: services,
        child: DockMetricsScope(
          metrics: scopeMetrics ?? _metrics,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: DockInfoCarousel(
              services: services,
              monitorId: 0,
              coordinator: coordinator,
            ),
          ),
        ),
      ),
    ),
  ),
);

ValueKey<String> _pageKey(int page) => ValueKey('dock.info.page.$page');

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 当前页判定：`_SlidingCard` 里唯一的 IgnorePointer，`!ignoring` = 前台页。
bool _isFront(WidgetTester tester, int page) {
  final finder = find.descendant(
    of: find.byKey(_pageKey(page)),
    matching: find.byType(IgnorePointer),
  );
  expect(finder, findsOneWidget);
  return !tester.widget<IgnorePointer>(finder).ignoring;
}

int _frontPage(WidgetTester tester, Iterable<int> candidates) =>
    candidates.singleWhere((p) => _isFront(tester, p));

/// 滚轮切页（`Listener.onPointerSignal`）：先把指针 hover 到槽内再滚。
Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(7, PointerDeviceKind.mouse, 7);
  final at = tester.getCenter(find.byType(DockInfoCarousel));
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

DockPreferences _prefs([List<String>? order, bool autoRotate = true]) =>
    DockPreferences(infoCardOrder: order ?? DockPreferences.kDockInfoCardOrderDefault, infoCardAutoRotate: autoRotate);

/// pinned 两条（launcher/trash 默认开）→ `DockMetrics.fromWidth` 的
/// pinnedCount=2、runningCount=0（整 pill 回归用）。
DockPreferences _shellPrefs(List<String> order) => DockPreferences(
  pinned: const [
    PinnedApplication(id: 'kate', appId: 'kate', name: 'Kate'),
    PinnedApplication(id: 'dolphin', appId: 'dolphin', name: 'Dolphin'),
  ],
  infoCardOrder: order,
);

/// 整 pill 宿主：真 `DockInfoCarousel` 经 `KosDockShell` 的 infoCard 槽。
/// 槽宽/RenderFlex 回归必须走真实 pill（`dock_container_test.dart` 用的是
/// `metrics.infoSlotWidth` 假槽，比真槽少 `0.2*iconSize`）。
Widget _wrapShell({
  required ShellServices services,
  required DockPreferences prefs,
  DockWeatherSnapshot? weather,
  DockMetricsSnapshot? metrics,
  /// 真实 `dockWeatherProviderProvider` body 的替身**工厂**（天气订阅门控用例的
  /// 计数/抛错探针，见「天气订阅门控」组）；null = 直接注入
  /// `_FakeWeatherProvider(weather)`（其余用例的既有行为）。
  DockWeatherProvider Function()? weatherProviderFactory,
}) => ProviderScope(
  overrides: [
    dockPreferencesStoreProvider.overrideWithValue(_MemoryStore(prefs)),
    if (weatherProviderFactory == null)
      dockWeatherProviderProvider.overrideWithValue(
        _FakeWeatherProvider(weather),
      )
    else
      // body 只在 provider 被 watch/read 时求值 → 工厂被调用次数 = 真实
      // provider 是否被构造（未构造则不会 `start()` 网络轮询）。
      dockWeatherProviderProvider.overrideWith(
        (ref) => weatherProviderFactory(),
      ),
    dockMetricsCollectorProvider.overrideWithValue(
      _FakeMetricsCollector(metrics),
    ),
    trashServiceProvider.overrideWithValue(_FakeTrashService()),
  ],
  child: MaterialApp(
    home: ShellTheme(
      data: const ShellThemeData(),
      child: KosDockShell(
        services: services,
        monitorId: 0,
        infoCard: (coordinator) => DockInfoCarousel(
          services: services,
          monitorId: 0,
          coordinator: coordinator,
        ),
      ),
    ),
  ),
);

/// media 的可变句柄（`_mutableMedia` 的写入端）。
Notifier<MprisPlaybackState> _mediaNotifier(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(DockInfoCarousel)),
      listen: false,
    ).read(_mediaStateProvider.notifier);

// ── tests ───────────────────────────────────────────────────────────────

void main() {
  group('carousel 成页（infoCardOrder × cardVisible）', () {
    testWidgets('media/weather 均可用 → 4 页全成页', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
          metrics: _metricsSnapshot,
        ),
      );
      await _settle(tester);
      for (final page in const [0, 1, 2, 3]) {
        expect(find.byKey(_pageKey(page)), findsOneWidget);
      }
    });

    testWidgets('media 不可用 → music 页不成页，clock/metrics 恒成页', (tester) async {
      final services = _FakeShellServices();
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs(), weather: _readyWeather),
      );
      await _settle(tester);
      expect(find.byKey(_pageKey(0)), findsNothing); // music
      expect(find.byKey(_pageKey(1)), findsOneWidget); // weather
      expect(find.byKey(_pageKey(2)), findsOneWidget); // clock
      expect(find.byKey(_pageKey(3)), findsOneWidget); // metrics
    });

    testWidgets('无 ready 天气快照 → weather 页不成页', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs()),
      );
      await _settle(tester);
      expect(find.byKey(_pageKey(1)), findsNothing); // weather
      expect(find.byKey(_pageKey(0)), findsOneWidget);
      expect(find.byKey(_pageKey(2)), findsOneWidget);
    });

    testWidgets('页序 = infoCardOrder（不含的页不建）', (tester) async {
      final services = _FakeShellServices();
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(['clock', 'metrics']),
        ),
      );
      await _settle(tester);
      expect(find.byKey(_pageKey(0)), findsNothing);
      expect(find.byKey(_pageKey(1)), findsNothing);
      expect(find.byKey(_pageKey(2)), findsOneWidget);
      expect(find.byKey(_pageKey(3)), findsOneWidget);
    });
  });

  group('首有效页 ensureValidPage(preferClock)', () {
    testWidgets('order 含 clock → 初始落 clock', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(['music', 'weather', 'metrics', 'clock']),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      expect(_isFront(tester, 2), isTrue);
    });

    testWidgets('order 无 clock → 第一可用页', (tester) async {
      final services = _FakeShellServices(); // music 不可用
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(['music', 'metrics']),
        ),
      );
      await _settle(tester);
      expect(_isFront(tester, 3), isTrue); // metrics
    });
  });

  group('30s 自动轮换 / hover 暂停 / 开关 / 单页', () {
    testWidgets('30s 自动切页', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      expect(_frontPage(tester, const [0, 1, 2, 3]), 2); // clock
      await tester.pump(const Duration(seconds: 30));
      expect(_frontPage(tester, const [0, 1, 2, 3]), 3); // → metrics
    });

    testWidgets('hover 暂停轮换', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(DockInfoCarousel)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 2), isTrue); // 停在 clock
      await gesture.removePointer();
    });

    testWidgets('infoCardAutoRotate=false 不轮换', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(null, false),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 2), isTrue);
    });

    testWidgets('单页不轮换', (tester) async {
      final services = _FakeShellServices();
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs(['clock'])),
      );
      await _settle(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 2), isTrue);
    });
  });

  group('每卡降级', () {
    testWidgets('clock `now` 恒用 1Hz `_clockNow`（services.clock 分钟流不取）',
        (tester) async {
      final services = _FakeShellServices(); // clockValue null
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs(['clock'])),
      );
      await _settle(tester);
      // 取首帧 HH:mm:ss，再 pump 1s → 文本必须变化（秒级 tick 真在走）。
      final first = tester
          .widget<Text>(
            find.textContaining(RegExp(r'^\d{2}:\d{2}:\d{2}$')),
          )
          .data!;
      await tester.pump(const Duration(seconds: 1));
      final second = tester
          .widget<Text>(
            find.textContaining(RegExp(r'^\d{2}:\d{2}:\d{2}$')),
          )
          .data!;
      expect(second, isNot(first));
      expect(find.byType(DockClockCard), findsOneWidget);
    });

    testWidgets('weather 无数据 → --', (tester) async {
      await tester.pumpWidget(
        _card(const DockWeatherCard(snapshot: DockWeatherSnapshot())),
      );
      expect(find.textContaining('--°'), findsWidgets);
      expect(find.textContaining('--'), findsWidgets);
    });

    testWidgets('metrics 无数据 → --° 且三环数值 0', (tester) async {
      await tester.pumpWidget(
        _card(const DockMetricsCard(snapshot: null, cpuFraction: null)),
      );
      expect(find.text('--°'), findsNWidgets(2));
      final paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is DockMetricsRingsPainter,
        ),
      );
      final painter = paint.painter! as DockMetricsRingsPainter;
      expect(painter.cpuValue, 0);
      expect(painter.memoryValue, 0);
      expect(painter.storageValue, 0);
    });

    testWidgets('music 无播放器 → 占位 No Track', (tester) async {
      await tester.pumpWidget(
        _card(
          DockMusicCard(
            state: MprisPlaybackState.unavailable(),
            artwork: null,
            pageActive: true,
          ),
        ),
      );
      expect(find.text('No Track', findRichText: true), findsOneWidget);
    });
  });

  group('详情 popup（hover 420/260 + 协调器抢占）', () {
    testWidgets('hover 420ms 开、离开 260ms 关', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(DockInfoCarousel)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DockInfoPanel), findsNothing);
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(DockInfoPanel), findsOneWidget);

      // 指针离开 → 260ms closeDelay + 140ms 退场。
      await gesture.moveTo(const Offset(2, 2));
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockInfoPanel), findsNothing);
    });

    testWidgets('被协调器抢占 → 立即收场', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      final coordinator = DockPopupCoordinator();
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
          coordinator: coordinator,
        ),
      );
      await _settle(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(DockInfoCarousel)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(DockInfoPanel), findsOneWidget);
      expect(coordinator.activePopup, isNotNull);

      coordinator.activate(_OtherPopup());
      await tester.pump();
      expect(find.byType(DockInfoPanel), findsNothing);
      await gesture.removePointer();
    });
  });

  group('可用页集变化 → 轮换表起停（C1 / E-1 / E-4）', () {
    testWidgets('可用页 1→2 增长后启动 30s 轮换（C1 回归）', (tester) async {
      // `['clock','music']`：首帧 media 未就绪 → pages=[clock] 不建表；
      // 音乐开始播放 → pages=[clock,music] → 轮换必须启动。
      final services = _FakeShellServices(mediaValue: _mutableMedia);
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs(['clock', 'music'])),
      );
      await _settle(tester);
      expect(find.byKey(_pageKey(0)), findsNothing); // music 未成页
      expect(_isFront(tester, 2), isTrue); // clock
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 2), isTrue); // 单页：不轮换

      _mediaNotifier(tester).state = _playingState();
      await _settle(tester);
      expect(find.byKey(_pageKey(0)), findsOneWidget); // music 成页

      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 0), isTrue); // clock → music（轮换真的启动）
    });

    testWidgets('可用页 2→1 收缩 → 停表并收敛到第一可用页（E-4）', (tester) async {
      final services = _FakeShellServices(mediaValue: _mutableMedia);
      await tester.pumpWidget(
        _wrapCarousel(services: services, prefs: _prefs(['clock', 'music'])),
      );
      _mediaNotifier(tester).state = _playingState();
      await _settle(tester);
      expect(_frontPage(tester, const [0, 2]), 2); // clock
      await tester.pump(const Duration(seconds: 30));
      expect(_frontPage(tester, const [0, 2]), 0); // 轮换到 music

      // 播放停止 → music 页消失，且当前页恰为消失页 → 收敛到第一可用页。
      _mediaNotifier(tester).state = MprisPlaybackState.unavailable();
      await _settle(tester);
      expect(find.byKey(_pageKey(0)), findsNothing);
      expect(_isFront(tester, 2), isTrue); // 收敛回 clock
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 2), isTrue); // 单页：轮换表已停
    });

    testWidgets('无关 prefs 写入不重置 30s 轮换表（缺陷 2）', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      final store = _MemoryStore(_prefs());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          store: store,
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      expect(_frontPage(tester, const [0, 1, 2, 3]), 2); // clock
      await tester.pump(const Duration(seconds: 20));
      expect(_frontPage(tester, const [0, 1, 2, 3]), 2); // 未到 30s

      // 与信息卡无关的 prefs 写入（showTrash）：KOS `running:` 是声明式绑定，
      // 值不变不重启 Timer。若 `ref.listen` 里无条件 `_syncCarouselTimer()`，
      // 30s 会从此刻重新起算 → 下面的 11s 不足以切页（缺陷 2）。
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DockInfoCarousel)),
        listen: false,
      );
      await container
          .read(dockPreferencesProvider.notifier)
          .updateShowTrash(false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 11)); // 距首次起表 >30s
      expect(_frontPage(tester, const [0, 1, 2, 3]), 3); // clock → metrics
    });

    testWidgets('order 内容变化 → 收敛回 clock 页（C4）', (tester) async {
      final store = _MemoryStore(_prefs(['clock', 'metrics']));
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(['clock', 'metrics']),
          store: store,
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      expect(_isFront(tester, 2), isTrue); // preferClock → clock
      // 用滚轮切到 metrics（`delta>0` → 下一页；页序 [clock, metrics]）。
      await _wheel(tester, 24);
      await _settle(tester);
      expect(_isFront(tester, 3), isTrue); // 现在停在 metrics（非 clock）
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DockInfoCarousel)),
        listen: false,
      );
      // order **内容**变化（仍含 clock）→ 收敛回 clock 页
      // （KOS `onCardOrderChanged: ensureValidPage(showClock)` :202）。
      await container
          .read(dockPreferencesProvider.notifier)
          .updateInfoCardOrder((_) => ['metrics', 'clock']);
      await _settle(tester);
      expect(_isFront(tester, 2), isTrue);
      // 仍然两页可用（order 顺序变了）。
      expect(find.byKey(_pageKey(3)), findsOneWidget);
    });
  });

  group('真实 carousel 进整 pill（槽宽 / RenderFlex 回归，E-2）', () {
    Future<void> pumpShellAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrapShell(
          services: _FakeShellServices(),
          prefs: _shellPrefs(DockPreferences.kDockInfoCardOrderDefault),
          weather: _readyWeather,
          metrics: _metricsSnapshot,
        ),
      );
      await _settle(tester);
    }

    for (final width in const [1920.0, 500.0, 320.0]) {
      testWidgets('@${width.toInt()} 真槽宽 = infoSlotWidth + 0.2*iconSize，整 pill 无溢出',
          (tester) async {
        await pumpShellAt(tester, width);
        // 与 KosDockShell 的 fromWidth 同参（pinned 2 / 无运行窗 / 有 info）。
        final metrics = DockMetrics.fromWidth(
          width,
          pinnedCount: 2,
          runningCount: 0,
          showLauncher: true,
          showTrash: true,
          hasInfo: true,
        );
        expect(find.byType(DockInfoCarousel), findsOneWidget);
        final slot = tester.getSize(find.byType(DockInfoCarousel));
        expect(
          slot.width,
          moreOrLessEquals(
            metrics.infoSlotWidth + metrics.iconSize * kDockInfoCardGapRatio,
            epsilon: 1e-6,
          ),
        );
        expect(
          slot.height,
          moreOrLessEquals(
            metrics.iconSize * kDockInfoSlotHeightRatio,
            epsilon: 1e-6,
          ),
        );
        // 真槽比假槽宽 0.2*iconSize：整 pill 不得 RenderFlex overflow。
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('空 infoCardOrder 端到端（E-3）', () {
    testWidgets('会话内 hasInfo=false：无 info 槽、无 divider2', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrapShell(
          services: _FakeShellServices(),
          prefs: _shellPrefs(const <String>[]),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockInfoCarousel), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dock.infoCard')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('对照：order 非空 → info 槽与 divider2 都在', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrapShell(
          services: _FakeShellServices(),
          prefs: _shellPrefs(const ['clock']),
        ),
      );
      await _settle(tester);
      expect(find.byType(DockInfoCarousel), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsOneWidget,
      );
    });
  });

  group('天气订阅门控（round-3 缺陷 1：门控必须真实生效）', () {
    /// 1920 宽 pill + 真实 `DockInfoCarousel`；[weatherProviderFactory] 每被求值
    /// 一次即证明「真实 `dockWeatherProviderProvider` 的默认 body 被求值」一次
    /// （默认 body 构造 `OpenMeteoDockWeatherProvider` 并 `start()` 网络轮询，
    /// `state/dock_settings.dart:48-52,63-67`）。
    Future<int Function()> pumpCountingWeather(
      WidgetTester tester,
      List<String> order,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var marker = 0;
      await tester.pumpWidget(
        _wrapShell(
          // media 可播：保证 hasInfo=true → carousel 真的挂进 pill。
          services: _FakeShellServices(mediaState: _playingState()),
          prefs: _shellPrefs(order),
          weatherProviderFactory: () {
            marker++;
            return _FakeWeatherProvider(_readyWeather);
          },
        ),
      );
      await _settle(tester);
      return () => marker;
    }

    testWidgets('order 只含 music/metrics（无 weather 无 clock）→ 真实 weather '
        'provider 不被构造/订阅', (tester) async {
      final marker = await pumpCountingWeather(
        tester,
        const ['music', 'metrics'],
      );
      // 用例前提：carousel 真在 pill 里（否则「未订阅」空洞）。
      expect(find.byType(DockInfoCarousel), findsOneWidget);
      expect(
        marker(),
        0,
        reason: 'order 无 weather 无 clock → shell 与 carousel 都不该订阅',
      );
      // 门控关闭的可见后果：weather 页不可用；music/metrics 照常。
      expect(find.byKey(_pageKey(1)), findsNothing); // weather
      expect(find.byKey(_pageKey(0)), findsOneWidget); // music
      expect(find.byKey(_pageKey(3)), findsOneWidget); // metrics
      // 跑完 30s 轮换（`_switchPage` 的门控读点）与 postFrame 收敛
      // （`initState` 的 `_syncCarouselTimer` / `_ensureValidPage`）后仍为 0。
      await tester.pump(const Duration(seconds: 31));
      expect(marker(), 0, reason: '轮换/收敛读点不得拉起真实 provider');
      expect(tester.takeException(), isNull);
    });

    testWidgets('对照：默认四卡（KOS 同构）→ 订阅 weather，clock 页日出/日落正常',
        (tester) async {
      final marker = await pumpCountingWeather(
        tester,
        DockPreferences.kDockInfoCardOrderDefault,
      );
      expect(
        marker(),
        1,
        reason: '默认含 clock/weather → 订阅一次（keepAlive，shell 与 carousel 共用）',
      );
      expect(find.byType(DockClockCard), findsOneWidget); // clock 为首有效页
      expect(find.text('06:00'), findsOneWidget); // 日出：快照真到了卡上
      expect(find.text('18:30'), findsOneWidget); // 日落
    });

    testWidgets('order 含 clock 不含 weather → 仍订阅 weather（日出/日落读同一快照）',
        (tester) async {
      final marker = await pumpCountingWeather(tester, const ['clock', 'metrics']);
      expect(
        marker(),
        1,
        reason: 'clock 页需要 weather 快照（SolarEventRow）→ 判据含 clock',
      );
      expect(find.text('06:00'), findsOneWidget);
      expect(find.text('18:30'), findsOneWidget);
      // weather 卡自身不在 order 里 → 不成页。
      expect(find.byKey(_pageKey(1)), findsNothing);
    });
  });

  group('compact 分支冒烟（iconSize<32 / music<36，E-5）', () {
    // 窄条带反解出 iconSize=27（<32 且 <36）→ 三卡紧凑行 + music compact。
    final narrow = DockMetrics.fromWidth(
      140,
      showLauncher: false,
      showTrash: false,
      hasInfo: true,
    );

    testWidgets('fixture 落在紧凑区间（iconSize=27、infoUnits=4）', (tester) async {
      expect(narrow.iconSize, 27);
      expect(narrow.infoUnits, 4);
    });

    testWidgets('clock/weather/metrics compact 行自然宽 > 卡宽 → FittedBox 兜底缩入'
        '（E-5）', (tester) async {
      // 三卡紧凑行外层是 `FittedBox(fit: scaleDown)`（clock_card.dart:113-117、
      // weather_card.dart:72-76、metrics_card.dart:97-101）：FittedBox 以无界
      // 约束布局子件，Row 永不 RenderFlex overflow——只断言
      // `takeException()==null` 对任意 fixture 恒真（断言空洞）。这里量「紧凑行
      // 自然宽」（FittedBox 子件的 `getSize` = 无界约束下的自然尺寸）与卡宽比较：
      // 自然宽超卡宽 → 兜底确实被触发；若某次回归把紧凑行收窄到卡内或摘掉
      // FittedBox，断言即失败。
      final cardWidth = narrow.iconSize * narrow.infoUnits +
          narrow.iconSize * kDockInfoCardGapRatio;
      Future<void> expectScaledDown(Type cardType, Widget card) async {
        await tester.pumpWidget(_card(card, metrics: narrow));
        expect(tester.takeException(), isNull);
        final rowFinder = find.descendant(
          of: find.byType(cardType),
          matching: find.byType(Row),
        );
        expect(rowFinder, findsOneWidget);
        final natural = tester.getSize(rowFinder).width;
        final fittedFinder = find.descendant(
          of: find.byType(cardType),
          matching: find.byType(FittedBox),
        );
        expect(fittedFinder, findsOneWidget);
        final fittedWidth = tester.getSize(fittedFinder).width;
        expect(natural, greaterThan(cardWidth)); // 兜底真被触发
        expect(fittedWidth, lessThanOrEqualTo(cardWidth + 1e-6)); // 缩放后落卡内
        expect(fittedWidth / natural, lessThan(1.0)); // 等比缩小（非恒等）
      }

      await expectScaledDown(
        DockClockCard,
        DockClockCard(
          data: DockClockCardData(
            now: DateTime(2026, 1, 1, 12, 34, 56),
            sunrise: '06:00',
            sunset: '18:30',
          ),
        ),
      );
      await expectScaledDown(
        DockWeatherCard,
        const DockWeatherCard(snapshot: _readyWeather),
      );
      await expectScaledDown(
        DockMetricsCard,
        const DockMetricsCard(snapshot: _metricsSnapshot, cpuFraction: 0.42),
      );
    });

    testWidgets('music compact（cover 叠播停 + 单行 metadata）无 overflow',
        (tester) async {
      await tester.pumpWidget(
        _card(
          DockMusicCard(
            state: _playingState(),
            artwork: null,
            pageActive: true,
          ),
          metrics: narrow,
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.takeException(), isNull);
      // 卸载：compact marquee 是 `repeat()` 的无限动画，测试结束前收掉。
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('滚轮切页 / popup 跟随（C5 / E-6）', () {
    Future<void> wheel(WidgetTester tester, double dy) => _wheel(tester, dy);

    testWidgets('delta>0 → 下一页；180ms 冷却内忽略', (tester) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      expect(_frontPage(tester, const [0, 1, 2, 3]), 2); // clock

      await wheel(tester, 24); // delta>0 → 下一页（与 KOS 相反，记 deltas）
      expect(_frontPage(tester, const [0, 1, 2, 3]), 3); // metrics
      await wheel(tester, 24); // 冷却内 → 忽略
      expect(_frontPage(tester, const [0, 1, 2, 3]), 3);
      await tester.pump(const Duration(milliseconds: 181));
      await wheel(tester, 24);
      expect(_frontPage(tester, const [0, 1, 2, 3]), 0); // 环绕到 music
    });

    testWidgets('popup 已开 → 30s 轮换暂停、面板不跟随切页（修复项 2）', (
      tester,
    ) async {
      final services = _FakeShellServices(mediaState: _playingState());
      await tester.pumpWidget(
        _wrapCarousel(
          services: services,
          prefs: _prefs(),
          weather: _readyWeather,
        ),
      );
      await _settle(tester);
      // 点击开详情 popup（clock 页）。
      await tester.tap(find.byType(DockInfoCarousel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DockInfoPanel), findsOneWidget);
      expect(find.text('时钟'), findsOneWidget);

      // popup 开着时 `_syncCarouselTimer` 不建表 + `_followPopupPage` 冻结：
      // 30s 后卡槽仍在 clock、面板仍显示「时钟」（修复项 2：曾轮换跳
      // metrics 且面板被带走；记 deltas——KOS popup 跟随 hoveredPage）。
      await tester.pump(const Duration(seconds: 30));
      expect(find.byType(DockInfoPanel), findsOneWidget);
      expect(find.text('时钟'), findsOneWidget);
      expect(find.text('资源占用'), findsNothing);
      expect(_isFront(tester, 2), isTrue); // 轮换没跑
      // 指针移出（popup 本体与槽都不 hover）→ 260ms closeDelay + 140ms
      // 退场后 popup 收掉，轮换恢复 → 再过 30s 切到 metrics。
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      // 先 hover 进卡槽（设 `_hovered`），再移出到屏角落 → onExit 触发
      // `_armPopupClose`。
      await gesture.moveTo(tester.getCenter(find.byType(DockInfoCarousel)));
      await tester.pump();
      await gesture.moveTo(const Offset(2, 2));
      await tester.pump(const Duration(milliseconds: 260 + 200));
      expect(find.byType(DockInfoPanel), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(_isFront(tester, 3), isTrue); // 轮换恢复 → metrics
    });
  });

  group('hasInfo = hasAvailableInfo（KOS DockContainer.qml:46-58,143；缺陷 1）', () {
    testWidgets('order=[music] 且无播放器 → 无 info 槽 / 无 divider2 / 无异常；'
        'media 可用后槽出现', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // order 里只有 music 且无播放器 → 零可用卡（KOS `hasAvailableInfo`
      // 由 `hasPlayingMusic || hasWeather || hasClock || hasTemperature` 推导）。
      final services = _FakeShellServices(mediaValue: _mutableMedia);
      await tester.pumpWidget(
        _wrapShell(services: services, prefs: _shellPrefs(const ['music'])),
      );
      await _settle(tester);
      expect(find.byType(DockInfoCarousel), findsNothing);
      expect(find.byKey(const ValueKey<String>('dock.infoCard')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // 播放器出现 → music 页可用 → info 槽与 divider2 一起回来。
      ProviderScope.containerOf(
        tester.element(find.byType(KosDockShell)),
        listen: false,
      ).read(_mediaStateProvider.notifier).state = _playingState();
      await _settle(tester);
      expect(find.byType(DockInfoCarousel), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dock.infoCard')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('iconSize 触底（MIN_ICON_SIZE=18）→ 摘掉 info 槽（KOS hideInfoCarousel；缺陷 6）',
      () {
    Future<void> pumpShellAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrapShell(
          services: _FakeShellServices(),
          prefs: _shellPrefs(DockPreferences.kDockInfoCardOrderDefault),
          weather: _readyWeather,
          metrics: _metricsSnapshot,
        ),
      );
      await _settle(tester);
    }

    testWidgets('@190 探针 iconSize 触底 → 整区摘除（无槽 / 无 divider2 / 无溢出）',
        (tester) async {
      // 触发条件 = KOS `_infoProbeLayout.iconSize <= MIN_ICON_SIZE`
      // （DockContainer.qml:130-137,141-143）：**带上 carousel** 反解即触底。
      final probe = DockMetrics.fromWidth(
        190,
        pinnedCount: 2,
        runningCount: 0,
        showLauncher: true,
        showTrash: true,
        hasInfo: true,
      );
      expect(probe.iconSize, kDockMinIconSize.toDouble());
      await pumpShellAt(tester, 190);
      expect(find.byType(DockInfoCarousel), findsNothing);
      expect(find.byKey(const ValueKey<String>('dock.infoCard')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsNothing,
      );
      // 未移植该兜底（hasInfo 仍 true）时：真槽比 fromWidth 的
      // renderedWidth 多 0.2*iconSize（3.6px）→ 本宽度下实测溢出 1.8px。
      expect(tester.takeException(), isNull);
      // 摘除后图标回血（KOS :139-140「returns its four icon-widths」）。
      final withoutInfo = DockMetrics.fromWidth(
        190,
        pinnedCount: 2,
        runningCount: 0,
        showLauncher: true,
        showTrash: true,
      );
      expect(withoutInfo.iconSize, greaterThan(kDockMinIconSize.toDouble()));
    });

    testWidgets('@210 探针 iconSize=19（下限之上）→ info 槽保留且无溢出',
        (tester) async {
      final probe = DockMetrics.fromWidth(
        210,
        pinnedCount: 2,
        runningCount: 0,
        showLauncher: true,
        showTrash: true,
        hasInfo: true,
      );
      expect(probe.iconSize, greaterThan(kDockMinIconSize.toDouble()));
      await pumpShellAt(tester, 210);
      expect(find.byType(DockInfoCarousel), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dock.divider.info')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// 直接挂单卡（不经 carousel）：ShellTheme + DockMetricsScope（默认基准
/// 几何 iconSize=42 → full 形态；传 [metrics] 可注入紧凑态几何）。
Widget _card(Widget child, {DockMetrics? metrics}) => MaterialApp(
  home: ShellTheme(
    data: const ShellThemeData(),
    child: DockMetricsScope(
      metrics: metrics ?? _metrics,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Center(child: child),
      ),
    ),
  ),
);
