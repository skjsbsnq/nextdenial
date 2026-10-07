/// TASK-09 控制中心弹层面板（KOS `bar/ControlCenterPanel.qml`，单窗口多卡片）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`，行号锚定）：
/// - 骨架/动画/锚定/互斥走 `dock_status_panels.dart` 的共享
///   `DockControlCenterPanelAnchor`（PopupMotion 150ms OutCubic 开 / 140ms
///   InCubic 关、scale 0.96→1、bottom dock 向上弹，KOS Panel:29-53 +
///   common/PopupMotion.qml + common/AppearanceTokens.qml:514-516）；
/// - **无面板级玻璃底板**：KOS 窗口 blur region = 各可见卡 `blurRegion` 的
///   并集（Panel:268-290），卡片间隙不糊 → 本端每张卡各自
///   `ShellBackdropBlur`（[DockStatusPanelSurface]），外层只做定位；
/// - 卡片几何/内部结构（KOS §2 卡片清单，offsetTop/offsetRight 相对 top-right
///   → 本端相对 top-left：`left = 336 - offsetRight - cardWidth`）：
///   wifi/bluetooth pill（137×59 r29.5，Panel:528-812）、媒体卡
///   （151×127 r25，:815-907）、亮度/音量条（296×57 r19，:1132-1287）；
///   52px 快捷卡（截图/主题/电源/勿扰/夜灯，:909-1129）恢复原版布局；
///   夜灯保留禁用提示，通知历史仍待实现。
/// - 子页 wifi/bluetooth/brightness/sound + 电源会话页（submenuCard 296 宽，高
///   360/340/280/420，Panel:1853-1860）：共用 header（返回钮 26 + 标题 +
///   wifi/bt 开关球 38×22，:1894-2002）+ 分隔线；页内导航 `PageMotion`
///   crossfade 200ms OutCubic + 0.96↔1 scale + 8px 位移（common/PageMotion.qml
///   :4-5、Panel:347-371）；
/// - 「坍缩回源胶囊 morph」/ thumb wobble / 通知卡 / 设置入口
///   （`settings.open kcm_*`）v1 砍掉记 deltas；
/// - 数据源：`networkConnectivityProvider`/`bluetoothProvider`（同 TASK-08，
///   子页复用 `DockWifiNetworkListBody`/`DockBluetoothDeviceListBody`）、
///   `services.media`（宿主实现即 `mediaPlaybackProvider`，
///   denial_desktop:`shell_plugin_services.dart:231-232`）/`services.mediaCommands`、
///   `audioServiceProvider`、`displayBrightnessProvider` + `displayLayoutProvider`。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/surfaces.dart' show DisplayOutput;
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/dock_tokens.dart';
import 'dock_bluetooth_panel.dart';
import 'dock_status_panels.dart';
import 'dock_wifi_panel.dart';
import 'media_art.dart';
import 'status_cells.dart';

/// 子页卡高（纯函数，可测）：KOS `ControlCenterPanel.qml:1857-1860`。
double dockControlCenterPageHeight(String page) => switch (page) {
  'wifi' => kDockControlCenterWifiPageHeight,
  'bluetooth' => kDockControlCenterBluetoothPageHeight,
  'sound' => kDockControlCenterSoundPageHeight,
  'session' => 420,
  // brightness 与未知页取 280（KOS else 分支同式）。
  _ => kDockControlCenterBrightnessPageHeight,
};

/// 蓝牙 pill 副标题的连接设备名（KOS `ControlCenterService.connectedDeviceName`，
/// 控制中心蓝牙卡 :775-777）：取首个 `connected` 设备名（匿名设备回退地址）。
String? dockBluetoothConnectedName(BluetoothState state) {
  for (final device in state.devices) {
    if (!device.connected) continue;
    return device.name.isEmpty ? device.address : device.name;
  }
  return null;
}

/// 控制中心面板宿主：26px 格外包一层 anchor（格本体 `DockControlCenterCell`
/// 的 `onToggle` 绑 [DockStatusPanelAnchorState.togglePanel]）。
class DockControlCenterPanelAnchor extends DockStatusPanelAnchor {
  const DockControlCenterPanelAnchor({
    required this.services,
    required super.coordinator,
    required super.child,
    super.key,
  });

  /// 宿主服务束（linkCursor/strings；面板数据源走全局 provider）。
  final ShellServices services;

  @override
  double get panelWidth => kDockControlCenterPanelWidth;

  /// 容器高 = 最高子页 + 上下 20（主页面与子页卡都底对齐容器；
  /// KOS dockHosted 子页 `offsetTop = height - 20 - cardHeight`，:1838-1840）。
  @override
  double get panelHeight => kDockControlCenterBoxHeight;

  @override
  double get panelRadius => kDockControlCenterRadius;

  /// 任务卡：间距同 Wi-Fi 面板 8px（KOS dockHosted `margins.bottom: 0`）。
  @override
  double get panelGap => kDockControlCenterPanelGap;

  /// KOS `open()`（Panel:427-440）：清页状态 + `ControlCenterService.refresh()`
  /// ——refresh 由面板子树首帧发（骨架无 `ref`，同 TASK-08 两面板范式）。
  @override
  void onOpened() {}

  @override
  Widget buildPanel(BuildContext context) =>
      DockControlCenterPanel(services: services);

  @override
  State<DockControlCenterPanelAnchor> createState() =>
      _DockControlCenterPanelAnchorState();
}

class _DockControlCenterPanelAnchorState
    extends DockStatusPanelAnchorState<DockControlCenterPanelAnchor> {}

/// 控制中心面板内容（overlay 子树；每张卡自带玻璃，面板本身透明）。
class DockControlCenterPanel extends ConsumerStatefulWidget {
  const DockControlCenterPanel({required this.services, super.key});

  final ShellServices services;

  @override
  ConsumerState<DockControlCenterPanel> createState() =>
      _DockControlCenterPanelState();
}

class _DockControlCenterPanelState extends ConsumerState<DockControlCenterPanel>
    with SingleTickerProviderStateMixin
    implements DockPanelEscapeHandler {
  /// 面板内容的 Esc 分步钩子宿主（anchor 的 Esc 先问本件，KOS
  /// `ControlCenterPanel.qml:512-524`）：子页开着 → 退回主页面（消费），
  /// 主页面 → 未消费 → anchor 关整面板。
  DockStatusPanelAnchorState? _anchor;

  /// 当前展示页（`''` = 主页面，其余 = 子页名，KOS `displayedPage`）。
  String _page = '';
  ProviderContainer? _sessionContainer;

  /// crossfade 出场页（KOS `outgoingPage`，动画结束后清空）。
  String? _outgoing;

  /// KOS `PageMotion.progress`：displayed 0→1、outgoing 1→0。
  late final AnimationController _pageMotion;

  // ── 音量（KOS `ControlCenterService.volumePercent/audioMuted`）──
  /// 服务侧音量 0-100（`audioService.states`/`readLevel()`）。
  double _level = 0;
  bool _muted = false;
  bool _draggingVolume = false;
  double _volumePreview = 0;

  /// `apply()` 的 `requestSerial`：单调自增，回显（同 serial）不再覆盖本地值。
  int _applySerial = 0;
  int _lastAppliedSerial = 0;

  // ── 亮度（KOS `brightnessPreview`）──
  bool _draggingBrightness = false;
  double? _brightnessPreview;

  // ── 子页数据（`audioService` 流）──
  List<AppAudioStream> _appStreams = const <AppAudioStream>[];
  List<AudioOutputDevice> _outputDevices = const <AudioOutputDevice>[];
  final _appPreviews = <int, double>{};

  /// 正在拖动应用音量行的 stream id（KOS 行内 `volumePreview` 是 delegate
  /// 局部态：拖动中不被服务值覆盖）。
  final _draggingAppIds = <int>{};

  /// 面板打开期间的周期刷新（KOS `ControlCenterService`：
  /// `audioApplicationsTimer` 1.8s（service:437-440）+
  /// `refreshTimer` 3s（`anyPanelOpen` 档，service:428-433））。
  /// 本件只在面板打开时挂载（overlay child）→ dispose 即停表。
  Timer? _appRefreshTimer;
  Timer? _refreshTimer;

  StreamSubscription<AudioLevelState>? _audioStates;
  StreamSubscription<List<AppAudioStream>>? _appStreamStates;
  StreamSubscription<List<AudioOutputDevice>>? _outputDeviceStates;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _pageMotion =
        AnimationController(
          vsync: this,
          duration: kDockControlCenterPageDuration,
        )..addStatusListener((status) {
          // crossfade 播完才丢弃出场页（KOS `outgoingPage` 同语义）。
          if (status == AnimationStatus.completed &&
              mounted &&
              _outgoing != null) {
            setState(() => _outgoing = null);
          }
        });
    // 静止态 = displayed 页完全展开（KOS progress 1）。
    _pageMotion.value = 1;
    final audio = ref.read(audioServiceProvider);
    _audioStates = audio.states.listen(_onAudioLevel);
    _appStreamStates = audio.appStreamStates.listen((streams) {
      if (!mounted) return;
      setState(() {
        _appStreams = streams;
        // KOS 的 1.8s 刷新会重建 delegate → 行内 `volumePreview` 回到服务值
        // （本地预览不长期遮蔽外部改动）；拖动中的行保留预览。
        _appPreviews.removeWhere((id, _) => !_draggingAppIds.contains(id));
      });
    });
    _outputDeviceStates = audio.outputDeviceStates.listen((devices) {
      if (mounted) setState(() => _outputDevices = devices);
    });
    // Esc 分步钩子注册（KOS `ControlCenterPanel.qml:512-524`）——面板内容挂在
    // anchor 的 overlay child 之下，`findAncestorStateOfType` 命中 anchor。
    _anchor = DockStatusPanelAnchorState.of(context);
    _anchor?.setEscapeHandler(this);
    // 开着期间的轮询（应用流 1.8s / 其余 3s，service:428-440）：SDK 侧为显式
    // 请求——冷开各发一次，之后按 KOS 周期重发（否则 `_appPreviews` 命中后
    // 服务值永不回灌，外部改动在本面板会话内不体现）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_readLevel());
      audio.requestAppStreams();
      audio.requestOutputDevices();
    });
    _appRefreshTimer = Timer.periodic(
      kDockControlCenterAppRefreshInterval,
      (_) => audio.requestAppStreams(),
    );
    _refreshTimer = Timer.periodic(kDockControlCenterRefreshInterval, (_) {
      unawaited(_readLevel());
      audio.requestOutputDevices();
    });
  }

  @override
  void dispose() {
    // 周期表与 Esc 钩子随面板卸载停/注销（面板内容只在开着时挂载）。
    final sessionContainer = _sessionContainer;
    if (sessionContainer != null) {
      final sessionSubscription = sessionContainer.listen(
        sessionPowerProvider.notifier,
        (_, _) {},
      );
      // Closing the popup disposes this widget during tree finalization.
      // Clear the shared confirmation after that lifecycle phase has ended.
      scheduleMicrotask(() {
        if (!sessionSubscription.closed) {
          sessionSubscription.read().cancelConfirmation();
          sessionSubscription.close();
        }
      });
    }
    _appRefreshTimer?.cancel();
    _refreshTimer?.cancel();
    _anchor?.setEscapeHandler(null);
    unawaited(_audioStates?.cancel());
    unawaited(_appStreamStates?.cancel());
    unawaited(_outputDeviceStates?.cancel());
    _pageMotion.dispose();
    super.dispose();
  }

  Future<void> _readLevel() async {
    final level = await ref.read(audioServiceProvider).readLevel();
    if (!mounted || level == null) return;
    setState(() => _applyLevel(level, muted: null));
  }

  void _applyLevel(double level, {bool? muted}) {
    _level = (level.clamp(0.0, 1.0) * 100).roundToDouble();
    if (muted != null) _muted = muted;
    if (!_draggingVolume) _volumePreview = _level;
  }

  /// `audioService.states` → 本地音量/静音（KOS
  /// `ControlCenterService.volumePercent/audioMuted`）。
  ///
  /// `requestSerial` 命中本端最近一次 `apply()` 时是自身回写回显，跳过以
  /// 免拖动被拉回（KOS 侧靠 `volumeChangeInProgress` 抑制，SDK 无该标记
  /// → 记 docs/dock-port/TASK-09-control-center.md）。
  void _onAudioLevel(AudioLevelState state) {
    if (_lastAppliedSerial != 0 && state.requestSerial == _lastAppliedSerial) {
      return;
    }
    setState(() => _applyLevel(state.level, muted: state.muted));
  }

  void _applyVolume(double percent) {
    final serial = ++_applySerial;
    _lastAppliedSerial = serial;
    // KOS `setVolume(0-100)`（service:80）→ SDK `apply(percent)`。
    ref
        .read(audioServiceProvider)
        .apply(percent.round().clamp(0, 100), requestSerial: serial);
  }

  /// KOS `Shortcut { sequence: "Escape" }`（Panel:512-524）的分步：确认框
  /// 先取消会话确认，再退回主页面；
  /// 已回主页面 → false（未消费）→ anchor 关整面板。
  @override
  bool handleEscapeStep() {
    if (_page == 'session' &&
        ref.read(sessionPowerProvider).confirmationAction != null) {
      ref.read(sessionPowerProvider.notifier).cancelConfirmation();
      return true;
    }
    if (_page.isEmpty) return false;
    _openPage('');
    return true;
  }

  /// 子页导航（KOS `openSubmenu`/`closeSubmenu`，Panel:87-116）：crossfade
  /// 200ms OutCubic，入场页 scale 0.96→1 + 8px 位移，出场页 1→0.96。
  ///
  /// 改道续播（KOS `KosPageMotion.reconcile()` crossfade 档，
  /// `shared/qml/foundation/KosPageMotion.qml:34-56`：「no snap, no empty
  /// frame」）：progress < 1 时**不重置为 0**，从当前进度续播并按剩余量缩短
  /// 时长（`enterDuration * (1 - progress)`）；progress 已到 1 才从 0 起播。
  void _openPage(String page) {
    if (_page == page) return;
    if (_page == 'session') {
      ref.read(sessionPowerProvider.notifier).cancelConfirmation();
    }
    if (page == 'session') {
      _sessionContainer = ProviderScope.containerOf(context, listen: false);
      ref.read(sessionPowerProvider.notifier).clearError();
    }
    final previous = _page;
    setState(() {
      _outgoing = previous;
      _page = page;
    });
    if (_reduceMotion) {
      _pageMotion.value = 1;
      setState(() => _outgoing = null);
      return;
    }
    final progress = _pageMotion.value;
    if (progress >= 1) {
      unawaited(_pageMotion.forward(from: 0));
      return;
    }
    unawaited(
      _pageMotion.animateTo(
        1,
        duration: Duration(
          milliseconds: math.max(
            1,
            (kDockControlCenterPageDuration.inMilliseconds * (1 - progress))
                .round(),
          ),
        ),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// KOS `panel.pageFactor(pageTag)`：displayed → progress、outgoing →
  /// 1−progress、其余 0（Panel:347-353）。
  double _pageFactor(String tag) {
    if (tag == _page) return _pageMotion.value;
    if (tag == _outgoing) return 1 - _pageMotion.value;
    return 0;
  }

  /// 内容高（当前页）：主页面 297 / 子页卡高 + 下边距 20（KOS :1838-1840）。
  double get _contentHeight => _page.isEmpty
      ? kDockControlCenterMainHeight
      : dockControlCenterPageHeight(_page) + kDockControlCenterMargin;

  /// 页 crossfade 由 [_pageMotion] 驱动：整块内容随其 tick 重建
  /// （KOS `PageMotion` 的 progress 直接绑到卡的 opacity/scale/contentOffsetY）。
  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _pageMotion, builder: _buildPanel);

  Widget _buildPanel(BuildContext context, Widget? _) {
    final mainFactor = _pageFactor('');
    final subPage = _page.isNotEmpty ? _page : (_outgoing ?? '');
    final subFactor = subPage.isEmpty ? 0.0 : _pageFactor(subPage);
    final progress = _pageMotion.value;
    return Stack(
      children: [
        // 卡间隙吸收点击（KOS 面板是独立 popup 窗口，整窗收输入，
        // Panel:39 `mask: interactive ? null : emptyRegion`）；内容区之外的
        // 空白仍落回 anchor 屏障 → 点外即关。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _contentHeight,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {},
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        if (mainFactor > 0.001)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              // 出场中不再收输入（KOS 出场卡 `enabled: false`，Panel:373-376）。
              ignoring: _page.isNotEmpty,
              child: _pageTransform(
                factor: mainFactor,
                incoming: _page.isEmpty,
                progress: progress,
                child: SizedBox(
                  height: kDockControlCenterMainHeight,
                  child: _mainPage(context),
                ),
              ),
            ),
          ),
        if (subPage.isNotEmpty && subFactor > 0.001)
          Positioned(
            left: kDockControlCenterMargin,
            bottom: kDockControlCenterMargin,
            width: kDockControlCenterSubmenuWidth,
            child: IgnorePointer(
              ignoring: subFactor < 0.99,
              child: _pageTransform(
                factor: subFactor,
                incoming: _page == subPage,
                progress: progress,
                // 页键挂在 crossfade 变换**之内**（`cc.page.<name>`），
                // 便于测试读该页的 opacity/scale 进度。
                child: KeyedSubtree(
                  key: ValueKey<String>('cc.page.$subPage'),
                  child: SizedBox(
                    height: dockControlCenterPageHeight(subPage),
                    child: _subPage(context, subPage),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 页 crossfade 变换：opacity = factor、入场 scale 0.96→1（出场 1→0.96）、
  /// 入场内容偏移 +8px（KOS Panel:347-371；锚在底边）。
  Widget _pageTransform({
    required double factor,
    required bool incoming,
    required double progress,
    required Widget child,
  }) {
    final scale = incoming
        ? kDockControlCenterPageStartScale +
              (1 - kDockControlCenterPageStartScale) * progress
        : 1 - (1 - kDockControlCenterPageStartScale) * progress;
    final offsetY = incoming
        ? kDockControlCenterPageOffset * (1 - progress)
        : 0.0;
    return DockStatusPanelFade(
      opacity: factor.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, offsetY),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 主页面
  // ══════════════════════════════════════════════════════════════════

  Widget _mainPage(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final services = widget.services;
    final net = ref.watch(networkConnectivityProvider);
    final bt = ref.watch(bluetoothProvider);
    final snapshot = net.snapshot;
    final media =
        ref.watch(services.media).value ?? MprisPlaybackState.unavailable();
    final layout = ref.watch(displayLayoutProvider);
    final brightness = ref.watch(displayBrightnessProvider);
    final primary = layout?.mainOutput;
    final level = primary == null ? null : brightness.levels[primary.monitorId];
    final brightnessValue = _draggingBrightness
        ? _brightnessPreview
        : (level == null ? null : level * 100);
    final connectedNetwork = snapshot.connectedNetwork;

    return Stack(
      children: [
        // ── Wi-Fi pill（KOS :528-658）──
        Positioned(
          key: const ValueKey<String>('cc.wifiPill'),
          left: kDockControlCenterColumnLeft,
          top: kDockControlCenterWifiTop,
          width: kDockControlCenterPillWidth,
          height: kDockControlCenterPillHeight,
          child: DockControlCenterPill(
            title: 'Wi-Fi',
            subtitle: snapshot.wirelessEnabled
                ? (connectedNetwork?.ssid.isNotEmpty ?? false
                      ? connectedNetwork!.ssid
                      : '未连接')
                : '已关闭',
            checked: snapshot.wirelessEnabled,
            available: snapshot.wifiDeviceAvailable,
            busy: net.scanning || net.radioChanging,
            cursor: services.linkCursor,
            buildDiscGlyph: (context, checked) => DockWifiSignalIcon(
              enabled: snapshot.wirelessEnabled,
              connected: connectedNetwork != null,
              strength: connectedNetwork?.strength ?? -1,
              size: kDockControlCenterPillGlyphSize,
              color: checked
                  ? theme.accentPalette.onPrimary
                  : colors.textPrimary,
            ),
            onToggle: () => unawaited(
              ref
                  .read(networkConnectivityProvider.notifier)
                  .setWirelessEnabled(!snapshot.wirelessEnabled),
            ),
            onOpenPage: () => _openPage('wifi'),
          ),
        ),
        // ── 蓝牙 pill（KOS :662-812）──
        Positioned(
          key: const ValueKey<String>('cc.btPill'),
          left: kDockControlCenterColumnLeft,
          top: kDockControlCenterBluetoothTop,
          width: kDockControlCenterPillWidth,
          height: kDockControlCenterPillHeight,
          child: DockControlCenterPill(
            title: '蓝牙',
            // KOS: :775-777 — `bluetoothPowered ? (connectedDeviceName ||
            // "未连接") : "已关闭"`；SDK 无 connectedDeviceName，
            // 取第一个 connected 设备（KOS ControlCenterService 同源语义）。
            subtitle: bt.powered
                ? (dockBluetoothConnectedName(bt) ?? '未连接')
                : '已关闭',
            checked: bt.powered,
            available: bt.available,
            busy: bt.powerChanging || bt.refreshing,
            cursor: services.linkCursor,
            buildDiscGlyph: (context, checked) => DockBluetoothGlyph(
              color: checked
                  ? theme.accentPalette.onPrimary
                  : colors.textPrimary,
              size: kDockControlCenterPillGlyphSize,
            ),
            onToggle: () =>
                unawaited(ref.read(bluetoothProvider.notifier).togglePower()),
            onOpenPage: () => _openPage('bluetooth'),
          ),
        ),
        // ── 媒体卡（KOS :815-907）──
        Positioned(
          key: const ValueKey<String>('cc.mediaCard'),
          left: kDockControlCenterMediaLeft,
          top: kDockControlCenterMediaTop,
          width: kDockControlCenterMediaWidth,
          height: kDockControlCenterMediaHeight,
          child: _mediaCard(context, media),
        ),
        // ── 亮度条（KOS :1132-1198）──
        Positioned(
          key: const ValueKey<String>('cc.brightnessBar'),
          left: kDockControlCenterMargin,
          top: kDockControlCenterBrightnessTop,
          width: kDockControlCenterBarWidth,
          height: kDockControlCenterBarHeight,
          child: _levelBar(
            context,
            hotKey: const ValueKey<String>('cc.brightnessHot'),
            sliderKey: const ValueKey<String>('cc.brightnessSlider'),
            label: '显示亮度',
            valueText: brightnessValue == null
                ? '无亮度设备'
                : '${brightnessValue.round()}\u00a0%',
            glyph: const Text(
              '☀',
              style: TextStyle(
                fontSize: kDockControlCenterSunGlyphSize,
                height: 1.0,
              ),
            ),
            valueRight: kDockControlCenterBarValueRight,
            valueSize: kDockControlCenterBarValueSize,
            valueAlpha: kDockControlCenterBarValueAlpha,
            hotZone: kDockControlCenterBrightnessHotZone,
            sliderLeft: kDockControlCenterBrightnessSliderLeft,
            sliderRight: kDockControlCenterBrightnessSliderRight,
            sliderEnabled: level != null,
            onOpenPage: () => _openPage('brightness'),
            slider: DockControlCenterSlider(
              value: (brightnessValue ?? 0) / 100,
              enabled: level != null,
              onPreviewChanged: (value) {
                if (primary == null) return;
                setState(() {
                  _draggingBrightness = true;
                  _brightnessPreview = value * 100;
                  // KOS `previewChanged` 只改本地预览；SDK 的 `setLevel` 是
                  // 90ms 去抖档，等价拖动实时预览（display_brightness.dart:58-64）。
                  ref
                      .read(displayBrightnessProvider.notifier)
                      .setLevel(primary, value);
                });
              },
              onCanceled: () => setState(() {
                _draggingBrightness = false;
                _brightnessPreview = null;
              }),
              onCommitRequested: (value) {
                if (primary == null) return;
                setState(() {
                  _draggingBrightness = false;
                  _brightnessPreview = value * 100;
                });
                // KOS `commitRequested → setBrightness`（Panel:1186-1189）→
                // SDK 立即提交 `commitLevel`（`setLevel` 是拖动去抖档）。
                ref
                    .read(displayBrightnessProvider.notifier)
                    .commitLevel(primary, value);
              },
            ),
          ),
        ),
        // ── 音量条（KOS :1201-1287）──
        Positioned(
          key: const ValueKey<String>('cc.volumeBar'),
          left: kDockControlCenterMargin,
          top: kDockControlCenterVolumeTop,
          width: kDockControlCenterBarWidth,
          height: kDockControlCenterBarHeight,
          child: _levelBar(
            context,
            hotKey: const ValueKey<String>('cc.volumeHot'),
            sliderKey: const ValueKey<String>('cc.volumeSlider'),
            label: '声音',
            valueText: '${_volumePreview.round()}\u00a0%',
            glyph: CustomPaint(
              size: const Size.square(kDockControlCenterVolumeGlyphSize),
              painter: DockControlCenterVolumeGlyph(
                color: colors.textPrimary,
                muted: _muted,
              ),
            ),
            valueRight: kDockControlCenterSoundValueRight,
            valueSize: kDockControlCenterSoundValueSize,
            valueAlpha: kDockControlCenterSoundValueAlpha,
            hotZone: kDockControlCenterSoundHotZone,
            sliderLeft: kDockControlCenterVolumeSliderLeft,
            sliderRight: kDockControlCenterVolumeSliderRight,
            sliderEnabled: true,
            onOpenPage: () => _openPage('sound'),
            slider: DockControlCenterSlider(
              value: _volumePreview / 100,
              onPreviewChanged: (value) => setState(() {
                _draggingVolume = true;
                _volumePreview = value * 100;
              }),
              onCanceled: () => setState(() {
                _draggingVolume = false;
                _volumePreview = _level;
              }),
              onCommitRequested: (value) {
                setState(() {
                  _draggingVolume = false;
                  _volumePreview = value * 100;
                });
                _applyVolume(value * 100);
              },
            ),
          ),
        ),
        for (final (index, id, label, icon, active, callback) in [
          (
            0,
            'screenshot',
            '截图',
            Icons.screenshot_monitor,
            false,
            () {
              final actions = ref.read(systemActionsServiceProvider);
              _anchor?.togglePanel();
              // Wait for the popup exit animation before capturing the desktop.
              unawaited(
                Future<void>.delayed(
                  const Duration(milliseconds: 260),
                  actions.takeScreenshot,
                ),
              );
            },
          ),
          (
            1,
            'theme',
            '深色模式',
            Icons.dark_mode_outlined,
            theme.brightness == Brightness.dark,
            () {
              ref
                  .read(shellSettingsProvider.notifier)
                  .setColorSchemePreference(
                    theme.brightness == Brightness.dark
                        ? DesktopColorSchemePreference.preferLight
                        : DesktopColorSchemePreference.preferDark,
                  );
            },
          ),
          (
            2,
            'power',
            '电源',
            Icons.power_settings_new,
            false,
            () => _openPage('session'),
          ),
          (
            3,
            'dnd',
            '勿扰',
            Icons.notifications_off_outlined,
            ref.watch(desktopNotificationsProvider).doNotDisturb,
            () => ref
                .read(desktopNotificationsProvider.notifier)
                .toggleDoNotDisturb(),
          ),
          (
            4,
            'nightlight',
            '夜灯（当前 SDK 不支持）',
            Icons.nightlight_outlined,
            false,
            null,
          ),
        ])
          Positioned(
            left: 20 + index * 61,
            top: 155,
            width: 52,
            height: 52,
            child: Tooltip(
              message: label,
              child: DockStatusPanelSurface(
                radius: 26,
                child: IconButton(
                  key: ValueKey<String>('cc.$id'),
                  tooltip: label,
                  onPressed: callback,
                  icon: Icon(
                    icon,
                    color: active ? theme.accent : null,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 媒体卡（KOS :815-907）：43×43 专辑图 + 标题/艺术家 + prev/play/next。
  Widget _mediaCard(BuildContext context, MprisPlaybackState media) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final commands = ref.watch(widget.services.mediaCommands);
    // 专辑图：SDK 只保证 `artUrl` 是 `file:`/`http:`/`https:` URI
    // （`mpris_playback_protocol.dart:200-207`），而 `imageBytes` 是裸路径
    // 加载器（宿主 `File(path)`）——必须剥 `file:` 才是本地路径；http(s)
    // 无通道 → 占位（`dockLocalArtPath`，与音乐卡同式）。
    final artPath = dockLocalArtPath(media.artUrl);
    final artBytes = artPath == null
        ? const AsyncValue<Uint8List?>.data(null)
        : ref.watch(widget.services.imageBytes(artPath));
    final placeholder = Center(
      child: Text(
        '♫',
        style: TextStyle(
          fontSize: kDockControlCenterMediaPlaceholderSize,
          color: colors.textPrimary.withValues(
            alpha: kDockControlCenterMediaPlaceholderAlpha,
          ),
          height: 1.0,
        ),
      ),
    );
    return DockStatusPanelSurface(
      radius: kDockControlCenterMediaRadius,
      child: Stack(
        children: [
          Positioned(
            left: kDockControlCenterMediaArtLeft,
            top: kDockControlCenterMediaArtTop,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                kDockControlCenterMediaArtRadius,
              ),
              child: Container(
                width: kDockControlCenterMediaArtSize,
                height: kDockControlCenterMediaArtSize,
                color: colors.tileOff,
                child: switch (artBytes.value) {
                  final Uint8List bytes? when bytes.isNotEmpty => Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    // 媒体封面原图远大于 kDockControlCenterMediaArtSize
                    // 缩略框：medium 双线性降采样消边缘锯齿。
                    filterQuality: FilterQuality.medium,
                  ),
                  _ => placeholder,
                },
              ),
            ),
          ),
          Positioned(
            left:
                kDockControlCenterMediaArtLeft +
                kDockControlCenterMediaArtSize +
                kDockControlCenterMediaTextLeft,
            right: kDockControlCenterMediaTextRight,
            top: kDockControlCenterMediaArtTop,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // KOS: :864 — `trackTitle || "未在播放"`。
                  media.title.isEmpty ? '未在播放' : media.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // KOS: :867 — 12px Bold。
                    fontSize: kDockControlCenterMediaTitleSize,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // KOS: :871 — `trackArtist || "媒体控制"`（SDK 无 loading 文案）。
                  media.artistLabel.isEmpty ? '媒体控制' : media.artistLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // KOS: :875 — 10px @0.70。
                    fontSize: kDockControlCenterMediaArtistSize,
                    color: colors.textPrimary.withValues(
                      alpha: kDockControlCenterMediaArtistAlpha,
                    ),
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            // KOS: :879 — `bottomMargin: 15`。
            bottom: kDockControlCenterMediaControlsBottom,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _TransportButton(
                  key: const ValueKey<String>('cc.media.previous'),
                  size: kDockControlCenterMediaNavSize,
                  glyph: Icons.skip_previous_rounded,
                  color: colors.textPrimary,
                  enabled: media.canGoPrevious,
                  cursor: widget.services.linkCursor,
                  onTap: () => unawaited(commands.previous()),
                ),
                // KOS: :881 — `spacing: 12`。
                const SizedBox(width: kDockControlCenterMediaControlsSpacing),
                _TransportButton(
                  key: const ValueKey<String>('cc.media.toggle'),
                  size: kDockControlCenterMediaPlaySize,
                  glyph: media.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: theme.accentPalette.onPrimary,
                  background: theme.accent,
                  enabled: media.playing ? media.canPause : media.canPlay,
                  cursor: widget.services.linkCursor,
                  onTap: () => unawaited(commands.playPause()),
                ),
                const SizedBox(width: kDockControlCenterMediaControlsSpacing),
                _TransportButton(
                  key: const ValueKey<String>('cc.media.next'),
                  size: kDockControlCenterMediaNavSize,
                  glyph: Icons.skip_next_rounded,
                  color: colors.textPrimary,
                  enabled: media.canGoNext,
                  cursor: widget.services.linkCursor,
                  onTap: () => unawaited(commands.next()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 亮度/音量条共用骨架（KOS :1132-1198 / :1201-1287）：标题 + 右上值 +
  /// 「›」+ 顶部热区（开子页）+ 左下 glyph + 底部滑条。
  Widget _levelBar(
    BuildContext context, {
    required Key hotKey,
    required Key sliderKey,
    required String label,
    required String valueText,
    required Widget glyph,
    required double valueRight,
    required double valueSize,
    required double valueAlpha,
    required double hotZone,
    required double sliderLeft,
    required double sliderRight,
    required bool sliderEnabled,
    required VoidCallback onOpenPage,
    required DockControlCenterSlider slider,
  }) {
    final colors = context.shellColors;
    return DockStatusPanelSurface(
      radius: kDockControlCenterBarRadius,
      child: Stack(
        children: [
          // 顶部热区（KOS :1166-1172 / :1228-1234）→ 开对应子页。
          Positioned(
            key: hotKey,
            left: 0,
            right: 0,
            top: 0,
            height: hotZone,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenPage,
              child: MouseRegion(cursor: widget.services.linkCursor),
            ),
          ),
          Positioned(
            left: kDockControlCenterBarLabelLeft,
            top: kDockControlCenterBarLabelTop,
            child: Text(
              label,
              style: TextStyle(
                // KOS: :1150/:1219 — 11px DemiBold。
                fontSize: kDockControlCenterBarLabelSize,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
          ),
          Positioned(
            right: valueRight,
            top: kDockControlCenterBarLabelTop,
            child: Text(
              valueText,
              style: ShellText.systemBarValue.copyWith(
                // Use the official shell's bundled numeric face. At fractional
                // display scale the old 9/10px values have too few pixels for
                // their thin stems; keep at least the shell caption's 11px.
                fontSize: math.max(valueSize, 11),
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
                color: colors.textPrimary.withValues(alpha: valueAlpha),
                height: 1.0,
              ),
            ),
          ),
          Positioned(
            right: kDockControlCenterBarChevronRight,
            top: kDockControlCenterBarChevronTop,
            child: Text(
              '›',
              style: TextStyle(
                // KOS: :1164 — 15px Bold。
                fontSize: kDockControlCenterBarChevronSize,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
          ),
          Positioned(
            left: kDockControlCenterBarGlyphLeft,
            bottom: kDockControlCenterBarGlyphBottom,
            child: Opacity(
              // KOS: :1195 — 「☀」@0.65。
              opacity: kDockControlCenterBarGlyphAlpha,
              child: glyph,
            ),
          ),
          Positioned(
            left: sliderLeft,
            right: sliderRight,
            bottom: kDockControlCenterSliderBottom,
            height: kDockControlCenterSliderHeight,
            child: IgnorePointer(
              ignoring: !sliderEnabled,
              child: Opacity(
                // KOS `LiquidSlider.qml:97` — `opacity: enabled ? 1.0 : 0.45`。
                opacity: sliderEnabled ? 1 : 0.45,
                child: KeyedSubtree(key: sliderKey, child: slider),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 子页
  // ══════════════════════════════════════════════════════════════════

  Widget _subPage(BuildContext context, String page) => DockStatusPanelSurface(
    // KOS: :1846-1852 — 子页卡基础半径 22（源胶囊半径仅 morph 时用到，v1 砍）。
    radius: kDockControlCenterRadius,
    child: Column(
      children: [
        _pageHeader(context, page),
        // KOS: :2005-2013 — 分隔线 `top: header.bottom + 9`、左右 12。
        const SizedBox(height: kDockControlCenterDividerTop),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(height: 1, color: context.shellColors.hairline),
        ),
        Expanded(child: _pageBody(context, page)),
      ],
    ),
  );

  /// 共用 header（KOS :1894-2002）：返回钮 26×26 r13 + 标题 + wifi/bt 开关球。
  Widget _pageHeader(BuildContext context, String page) {
    final colors = context.shellColors;
    final title = switch (page) {
      'wifi' => 'Wi-Fi',
      'bluetooth' => '蓝牙',
      'brightness' => '显示亮度',
      'sound' => '声音',
      'session' => '电源与会话',
      _ => '',
    };
    final Widget? trailing = switch (page) {
      'wifi' => _pageToggle(
        checked: ref
            .watch(networkConnectivityProvider)
            .snapshot
            .wirelessEnabled,
        busy: ref.watch(networkConnectivityProvider).radioChanging,
        onToggle: () => unawaited(
          ref
              .read(networkConnectivityProvider.notifier)
              .setWirelessEnabled(
                !ref.read(networkConnectivityProvider).snapshot.wirelessEnabled,
              ),
        ),
      ),
      'bluetooth' => _pageToggle(
        checked: ref.watch(bluetoothProvider).powered,
        busy: ref.watch(bluetoothProvider).powerChanging,
        onToggle: () =>
            unawaited(ref.read(bluetoothProvider.notifier).togglePower()),
      ),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(
        top: kDockControlCenterHeaderTop,
        left: kDockControlCenterHeaderSideMargin,
        right: kDockControlCenterHeaderSideMargin,
      ),
      child: SizedBox(
        height: kDockControlCenterHeaderHeight,
        child: Row(
          children: [
            // 返回钮（KOS :1908-1940）：「‹」18 Bold、按下 0.92。
            GestureDetector(
              key: const ValueKey<String>('cc.page.back'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _openPage(''),
              child: MouseRegion(
                cursor: widget.services.linkCursor,
                child: Container(
                  width: kDockControlCenterBackSize,
                  height: kDockControlCenterBackSize,
                  decoration: BoxDecoration(
                    color: colors.tileOff,
                    borderRadius: BorderRadius.circular(
                      kDockControlCenterBackRadius,
                    ),
                    border: Border.all(color: colors.hairlineSoft),
                  ),
                  child: Center(
                    child: Text(
                      '‹',
                      style: TextStyle(
                        fontSize: kDockControlCenterBackGlyphSize,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: kDockControlCenterTitleLeft),
            Text(
              title,
              style: TextStyle(
                // KOS: :1954 — 13px Bold。
                fontSize: kDockControlCenterTitleSize,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// wifi/bt 子页右侧开关球（KOS :1958-2000）：38×22 r11、thumb 18、
  /// x 160ms OutCubic、toggle 中 opacity .6。
  Widget _pageToggle({
    required bool checked,
    required bool busy,
    required VoidCallback onToggle,
  }) => _DockControlCenterSwitch(
    checked: checked,
    busy: busy,
    cursor: widget.services.linkCursor,
    onToggle: onToggle,
  );

  Widget _sessionPage(BuildContext context) {
    final state = ref.watch(sessionPowerProvider);
    final controller = ref.read(sessionPowerProvider.notifier);
    const labels = {
      SessionPowerAction.lock: '锁定',
      SessionPowerAction.logout: '注销',
      SessionPowerAction.suspend: '睡眠',
      SessionPowerAction.hibernate: '休眠',
      SessionPowerAction.reboot: '重启',
      SessionPowerAction.powerOff: '关机',
    };
    final confirmation = state.confirmationAction;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (state.error != null)
          Text(
            state.error!,
            style: TextStyle(color: context.shellColors.textPrimary),
          ),
        if (confirmation != null) ...[
          Text(
            '确认${labels[confirmation]}？',
            style: TextStyle(color: context.shellColors.textPrimary),
          ),
          TextButton(
            onPressed: state.busy ? null : controller.cancelConfirmation,
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('cc.session.confirm'),
            onPressed: state.busy
                ? null
                : () => unawaited(controller.confirm()),
            child: Text('确认${labels[confirmation]}'),
          ),
        ] else
          for (final action in SessionPowerAction.values)
            ListTile(
              key: ValueKey<String>('cc.session.${action.name}'),
              title: Text(labels[action]!),
              subtitle: state.availabilityFor(action).unavailableReason == null
                  ? null
                  : Text(state.availabilityFor(action).unavailableReason!),
              enabled: !state.busy && state.availabilityFor(action).enabled,
              onTap: () => unawaited(controller.request(action)),
            ),
      ],
    );
  }

  Widget _pageBody(BuildContext context, String page) => switch (page) {
    'session' => _sessionPage(context),
    'wifi' => _wifiPage(context),
    'bluetooth' => _bluetoothPage(context),
    'brightness' => _brightnessPage(context),
    'sound' => _soundPage(context),
    _ => const SizedBox.shrink(),
  };

  /// wifi 子页（KOS :2019-2286）：关态提示；开态「附近网络」+ 列表（复用
  /// TASK-08 行件，行高 42）+ 「网络设置…」禁用底脚。
  Widget _wifiPage(BuildContext context) {
    final net = ref.watch(networkConnectivityProvider);
    final enabled = net.snapshot.wirelessEnabled;
    if (!enabled) {
      // KOS: :2032-2052 — 「Wi‑Fi 已关闭」14 Bold + 说明 12 DemiBold。
      return _pageOffState(context, title: 'Wi-Fi 已关闭', body: '在上方开启开关以查看附近网络');
    }
    return Column(
      children: [
        _sectionHeader(
          context,
          title: '附近网络',
          trailing: net.scanning ? '正在扫描…' : null,
        ),
        const SizedBox(height: 2),
        Expanded(
          child: DockWifiNetworkListBody(
            services: widget.services,
            rowHeight: kDockControlCenterPageRowHeight,
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
          ),
        ),
        _pageFooter(context, '网络设置…'),
      ],
    );
  }

  /// 蓝牙子页（KOS :2288-2516）：关态提示；开态「设备」+ 列表 + 底脚。
  Widget _bluetoothPage(BuildContext context) {
    final bt = ref.watch(bluetoothProvider);
    if (!bt.powered) {
      // KOS: :2300-2320 — 「蓝牙已关闭」13 Bold + 说明 11。
      return _pageOffState(context, title: '蓝牙已关闭', body: '在上方开启开关以连接设备');
    }
    return Column(
      children: [
        _sectionHeader(
          context,
          title: '设备',
          trailing: bt.refreshing || bt.scanning ? '正在刷新…' : null,
        ),
        Expanded(
          child: DockBluetoothDeviceListBody(
            services: widget.services,
            rowHeight: kDockControlCenterPageRowHeight,
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            // 小节头已画「正在刷新…」（KOS :2344-2370）→ 列表体不重复。
            refreshLabelInHeader: true,
          ),
        ),
        _pageFooter(context, '蓝牙设置…'),
      ],
    );
  }

  /// 亮度子页（KOS :2519-2625）：每显示器一行 82px（label + % + 滑条）。
  ///
  /// SDK `DisplayOutput` 无 `isInternal` 字段 → KOS 的「内置屏幕/外接显示器」
  /// 副行省略（记 docs/dock-port/TASK-09-control-center.md）。
  Widget _brightnessPage(BuildContext context) {
    final colors = context.shellColors;
    final layout = ref.watch(displayLayoutProvider);
    final brightness = ref.watch(displayBrightnessProvider);
    final outputs = layout?.outputs ?? const <DisplayOutput>[];
    final adjustable = outputs
        .where((output) => brightness.levels.containsKey(output.monitorId))
        .toList(growable: false);
    return Column(
      children: [
        const SizedBox(height: 8),
        Expanded(
          child: adjustable.isEmpty
              // KOS: :2590-2596 — 「未发现可调节亮度的显示器」。
              ? Center(
                  child: Text(
                    '未发现可调节亮度的显示器',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textPrimary.withValues(
                        alpha: kDockControlCenterSectionTitleAlpha,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kDockControlCenterPageListMargin,
                  ),
                  itemCount: adjustable.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) => SizedBox(
                    height: kDockControlCenterBrightnessRowHeight,
                    child: _brightnessRow(context, adjustable[index]),
                  ),
                ),
        ),
        _pageFooter(context, '显示设置…'),
      ],
    );
  }

  /// 亮度子页行（KOS :2545-2587）：label 11 DemiBold + 「%」10 + 滑条 bottom 3。
  Widget _brightnessRow(BuildContext context, DisplayOutput output) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final levels = ref.watch(displayBrightnessProvider).levels;
    final level = levels[output.monitorId] ?? 0;
    final preview = _brightnessPreview;
    final dragging =
        _draggingBrightness && _brightnessOutputId == output.monitorId;
    final value = dragging ? (preview ?? level * 100) : level * 100;
    return Stack(
      children: [
        Text(
          // KOS: :2554 — `label || id || "显示器"`；SDK 只有输出名。
          output.name.isEmpty ? '显示器' : output.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
            height: 1.0,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: Text(
            // KOS: :2562 — `Math.round(preview) + "%"`。
            '${value.round()}%',
            style: TextStyle(
              fontSize: 10,
              color: colors.textPrimary,
              height: 1.0,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 3,
          height: kDockControlCenterSliderHeight,
          child: DockControlCenterSlider(
            value: value / 100,
            onPreviewChanged: (next) => setState(() {
              _draggingBrightness = true;
              _brightnessOutputId = output.monitorId;
              _brightnessPreview = next * 100;
              ref
                  .read(displayBrightnessProvider.notifier)
                  .setLevel(output, next);
            }),
            onCanceled: () => setState(() {
              _draggingBrightness = false;
              _brightnessOutputId = null;
              _brightnessPreview = null;
            }),
            onCommitRequested: (next) {
              setState(() {
                _draggingBrightness = false;
                _brightnessOutputId = null;
                _brightnessPreview = next * 100;
              });
              ref
                  .read(displayBrightnessProvider.notifier)
                  .commitLevel(output, next);
            },
            trackColor: colors.brightnessTrack,
            accentColor: theme.accent,
            thumbColor: colors.sliderThumb,
          ),
        ),
      ],
    );
  }

  /// 声音子页（KOS :2627-3022）：主音量区 62 + 输出设备 52 + 应用音量行 58。
  Widget _soundPage(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final apps = _appStreams
        .take(kDockControlCenterAppRowCount)
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: 6,
            left: kDockControlCenterPageListMargin,
            right: kDockControlCenterPageListMargin,
          ),
          child: SizedBox(
            height: kDockControlCenterVolumeSectionHeight,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 2,
                  child: Text(
                    '主音量',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                      height: 1.0,
                    ),
                  ),
                ),
                Positioned(
                  right: 14,
                  top: 2,
                  child: Text(
                    '${_volumePreview.round()}%',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.textPrimary.withValues(alpha: 0.65),
                      height: 1.0,
                    ),
                  ),
                ),
                Positioned(
                  left: 2,
                  bottom: kDockControlCenterSubmenuVolumeSliderBottom + 6,
                  child: CustomPaint(
                    size: const Size(
                      kDockControlCenterSubmenuGlyphWidth,
                      kDockControlCenterSubmenuGlyphHeight,
                    ),
                    // KOS: :2747-2753 — glyph 点击 `setMuted`；SDK 无 mute
                    // 通道（`AudioService` 只有 `apply(percent)`）→ glyph
                    // 只读展示 muted 态、不可点（记 deltas）。
                    painter: DockControlCenterVolumeGlyph(
                      color: colors.textPrimary,
                      muted: _muted,
                      large: true,
                    ),
                  ),
                ),
                Positioned(
                  left: kDockControlCenterSubmenuVolumeSliderLeft,
                  right: kDockControlCenterSubmenuVolumeSliderRight,
                  bottom: kDockControlCenterSubmenuVolumeSliderBottom,
                  child: DockControlCenterSlider(
                    key: const ValueKey<String>('cc.sound.volume'),
                    value: _volumePreview / 100,
                    onPreviewChanged: (value) => setState(() {
                      _draggingVolume = true;
                      _volumePreview = value * 100;
                    }),
                    onCanceled: () => setState(() {
                      _draggingVolume = false;
                      _volumePreview = _level;
                    }),
                    onCommitRequested: (value) {
                      setState(() {
                        _draggingVolume = false;
                        _volumePreview = value * 100;
                      });
                      _applyVolume(value * 100);
                    },
                    trackColor: colors.volumeTrack,
                    accentColor: theme.accent,
                    thumbColor: colors.sliderThumb,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kDockControlCenterPageListMargin,
          ),
          child: SizedBox(
            height: kDockControlCenterOutputSectionHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // KOS: :2790-2796 — 「输出设备」10 DemiBold @0.60。
                  '输出设备',
                  style: TextStyle(
                    fontSize: kDockControlCenterSectionTitleSize,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary.withValues(
                      alpha: kDockControlCenterSectionTitleAlpha,
                    ),
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // KOS: :2798-2809 — r10 底 + 1px 边。
                      borderRadius: BorderRadius.circular(
                        kDockControlCenterOutputRowRadius,
                      ),
                      color: colors.textPrimary.withValues(
                        alpha: kDockStatusCardFillAlpha,
                      ),
                      border: Border.all(color: colors.hairlineSoft),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        kDockControlCenterOutputRowRadius,
                      ),
                      child: _outputDeviceList(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(
              left: kDockControlCenterPageListMargin,
              right: kDockControlCenterPageListMargin,
              bottom: 4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // KOS: :2851-2858 — 「应用音量」10 DemiBold @0.60。
                  '应用音量',
                  style: TextStyle(
                    fontSize: kDockControlCenterSectionTitleSize,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary.withValues(
                      alpha: kDockControlCenterSectionTitleAlpha,
                    ),
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: apps.isEmpty
                      // KOS: :2860-2868 — 「没有活动的音频应用」。
                      ? Center(
                          child: Text(
                            '没有活动的音频应用',
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.textPrimary.withValues(alpha: 0.45),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: apps.length,
                          separatorBuilder: (_, _) => const SizedBox(
                            height: kDockControlCenterAppRowGap,
                          ),
                          itemBuilder: (context, index) =>
                              _appVolumeRow(context, apps[index]),
                        ),
                ),
              ],
            ),
          ),
        ),
        _pageFooter(context, '声音设置…'),
      ],
    );
  }

  /// 输出设备列表（KOS 是静态「默认音频输出设备」占位，:2811-2834）——
  /// SDK `outputDeviceStates` 有真列表 → 渲染真设备（点行
  /// `selectOutputDevice`）；无数据时回落 KOS 的占位行（记 deltas）。
  Widget _outputDeviceList(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    if (_outputDevices.isEmpty) {
      return Row(
        children: [
          const SizedBox(width: 10),
          Text(
            '✓',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: theme.accent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            // KOS: :2830 — 静态占位文案。
            '默认音频输出设备',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final device in _outputDevices)
          GestureDetector(
            key: ValueKey<String>('cc.output.${device.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: device.active
                ? null
                : () => ref
                      .read(audioServiceProvider)
                      .selectOutputDevice(device.name),
            child: MouseRegion(
              cursor: device.active
                  ? SystemMouseCursors.basic
                  : widget.services.linkCursor,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 14,
                    child: device.active
                        ? Text(
                            '✓',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: theme.accent,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      device.description.isEmpty
                          ? device.name
                          : device.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: device.active
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 应用音量行（KOS :2882-2983）：name + % + 滑条（hover 底 r8，KOS :2898-2903）。
  ///
  /// KOS 的 28px 静音钮（`setApplicationMuted`）与 0-150% 量程 SDK 都没有
  /// （`applyAppStream(id, percent)` 签名只收 0-100 的 percent，
  /// `platform/bridge/audio_client.dart:128-131` 内部 `clamp(0,100)`）→
  /// 静音钮砍掉、量程取 0-100%（记 docs/dock-port/TASK-09-control-center.md）。
  Widget _appVolumeRow(BuildContext context, AppAudioStream stream) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final preview = _appPreviews[stream.id];
    final value = preview ?? stream.level * 100;
    final hovered = _hoveredAppId == stream.id;
    return MouseRegion(
      key: ValueKey<String>('cc.app.${stream.id}'),
      onEnter: (_) => setState(() => _hoveredAppId = stream.id),
      onExit: (_) => setState(() {
        if (_hoveredAppId == stream.id) _hoveredAppId = null;
      }),
      child: SizedBox(
        height: kDockControlCenterAppRowHeight,
        child: Stack(
          children: [
            // KOS: :2898-2903 — hover 底 r8 `rgba(1,1,1,.10)`（浅色档
            // `rgba(0,0,0,.055)` → 同式 foreground 低 alpha）100ms。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    kDockControlCenterAppRowRadius,
                  ),
                  color: hovered
                      ? colors.textPrimary.withValues(
                          alpha: kDockControlCenterAppRowHoverAlpha,
                        )
                      : const Color(0x00000000),
                ),
              ),
            ),
            Text(
              // KOS: :2938 — `name || "音频应用"`。
              stream.name.isEmpty ? '音频应用' : stream.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
            Positioned(
              right: 5,
              top: 0,
              child: Text(
                '${value.round()}%',
                style: TextStyle(
                  fontSize: 9,
                  color: colors.textPrimary.withValues(alpha: 0.55),
                  height: 1.0,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 4,
              bottom: 3,
              height: kDockControlCenterAppSliderHeight,
              child: DockControlCenterSlider(
                value: value / 100,
                onPreviewChanged: (next) => setState(() {
                  _draggingAppIds.add(stream.id);
                  _appPreviews[stream.id] = next * 100;
                }),
                onCanceled: () => setState(() {
                  _draggingAppIds.remove(stream.id);
                  _appPreviews.remove(stream.id);
                }),
                onCommitRequested: (next) {
                  setState(() {
                    // 拖动结束：预览留到下一次服务回灌（KOS 行内
                    // `volumePreview` 同语义），但仍未被服务值覆盖前的拖动
                    // 保护解除。
                    _draggingAppIds.remove(stream.id);
                    _appPreviews[stream.id] = next * 100;
                  });
                  // KOS `setApplicationVolume(id, v*150)`（:2977-2978）→ SDK
                  // `applyAppStream(id, percent)`（0-100）。滑条值是 0..1 →
                  // percent，量纲必须 ×100（同音量条 :1229 口径）。
                  ref
                      .read(audioServiceProvider)
                      .applyAppStream(
                        stream.id,
                        (next * 100).round().clamp(0, 100),
                      );
                },
                trackColor: colors.volumeTrack,
                accentColor: theme.accent,
                thumbColor: colors.sliderThumb,
                height: kDockControlCenterAppSliderHeight,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前 hover 的应用音量行（KOS delegate 内 `HoverHandler`）。
  int? _hoveredAppId;

  /// 子页关态提示（KOS wifi :2032-2052 / bt :2300-2320）。
  Widget _pageOffState(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    final colors = context.shellColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontSize: 12,
              color: colors.textPrimary,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// 子页小节头（KOS :2059-2084 / :2326-2351）：22px、左右 14。
  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    String? trailing,
  }) {
    final colors = context.shellColors;
    return Padding(
      padding: const EdgeInsets.only(
        top: 6,
        left: kDockControlCenterPageListMargin,
        right: kDockControlCenterPageListMargin,
      ),
      child: SizedBox(
        height: 22,
        child: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary.withValues(alpha: 0.72),
                  height: 1.0,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 子页底脚（KOS :2598-2624 / :2988-3021）：38px、1px 分隔（左右 12）、
  /// 11px DemiBold 标签 + 「›」；`settings.open` 无 SDK 等价物 → 禁用态。
  Widget _pageFooter(BuildContext context, String label) {
    final colors = context.shellColors;
    return SizedBox(
      height: kDockControlCenterPageFooterHeight,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(height: 1, color: colors.hairline),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      // KOS: :2610 — 11px DemiBold（禁用 → 三级前景）。
                      fontSize: kDockControlCenterPageFooterFontSize,
                      fontWeight: FontWeight.w600,
                      color: colors.textTertiary,
                      height: 1.0,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '›',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.textTertiary,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前拖动的亮度行（多显示器时定位预览值归属）。
  int? _brightnessOutputId;
}

/// 控制中心 pill（KOS `ControlCenterPanel.qml:528-812`）：39px 圆开关盘 +
/// 标题/副标题 + 右缘「›」。
///
/// 交互分工（KOS :608-617 / :644-657）：点圆盘 → `onToggle()`；点其余
/// （`leftMargin: 49` 起）→ `onOpenPage()`。不可用（!available）时整卡
/// alpha .48（KOS :673）。
class DockControlCenterPill extends StatefulWidget {
  const DockControlCenterPill({
    required this.title,
    required this.subtitle,
    required this.checked,
    required this.available,
    required this.busy,
    required this.cursor,
    required this.buildDiscGlyph,
    required this.onToggle,
    required this.onOpenPage,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool checked;
  final bool available;

  /// toggle 进行中（KOS `wifiToggleInProgress`/`bluetoothChangeInProgress`）
  /// → 盘 opacity .55。
  final bool busy;
  final MouseCursor cursor;

  /// 盘内 glyph（`checked` = 盘已点亮，用于取对比色）。
  final Widget Function(BuildContext context, bool checked) buildDiscGlyph;

  final VoidCallback onToggle;
  final VoidCallback onOpenPage;

  @override
  State<DockControlCenterPill> createState() => _DockControlCenterPillState();
}

class _DockControlCenterPillState extends State<DockControlCenterPill>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _pressed = false;
  bool _discPressed = false;

  /// KOS :570-617 — busy 档的 21px 旋转弧（900ms/圈，`RotationAnimation`
  /// `running: spinner.visible && toggleInProgress`）。
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: kDockControlCenterBusySpinDuration,
    );
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant DockControlCenterPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy == oldWidget.busy) return;
    if (widget.busy) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final checked = widget.checked;
    final enabled = widget.available && !widget.busy;
    // KOS: :531-532 — 卡 scale 1.015（hover）/0.97（press）/1（135ms OutCubic）。
    final cardScale = widget.available
        ? (_pressed
              ? kDockControlCenterPillCardPressedScale
              : (_hovered ? kDockControlCenterPillCardHoverScale : 1.0))
        : 1.0;
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: cardScale,
        duration: kDockControlCenterCellDuration,
        curve: Curves.easeOutCubic,
        child: DockStatusPanelFade(
          // KOS: :673 — `!bluetoothAvailable → cardOpacity .48`。
          opacity: widget.available
              ? 1.0
              : kDockControlCenterPillUnavailableAlpha,
          child: DockStatusPanelSurface(
            radius: kDockControlCenterPillRadius,
            child: Stack(
              children: [
                // 圆开关盘（KOS :542-554）。
                Positioned(
                  left: kDockControlCenterPillDiscLeft,
                  top:
                      (kDockControlCenterPillHeight -
                          kDockControlCenterPillDiscSize) /
                      2,
                  child: Listener(
                    onPointerDown: (_) => setState(() => _discPressed = true),
                    onPointerUp: (_) => setState(() => _discPressed = false),
                    onPointerCancel: (_) =>
                        setState(() => _discPressed = false),
                    child: GestureDetector(
                      key: const ValueKey<String>('cc.pill.disc'),
                      behavior: HitTestBehavior.opaque,
                      onTap: enabled ? widget.onToggle : null,
                      child: MouseRegion(
                        cursor: enabled
                            ? widget.cursor
                            : SystemMouseCursors.basic,
                        child: AnimatedOpacity(
                          // KOS: :549 — toggle 中盘 opacity .55。
                          opacity: widget.busy
                              ? kDockControlCenterPillBusyOpacity
                              : 1.0,
                          duration: kDockControlCenterCellDuration,
                          child: AnimatedScale(
                            // KOS: :551-554 — 1.04 hover / 0.92 press / 1。
                            scale: _discPressed
                                ? kDockControlCenterPillDiscPressedScale
                                : (_hovered
                                      ? kDockControlCenterPillDiscHoverScale
                                      : 1.0),
                            duration: kDockControlCenterCellDuration,
                            curve: Curves.easeOutCubic,
                            child: Container(
                              width: kDockControlCenterPillDiscSize,
                              height: kDockControlCenterPillDiscSize,
                              decoration: BoxDecoration(
                                // 开 → accent（KOS `tileActiveFill`）；关 →
                                // tileOff（KOS 半透明黑白覆层语义映射）。
                                color: checked ? theme.accent : colors.tileOff,
                                shape: BoxShape.circle,
                                border: Border.all(color: colors.hairlineSoft),
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // KOS :570 — 盘内 glyph `opacity:
                                  // toggleInProgress ? 0 : 1`（140ms）。
                                  AnimatedOpacity(
                                    opacity: widget.busy ? 0 : 1,
                                    duration:
                                        kDockControlCenterBusyFadeDuration,
                                    child: widget.buildDiscGlyph(
                                      context,
                                      checked,
                                    ),
                                  ),
                                  // KOS :575-617 — 21px 旋转弧、900ms/圈、
                                  // `r = w/2 − 1.5`、lineWidth 2、圆帽、扫 1.5π。
                                  AnimatedOpacity(
                                    key: const ValueKey<String>(
                                      'cc.pill.spinner',
                                    ),
                                    opacity: widget.busy ? 1 : 0,
                                    duration:
                                        kDockControlCenterBusyFadeDuration,
                                    child: RotationTransition(
                                      turns: _spin,
                                      child: CustomPaint(
                                        size: const Size.square(
                                          kDockControlCenterPillSpinnerSize,
                                        ),
                                        painter:
                                            DockControlCenterBusyArcPainter(
                                              color: checked
                                                  ? theme
                                                        .accentPalette
                                                        .onPrimary
                                                  : colors.textPrimary,
                                            ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 文字列（KOS :619-636）。
                Positioned(
                  left: kDockControlCenterPillTextLeft,
                  right: kDockControlCenterPillTextRight,
                  top: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // KOS: :626 — 12px Bold。
                          fontSize: kDockControlCenterPillTitleSize,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // KOS: :634 — 10px。
                          fontSize: kDockControlCenterPillSubtitleSize,
                          color: colors.textSecondary,
                          height: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
                // 右缘「›」（KOS :637-643）。
                Positioned(
                  right: kDockControlCenterPillChevronRight,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Text(
                      '›',
                      style: TextStyle(
                        // KOS: :642 — 14px Bold @0.60。
                        fontSize: kDockControlCenterPillChevronSize,
                        fontWeight: FontWeight.w700,
                        color: colors.textSecondary.withValues(alpha: 0.60),
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                // 整卡点击区（圆盘外，KOS `leftMargin: 49`）→ 开子页；按下时
                // 卡 scale 0.97（KOS :531 `wifiPagePointer.pressed`）。
                Positioned(
                  left: kDockControlCenterPillTapLeft,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Listener(
                    onPointerDown: (_) => setState(() => _pressed = true),
                    onPointerUp: (_) => setState(() => _pressed = false),
                    onPointerCancel: (_) => setState(() => _pressed = false),
                    child: GestureDetector(
                      key: const ValueKey<String>('cc.pill.page'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.available ? widget.onOpenPage : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 控制中心 pill busy 档的旋转弧（KOS `ControlCenterPanel.qml:570-617`）：
/// 21×21 画布、`strokeStyle = glyphColor`、`lineWidth 2.0`、圆帽、
/// 圆心画布中心、`r = w/2 − 1.5`、弧 0→1.5π；转速由外层
/// `RotationTransition`（900ms/圈）给。
class DockControlCenterBusyArcPainter extends CustomPainter {
  const DockControlCenterBusyArcPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = kDockControlCenterPillSpinnerStroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: size.width / 2 - kDockControlCenterPillSpinnerInset,
      ),
      0,
      math.pi * 1.5,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(DockControlCenterBusyArcPainter old) => old.color != color;
}

/// 控制中心滑条（KOS `bar/ControlCenterSlider.qml` → `LiquidSlider` 的
/// Flutter 近似）：高 30（可覆写）、track 4、白 thumb 36×18 r9、两阶段
/// `onPreviewChanged`（拖动实时）/`onCommitRequested`（松手提交）。
///
/// v1 差异（记 docs/dock-port/TASK-09-control-center.md）：LiquidSlider 的 thumb 展开
/// （270ms OutBack 1.36 / 460ms OutQuint）+ wobble squash-stretch 与玻璃
/// 透镜高光不做；轨道/进度/thumb 颜色由调用方传语义 role（KOS glass
/// `rgba(1,1,1,0.17)`/`0.42` + `#ffffff`）。
class DockControlCenterSlider extends StatefulWidget {
  const DockControlCenterSlider({
    required this.value,
    required this.onPreviewChanged,
    required this.onCommitRequested,
    this.onCanceled,
    this.enabled = true,
    this.height = kDockControlCenterSliderHeight,
    this.trackColor,
    this.accentColor,
    this.thumbColor,
    super.key,
  });

  /// 外部值（0..1）；拖动中显示内部预览。
  final double value;
  final ValueChanged<double> onPreviewChanged;
  final ValueChanged<double> onCommitRequested;

  /// 拖动取消（KOS `canceled()`）→ 调用方回退到服务值。
  final VoidCallback? onCanceled;
  final bool enabled;
  final double height;

  final Color? trackColor;
  final Color? accentColor;
  final Color? thumbColor;

  @override
  State<DockControlCenterSlider> createState() =>
      _DockControlCenterSliderState();
}

class _DockControlCenterSliderState extends State<DockControlCenterSlider> {
  double? _drag;

  double get _display => (_drag ?? widget.value).clamp(0.0, 1.0);

  void _preview(double dx, double width) {
    if (!widget.enabled) return;
    final thumb = kDockControlCenterThumbWidth;
    final span = math.max(1.0, width - thumb);
    final value = ((dx - thumb / 2) / span).clamp(0.0, 1.0);
    setState(() => _drag = value);
    widget.onPreviewChanged(value);
  }

  void _commit() {
    final value = _display;
    setState(() => _drag = null);
    widget.onCommitRequested(value);
  }

  void _cancel() {
    setState(() => _drag = null);
    widget.onCanceled?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    // KOS `ControlCenterSlider.qml:18-21` glass 档：轨 `rgba(1,1,1,0.17)`、
    // 进度 `rgba(1,1,1,0.42)` → textPrimary 同 alpha 语义映射（缺省值即
    // KOS glass 档；调用方传 `brightnessTrack`/`volumeTrack`/accent 覆写为
    // shellColors 角色）。
    final track =
        widget.trackColor ??
        colors.textPrimary.withValues(alpha: kDockControlCenterTrackAlpha);
    final accent =
        widget.accentColor ??
        colors.textPrimary.withValues(
          alpha: kDockControlCenterTrackAccentAlpha,
        );
    final thumb = widget.thumbColor ?? colors.sliderThumb;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _preview(details.localPosition.dx, width),
          onTapUp: (_) => _commit(),
          onTapCancel: _cancel,
          onHorizontalDragStart: (details) =>
              _preview(details.localPosition.dx, width),
          onHorizontalDragUpdate: (details) =>
              _preview(details.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _commit(),
          onHorizontalDragCancel: _cancel,
          child: CustomPaint(
            size: Size(width, widget.height),
            painter: DockControlCenterTrackPainter(
              value: _display,
              track: track,
              accent: accent,
              thumb: thumb,
              enabled: widget.enabled,
            ),
          ),
        );
      },
    );
  }
}

/// 滑条绘制：track（4px 全圆）+ 进度（accent）+ thumb（白 36×18 r9）。
class DockControlCenterTrackPainter extends CustomPainter {
  const DockControlCenterTrackPainter({
    required this.value,
    required this.track,
    required this.accent,
    required this.thumb,
    required this.enabled,
  });

  final double value;
  final Color track;
  final Color accent;
  final Color thumb;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final thumbW = math.min(kDockControlCenterThumbWidth, size.width);
    final thumbH = math.min(kDockControlCenterThumbHeight, size.height);
    final span = math.max(0.0, size.width - thumbW);
    final center = thumbW / 2 + span * value;
    final radius = kDockControlCenterTrackHeight / 2;
    final trackRect = Rect.fromLTWH(
      0,
      midY - radius,
      size.width,
      kDockControlCenterTrackHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, Radius.circular(radius)),
      Paint()..color = track,
    );
    if (center > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            0,
            midY - radius,
            center,
            kDockControlCenterTrackHeight,
          ),
          Radius.circular(radius),
        ),
        Paint()..color = accent,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(center, midY),
          width: thumbW,
          height: thumbH,
        ),
        Radius.circular(kDockControlCenterThumbRadius),
      ),
      Paint()..color = enabled ? thumb : thumb.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(DockControlCenterTrackPainter old) =>
      old.value != value ||
      old.track != track ||
      old.accent != accent ||
      old.thumb != thumb ||
      old.enabled != enabled;
}

/// 媒体卡传输钮（KOS `TransportButton` = MediaControlButton，:147-151）：
/// prev/next 32、play 40，圆形。
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.size,
    required this.glyph,
    required this.color,
    required this.enabled,
    required this.cursor,
    required this.onTap,
    this.background,
    super.key,
  });

  final double size;
  final IconData glyph;
  final Color color;
  final bool enabled;
  final MouseCursor cursor;
  final VoidCallback onTap;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: MouseRegion(
        cursor: enabled ? cursor : SystemMouseCursors.basic,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.4,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Icon(glyph, size: size * 0.55, color: color),
          ),
        ),
      ),
    );
  }
}

/// wifi/bt 子页右侧开关球（KOS `ControlCenterPanel.qml:1958-2000`）：
/// 38×22 r11、thumb 18 r9、内缩 2、x 动画 160ms OutCubic、toggle 中 opacity .6。
class _DockControlCenterSwitch extends StatelessWidget {
  const _DockControlCenterSwitch({
    required this.checked,
    required this.busy,
    required this.cursor,
    required this.onToggle,
  });

  final bool checked;
  final bool busy;
  final MouseCursor cursor;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final thumb = kDockControlCenterSwitchThumbSize;
    return GestureDetector(
      key: const ValueKey<String>('cc.page.toggle'),
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onToggle,
      child: MouseRegion(
        cursor: busy ? SystemMouseCursors.basic : cursor,
        child: AnimatedOpacity(
          opacity: busy ? kDockControlCenterSwitchBusyOpacity : 1.0,
          duration: kDockControlCenterSwitchDuration,
          child: AnimatedContainer(
            duration: kDockControlCenterSwitchDuration,
            curve: Curves.easeOutCubic,
            width: kDockControlCenterSwitchWidth,
            height: kDockControlCenterSwitchHeight,
            // KOS: :1976-1982 — thumb 内缩 `kDockControlCenterSwitchThumbInset`。
            padding: const EdgeInsets.symmetric(
              horizontal: kDockControlCenterSwitchThumbInset,
              vertical: kDockControlCenterSwitchThumbInset,
            ),
            decoration: BoxDecoration(
              // KOS: :1973-1975 — 开 `#0a84ff` → theme.accent。
              color: checked ? theme.accent : colors.tileOff,
              borderRadius: BorderRadius.circular(
                kDockControlCenterSwitchRadius,
              ),
            ),
            child: AnimatedAlign(
              // KOS: :1984-1985 — `x` Behavior 160ms OutCubic。
              duration: kDockControlCenterSwitchDuration,
              curve: Curves.easeOutCubic,
              alignment: checked ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: thumb,
                height: thumb,
                decoration: BoxDecoration(
                  color: colors.sliderThumb,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音量喇叭 glyph（KOS `ControlCenterPanel.qml:1242-1269` 音量条 15×15 /
/// `:2665-2740` 子页 19×16 三级弧）：muted → 斜杠；音量分档弧数
/// `>66 ? 3 : >33 ? 2 : >0 ? 1 : 0`（:2722）。
class DockControlCenterVolumeGlyph extends CustomPainter {
  const DockControlCenterVolumeGlyph({
    required this.color,
    required this.muted,
    this.large = false,
  });

  final Color color;
  final bool muted;

  /// 子页版（19×16、三级弧）；false = 音量条版（15×15、单弧）。
  final bool large;

  @override
  void paint(Canvas canvas, Size size) {
    final designWidth = large
        ? kDockControlCenterSubmenuGlyphWidth
        : kDockControlCenterVolumeGlyphSize;
    final designHeight = large
        ? kDockControlCenterSubmenuGlyphHeight
        : kDockControlCenterVolumeGlyphSize;
    final scale = math.min(
      size.width / designWidth,
      size.height / designHeight,
    );
    canvas.save();
    canvas.scale(scale, scale);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 音箱主体（KOS: :1256-1257 / :2696-2704 同式折线）。
    canvas.drawRect(const Rect.fromLTWH(1, 6, 3.5, 4), fill);
    final body = Path()
      ..moveTo(4.3, 6)
      ..lineTo(8, 3)
      ..lineTo(8, 13)
      ..lineTo(4.3, 10)
      ..close();
    canvas.drawPath(body, fill);
    if (muted) {
      // KOS: :1262 / :2709-2712 — 斜杠。
      canvas.drawLine(const Offset(10.5, 4.5), const Offset(14, 11.5), stroke);
      return canvas.restore();
    }
    if (large) {
      // KOS: :2725-2738 — 三级弧 r4.2/7.0/9.8。
      for (final arc in const <List<double>>[
        <double>[4.2, -0.65, 0.65],
        <double>[7.0, -0.70, 0.70],
        <double>[9.8, -0.72, 0.72],
      ]) {
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(6, 8), radius: arc[0]),
          arc[1],
          arc[2] - arc[1],
          false,
          stroke,
        );
      }
    } else {
      // KOS: :1260 — 单弧 r4、角度 -0.8→0.8。
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(7.2, 8), radius: 4),
        -0.8,
        1.6,
        false,
        stroke,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DockControlCenterVolumeGlyph old) =>
      old.color != color || old.muted != muted || old.large != large;
}
