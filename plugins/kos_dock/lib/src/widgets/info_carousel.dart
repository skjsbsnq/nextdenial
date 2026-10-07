/// KOS Dock 信息卡区 carousel（TASK-05 核心件）。
///
/// 移植 NextKde `shell/desktop/modules/dock/DockInfoCarousel.qml`（380 行
/// 已通读，行号在各段标注）：4 卡共享槽 clock/weather/metrics/music——
/// - 页序 = `prefs.infoCardOrder`（默认 `[music,weather,clock,metrics]`，
///   :21），KOS 页索引 music=0/weather=1/clock=2/metrics=3 经 [pageForId]
///   映射；
/// - 槽宽 `infoUnits*iconSize + iconSize*0.2`（:43,56——cardGap=
///   `iconSize*0.2` 是卡背外延，本端直接进槽宽），槽高 `iconSize*1.2`
///   （:57，容纳卡背上下外延），carousel 模式 clip（:58）；
/// - 页可见性 `cardVisible`（:73-81）：music → `MprisPlaybackState.
///   available`、weather → `snapshot.status=='ready'`、clock/metrics
///   恒真；
/// - 首有效页 `ensureValidPage(preferClock)`（:125-137）：order 含 clock
///   时首选 clock 页，否则第一可用页；
/// - `carouselTimer` 30s 自动轮换（:205-213，`autoRotate &&
///   availablePageCount>1`；KOS 的 `running:` **无 hover 项**，hover 暂停是
///   本端按任务卡要求新增的偏差，记 deltas）；切页 `switchPage`（:139-153）
///   记录 previousPage + transitionDirection；页 x 经 `pageX`
///   （:155-161）`±cardWidth`；每卡 x 260ms OutCubic、opacity 220ms
///   OutCubic（:332-333 等）；滚轮切页 180ms cooldown（:215-235）；
/// - hover 420ms 开 DockInfoPopup / 260ms 关（:279-312；music 的
///   DockMusicPopup 同节奏但独立面板（DockMusicPlayer.qml:88-107）、metrics
///   页走 TemperatureSensorPopups（DockTemperatureWidget.qml:278-281）——
///   本端四页统一走 [DockInfoOverlay]，记 deltas）；滚轮切页方向本端
///   `delta>0` → 下一页，与 KOS `delta >= 0 ? -1 : 1`（:231）相反（记
///   deltas）；右键 `editRequested`（:237-241）v1 无编辑器忽略（记
///   deltas）；点击卡 → 立即开详情 popup（任务卡「hover/点击都开详情」）。
///
/// expanded 模式（`infoCardMode=="expanded"`）v1 不做：prefs 读侧已
/// clamp 为 carousel（记 deltas）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:denial_sdk/system.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dock_settings.dart';
import '../theme/dock_tokens.dart';
import 'cards/clock_card.dart';
import 'cards/metrics_card.dart';
import 'cards/music_card.dart';
import 'cards/weather_card.dart';
import 'dock_info_popup.dart';
import 'dock_preview_popup.dart';
import 'media_art.dart';

/// KOS `DockInfoCarousel`：4 卡共享槽 + 30s 自动轮换 + DockInfoPopup。
/// popup 协调器经构造参数下发（`dock_shell.dart` 的全 pill 唯一
/// [DockPopupCoordinator]；KOS `DockModelService.activeDockPopup` 单例
/// 语义，DockInfoCarousel 走 `openDockPopup` :276,300 +
/// `releaseDockPopup` :318）。
class DockInfoCarousel extends ConsumerStatefulWidget {
  const DockInfoCarousel({
    required this.services,
    required this.monitorId,
    this.coordinator,
    super.key,
  });

  final ShellServices services;
  final int monitorId;

  /// 全 pill 共享 popup 协调器（null = 独立宿主/测试退化为无协调）。
  final DockPopupCoordinator? coordinator;

  @override
  ConsumerState<DockInfoCarousel> createState() => _DockInfoCarouselState();
}

class _DockInfoCarouselState extends ConsumerState<DockInfoCarousel>
    with SingleTickerProviderStateMixin
    implements DockPopup {
  // KOS 页索引（DockInfoCarousel.qml:17-20）。
  static const int musicPage = 0;
  static const int weatherPage = 1;
  static const int clockPage = 2;
  static const int metricsPage = 3;

  /// `pageForId`（:61-71）：temperature→metrics 别名已在 prefs 归一化
  /// 层处理，此处 metrics 直给。
  static int? pageForId(String id) => switch (id) {
    'music' => musicPage,
    'weather' => weatherPage,
    'clock' => clockPage,
    'metrics' => metricsPage,
    _ => null,
  };

  // ── 页状态（KOS `page`/`previousPage`/`transitionDirection`，:52-54）──
  int _page = clockPage; // KOS: :51 `property int page: clockPage`
  int _previousPage = -1;
  int _transitionDirection = 1;
  bool _ensureScheduled = false;

  // ── 轮换计时器输入签名（C1）──────────────────────────────────────
  // KOS `running: autoRotate && !expanded && availablePageCount > 1`
  // （DockInfoCarousel.qml:205-213）是声明式绑定：可用页集 / 开关任一变化
  // 都重新求值。本端把 build 期算出的「可用页集 + autoRotate + hover」记成
  // 签名，变化时（postFrame，避免 build 内改状态）无条件
  // [_syncCarouselTimer]。只在「当前页失效」分支重建计时器会让
  // 「1 页 → ≥2 页」的启动方向漏掉（首帧 media/weather 未就绪时 pages 只有
  // clock → 不建表，随后数据到位 → 永不轮换）。
  List<int> _timerPages = const <int>[];
  bool _timerAutoRotate = false;
  bool _timerHovered = false;
  bool _timerSyncScheduled = false;

  // ── 计时器（carouselTimer/wheelCooldown/openDelay/closeDelay）──
  Timer? _carouselTimer;
  Timer? _wheelCooldown;
  Timer? _popupOpenDelay;
  Timer? _popupCloseDelay;
  bool _hovered = false;
  bool _popupPointerInside = false;

  // ── popup 宿主（OverlayPortal + 显隐动画）──
  final _portalController = OverlayPortalController();
  late final AnimationController _popupProgress;
  int _popupPage = -1;
  bool _popupVisible = false;
  bool _popupClosing = false;

  // ── clock tick 自建驱动（services.clock fake 不 tick 时兜底，记
  // deltas）──
  Timer? _clockTicker;
  DateTime _clockNow = DateTime.now();

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    // popup 显隐动画：150ms OutCubic 开 / 140ms InCubic 关（ACCEPTANCE
    // popup 条款，dock_menu.dart 同式）；dismissed 收 portal + 释放协调器。
    _popupProgress =
        AnimationController(
            vsync: this,
            duration: kDockMenuOpenDuration,
            reverseDuration: kDockMenuCloseDuration,
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.dismissed) {
              _popupClosing = false;
              if (_popupVisible) {
                _popupVisible = false;
                _portalController.hide();
                widget.coordinator?.release(this);
              }
              // popup 完全收起 → 恢复 30s 轮换（popup 开着时
              // [_syncCarouselTimer] 不建表，记 deltas）。dispose 中
              // status 变回 dismissed 时不做 ref.read。
              if (mounted) _syncCarouselTimer();
            }
          });
    // KOS `Component.onCompleted: ensureValidPage(showClock)`（:195）——
    // showClock 融合模式恒真（`hasClock` = infoCardOrder 含 clock，
    // DockContainer.qml:52-53），
    // 故 preferClock=true。
    _ensureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureScheduled = false;
      _ensureValidPage(true);
    });
    _syncCarouselTimer();
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // KOS `SystemClock precision: Seconds`（DockInfoPopup.qml:41-44 /
      // DockClockWidget.qml:27-30）的等价物：时钟卡 `now` 恒取秒级
      // `_clockNow`；`services.clock` 是分钟级流、对秒字段无价值故不取
      // （记 deltas）。1Hz setState 重绘保留。
      _clockNow = DateTime.now();
      // Hidden clock pages need no rebuild; switching pages reads fresh time.
      if (mounted && (_page == clockPage || _popupVisible)) setState(() {});
    });
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _wheelCooldown?.cancel();
    _popupOpenDelay?.cancel();
    _popupCloseDelay?.cancel();
    _clockTicker?.cancel();
    _popupProgress.dispose();
    widget.coordinator?.release(this);
    super.dispose();
  }

  // ── KOS `cardVisible`（:73-81）──────────────────────────────────
  bool _cardVisible(
    int page, {
    required bool hasMusic,
    required bool hasWeather,
  }) => switch (page) {
    musicPage => hasMusic,
    weatherPage => hasWeather,
    clockPage => true, // KOS showClock 融合模式恒真
    _ => true, // metrics 恒真（`hasTemperature`，DockContainer.qml:56-58）
  };

  /// `pageOrder`（:22-29）：infoCardOrder 过滤未知 id + 保序去重（prefs
  /// 已归一化，此处只做 id→page 映射与去重防御）。
  List<int> _pageOrder(List<String> cardOrder) {
    final pages = <int>[];
    for (final id in cardOrder) {
      final candidate = pageForId(id);
      if (candidate != null && !pages.contains(candidate)) {
        pages.add(candidate);
      }
    }
    return pages;
  }

  /// `availablePages`（:117-124）。
  List<int> _availablePages(
    List<int> pageOrder, {
    required bool hasMusic,
    required bool hasWeather,
  }) => [
    for (final p in pageOrder)
      if (_cardVisible(p, hasMusic: hasMusic, hasWeather: hasWeather)) p,
  ];

  /// 天气快照订阅门控判据（**与 `dock_shell.dart` 的 `weatherGate` 同源**，
  /// 判据本体是 [dockInfoCardNeedsWeather]）：偏好已真正读到
  /// （`prefsAsync.hasValue`——loading 帧的 `prefs` 是默认四卡兜底，只按它订阅
  /// 会让无天气卡的用户在启动帧就起真实轮询）**且** order 含 `weather` 或含
  /// `clock`（clock 页的日出/日落读同一份快照）。
  static bool _weatherGateOpen(
    AsyncValue<DockPreferences> prefsAsync,
    DockPreferences prefs,
  ) => prefsAsync.hasValue && dockInfoCardNeedsWeather(prefs.infoCardOrder);

  /// 门控读天气快照——**build 之外的三个读点**（`initState` 的
  /// [_syncCarouselTimer]、[_ensureValidPage]、[_switchPage]）。
  ///
  /// 必须与 build 同一门控：`ref.read` 对尚未被订阅的 `StreamProvider`
  /// **同样会初始化它**（provider body 里的 `unawaited(provider.start())` 起
  /// 真实 HttpClient/状态文件/周期 Timer，`state/dock_settings.dart:63-67`），
  /// 否则 order 不含 weather/clock 时仍会被这几个读点把真实 provider 拉起来
  /// （复审 round-3 探针实测命中的路径之一）。
  DockWeatherSnapshot? _gatedWeather() {
    final prefsAsync = ref.read(dockPreferencesProvider);
    final gateOpen = _weatherGateOpen(
      prefsAsync,
      prefsAsync.value ?? const DockPreferences(),
    );
    return gateOpen ? ref.read(dockWeatherSnapshotProvider).value : null;
  }

  // ── KOS `ensureValidPage`（:125-137）──────────────────────────────
  void _ensureValidPage(bool preferClock) {
    if (!mounted) return;
    final prefs =
        ref.read(dockPreferencesProvider).value ?? const DockPreferences();
    final order = _pageOrder(prefs.infoCardOrder);
    final media = ref.read(widget.services.media).value;
    final weather = _gatedWeather();
    final hasMusic = media?.available ?? false;
    final hasWeather = weather?.available ?? false;
    setState(() {
      if (preferClock && order.contains(clockPage)) {
        _previousPage = _page;
        _page = clockPage;
        _followPopupPage();
        return;
      }
      if (_cardVisible(_page, hasMusic: hasMusic, hasWeather: hasWeather) &&
          order.contains(_page)) {
        return;
      }
      final pages = _availablePages(
        order,
        hasMusic: hasMusic,
        hasWeather: hasWeather,
      );
      _previousPage = _page;
      _page = pages.isNotEmpty ? pages.first : clockPage;
      _followPopupPage();
    });
  }

  // ── KOS `switchPage`（:139-153）───────────────────────────────────
  void _switchPage({required bool resetTimer, int direction = 1}) {
    final prefs =
        ref.read(dockPreferencesProvider).value ?? const DockPreferences();
    final order = _pageOrder(prefs.infoCardOrder);
    final media = ref.read(widget.services.media).value;
    final weather = _gatedWeather();
    final pages = _availablePages(
      order,
      hasMusic: media?.available ?? false,
      hasWeather: weather?.available ?? false,
    );
    if (pages.length < 2) return;
    final dir = direction >= 0 ? 1 : -1;
    var currentIndex = pages.indexOf(_page);
    if (currentIndex < 0) currentIndex = 0;
    setState(() {
      _previousPage = _page;
      _transitionDirection = dir;
      _page = pages[(currentIndex + dir + pages.length) % pages.length];
      // popup 开着期间 `_followPopupPage` 冻结 `_popupPage`（详情不随
      // 轮播跳走；KOS `infoPopup.page: carousel.hoveredPage` :317 的实时
      // 跟随是本端有意偏差，记 deltas）。popup 开着时 [_syncCarouselTimer]
      // 不建表，此路径只剩滚轮切页可达。
      _followPopupPage();
    });
    // KOS `switchPage(resetTimer=true)` → carouselTimer.restart()（:143）。
    if (resetTimer && prefs.infoCardAutoRotate) {
      _syncCarouselTimer();
    }
  }

  /// `carouselTimer`（:205-213）：`autoRotate && availablePageCount>1`。
  /// KOS 的 `running:` 只有这三项、**无 hover 项**（hover 只驱动
  /// `infoPopupOpenDelay/CloseDelay`，:279-312）；本端 hover 暂停是任务卡
  /// 新增的偏差（记 docs/visual-deltas.md）——cancel/restart 重计 30s 与
  /// KOS `Timer.restart` 同式。
  void _syncCarouselTimer() {
    _carouselTimer?.cancel();
    _carouselTimer = null;
    final prefs =
        ref.read(dockPreferencesProvider).value ?? const DockPreferences();
    final order = _pageOrder(prefs.infoCardOrder);
    final media = ref.read(widget.services.media).value;
    final weather = _gatedWeather();
    final pages = _availablePages(
      order,
      hasMusic: media?.available ?? false,
      hasWeather: weather?.available ?? false,
    );
    // 记录本次求值输入：显式调用点（initState / hover / prefs 监听 / 切页）
    // 同样收敛签名，避免下一帧的 [_maybeSyncCarouselTimer] 重复建表
    // （重复建表会把 30s 重新起算）。
    _timerPages = pages;
    _timerAutoRotate = prefs.infoCardAutoRotate;
    _timerHovered = _hovered;
    // popup 开着时不建轮换表——轮播切页会带着 popup 内容跳走（popup 开时
    // `_followPopupPage` 已冻结 `_popupPage`，这里连轮换本身也停掉，记
    // deltas：KOS `carouselTimer.running` 无此项）。
    if (_portalController.isShowing) return;
    if (!prefs.infoCardAutoRotate || _hovered) return;
    if (pages.length < 2) return;
    _carouselTimer = Timer.periodic(kDockInfoCarouselInterval, (_) {
      _switchPage(resetTimer: false);
    });
  }

  /// build 期签名比较 + postFrame 复算（C1）。
  ///
  /// 页集 / `autoRotate` / hover 任一变化都无条件重算轮换表——包含
  /// 「1 页 → ≥2 页」的启动方向（KOS `running:` 绑定的等价行为）。
  void _maybeSyncCarouselTimer(
    List<int> pages,
    bool autoRotate,
    bool hovered,
  ) {
    if (_timerSyncScheduled ||
        (hovered == _timerHovered &&
            autoRotate == _timerAutoRotate &&
            listEquals(pages, _timerPages))) {
      return;
    }
    _timerSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _timerSyncScheduled = false;
      if (mounted) _syncCarouselTimer();
    });
  }

  /// `_page` 变更后（切页 / 收敛）的历史上曾让已开的详情 popup 跟随新页
  /// （KOS `infoPopup.page: carousel.hoveredPage` :317）。**popup 开着时不再
  /// 跟随**（记 deltas：KOS 的 hoveredPage≈本端 `_page`，轮播把 `_page`
  /// 切走会带着详情内容跳走；本端改为 popup 开着期间 `_popupPage` 冻结，
  /// 指针移到别的卡上由 hover 重触发 `_openPopup` 换内容）。
  /// 只换 `_popupPage`——`_popupProgress` 不动，150/140ms 显隐动画不重播。
  void _followPopupPage() {
    // `_portalController.isShowing`（popup 开着）→ 不跟随页变化。
    if (_portalController.isShowing) return;
    _popupPage = _page;
  }

  // ── KOS `pageX`（:155-161）─────────────────────────────────────────
  double _pageX(int pageIndex, double pageWidth) {
    if (_page == pageIndex) return 0;
    if (_previousPage == pageIndex) return -_transitionDirection * pageWidth;
    return _transitionDirection * pageWidth;
  }

  // ── popup（hover 420/260 节奏 + 点击即开）─────────────────────────
  void _armPopupOpen() {
    _popupCloseDelay?.cancel();
    _popupOpenDelay?.cancel();
    // popup 已开/关闭中指针回到槽 → 立即取消 closing（KOS `infoPopup` 的
    // requestClose 由 hover 回槽直接取消，DockInfoCarousel.qml:279-283）。
    if (_portalController.isShowing) {
      _openPopup();
      return;
    }
    // KOS `infoPopupOpenDelay`（:292-302）：420ms 后 openDockPopup（:300）。
    // music/metrics 页 KOS 走独立 popup 不走 infoPopup（:253-277），本端
    // 统一（记 deltas）。
    _popupOpenDelay = Timer(kDockInfoPopupOpenDelay, _openPopup);
  }

  void _armPopupClose() {
    _popupOpenDelay?.cancel();
    // KOS `infoPopupCloseDelay`（:304-312）：260ms 后若槽与 popup 都不
    // hover 则 requestClose。
    _popupCloseDelay?.cancel();
    _popupCloseDelay = Timer(kDockInfoPopupCloseDelay, () {
      if (!_hovered && !_popupPointerInside) _closePopup();
    });
  }

  /// KOS `openDockPopup`（openDelay 触发点 :300，指针换页触发点 :276）。
  /// hover 与点击共用——`popupPage` 取当前页（KOS `infoAnchor` :243-251 +
  /// `infoPopup.page: carousel.hoveredPage` :317）。
  void _openPopup() {
    if (!mounted) return;
    // KOS `activeContextMenu` 抑制预览 dwell 的同式：行内菜单开着时不开
    // 详情 popup。
    if (widget.coordinator?.menuOpen ?? false) return;
    if (!ShellSurfacePresentation.visibleOf(context)) return;
    _popupPage = _page;
    _popupOpenDelay?.cancel();
    _popupCloseDelay?.cancel();
    widget.coordinator?.activate(this); // KOS `openDockPopup` :300
    if (_portalController.isShowing) {
      // 已开或关闭中重入 → 取消 closing、forward 回弹（KOS handoff 语义）。
      _popupClosing = false;
      if (_reduceMotion) {
        _popupProgress.value = 1;
      } else {
        unawaited(_popupProgress.forward());
      }
      return;
    }
    _popupClosing = false;
    _portalController.show();
    _popupVisible = true;
    // popup 打开 → 停 30s 轮换（popup 开着时 [_syncCarouselTimer] 不建表，
    // 直接 cancel 一次，避免上一张表继续在背后切页；记 deltas）。
    _carouselTimer?.cancel();
    _popupProgress.value = 0;
    if (_reduceMotion) {
      _popupProgress.value = 1;
    } else {
      // ACCEPTANCE popup 条款：150ms OutCubic 入场（scale 0.96→1 + 20px
      // 位移由 DockInfoOverlay 的 progress 驱动）。
      unawaited(
        _popupProgress.animateTo(1, curve: Curves.easeOutCubic),
      );
    }
  }

  /// KOS `requestClose`（DockInfoPopup.qml:63 `hide()` 等价）——播 140ms
  /// InCubic 退场，dismissed 监听收 portal + `releaseDockPopup`（:318）。
  void _closePopup() {
    if (!_portalController.isShowing || _popupClosing) return;
    _popupOpenDelay?.cancel();
    _popupCloseDelay?.cancel();
    _popupClosing = true;
    if (_reduceMotion) {
      _popupProgress.value = 0; // dismissed 监听收 portal + release
    } else {
      unawaited(_popupProgress.animateBack(0, curve: Curves.easeInCubic));
    }
  }

  /// KOS `dismissDockPopupImmediately`（DockModelService.qml:56-63）：被
  /// 协调器抢占时立即收场（不播退场动画）。
  @override
  void dismissDockPopupImmediately() {
    _popupOpenDelay?.cancel();
    _popupCloseDelay?.cancel();
    _popupPointerInside = false;
    _popupClosing = false;
    _popupVisible = false;
    widget.coordinator?.release(this);
    if (_portalController.isShowing) _portalController.hide();
    _popupProgress.stop();
    _popupProgress.value = 0;
    // 被协调器硬切收掉 → 同样恢复轮换表（popup 已不在屏上）。dispose 后
    // coordinator.release 仍可能触发本方法 → ref.read 前需 mounted 门。
    if (mounted) _syncCarouselTimer();
  }

  // ── 行内容构建 ──────────────────────────────────────────────────
  Widget _cardFor(
    int page, {
    required bool pageActive,
    required DockWeatherSnapshot? weather,
    required MprisPlaybackState media,
    required MediaCommands mediaCommands,
    required DockMetricsSnapshot? metrics,
    required double? cpuFraction,
    required Uint8List? artwork,
  }) => switch (page) {
    musicPage => DockMusicCard(
      state: media,
      artwork: artwork,
      pageActive: pageActive,
      onPrevious: () => unawaited(mediaCommands.previous()),
      onPlayPause: () => unawaited(mediaCommands.playPause()),
      onNext: () => unawaited(mediaCommands.next()),
    ),
    weatherPage => DockWeatherCard(
      snapshot: weather ?? const DockWeatherSnapshot(),
    ),
    clockPage => DockClockCard(
      data: DockClockCardData(
        // KOS `SystemClock precision: Seconds`（DockInfoPopup.qml:41-44 /
        // DockClockWidget.qml:27-30）→ 本端 1Hz `_clockNow`（`_clockTicker`
        // 每秒 setState）等价；`services.clock` 是分钟级快照流，对 HH:mm:ss
        // 的秒字段无价值且会盖住秒级 tick → 不取（记 deltas）。
        now: _clockNow,
        sunrise: weather?.sunrise ?? '--:--',
        sunset: weather?.sunset ?? '--:--',
      ),
    ),
    _ => DockMetricsCard(snapshot: metrics, cpuFraction: cpuFraction),
  };

  /// KOS `detailRows()`（DockInfoPopup.qml:77-120）按页投影；music 页
  /// KOS 无 infoPopup 行——本端补标题/歌手/专辑/进度（记 deltas）。
  DockInfoContent _popupContent(
    int page, {
    required DateTime now,
    required DockWeatherSnapshot? weather,
    required MprisPlaybackState media,
    required DockMetricsSnapshot? metrics,
    required double? cpuFraction,
  }) {
    String percent(double? v) =>
        v == null ? '--' : '${(v.clamp(0.0, 1.0) * 100).round()}%';
    String thermal(int milliC) =>
        milliC >= 0 ? '${(milliC / 1000).round()}°' : '--°';
    String two(int v) => v.toString().padLeft(2, '0');
    String positionLabel() {
      final pos = media.positionAt(now);
      final len = media.length;
      String fmt(Duration d) =>
          '${d.inMinutes}:${two(d.inSeconds.remainder(60))}';
      if (len <= Duration.zero) return fmt(pos);
      return '${fmt(pos)} / ${fmt(len)}';
    }

    return switch (page) {
      clockPage => DockInfoContent(
        title: '时钟', // KOS: DockInfoPopup.qml:55
        rows: [
          DockInfoRow(
            label: '时间',
            value: // KOS: :83 `HH:mm:ss`
                '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
          ),
          DockInfoRow(
            label: '日期',
            // KOS: :84-86 `M月d日` + ` 周X`（不含年，与 KOS 逐字一致）。
            value: '${now.month}月${now.day}日 ${DockClockCard.weekdayName(now)}',
          ),
          DockInfoRow(label: '日出', value: weather?.sunrise ?? '--:--'),
          DockInfoRow(label: '日落', value: weather?.sunset ?? '--:--'),
        ],
      ),
      weatherPage => DockInfoContent(
        title: '天气', // KOS: :57
        scope: weather?.cityName, // :163-174 仅天气页 cityName
        rows: [
          DockInfoRow(
            label: '天气',
            value: weather?.available == true
                ? dockWeatherConditionText(weather!.weatherCode)
                : '--', // :93-95
          ),
          DockInfoRow(label: '气温', value: weather?.temperature ?? '--°'),
          DockInfoRow(
            label: '体感',
            value: weather?.apparentTemperature ?? '--°',
          ),
          DockInfoRow(label: '湿度', value: weather?.humidity ?? '--'),
          DockInfoRow(label: '风速', value: weather?.windSpeedLabel ?? '--'),
        ],
      ),
      metricsPage => DockInfoContent(
        title: '资源占用', // KOS: :59
        rows: [
          DockInfoRow(
            label: '平均温度',
            value: thermal(metrics?.currentMilliC ?? -1),
          ),
          DockInfoRow(
            label: '最高温度',
            value: thermal(metrics?.maximum5MinuteMilliC ?? -1),
          ),
          DockInfoRow(label: 'CPU', value: percent(cpuFraction)),
          DockInfoRow(
            label: '内存',
            value: (metrics?.memoryTotalBytes ?? 0) > 0
                ? percent(metrics!.memoryFraction)
                : '--', // :109-112
          ),
          DockInfoRow(
            label: '存储',
            value: (metrics?.diskTotalBytes ?? 0) > 0
                ? percent(metrics!.diskFraction)
                : '--', // :113-116
          ),
        ],
      ),
      musicPage => DockInfoContent(
        // KOS music 走 DockMusicPopup（无 detailRows）；本端统一面板补
        // 标题/歌手/专辑/进度行（记 deltas）。
        title: '正在播放',
        scope: media.identity.isNotEmpty ? media.identity : null,
        rows: [
          DockInfoRow(
            label: '标题',
            value: media.title.isEmpty ? 'No Track' : media.title,
            // KOS: DockMusicPlayer.qml:243
          ),
          DockInfoRow(
            label: '歌手',
            value: media.artistLabel.isEmpty ? '--' : media.artistLabel,
          ),
          DockInfoRow(
            label: '专辑',
            value: media.album.isEmpty ? '--' : media.album,
          ),
          DockInfoRow(label: '进度', value: positionLabel()),
        ],
      ),
      _ => const DockInfoContent(title: '', rows: []),
    };
  }

  /// popup 锚/屏内几何（dock_preview_popup.dart `_geometry` 同式）：anchor
  /// = 本槽位矩形（overlay 坐标系），output = 监视器 bounds ∩ overlay。
  Widget _buildInfoPopup(
    BuildContext context,
    OverlayChildLayoutInfo layout, {
    required Rect? monitorBounds,
    required DockWeatherSnapshot? weather,
    required MprisPlaybackState media,
    required DockMetricsSnapshot? metricsSnapshot,
    required double? cpuFraction,
  }) {
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final output = (monitorBounds ?? (Offset.zero & layout.overlaySize))
        .intersect(Offset.zero & layout.overlaySize);
    if (output.isEmpty) return const SizedBox.shrink();
    // KOS `SystemClock precision: Seconds`（DockInfoPopup.qml:41-44 /
    // DockClockWidget.qml:27-30）→ 详情行 `now` 同样用 1Hz `_clockNow`；
    // `services.clock` 分钟级流对 HH:mm:ss 秒字段无价值故不取（记 deltas）。
    final now = _clockNow;
    return DockInfoOverlay(
      anchor: anchor,
      output: output,
      progress: _popupProgress,
      content: _popupContent(
        _popupPage >= 0 ? _popupPage : _page,
        now: now,
        weather: weather,
        media: media,
        metrics: metricsSnapshot,
        cpuFraction: cpuFraction,
      ),
      // KOS `pointerInside`（DockInfoPopup.qml:22,219-221）：进 popup 取消
      // closeDelay，出 popup 且槽不 hover → 重启 closeDelay。
      onPointerInsideChanged: (inside) {
        _popupPointerInside = inside;
        if (inside) {
          _popupCloseDelay?.cancel();
        } else if (!_hovered) {
          _armPopupClose();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final prefsAsync = ref.watch(dockPreferencesProvider);
    final prefs = prefsAsync.value ?? const DockPreferences();
    // KOS hasMusic/hasWeather（:39-40 经 DockContainer hasPlayingMusic/
    // hasWeather 等价式）。
    final mediaAsync = ref.watch(widget.services.media);
    final media = mediaAsync.value ?? MprisPlaybackState.unavailable();
    // music 可用性**与 shell 同源门控**（`dock_shell.dart` 的 `hasAvailableInfo`
    // music 项同一表达式）：order 不含 music 时该项对 hasInfo 无贡献，此处也
    // 不把它算作可用页来源，避免「shell 判 hasInfo=true 而 carousel 认为 music
    // 不可用」的两侧漂移（`_ensureValidPage`/`_switchPage`/`_syncCarouselTimer`
    // 里的 `hasMusic` 已与 `order` 求交——页集本就由 order 过滤，等价）。
    final hasMusic = prefs.infoCardOrder.contains('music') && media.available;
    // weather 快照**只在门控打开时才订阅**（[_weatherGateOpen]：
    // [dockInfoCardNeedsWeather] = order 含 `weather` **或** 含 `clock`，且偏好
    // 已真正读到）。门控关闭 → `weather` 恒 null → weather 页不可用、clock 页的
    // 日出/日落显 `--:--`（与 KOS 无数据同）。判据与 shell
    // （`dock_shell.dart` 的 `weatherGate`）逐字同源：shell 用它决定
    // `hasAvailableInfo` 的 weather 项，carousel 用它决定是否 `ref.watch`。
    //
    // 为什么必须两处一致（复审 round-3 缺陷 1）：插件恒传非 null `infoCard`
    // （`kos_dock.dart:134`），默认 order 含 clock/metrics → `hasInfo` 首帧即真
    // → 本 carousel 一挂载只要无条件 `ref.watch` 就会 `start()` 真实 provider
    // （`state/dock_settings.dart:63-67` 的网络轮询，keepAlive 不会自行停），
    // shell 侧无论怎么门控都没用。仅当 order **既无 weather 也无 clock** 时才
    // 不订阅；默认四卡（KOS 同构）恒订阅——KOS `WeatherService` 是 shell 全局
    // 常驻服务、与卡片选中无关（`DockContainer.qml:48-49` 只决定卡是否可用），
    // 本端把订阅收敛到卡片集合属移植期收敛（记 docs/visual-deltas.md TASK-05）。
    final weather = _weatherGateOpen(prefsAsync, prefs)
        ? ref.watch(dockWeatherSnapshotProvider).value
        : null;
    final hasWeather = weather?.available ?? false;
    final needsMetrics =
        prefsAsync.hasValue && prefs.infoCardOrder.contains('metrics');
    final metricsSnapshot = needsMetrics
        ? ref.watch(dockMetricsSnapshotProvider).value
        : null;
    final cpuFraction = needsMetrics
        ? ref.watch(widget.services.cpu.select((series) => series.current))
        : null;
    final mediaCommands = ref.watch(widget.services.mediaCommands);
    final monitorBounds = ref.watch(
      widget.services.monitorBounds(widget.monitorId),
    );
    // 封面：artUrl → 本地路径（`file:` 剥前缀；http(s)/空/其它 scheme →
    // null，本端不抓网络图，记 deltas）经 `imageBytes`。
    final artPath = prefsAsync.hasValue && hasMusic
        ? dockLocalArtPath(media.artUrl)
        : null;
    final artwork = artPath == null
        ? null
        : ref.watch(widget.services.imageBytes(artPath)).value;

    final order = _pageOrder(prefs.infoCardOrder);
    final pages = _availablePages(
      order,
      hasMusic: hasMusic,
      hasWeather: hasWeather,
    );

    // prefs 异步解析/运行时切换 → order 变更收敛 + 轮换计时器复算
    // （KOS `running:` 绑定 DockInfoCarousel.qml:205-213 + `onCardOrderChanged:
    // ensureValidPage(showClock)` :202）。首帧 prefs loading 时按默认启动，
    // 解析后必须收敛；order **内容**真正变化才做 clock 收敛（loading →
    // resolved 不算，避免无谓跳页）。
    //
    // 计时器复算必须走与 build 同源的签名比较（[_maybeSyncCarouselTimer]，
    // 见 C1 注释）：KOS `running:` 是声明式绑定，**值不变时不重启 Timer**。
    // 若此处无条件调 `_syncCarouselTimer()`（cancel + 新建 30s 表），则 pin
    // 增删 / 可见性切换 / loading→data 首次解析等任何 prefs 写入都会把 30s
    // 重新起算——用户以 <30s 间隔重排 pin 时轮换永不前进。
    ref.listen(dockPreferencesProvider, (previous, next) {
      final before = previous?.value?.infoCardOrder;
      final after = next.value?.infoCardOrder;
      if (before != null && after != null && !listEquals(before, after)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureValidPage(true);
        });
      }
      // 签名（页集 + autoRotate + hover）不变 → 不重建轮换表。
      _maybeSyncCarouselTimer(pages, prefs.infoCardAutoRotate, _hovered);
    });

    // `onXxxChanged → ensureValidPage(false)`（:198-201）：可用页集变化
    // 且当前页不在其中时收敛到第一可用页。
    _maybeEnsureValidPage(pages);
    // KOS `running:` 声明式绑定（:205-213）的等价：页集 / autoRotate / hover
    // 任一变化都重算轮换表（C1——只覆盖「页失效」分支会漏掉 1→2 页启动）。
    _maybeSyncCarouselTimer(pages, prefs.infoCardAutoRotate, _hovered);

    // 槽位几何：KOS :56-57 `iconSize*widthUnits + iconSize*0.2` ×
    // `iconSize*1.2`；widthUnits=infoUnits（carousel 模式恒 4）。pageX 的
    // 位移 = cardWidth = 槽宽（carousel 模式各页同宽，widthUnits 恒 4）。
    final slotWidth = metrics.infoSlotWidth + iconSize * kDockInfoCardGapRatio;
    final slotHeight = iconSize * kDockInfoSlotHeightRatio;
    final pageWidth = slotWidth;

    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portalController,
      overlayChildBuilder: (overlayContext, layout) => _buildInfoPopup(
        overlayContext,
        layout,
        monitorBounds: monitorBounds,
        weather: weather,
        media: media,
        metricsSnapshot: metricsSnapshot,
        cpuFraction: cpuFraction,
      ),
      child: MouseRegion(
        // KOS `infoHover` HoverHandler（:279-290）：hover 变化驱动
        // openDelay/closeDelay 与 carouselTimer 暂停。
        onEnter: (_) {
          _hovered = true;
          _syncCarouselTimer();
          _armPopupOpen();
        },
        onExit: (_) {
          _hovered = false;
          _syncCarouselTimer();
          if (!_popupPointerInside) _armPopupClose();
        },
        child: GestureDetector(
          // 点击卡 → 立即开详情 popup（任务卡「hover/点击都开详情」；
          // KOS 的 editRequested 右键 :237-241 v1 忽略，记 deltas）。
          behavior: HitTestBehavior.opaque,
          onTap: _openPopup,
          child: Listener(
            // KOS MouseArea `acceptedButtons: Qt.NoButton` + onWheel
            // （:221-235）：180ms cooldown；任务卡约定 deltaY>0→下一页
            // （KOS 源 `delta >= 0 ? -1 : 1` 是 KOS 的滚轮方向约定，本端按
            // 任务卡口径取反，记 deltas）。
            onPointerSignal: (signal) {
              if (signal is! PointerScrollEvent) return;
              if (_wheelCooldown?.isActive ?? false) return;
              final delta = signal.scrollDelta.dy;
              if (delta == 0) return;
              _switchPage(resetTimer: true, direction: delta > 0 ? 1 : -1);
              _wheelCooldown?.cancel();
              _wheelCooldown = Timer(kDockInfoWheelCooldown, () {});
            },
            child: ClipRect(
              // KOS: :58 `clip: !expanded`。
              child: SizedBox(
                width: slotWidth,
                height: slotHeight,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    for (final candidate in order)
                      if (_cardVisible(
                        candidate,
                        hasMusic: hasMusic,
                        hasWeather: hasWeather,
                      ))
                        _SlidingCard(
                          key: ValueKey('dock.info.page.$candidate'),
                          // KOS `x: layoutX(candidate)`（:330 等）→
                          // 隐式动画 260ms OutCubic（:332）+ opacity
                          // 220ms OutCubic（:333）。
                          x: _pageX(candidate, pageWidth),
                          shown: _page == candidate,
                          child: _cardFor(
                            candidate,
                            pageActive: _page == candidate,
                            weather: weather,
                            media: media,
                            mediaCommands: mediaCommands,
                            metrics: metricsSnapshot,
                            cpuFraction: cpuFraction,
                            artwork: artwork,
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `onHasMusicChanged/onHasWeatherChanged/onCardOrderChanged` 的
  /// ensureValidPage 收敛（DockInfoCarousel.qml:198-202）：build 期比较
  /// 当前页是否仍在可用页集内，不在则收敛（postFrame 改状态避免 build 内
  /// setState；`_ensureScheduled` 防重入排队）。
  ///
  /// 计时器复算不在这里兜底——页集变化由 build 的
  /// [_maybeSyncCarouselTimer] 签名比较无条件覆盖（含 1→2 页与 2→1 页两个
  /// 方向）。
  void _maybeEnsureValidPage(List<int> available) {
    if (available.contains(_page) || _ensureScheduled) return;
    _ensureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureScheduled = false;
      if (!mounted) return;
      setState(() {
        _previousPage = _page;
        _page = available.isNotEmpty ? available.first : clockPage;
        _followPopupPage();
      });
    });
  }
}

/// 单卡滑动容器：x 260ms OutCubic + opacity 220ms OutCubic
/// （DockInfoCarousel.qml:332-333 等 `Behavior on x/opacity`）。
/// 非当前页 IgnorePointer——隐藏页不吃 hover/点击。
class _SlidingCard extends StatefulWidget {
  const _SlidingCard({
    required this.x,
    required this.shown,
    required this.child,
    super.key,
  });

  /// pageX 结果（px）：0=当前页；±pageWidth=入/出位置。
  final double x;
  final bool shown;
  final Widget child;

  @override
  State<_SlidingCard> createState() => _SlidingCardState();
}

class _SlidingCardState extends State<_SlidingCard> {
  late bool _keepContent = widget.shown;

  @override
  void didUpdateWidget(_SlidingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown) _keepContent = true;
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // KOS `Behavior on x`（:332 260ms OutCubic）：`Tween(end:)` 隐式动画
      // 模式——x 变化时从上值滑到新值（begin null → 首帧直接落位不播入）。
      tween: Tween(end: widget.x),
      duration: kDockInfoPageSlideDuration,
      curve: Curves.easeOutCubic,
      builder: (context, dx, child) => Transform.translate(
        offset: Offset(dx, 0),
        child: AnimatedOpacity(
          // KOS `Behavior on opacity`（:333 220ms OutCubic）。
          opacity: widget.shown ? 1 : 0,
          onEnd: () {
            if (!widget.shown && mounted) {
              setState(() => _keepContent = false);
            }
          },
          duration: kDockInfoPageFadeDuration,
          curve: Curves.easeOutCubic,
          child: IgnorePointer(ignoring: !widget.shown, child: child),
        ),
      ),
      child: _keepContent ? widget.child : const SizedBox.shrink(),
    );
  }
}
