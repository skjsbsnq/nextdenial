/// KOS Dock 窗口预览 popup + 右键菜单（TASK-03）。
///
/// 对齐 NextKde `dock/DockWindowPreview.qml`（独立 Wayland PopupWindow）
/// 与 `dock/DockIcon.qml:400-545`（ContextMenu 组件 + previewDelay /
/// previewCloseDelay 两个 Timer + pointerInside 交接）。Denial 无独立
/// popup surface，全部走 `OverlayPortal.overlayChildLayoutBuilder`
/// （denial_taskbar `window_buttons.dart:518-856` `_WindowButton` 范式）：
///
/// - **hover 触发**：MouseRegion onEnter → 300ms `previewDelay`
///   （DockAnimation.qml:93，仅 `windows` 非空时 arm）；onExit → 取消 +
///   130ms `previewCloseDelay`（:96）防抖，让指针跨过 6px 间隙进 popup。
/// - **pointerInside 桥接**：popup 容器高度含 gap 桥带（taskbar
///   `height + 8` 模式），MouseRegion 覆整个桥带；进 popup → 取消关闭、
///   若正在退场则 30ms handoff 回弹（DockWindowPreview.qml:533-539）；出
///   popup 且图标未 hover → 重启 closeDelay（DockIcon.qml:452-459）。
/// - **reveal 动画**：`AnimationController`（非弹簧），入场 16ms 预滚 +
///   120ms OutCubic（DockWindowPreview.qml:130-147）；退场 110ms InCubic
///   （:158-167）；handoff 30ms（:149-156）。revealProgress 驱动
///   opacity、scale 0.94→1（transformOrigin 底）、y 下沉 7px
///   （:172-194，KOS 数值逐字面移植）。
/// - **右键菜单**：KOS pinned 分支 `open/new_window/pin`（DockIcon.qml:
///   912-924）；`close_all/minimize/close` 按 CONSTRAINTS §5 协议缺口
///   砍掉。点外即关 + Esc；150ms OutCubic 开 / 140ms InCubic 关 +
///   scale 0.96→1 + 20px 位移（ACCEPTANCE 菜单条款）。菜单面板/行/浮层
///   骨架已提取为公共件 `dock_menu.dart`（TASK-04 等价重构，供
///   launcher/trash 复用；本文件行为与数值不变）。
/// - **emphasize**：预览卡 hover 300ms 后 `services.emphasizeWindow`
///   联动（taskbar `PreviewEmphasis` 逐字搬运，KOS 无此特性——Denial
///   新增，记 docs/visual-deltas.md）。
/// - **抑制**：菜单开着 / 重排拖拽 / surface 不可见 / `windows` 变空 →
///   不弹或立即关（KOS `onEffectiveWindowsChanged` →
///   `dismissDockPopupImmediately`，DockWindowPreview.qml:84-91）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:flutter/material.dart';

import '../state/preview_emphasis.dart';
import '../theme/dock_tokens.dart';
import 'dock_menu.dart';

/// KOS `dismissDockPopupImmediately` 的参与者契约（dock/DockModelService.qml:
/// 39,56-63）：被协调器抢占时必须**立即**收场（不播退场动画）。
abstract interface class DockPopup {
  /// 立即收起本 popup（KOS `DockModelService.dismissDockPopupImmediately`，
  /// dock/DockModelService.qml:56-63）。
  void dismissDockPopupImmediately();
}

/// 全 pill 共享 popup 协调器（KOS dock/DockModelService.qml:32-39,65-72：
/// `activeDockPopup`/`activeContextMenu` 单例语义）。任一时刻只允许一个
/// popup——pinned 预览/右键菜单、launcher、trash 菜单、清空确认弹窗都计入；
/// 新打开者先同步收掉前一个（`openDockPopup`，:65-72），关闭者释放槽位
/// （`releaseDockPopup`，:74-77）；任一 pinned 图标菜单开着时 [menuOpen]
/// 为 true，全体图标的 previewDelay 抑制（KOS `activeContextMenu`）。
/// 由 `KosDockShell` 持有一份，下发 `DockIconRow` → `DockIcon` →
/// `DockPreviewAnchor`、`LauncherIcon`、`TrashIcon`、`TrashConfirmDialog`；
/// 未注入时各宿主自建一个实例（独立宿主/单测退化为无协调）。
class DockPopupCoordinator {
  /// 当前活跃 popup（预览/菜单/确认弹窗都算）。
  DockPopup? _active;

  /// 任一 pinned 图标菜单开着（KOS `activeContextMenu`：抑制全体
  /// previewDelay）。
  bool menuOpen = false;

  /// 是否存在活跃 popup（含关闭动画中的宿主）。
  bool get hasActivePopup => _active != null;

  /// 当前活跃 popup（诊断/测试用）。
  DockPopup? get activePopup => _active;

  /// 成为唯一活跃 popup；已有其他宿主占着时立刻同步收掉它
  /// （KOS `openDockPopup` → `dismissDockPopupImmediately`，
  /// dock/DockModelService.qml:65-72）。
  void activate(DockPopup popup) {
    final previous = _active;
    if (identical(previous, popup)) return;
    _active = popup;
    previous?.dismissDockPopupImmediately();
  }

  /// 释放活跃位（popup 关闭 / dispose 时调用，KOS `releaseDockPopup`，
  /// dock/DockModelService.qml:74-77）。
  void release(DockPopup popup) {
    if (identical(_active, popup)) _active = null;
  }

  /// 立即收掉当前活跃 popup（launcher tap 前的清场，KOS
  /// dock/DockContainer.qml:560-563）。
  void dismissActive() {
    final previous = _active;
    if (previous == null) return;
    _active = null;
    previous.dismissDockPopupImmediately();
  }
}

/// 图标 hover 预览 + 右键菜单的 popup 宿主。包在图标槽位外侧；`child`
/// 是固定槽位本体（布局尺寸不变，portal 不占布局）。
class DockPreviewAnchor extends StatefulWidget {
  const DockPreviewAnchor({
    required this.name,
    required this.launchId,
    required this.monitorId,
    required this.windows,
    required this.monitorBounds,
    required this.dragging,
    this.isPinnedEntry = true,
    required this.onTogglePin,
    this.coordinator,
    required this.child,
    super.key,
  });

  /// 应用显示名（preview 工具条标签 + 菜单标题用）。
  final String name;
  final String? launchId;
  final int monitorId;
  final List<ApplicationWindow> windows;
  final Rect? monitorBounds;
  final bool dragging;

  /// 该条目是否属于 pinned 段（KOS `DockIcon.qml:916-927`：window item 的
  /// 第三项是 `pinned ? "取消固定" : "固定此应用"`）。
  final bool isPinnedEntry;

  /// pin/unpin 写回（dock_icons.dart `_savePins` 封装）。
  final Future<void> Function() onTogglePin;

  /// 全 pill 共享 popup 协调器（[DockPopupCoordinator]；null → 本 anchor
  /// 自建一个，单图标场景退化为无协调）。
  final DockPopupCoordinator? coordinator;
  final Widget child;

  @override
  State<DockPreviewAnchor> createState() => DockPreviewAnchorState();
}

class DockPreviewAnchorState extends State<DockPreviewAnchor>
    with SingleTickerProviderStateMixin
    implements DockPopup {
  final _portal = OverlayPortalController();

  /// popup 协调器（见 [DockPopupCoordinator]）；未注入时自建实例。
  late final DockPopupCoordinator _coordinator =
      widget.coordinator ?? DockPopupCoordinator();

  /// revealProgress：0=隐藏，1=完全展开；驱动 opacity/scale/sink。
  late final AnimationController _reveal;
  late final _emphasis = PreviewEmphasis(
    request: (id) {
      if (!mounted ||
          _menu ||
          !_portal.isShowing ||
          !widget.windows.any((window) => window.id == id)) {
        return () {};
      }
      return ShellServicesScope.of(
        context,
      ).emphasizeWindow(id, monitorId: widget.monitorId);
    },
  );

  Timer? _openTimer;
  Timer? _closeTimer;
  Timer? _preRoll;

  /// 图标 MouseRegion 的指针在内状态（含 0 窗图标；预览仍要求 windows
  /// 非空才 arm）。
  bool _iconHovered = false;

  /// popup 桥带/内容的指针在内状态（KOS `preview.pointerInside`，
  /// DockWindowPreview.qml:25）。
  bool _popupHovered = false;
  bool _menu = false;

  /// 菜单 140ms InCubic 退场播送中（播完由 dismissed 监听收 portal）。
  bool _menuClosing = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _reveal =
        AnimationController(
            vsync: this,
            // KOS: dock/DockAnimation.qml:97 `windowPreviewHandoffDuration:
            // 30` —— forward 的标称时长（关闭中重入的交接）。
            duration: kDockPreviewHandoffDuration,
            // KOS: dock/DockAnimation.qml:98 `windowPreviewExitDuration:
            // 110` —— 退场（fade + scale0.94 + 下沉 7px）。
            reverseDuration: kDockPreviewExitDuration,
          )
          ..addStatusListener((status) {
            // KOS: dock/DockWindowPreview.qml:167-172 —— exit 播完才把
            // popup visible 置 false。
            if (status == AnimationStatus.dismissed && mounted) {
              _closing = false;
              if (_menuClosing) {
                // 菜单 140ms InCubic 关播完 → 收 portal + 释放协调器。
                _menuClosing = false;
                _portal.hide();
                _coordinator.release(this);
                if (_menu) setState(() => _menu = false);
              } else if (!_menu) {
                // 菜单开着时 openContextMenu 的 reveal=0 重置不触发
                // hide——portal 马上以菜单重建（防 hide→show 闪现）。
                _portal.hide();
                _coordinator.release(this);
              }
            }
          });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // taskbar `window_buttons.dart:357-368` 范式：surface 不可见 → 立即关。
    if (!ShellSurfacePresentation.visibleOf(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ShellSurfacePresentation.visibleOf(context)) {
          _dismissImmediately();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant DockPreviewAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // emphasize 目标窗已消失 → 释放（taskbar 范式）。
    if (_emphasis.windowId != null &&
        !widget.windows.any((w) => w.id == _emphasis.windowId)) {
      _emphasis.clear();
    }
    // KOS: dock/DockWindowPreview.qml:84-91 `onEffectiveWindowsChanged` →
    // 空窗即 dismiss；拖拽中 popup 也立刻收（OverlayPortal 不能在父级
    // build 中改 overlay，帧后做）。
    if (widget.dragging || (!_menu && widget.windows.isEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            (widget.dragging || (!_menu && widget.windows.isEmpty))) {
          _dismissImmediately();
        }
      });
    }
  }

  // ── 开/关状态机（KOS setDockPopupVisible / cancelClosing /
  //    dismissDockPopupImmediately，DockWindowPreview.qml:93-128,533-539）─

  /// KOS `setDockPopupVisible(true)`：已展开→不动；关闭中→30ms handoff；
  /// 未开→show + 16ms 预滚 + 120ms OutCubic 入场。
  void _openPreview() {
    if (!mounted ||
        widget.dragging ||
        _menu ||
        widget.windows.isEmpty ||
        !ShellSurfacePresentation.visibleOf(context)) {
      return;
    }
    // KOS: dock/DockWindowPreview.qml:98-99 `if (visible && !closing)
    // return` —— 已展开或入场中重入直接返回，不重启 forward、不砍 16ms
    // 预滚（避免截断 in-flight entrance）。
    if (_portal.isShowing && !_closing) return;
    if (_portal.isShowing) {
      // 关闭中重入 → 30ms handoff 回弹。
      _preRoll?.cancel();
      _closing = false;
      if (_reduceMotion) {
        _reveal.value = 1;
      } else {
        _reveal.forward();
      }
      return;
    }
    _closing = false;
    // KOS: dock/DockModelService.qml:34-88 —— 行内单例 popup：打开前
    // 先收掉上一只（立即 dismiss，不经 closeDelay/退场动画）。
    _coordinator.activate(this);
    _portal.show();
    _reveal.value = 0;
    _preRoll?.cancel();
    if (_reduceMotion) {
      _reveal.value = 1;
      return;
    }
    // KOS: dock/DockWindowPreview.qml:130-138 —— 16ms 预滚后再播 120ms
    // entrance（避免快速 hover 时玻璃闪帧）。
    _preRoll = Timer(kDockPreviewRevealStart, () {
      if (!mounted || _closing || !_portal.isShowing) return;
      // entrance：animateTo(1, 120ms, OutCubic)。
      _reveal.animateTo(
        1,
        duration: kDockPreviewEntranceDuration,
        curve: Curves.easeOutCubic,
      );
    });
  }

  bool _closing = false;

  /// KOS `setDockPopupVisible(false)`：closing=true + exit 动画（110ms
  /// InCubic → dismissed 时 hide）。
  void _startClosing() {
    if (!_portal.isShowing || _closing) return;
    _emphasis.clear();
    _closing = true;
    if (_reduceMotion) {
      _dismissImmediately();
    } else {
      // KOS: dock/DockWindowPreview.qml:158-166 —— exit 110ms InCubic。
      _reveal.animateBack(
        0,
        duration: kDockPreviewExitDuration,
        curve: Curves.easeInCubic,
      );
    }
  }

  /// KOS `dismissDockPopupImmediately`（DockWindowPreview.qml:120-128）：
  /// 停全部 timer/动画、reveal=0、portal hide、emphasis 释放。
  void _dismissImmediately() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _preRoll?.cancel();
    _emphasis.clear();
    _closing = false;
    _menuClosing = false;
    _popupHovered = false;
    _coordinator.release(this);
    if (_menu) _coordinator.menuOpen = false;
    if (!mounted) return;
    _portal.hide();
    _reveal.value = 0;
    if (_menu) setState(() => _menu = false);
  }

  /// [DockPopup] 契约：被其他 popup 抢占时立即收场（KOS
  /// `DockModelService.dismissDockPopupImmediately`，dock/DockModelService.qml:
  /// 56-63,65-72）。
  @override
  void dismissDockPopupImmediately() => _dismissImmediately();

  // ── 图标侧 hover（KOS DockIcon.qml:939-944 onEntered/onExited）──────────

  /// 由 DockIcon 的 MouseRegion onEnter 转发：arm 300ms dwell。
  void onIconEnter() {
    _iconHovered = true;
    _closeTimer?.cancel();
    // KOS: dock/DockWindowPreview.qml:533-539 —— 关闭中指针回到图标 →
    // cancelClosing + handoff。
    if (_portal.isShowing && !_menu) {
      _openPreview();
      return;
    }
    _openTimer?.cancel();
    // 无窗图标不 arm（KOS `_previewWindowId` 为空即 skip，DockIcon.qml:
    // 938-941）；菜单开着/拖拽中也不 arm。
    // KOS: dock/DockModelService.qml `activeContextMenu` —— 行内任一
    // 图标菜单开着时，全体 previewDelay 抑制（不止本图标）。
    if (widget.windows.isEmpty ||
        widget.dragging ||
        _menu ||
        _coordinator.menuOpen) {
      return;
    }
    _openTimer = Timer(kDockPreviewDelay, () {
      if (_iconHovered) _openPreview();
    });
  }

  /// 由 DockIcon 的 MouseRegion onExit 转发：取消 dwell、启动 130ms
  /// closeDelay（指针有窗口跨 gap 进 popup）。
  void onIconExit() {
    _iconHovered = false;
    _openTimer?.cancel();
    _armCloseDelay();
  }

  /// KOS `previewCloseDelay`（DockIcon.qml:514-520）：130ms 后图标与
  /// popup 都不 hover 才关。
  void _armCloseDelay() {
    if (_menu) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(kDockPreviewCloseDelay, () {
      if (!_iconHovered && !_popupHovered) _startClosing();
    });
  }

  // ── popup 侧 hover（KOS DockIcon.qml:452-459 onPointerInsideChanged）────

  void _popupEnter() {
    _popupHovered = true;
    _closeTimer?.cancel();
    if (_closing) {
      // 关闭中进入 popup → handoff 回弹（30ms）。
      _openPreview();
    }
  }

  void _popupExit() {
    _popupHovered = false;
    // 图标仍 hover 时不启动关闭（KOS: `else if (!icon._hovering)`）。
    if (!_iconHovered) _armCloseDelay();
  }

  // ── 右键菜单（KOS DockIcon.qml:894-932 pinned 分支）─────────────────────

  /// 由 DockIcon 的 `onSecondaryTap` 转发。
  void openContextMenu() {
    if (widget.dragging || !ShellSurfacePresentation.visibleOf(context)) {
      return;
    }
    // KOS: dock/DockIcon.qml:902 `previewDelay.stop()` —— 右键是独立交互，
    // 收掉预览 dwell，菜单独占 popup 协调器。
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _preRoll?.cancel();
    _emphasis.clear();
    _closing = false;
    _menuClosing = false;
    _popupHovered = false;
    // KOS: dock/DockModelService.qml:34-88 —— 行内单例 popup：开菜单前
    // 先收掉上一只 popup；菜单标记对全体 anchor 可见（抑制 dwell）。
    _coordinator.activate(this);
    _coordinator.menuOpen = true;
    // 先置 _menu 再清 reveal：value=0 的 dismissed 监听看到 _menu 会跳过
    // portal.hide，避免菜单接管时「hide→show」闪现。
    setState(() => _menu = true);
    _reveal.value = 0;
    _portal.show();
    // ACCEPTANCE 菜单条款：150ms OutCubic 开（140ms InCubic 关见
    // [_closeMenu]）；开/关共用 `_reveal` 驱动面板变换。
    if (_reduceMotion) {
      _reveal.value = 1;
    } else {
      _reveal.animateTo(
        1,
        duration: kDockMenuOpenDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 菜单关闭：140ms InCubic 退场（ACCEPTANCE 菜单条款，
  /// [kDockMenuCloseDuration]），播完由 dismissed 监听收 portal；
  /// reduceMotion 退化即关。
  void _closeMenu() {
    if (!_menu || _menuClosing) return;
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _preRoll?.cancel();
    _emphasis.clear();
    _coordinator.menuOpen = false;
    if (_reduceMotion) {
      _dismissImmediately();
      return;
    }
    _menuClosing = true;
    _reveal.animateBack(
      0,
      duration: kDockMenuCloseDuration,
      curve: Curves.easeInCubic,
    );
  }

  void _menuOpen() {
    _closeMenu();
    // KOS: dock/DockIcon.qml:416-419 `open` → activateApp（无窗 launch、
    // 否则 activate MRU 首窗——CONSTRAINTS §5 无 minimize 分支）。
    final services = ShellServicesScope.of(context);
    if (widget.windows.isEmpty) {
      final id = widget.launchId;
      if (id != null) {
        unawaited(services.launchApplication(id, monitorId: widget.monitorId));
      }
    } else {
      services.activateWindow(widget.windows.first.id);
    }
  }

  void _menuNewWindow() {
    _closeMenu();
    // KOS: dock/DockIcon.qml:420-421 `new_window` → launchNewWindow。
    final id = widget.launchId;
    if (id == null) return;
    unawaited(
      ShellServicesScope.of(
        context,
      ).launchApplication(id, monitorId: widget.monitorId),
    );
  }

  void _menuUnpin() {
    _closeMenu();
    // KOS: dock/DockIcon.qml:424-425 `unpin` → AppActionService.unpin；
    // Denial 侧为 updatePins 移除本 pin（dock_icons.dart `_savePins`）。
    unawaited(widget.onTogglePin());
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _preRoll?.cancel();
    _emphasis.dispose();
    _coordinator.release(this);
    if (_menu) _coordinator.menuOpen = false;
    _reveal.dispose();
    super.dispose();
  }

  // ── 布局/绘制 ─────────────────────────────────────────────────────────

  ({Rect anchor, Rect output}) _geometry(OverlayChildLayoutInfo layout) => (
    anchor: MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    ),
    output: (widget.monitorBounds ?? (Offset.zero & layout.overlaySize))
        .intersect(Offset.zero & layout.overlaySize),
  );

  /// 预览 popup 宽：rowPadding*2 + count*cardWidth + (count-1)*rowSpacing，
  /// clamp 到 max(300, outputW*0.88) 与下限 cardWidth+padding*2。
  ///
  /// KOS: dock/DockWindowPreview.qml:55-65。
  double _previewWidth(Rect output) {
    final count = widget.windows.length;
    final natural = count == 0
        ? 0.0
        : kDockPreviewRowPadding * 2 +
              count * kDockPreviewCardWidth +
              (count - 1) * kDockPreviewRowSpacing;
    final maxAllowed = math.max(
      kDockPreviewMinPopupWidth,
      output.width * kDockPreviewMaxWidthRatio,
    );
    return math.min(
      maxAllowed,
      math.max(kDockPreviewCardWidth + kDockPreviewRowPadding * 2, natural),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, layout) =>
          _menu ? _buildMenu(context, layout) : _buildPreview(context, layout),
      child: widget.child,
    );
  }

  /// 预览 popup 内容：顶部 26px 工具条（appName [· N 个窗口] + 「+」）+
  /// 横向滚动卡行。容器含 gap 桥带（KOS 两 surface 间的 pointerInside
  /// 桥接 → 这里同一个 MouseRegion 覆到图标顶边）。
  Widget _buildPreview(BuildContext context, OverlayChildLayoutInfo layout) {
    if (widget.windows.isEmpty || widget.dragging) {
      _emphasis.clear();
      return const SizedBox.shrink();
    }
    final geometry = _geometry(layout);
    final width = _previewWidth(geometry.output);
    const height = kDockPreviewPopupHeight;
    const gap = kDockPreviewGap;
    final left = (geometry.anchor.center.dx - width / 2).clamp(
      geometry.output.left + kDockPopupEdgeMargin,
      math.max(
        geometry.output.left + kDockPopupEdgeMargin,
        geometry.output.right - kDockPopupEdgeMargin - width,
      ),
    );
    final top = geometry.anchor.top - gap - height;
    final services = ShellServicesScope.of(context);
    // KOS: dock/DockWindowPreview.qml:46-49 `toolbarLabel`：
    // `appName`（count>1 → `appName · N 个窗口`；zh locale 用 KOS 原文，
    // 其他 locale 用 "windows"——ShellStrings 无此键）。
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final count = widget.windows.length;
    final label = widget.name.trim().isEmpty
        ? (chinese ? '窗口' : 'Windows')
        : widget.name.trim();
    final toolbarLabel = count > 1
        ? '$label · $count ${chinese ? '个窗口' : 'windows'}'
        : label;
    // 容器高 = gap + popup 高、面板顶对齐 → 底部 6px 桥带贴着图标顶
    // （MouseRegion 整覆桥带，替代 KOS pointerInside 跨 surface 桥接；
    // taskbar `height + 8` 范式）。
    return Stack(
      children: [
        Positioned(
          left: left.toDouble(),
          top: top,
          width: width,
          height: height + gap,
          child: ShellInputRegion(
            debugLabel: 'Dock window preview',
            child: MouseRegion(
              onEnter: (_) => _popupEnter(),
              onExit: (_) => _popupExit(),
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, _) {
                      // KOS: dock/DockWindowPreview.qml:172-194 —
                      // opacity=reveal；scale=0.94+0.06·reveal（transformOrigin
                      // 底部）；y=(1−reveal)·7。revealProgress 已带 easing
                      // （入场 animateTo OutCubic / 退场 reverse InCubic /
                      // handoff forward 30ms），这里直接用 controller 值。
                      // opacity 不套整只面板——backdrop 模糊会随透明度弱化
                      // （「先透明再模糊」）；淡入改由 _DockPreviewPanel 内部
                      // 只作用于前景（backdrop 第一帧即满强度）。
                      final reveal = _reveal.value;
                      return Transform.translate(
                        offset: Offset(0, (1 - reveal) * kDockPreviewSink),
                        child: Transform.scale(
                          scale:
                              kDockPreviewExitScale +
                              (1 - kDockPreviewExitScale) * reveal,
                          alignment: Alignment.bottomCenter,
                          child: _DockPreviewPanel(
                            toolbarLabel: toolbarLabel,
                            windows: widget.windows,
                            services: services,
                            progress: reveal,
                            onNewWindow: widget.launchId == null
                                ? null
                                : () {
                                    // KOS: dock/DockWindowPreview.qml:274-287 —
                                    // launchNewWindow 后关 popup。
                                    final id = widget.launchId!;
                                    _dismissImmediately();
                                    unawaited(
                                      services.launchApplication(
                                        id,
                                        monitorId: widget.monitorId,
                                      ),
                                    );
                                  },
                            onCardEnter: _emphasis.enter,
                            onCardExit: _emphasis.leave,
                            onCardTap: (window) {
                              // KOS: dock/DockWindowPreview.qml:512-515 —
                              // activateWindow + 关 popup。
                              _dismissImmediately();
                              services.activateWindow(window.id);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 右键菜单面板：fullScene 透明 barrier 点外即关 + Esc；150ms 开/140ms
  /// 关 + scale 0.96→1 + 20px 位移（ACCEPTANCE 菜单条款；任务栏
  /// `_buildMenu` 几何范式 window_buttons.dart:629-758）。
  Widget _buildMenu(BuildContext context, OverlayChildLayoutInfo layout) {
    final geometry = _geometry(layout);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final canLaunch = widget.launchId != null;
    final maxHeight = math.max(
      0.0,
      geometry.anchor.top -
          geometry.output.top -
          kDockPopupEdgeMargin -
          kDockPreviewGap,
    );
    if (maxHeight <= 0) return const SizedBox.shrink();
    final openLabel = chinese ? '打开' : 'Open';
    final newLabel = chinese ? '新建窗口' : 'New Window';
    // KOS: dock/DockIcon.qml:921-927 — 第三项随 pinned 状态切换：
    // `pinned ? "取消固定" : "固定此应用"`（window item / 运行中未 pin）。
    final toggleLabel = widget.isPinnedEntry
        ? (chinese ? '取消固定' : 'Unpin')
        : (chinese ? '固定此应用' : 'Keep in Dock');
    final items = <DockMenuItem>[
      DockMenuItem(
        // KOS: dock/DockIcon.qml:917 `"folder-open", "打开", "open"`。
        label: openLabel,
        icon: Icons.folder_open_outlined,
        onTap: _menuOpen,
      ),
      DockMenuItem(
        // KOS: dock/DockIcon.qml:918 `"window-new", "新建窗口"`；
        // 无 launchId 时禁用。
        label: newLabel,
        icon: Icons.add_to_photos_outlined,
        onTap: canLaunch ? _menuNewWindow : null,
      ),
      DockMenuItem(
        // KOS: dock/DockIcon.qml:919-920 `"unpin", "取消固定"`；CONSTRAINTS
        // §5 砍掉 `"close_all"/"minimize"/"close"` 三项。
        label: toggleLabel,
        icon: Icons.push_pin_outlined,
        onTap: _menuUnpin,
      ),
    ];
    return DockMenuOverlay(
      debugLabel: 'Dock icon context menu',
      anchor: geometry.anchor,
      output: geometry.output,
      overlaySize: layout.overlaySize,
      progress: _reveal,
      items: items,
      onDismiss: _closeMenu,
    );
  }
}

/// 预览 popup 玻璃面板：radius 14 + panelGradient + hairline 边，内部
/// Column = 工具条 + 卡行（KOS LiquidGlassPanel → ShellBackdropBlur 近似）。
///
/// KOS: dock/DockWindowPreview.qml:182-523。
class _DockPreviewPanel extends StatelessWidget {
  const _DockPreviewPanel({
    required this.toolbarLabel,
    required this.windows,
    required this.services,
    required this.onNewWindow,
    required this.onCardEnter,
    required this.onCardExit,
    required this.onCardTap,
    this.progress = 1.0,
  });

  final String toolbarLabel;
  final List<ApplicationWindow> windows;
  final ShellServices services;

  /// 「+」新建窗口（无 launchId 时为 null → 不渲染按钮）。
  final VoidCallback? onNewWindow;
  final void Function(int windowId) onCardEnter;
  final void Function(int windowId) onCardExit;
  final void Function(ApplicationWindow window) onCardTap;

  /// 显隐进度（0..1）：只淡前景（渐变+边框+内容），backdrop 模糊不吃
  /// 淡入——外层 Opacity 套整只面板会把模糊层一起淡化（「先透明再模糊」）。
  final double progress;


  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    const radius = BorderRadius.all(
      Radius.circular(kDockPreviewPopupRadius),
    );
    return ShellBackdropBlur(
      blur: theme.backdropBlurEnabled,
      separateChild: true,
      borderRadius: radius,
      // backdrop 层不吃 [progress]——模糊从第一帧就满强度；Opacity 只套前景
      // （渐变+边框+工具条/卡行），避免「先透明再模糊」。
      child: Opacity(
        opacity: progress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: theme.panelGradient(
              colors.panelBackground,
              colors.panelBackgroundBottom,
            ),
            border: Border.all(color: colors.hairlineSoft),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Padding(
            // KOS: dock/DockWindowPreview.qml:215 `anchors.margins:
            // rowPadding`（7px）+ Column spacing 2（:216）。
            padding: const EdgeInsets.all(kDockPreviewRowPadding),
            child: Column(
              children: [
                SizedBox(
                  height: kDockPreviewToolbarHeight,
                  child: Row(
                    children: [
                      Expanded(
                        // KOS: :223-236 — 12px DemiBold、ElideRight。
                        child: Text(
                          toolbarLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (onNewWindow != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: _DockPreviewPlusButton(onTap: onNewWindow!),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: kDockPreviewToolbarGap),
                // KOS: :292-299 Flickable（StopAtBounds + clip）——
                // 卡数多超宽时横向滚动。
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.hardEdge,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        for (final (i, window) in windows.indexed) ...[
                          if (i > 0)
                            const SizedBox(width: kDockPreviewRowSpacing),
                          MouseRegion(
                            key: ValueKey(window.id),
                            onEnter: (_) => onCardEnter(window.id),
                            onExit: (_) => onCardExit(window.id),
                            child: _DockPreviewCard(
                              window: window,
                              services: services,
                              onTap: () => onCardTap(window),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// 「+」新建窗口按钮（34×26、radius 8；hover accent@0.35/边@0.65，正常
/// textPrimary@0.08/边 hairline）。
///
/// KOS: dock/DockWindowPreview.qml:238-289。
class _DockPreviewPlusButton extends StatefulWidget {
  const _DockPreviewPlusButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DockPreviewPlusButton> createState() => _DockPreviewPlusButtonState();
}

class _DockPreviewPlusButtonState extends State<_DockPreviewPlusButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // KOS: :253-258 `Behavior on color/border.color` 100ms。
          duration: const Duration(milliseconds: 100),
          width: kDockPreviewPlusWidth,
          height: kDockPreviewPlusHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kDockPreviewPlusRadius),
            color: _hovered
                ? theme.accent.withValues(alpha: kDockPreviewPlusHoverAlpha)
                : colors.textPrimary.withValues(
                    alpha: kDockPreviewPlusBgAlpha,
                  ),
            border: Border.all(
              color: _hovered
                  ? theme.accent.withValues(
                      alpha: kDockPreviewPlusHoverBorderAlpha,
                    )
                  : colors.hairline,
            ),
          ),
          child: Center(
            child: Text(
              '+',
              // KOS: :263-266 — 21px Medium、前景色。
              style: TextStyle(
                fontSize: 16,
                height: 1,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单窗预览卡（174×124、radius 8）：缩略图区 + 底部标题。无「×」关闭钮
/// （CONSTRAINTS §5：closeWindow 协议缺口，记入 docs/visual-deltas.md）。
///
/// KOS: dock/DockWindowPreview.qml:306-517（去 :459-503 closeBtn 分支）。
class _DockPreviewCard extends StatefulWidget {
  const _DockPreviewCard({
    required this.window,
    required this.services,
    required this.onTap,
  });

  final ApplicationWindow window;
  final ShellServices services;
  final VoidCallback onTap;

  @override
  State<_DockPreviewCard> createState() => _DockPreviewCardState();
}

class _DockPreviewCardState extends State<_DockPreviewCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return MouseRegion(
      cursor: widget.services.linkCursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // KOS: :341-343 `Behavior on color` 100ms。
          duration: const Duration(milliseconds: 100),
          width: kDockPreviewCardWidth,
          height: kDockPreviewCardHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kDockPreviewCardRadius),
            // KOS: :332-338 — hover 前景色 tint；激活窗未 hover 时 accent
            // 0.16 tint。
            color: _hovered
                ? colors.textPrimary.withValues(
                    alpha: kDockPreviewCardHoverAlpha,
                  )
                : (widget.window.active
                      ? theme.accent.withValues(
                          alpha: kDockPreviewCardActiveAlpha,
                        )
                      : Colors.transparent),
          ),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  // KOS: :352-359 — 缩略图区 top/left/right 6、bottom 5。
                  padding: const EdgeInsets.fromLTRB(
                    kDockPreviewThumbMargin,
                    kDockPreviewThumbMargin,
                    kDockPreviewThumbMargin,
                    kDockPreviewThumbBottomGap,
                  ),
                  child: ClipRRect(
                    // KOS: :378-395 — 4px 圆角裁切预览纹理。
                    borderRadius: BorderRadius.circular(
                      kDockPreviewThumbRadius,
                    ),
                    child: ExcludeSemantics(
                      child: FittedBox(
                        // KOS: `Image.PreserveAspectFit`（:365）→ contain；
                        // 预览纹理不可用时 SDK 内部回退应用图标。
                        fit: BoxFit.contain,
                        child: widget.services.buildWindowPreview(
                          context,
                          widget.window.id,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                // KOS: :441-457 — 标题 bottom margins 7、11px DemiBold、
                // 居中、ElideRight（`Text.Outline` → shadow token）。
                padding: const EdgeInsets.fromLTRB(
                  kDockPreviewCardTitleMargin,
                  0,
                  kDockPreviewCardTitleMargin,
                  kDockPreviewCardTitleMargin,
                ),
                child: Semantics(
                  label: widget.window.title,
                  button: true,
                  child: Text(
                    widget.window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      // KOS: dock/DockWindowPreview.qml:451-454 — 11px
                      // DemiBold + `Text.Outline` 黑0.45 → shellTheme
                      // shadow token（不硬编码颜色，记 visual-deltas）。
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                      shadows: [
                        Shadow(color: colors.shadow, blurRadius: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
