/// TASK-08 状态格弹层共享骨架：Wi-Fi / 蓝牙面板共用的 PopupMotion 动画宿主、
/// 玻璃面板表面与列表行件（TASK-09 控制中心复用同一批件）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 动画走 KOS `common/PopupMotion.qml` + `AnimatedPopupWindow.qml`：
///   `revealProgress` 驱动 `opacity`（:16）与 `scale = 0.96 + 0.04*progress`
///   （:17-18），`transformOrigin = motionOrigin`（bottom dock → Bottom，
///   面板从格向上弹）；开 150ms OutCubic / 关 140ms InCubic
///   （common/AppearanceTokens.qml:514-516 `popupOpenDuration:150` /
///   `popupCloseDuration:140` / `popupStartScale:0.96`）。
/// - 锚定：bottom dock → `edges/gravity = Top`、`margins.top = -8/-6`
///   （bar/NetworkPanel.qml:50-55、bar/BluetoothPanel.qml:27-34）——面板底边
///   贴格顶 −gap；屏内 clamp（`kDockPopupEdgeMargin`）。
/// - 表面：KOS `LiquidGlassPanel` → `ShellBackdropBlur` + `panelGradient` +
///   hairlineSoft 边（`_DockPreviewPanel` 同式近似，squircle → circular 记
///   docs/visual-deltas.md）。
/// - 单例互斥：`DockPopupCoordinator.activate/release`（KOS
///   `DockModelService.activeDockPopup`，dock/DockModelService.qml:32-39,
///   65-77）；打开前收掉上一只 popup，被抢占时立即收场（不播退场）。
/// - 点外即关 + Esc：KOS 面板是独立 Wayland PopupWindow（出焦即关由
///   compositor 管），Denial OverlayPortal 无独立 surface → `fullScene`
///   输入区 + 透明 barrier（`DockMenuOverlay` 范式），Esc 由
///   `keyboardPolicy: capture` + `CallbackShortcuts` 提供。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/glass_configuration.dart'
    show ShellTransparencyMode;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/surfaces.dart' show ShellSurfacePresentation;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/dock_tokens.dart';
import 'dock_backdrop_blur.dart';
import 'dock_preview_popup.dart';

/// The full Dock body supplies the vertical boundary for status popups.
class DockStatusPanelBounds extends InheritedWidget {
  const DockStatusPanelBounds({required super.child, super.key});

  @override
  bool updateShouldNotify(DockStatusPanelBounds oldWidget) => false;
}

/// 面板内容的 Esc 分步钩子（KOS `bar/ControlCenterPanel.qml:512-524`：确认框、
/// 子页、整面板逐级回退）。面板内容在 initState 里经
/// [DockStatusPanelAnchorState.setEscapeHandler] 注册自己；未注册（Wi-Fi、
/// 蓝牙单面板无子页层）则 Esc 恒直关整面板（KOS 同）。
abstract interface class DockPanelEscapeHandler {
  /// 消费一级 Esc：true = 已处理（面板保持开），false = 未消费则关面板。
  bool handleEscapeStep();
}

/// 状态格面板宿主：把 [child]（26px 格）包成 `OverlayPortal` 锚点，点击
/// [onToggle] 开/关面板。实现 [DockPopup] 契约参与全 pill 单例互斥。
///
/// 生命周期（对齐 `DockPreviewAnchor` 范式）：
/// - `open()`：coordinator.activate → portal.show → reveal 0→1（150ms
///   OutCubic）；已开再点 toggle → 播 140ms InCubic 退场后收 portal；
/// - 被 `activate` 抢占 / surface 不可见 / dispose → `dismissDockPopup
///   Immediately` 立即收场（KOS `dismissDockPopupImmediately`，
///   dock/DockModelService.qml:56-63）。
/// - [onOpened] 在每次**由关转开**时回调一次（KOS `open()` →
///   `refreshWifiNetworks()`/`refreshBluetoothDevices()` 语义，
///   NetworkPanel.qml:84-91 / BluetoothPanel.qml:53-58）；toggle 重入开着
///   的面板不重复触发（KOS `toggle` 已是 close 分支，preview 重入也不重
///   播入场——这里只在冷开时回调）。
abstract class DockStatusPanelAnchor extends StatefulWidget {
  const DockStatusPanelAnchor({
    required this.coordinator,
    required this.child,
    super.key,
  });

  /// 全 pill 唯一协调器；null → 自建实例（独立宿主/单测退化为无协调，
  /// 同 `DockPreviewAnchor` 缺省语义）。
  final DockPopupCoordinator? coordinator;

  /// 26px 状态格本体（命中区/图标在格内）。
  final Widget child;

  /// 面板宽/高/圆角/与格间距（KOS `margins.top` 负值的绝对值）。
  double get panelWidth;
  double get panelHeight;
  double get panelRadius;
  double get panelGap;

  /// 面板冷开回调（KOS `open()` 内的 refresh/scan）。
  void onOpened();

  /// 面板内容（overlayChild，reveal 变换由本骨架施加）。
  Widget buildPanel(BuildContext context);
}

class DockStatusPanelAnchorState<T extends DockStatusPanelAnchor>
    extends State<T>
    with SingleTickerProviderStateMixin
    implements DockPopup {
  final _portal = OverlayPortalController();
  late final DockPopupCoordinator _coordinator =
      widget.coordinator ?? DockPopupCoordinator();

  /// KOS `revealProgress`（AnimatedPopupWindow.qml:16-18 消费）：0=隐藏，
  /// 1=完全展开；驱动 opacity 与 scale 0.96→1。
  late final AnimationController _reveal;
  bool _closing = false;

  /// 面板开合态（KOS `ControlCenterToggle.panelOpen` 的等价源）：`open()` /
  /// `close()` 同步翻转（KOS `popupMotion.requestedOpen`，非退场动画进度），
  /// 经 [DockStatusPanelOpenScope] 下发给格。
  bool _open = false;

  /// 面板内容的 Esc 分步钩子（[DockPanelEscapeHandler]）；null → Esc 直关。
  DockPanelEscapeHandler? _escapeHandler;
  void _setOpen(bool value) {
    if (_open == value) return;
    if (!mounted) {
      _open = value;
      return;
    }
    setState(() => _open = value);
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  /// 面板当前在屏或入场/退场中（测试与格互斥断言用）。
  bool get panelShowing => _portal.isShowing;

  @override
  void initState() {
    super.initState();
    _reveal =
        AnimationController(
          vsync: this,
          // KOS: common/AppearanceTokens.qml:514-515 —
          // `popupOpenDuration:150` / `popupCloseDuration:140`。
          duration: kDockMenuOpenDuration,
          reverseDuration: kDockMenuCloseDuration,
        )..addStatusListener((status) {
          // KOS PopupMotion.qml:22-32 — `close()` 动画到 0 完成后
          // `mapped=false`：退场播完才收 portal + 释放协调器。
          if (status == AnimationStatus.dismissed && mounted) {
            _closing = false;
            _portal.hide();
            _coordinator.release(this);
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // taskbar `window_buttons.dart:357-368` / `DockPreviewAnchor` 范式：
    // surface 不可见 → 立即关（KOS `onOutputAvailableChanged → close()`，
    // NetworkPanel.qml:100-106 / BluetoothPanel.qml:61-67）。
    if (!ShellSurfacePresentation.visibleOf(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ShellSurfacePresentation.visibleOf(context)) {
          _dismissImmediately();
        }
      });
    }
  }

  @override
  void dispose() {
    _coordinator.release(this);
    _reveal.dispose();
    super.dispose();
  }

  /// KOS `toggle(item)`（NetworkPanel.qml:75-82）：开着 → `close()`；否则
  /// `open()`。
  void togglePanel() {
    if (_portal.isShowing) {
      _closePanel();
    } else {
      _openPanel();
    }
  }

  /// KOS `open()`：anchor + show + 刷新回调（NetworkPanel.qml:84-91、
  /// BluetoothPanel.qml:53-58）+ PopupMotion 150ms OutCubic 入场。
  void _openPanel() {
    if (!mounted || !ShellSurfacePresentation.visibleOf(context)) return;
    // KOS `openDockPopup`（dock/DockModelService.qml:65-72）：先收掉上
    // 一只 popup（立即 dismiss），再占活跃位。
    _coordinator.activate(this);
    _closing = false;
    _portal.show();
    _reveal.value = 0;
    widget.onOpened();
    // KOS `popupMotion.requestedOpen = true`（开即翻）。
    _setOpen(true);
    if (_reduceMotion) {
      _reveal.value = 1;
    } else {
      unawaited(_reveal.animateTo(1, curve: Curves.easeOutCubic));
    }
  }

  /// KOS `close()`（NetworkPanel.qml:95-98）→ 140ms InCubic 退场，播完由
  /// dismissed 监听收 portal。
  void _closePanel() {
    if (!_portal.isShowing || _closing) return;
    _closing = true;
    // KOS `close()` → `requestedOpen = false`（立即翻，退场动画不停表）。
    _setOpen(false);
    if (_reduceMotion) {
      _dismissImmediately();
    } else {
      unawaited(_reveal.animateBack(0, curve: Curves.easeInCubic));
    }
  }

  /// 面板内容注册 Esc 分步钩子（KOS `ControlCenterPanel.qml:512-524`）：
  /// 控制中心面板在 initState/dispose 里注册与注销自己；Wi-Fi/蓝牙单面板
  /// 不注册 → `_escapeHandler == null` → Esc 直关。
  void setEscapeHandler(DockPanelEscapeHandler? handler) =>
      _escapeHandler = handler;

  /// Esc（KOS `Shortcut { sequence: "Escape" }`，Panel:512-524）：先给面板内容
  /// 分步机会（子页开着 → 退回主页面），未消费 → 关整面板。
  void _handleEscape() {
    if (_escapeHandler?.handleEscapeStep() ?? false) return;
    _closePanel();
  }

  void _dismissImmediately() {
    _closing = false;
    _coordinator.release(this);
    if (!mounted) return;
    if (_portal.isShowing) _portal.hide();
    _reveal.value = 0;
    _setOpen(false);
  }

  /// [DockPopup] 契约：被其他 popup 抢占时立即收场（KOS
  /// `DockModelService.dismissDockPopupImmediately`）。
  @override
  void dismissDockPopupImmediately() => _dismissImmediately();

  /// 最近祖先 anchor 的 toggle（格 `onToggle` 经 `Builder` 上查 anchor
  /// state——child 是 anchor 的 OverlayPortal child，ancestor 命中本
  /// anchor；找不到时返回 null 兼容独立挂载）。
  static void togglePanelOf(BuildContext context) {
    context
        .findAncestorStateOfType<DockStatusPanelAnchorState>()
        ?.togglePanel();
  }

  /// 最近祖先 anchor state（面板内容注册 Esc 分步钩子用；找不到 → null）。
  static DockStatusPanelAnchorState? of(BuildContext context) =>
      context.findAncestorStateOfType<DockStatusPanelAnchorState>();

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: _buildOverlay,
    // 格（controlcenter/wifi/bt）经 scope 读 `panelOpen`。
    child: DockStatusPanelOpenScope(open: _open, child: widget.child),
  );

  /// 最近祖先 anchor 的面板开合态（无祖先 → false；KOS
  /// `ControlCenterToggle.panelOpen`）。
  static bool panelOpenOf(BuildContext context) =>
      DockStatusPanelOpenScope.of(context);

  /// 浮层内容：fullScene 输入区 + 点外即关 + Esc + 面板锚到格顶 −gap。
  ///
  /// KOS: bar/NetworkPanel.qml:43-61（dock bottom → edges/gravity Top、
  /// margins.top −8）/ bar/BluetoothPanel.qml:23-41（同式 −6）；点外即关在
  /// KOS 由独立 popup surface 的失焦语义承担（`DockMenuOverlay` 屏障范式）。
  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo layout) {
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final output = Offset.zero & layout.overlaySize;
    final width = widget.panelWidth;
    final dockElement = context
        .getElementForInheritedWidgetOfExactType<DockStatusPanelBounds>();
    final dockBox = dockElement?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    final dockTop = dockBox is RenderBox && overlayBox is RenderBox
        ? dockBox.localToGlobal(Offset.zero, ancestor: overlayBox).dy
        : anchor.top;
    final gap = widget.panelGap;
    final maxHeight = math.max(
      0.0,
      dockTop - output.top - kDockPopupEdgeMargin - gap,
    );
    if (maxHeight <= 0) return const SizedBox.shrink();
    final height = math.min(widget.panelHeight, maxHeight);
    final left = (anchor.center.dx - width / 2).clamp(
      output.left + kDockPopupEdgeMargin,
      math.max(
        output.left + kDockPopupEdgeMargin,
        output.right - kDockPopupEdgeMargin - width,
      ),
    );
    return ShellInputRegion(
      debugLabel: 'Dock status panel',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: CallbackShortcuts(
        bindings: {
          // Esc 分步：面板内容（控制中心子页）先消费，否则关整面板
          // （KOS `Shortcut { sequence: "Escape" }`，ControlCenterPanel.qml:512-524）。
          const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // 点外即关（`DockMenuOverlay` barrier 范式：opaque、点击不穿透
              // ——Overlay 单树模型下下层格收不到这次点击；KOS 的 popup 是
              // 独立 surface、点击穿透语义无法复刻，偏差记
              // docs/visual-deltas.md）。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => _closePanel(),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                // 面板底边贴格顶 −gap（KOS `anchor.margins.top: -8/-6`）。
                bottom: layout.overlaySize.height - dockTop + gap,
                width: width,
                height: height,
                child: AnimatedBuilder(
                  animation: _reveal,
                  builder: (context, _) {
                    final v = _reveal.value;
                    // KOS: common/AnimatedPopupWindow.qml:16-18 —
                    // opacity = revealProgress；scale = 0.96 + 0.04·reveal，
                    // transformOrigin = Bottom（bottom dock 向上弹）。
                    // opacity 不套整只面板——backdrop 模糊会随透明度弱化
                    // （「先透明再模糊」）；淡入改由 DockStatusPanelSurface
                    // 内部只作用于前景（backdrop 第一帧即满强度）。
                    return Transform.scale(
                      scale:
                          kDockMenuEnterScale + (1 - kDockMenuEnterScale) * v,
                      alignment: Alignment.bottomCenter,
                      // reveal 经 scope 下发：DockStatusPanelSurface 读它只淡
                      // 前景（backdrop 模糊不吃淡入）。open 与格外层同源。
                      child: DockStatusPanelOpenScope(
                        open: _open,
                        reveal: v,
                        child: widget.buildPanel(context),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态面板玻璃表面：`ShellBackdropBlur` + panelGradient。
/// 普通模糊保留 hairline；glass 按官方 quick-settings tile 使用材质亮边。
/// （`_DockPreviewPanel`/`DockMenuPanel` 同式近似 KOS `LiquidGlassPanel`）。
///
/// 前景（渐变+边框+内容）按 `DockStatusPanelOpenScope.revealOf` 淡入；
/// backdrop 模糊层不吃淡入——从第一帧就满强度，避免「先透明再模糊」。
class DockStatusPanelSurface extends StatelessWidget {
  const DockStatusPanelSurface({
    required this.radius,
    required this.child,
    this.clipBackdropToRadius = false,
    super.key,
  });

  /// 面板圆角（Wi-Fi 19 / 蓝牙 20，squircle 退化记 deltas）。
  final double radius;
  final Widget child;
  final bool clipBackdropToRadius;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final radius = BorderRadius.circular(this.radius);
    // reveal 来自 DockStatusPanelAnchor 的 overlay scope；无祖先 → 1（独立
    // 挂载/测试默认全展开）。
    final reveal = DockStatusPanelOpenScope.revealOf(context);
    final materialOpacity = _DockStatusPanelFadeScope.of(context);
    return DockBackdropBlur(
      clipBackdropToRadius: clipBackdropToRadius,
      // Keep static and fading glass compositing consistent. srcOver preserves
      // destination pixels where filter output is only partially opaque.
      glassBlendMode: BlendMode.srcOver,
      blur: theme.backdropBlurEnabled,
      borderRadius: radius,
      opacity: materialOpacity < 1
          ? AlwaysStoppedAnimation(materialOpacity)
          : null,
      child: Opacity(
        opacity: reveal,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: theme.panelGradient(
              colors.panelBackground,
              colors.panelBackgroundBottom,
            ),
            // Match the official quick-settings tile: glass already draws its
            // rounded rim. A second stroke adds another blended edge over it.
            border: theme.transparencyMode == ShellTransparencyMode.glass
                ? null
                : Border.all(color: colors.hairlineSoft),
          ),
          child: ClipRRect(borderRadius: radius, child: child),
        ),
      ),
    );
  }
}

/// Fade each glass replacement separately from its foreground controls.
/// An outer Opacity would flatten all cards, their backdrop filters and text
/// into one intermediate image (contrary to ShellBackdropBlur's contract).
class DockStatusPanelFade extends StatelessWidget {
  const DockStatusPanelFade({
    required this.opacity,
    required this.child,
    super.key,
  });

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) => _DockStatusPanelFadeScope(
    opacity: opacity.clamp(0.0, 1.0) * _DockStatusPanelFadeScope.of(context),
    child: child,
  );
}

class _DockStatusPanelFadeScope extends InheritedWidget {
  const _DockStatusPanelFadeScope({
    required this.opacity,
    required super.child,
  });

  final double opacity;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_DockStatusPanelFadeScope>()
          ?.opacity ??
      1.0;

  @override
  bool updateShouldNotify(_DockStatusPanelFadeScope oldWidget) =>
      opacity != oldWidget.opacity;
}

/// 面板底脚（「无线局域网设置…」/「蓝牙设置…」）：50px 高、顶部 1px 分隔、
/// 左 18px 14px DemiBold 标签。
///
/// KOS: bar/NetworkPanel.qml:541-564；bar/BluetoothPanel.qml:179-201。
/// `onTap == null` → 禁用态（SDK 无 `settings.open` 等价物时的缺口降级，
/// 记 docs/visual-deltas.md）。
class DockStatusPanelFooter extends StatelessWidget {
  const DockStatusPanelFooter({
    required this.label,
    required this.onTap,
    required this.cursor,
    super.key,
  });

  final String label;

  /// null → 禁用（文本降透明度、无 hover、无点击）。
  final VoidCallback? onTap;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final enabled = onTap != null;
    return SizedBox(
      // KOS: bar/NetworkPanel.qml:541-564 — 50px、顶部 1px 分隔。
      height: kDockStatusFooterHeight,
      child: Column(
        children: [
          Container(
            height: 1,
            // KOS `Qt.rgba(1,1,1,0.16)` → textPrimary@0.16 语义映射。
            color: colors.textPrimary.withValues(
              alpha: kDockStatusFooterDividerAlpha,
            ),
          ),
          Expanded(
            child: MouseRegion(
              cursor: enabled ? cursor : SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: kDockStatusFooterLabelLeft,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // KOS :551-555 — 14px DemiBold 前景色。
                        fontSize: kDockStatusFooterFontSize,
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? colors.textPrimary
                            : colors.textTertiary,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板空态行：12px、居中、前景降透明度。
///
/// KOS: bar/NetworkPanel.qml:519-536（「正在扫描…」/「未发现可用 Wi‑Fi」）；
/// bar/BluetoothPanel.qml:151-176（「蓝牙已关闭」/「正在刷新…」/「未发现已配
/// 对设备」）。
class DockStatusPanelEmptyLabel extends StatelessWidget {
  const DockStatusPanelEmptyLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontSize: kDockStatusEmptyFontSize,
          color: colors.textSecondary.withValues(alpha: kDockStatusEmptyAlpha),
        ),
      ),
    );
  }
}

/// 面板开合态下发（KOS `ControlCenterToggle.panelOpen` 的等价）：状态格
/// （控制中心格）据它调透明度并隐藏 tooltip。
///
/// 面板开合态与 reveal 进度下发（KOS `ControlCenterToggle.panelOpen` 的等价
/// + `AnimatedPopupWindow.revealProgress`）：状态格（控制中心格）据 `open`
/// 调透明度并隐藏 tooltip；`DockStatusPanelSurface` 据 `reveal` 淡前景——
/// backdrop 模糊不吃淡入（外层 Opacity 套整只面板会把模糊层一起淡化，
/// 出现「先透明再模糊」），故 reveal 经本 scope 下发给 surface 内部。
///
/// KOS: bar/ControlCenterToggle.qml:32-33（`panelOpen ? 1.0 : 0.88`）、
/// :47（`shown: containsMouse && !panelOpen`）；
/// common/AnimatedPopupWindow.qml:16-18（`revealProgress` 驱动 opacity）。
class DockStatusPanelOpenScope extends InheritedWidget {
  const DockStatusPanelOpenScope({
    required this.open,
    this.reveal = 1.0,
    required super.child,
    super.key,
  });

  /// 面板当前展开（`open()` 后、`close()` 前）。
  final bool open;

  /// `AnimatedPopupWindow.revealProgress`（0=隐藏/关闭中，1=完全展开）；
  /// 由 `DockStatusPanelSurface` 读，只淡前景不动 backdrop 模糊。
  final double reveal;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DockStatusPanelOpenScope>()
          ?.open ??
      false;

  /// panel 的 reveal 进度（无祖先 → 1，独立挂载/测试默认全展开）。
  static double revealOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DockStatusPanelOpenScope>()
          ?.reveal ??
      1.0;

  @override
  bool updateShouldNotify(DockStatusPanelOpenScope oldWidget) =>
      oldWidget.open != open || oldWidget.reveal != reveal;
}
