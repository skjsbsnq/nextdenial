/// DockItem — a single dock entry: app icon, running indicator bar, launch
/// bounce, hover bridge, tooltip, click-to-activate and in-dock reorder drag.
///
/// Ported semantics (line anchors are into quickshell
/// `Modules/Dock/DockItem.qml` unless noted):
/// - bounce 0→19px/220ms OutQuad → 19→0/340ms OutBounce, `onStopped` resets to
///   0 (:86-104); triggered once per `launching` false→true edge or when the
///   first build already sees `launching` (:80-85); only `kind == 'app'` and
///   `launchBounce` (DockService.qml:81, DockModel.js:10).
/// - icon opacity 0.45 when `!available && windowCount == 0` (:126); the whole
///   item is transparent while `dragged` (:61).
/// - indicator bar (Denial deviation, docs/visual-deltas.md): a 10×3 rounded
///   bar in the wallpaper-derived `colorScheme.primary`, visible for app entries
///   with `windowCount > 0 && showIndicators`, at alpha 1.0 focused / 0.8
///   unfocused (:180-189); it sits in the glass inset lane beneath the icon and
///   its geometry never follows magnification (:182).
/// - tooltip text = `name` (`dropHint` while `dropTarget`), delay = 0,
///   visibility `dropTarget || (showTooltip && containsMouse && !pressed &&
///   !dragged && !contextActive)` (:172-177).
/// - gestures: `pressStarted` on any press, `grabOffset = pressPoint − icon
///   centre` (:208-213), 10px `hypot` drag gate (:218-223), `dragMoved` /
///   `dragReleased` / `dragCancelled` (:224-233), `moved` suppresses the click
///   (:234-236), right click and press-and-hold → `contextRequested`
///   (:237-245). Only `kind != 'trash'` entries drag (:216).
library;

import 'dart:async';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'dock_item_math.dart';
import 'dock_surface_math.dart' show kDockIconBottomInset;

export 'dock_item_math.dart';

/// Bounce geometry (DockItem.qml:92).
const double _bounceRise = 19;

/// Rise 220ms OutQuad → fall 340ms OutBounce (DockItem.qml:93-101).
const Duration _bounceUp = Duration(milliseconds: 220);
const Duration _bounceDown = Duration(milliseconds: 340);

/// pressShade 0.3 / 90ms fade (DockItem.qml:115-121).
const double _pressShadeAlpha = 0.3;
const Duration _pressShadeDuration = Duration(milliseconds: 90);

/// Signature for `dragMoved(key, position, offset, size)` (DockItem.qml:57).
/// [position] and [grabOffset] are in scene coordinates.
typedef DockItemDragMoved = void Function(
  String key,
  Offset position,
  Offset grabOffset,
  double iconSize,
);

/// Signature for `dragReleased(key, position)` (DockItem.qml:58).
typedef DockItemDragReleased = void Function(String key, Offset position);

/// A single dock entry. Self-mountable: renders icon + indicator without the
/// TASK-01 layout; magnification, drag reordering and preview gating are
/// consumed by the parent through the callbacks.
class DockItem extends StatefulWidget {
  const DockItem({
    required this.entryKey,
    required this.name,
    required this.appId,
    super.key,
    this.kind = 'app',
    this.launchId,
    this.monitorId,
    this.windowId,
    this.windowCount = 0,
    this.focused = false,
    this.launching = false,
    this.available = true,
    this.dragged = false,
    this.contextActive = false,
    this.dropTarget = false,
    this.dropHint = '',
    this.showTooltip = false,
    this.showIndicators = true,
    this.launchBounce = true,
    this.edge = PanelEdge.bottom,
    this.iconSize = kDockItemDefaultIconSize,
    this.restingIconSize = kDockItemDefaultIconSize,
    this.onHovered,
    this.onHoverLeft,
    this.onPressStarted,
    this.onActivated,
    this.onContextRequested,
    this.onDragMoved,
    this.onDragReleased,
    this.onDragCancelled,
  }) : assert(
         iconSize >= kDockItemMinIconSize && iconSize <= kDockItemMaxIconSize,
         'iconSize must be within $kDockItemMinIconSize–$kDockItemMaxIconSize',
       );

  /// Stable entry identity (`entryKey`, DockItem.qml:14).
  final String entryKey;

  /// Entry kind: `app`, `trash`, `spacer`, `small-spacer`, … (:15,:28).
  final String kind;

  /// Display name; tooltip + semantics label (:16, :173, :204).
  final String name;

  /// Icon identity for `services.buildApplicationIcon`.
  final String appId;

  /// Launch identity for `services.launchApplication` when there is no window.
  final String? launchId;

  /// Target output for `launchApplication`.
  final int? monitorId;

  /// Window to `activateWindow` on click; paired with [windowCount].
  final int? windowId;

  /// Running window count (`windowCount`, :23); drives the indicator dot.
  final int windowCount;

  /// Whether a window of this entry is focused (`focused`, :20) — indicator
  /// alpha 1.0 vs 0.8 (:188).
  final bool focused;

  /// Launch acknowledgement flag (`launching`, :21) — one bounce per
  /// false→true edge.
  final bool launching;

  /// Whether the entry is launchable/available (`available`, :22).
  final bool available;

  /// Parent-driven "being dragged" flag; renders fully transparent (:61).
  final bool dragged;

  /// Whether this entry's context popup is open (`contextActive`, :32).
  final bool contextActive;

  /// External drop hover state (:36); swaps the tooltip to [dropHint].
  final bool dropTarget;

  /// Tooltip text while [dropTarget] (:173).
  final String dropHint;

  /// Tooltip gate supplied by the parent (preview not active); corresponds to
  /// DockSurface.qml:977-987.
  final bool showTooltip;

  /// `DockService.showIndicators` (:181).
  final bool showIndicators;

  /// `DockService.launchBounce` user setting (:81); default true.
  final bool launchBounce;

  /// Dock edge; `bottom` bounces the icon upwards, left/right sideways
  /// (:110-112).
  final PanelEdge edge;

  /// Displayed (possibly magnified) icon edge (`iconSize`, :25). The artwork
  /// itself is laid out/rasterized once at [restingIconSize] and scaled to
  /// this edge by a `Transform.scale` — magnification no longer relayouts the
  /// icon box, so the per-frame wave cannot re-rasterize SVG/PNG artwork.
  final double iconSize;

  /// Unmagnified icon edge (`restingIconSize`, :26): the layout/raster size of
  /// the artwork. The indicator bar no longer derives from it (Denial sizes it
  /// by constants), but it remains part of the entry contract for the parent
  /// layout.
  final double restingIconSize;

  /// `hovered(key)` (:52, :206) — parent feeds magnification.
  final void Function(String key)? onHovered;

  /// `hoverLeft(key)` (:53, :207).
  final void Function(String key)? onHoverLeft;

  /// `pressStarted` (:54, :209) — parent dismisses popups / resets state.
  final VoidCallback? onPressStarted;

  /// `activated(key)` (:55) — fired on an accepted left click in addition to
  /// the built-in activate/launch.
  final void Function(String key)? onActivated;

  /// `contextRequested(key)` (:56, :238, :244); the menu itself is a later
  /// task card.
  final void Function(String key)? onContextRequested;

  /// `dragMoved(key, position, offset, size)` (:57, :224).
  final DockItemDragMoved? onDragMoved;

  /// `dragReleased(key, position)` (:58, :228).
  final DockItemDragReleased? onDragReleased;

  /// `dragCancelled` (:59, :232).
  final VoidCallback? onDragCancelled;

  bool get _spacer => kind == 'spacer' || kind == 'small-spacer'; // :28

  @override
  State<DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<DockItem>
    with SingleTickerProviderStateMixin {
  final _artworkKey = GlobalKey();
  late final AnimationController _bounce;
  late final Animation<double> _bounceValue;

  bool _containsMouse = false;
  bool _pressed = false;
  bool _launching = false; // taskbar _launching re-entry gate

  // Pointer bookkeeping for the self-implemented 10px drag gate
  // (DockItem.qml:208-233). A raw Listener is used instead of
  // Draggable/LongPressDraggable because the source has no long-press delay
  // and no Flutter-style gesture arena: the press fires `pressStarted`
  // immediately and only the hypot gate separates click from drag.
  int? _activePointer;
  bool _downPrimary = true;
  bool _moved = false;
  Offset _pressPoint = Offset.zero;
  Offset _grabOffset = Offset.zero;
  Timer? _holdTimer;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _bounce =
        AnimationController(
          vsync: this,
          duration: _bounceUp + _bounceDown, // 560ms total (:93,:100)
        )..addStatusListener((status) {
          // `onStopped: root.bounce = 0` (:103) — never leave the icon mid-air.
          if (status != AnimationStatus.forward && _bounce.value != 0) {
            _bounce.value = 0;
          }
        });
    _bounceValue = _bounce.drive(
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween<double>(
            begin: 0,
            end: _bounceRise,
          ).chain(CurveTween(curve: Curves.easeOutQuad)), // :88-95
          weight: _bounceUp.inMilliseconds.toDouble(),
        ),
        TweenSequenceItem(
          tween: Tween<double>(
            begin: _bounceRise,
            end: 0,
          ).chain(CurveTween(curve: Curves.bounceOut)), // :96-102
          weight: _bounceDown.inMilliseconds.toDouble(),
        ),
      ]),
    );
    // Component.onCompleted: animateLaunch() (:85) — first frame already true.
    if (widget.launching) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _animateLaunch());
    }
  }

  @override
  void didUpdateWidget(covariant DockItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // onLaunchingChanged: animateLaunch() (:84) — one acknowledgement per edge.
    if (!oldWidget.launching && widget.launching) _animateLaunch();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _bounce.dispose();
    super.dispose();
  }

  /// `animateLaunch()` (:80-83): only app entries, honouring `launchBounce`
  /// and reduce-motion (brief §测试 — bounce zeroed under disableAnimations).
  void _animateLaunch() {
    if (!mounted ||
        !widget.launching ||
        widget.kind != 'app' ||
        !widget.launchBounce ||
        _reduceMotion) {
      return;
    }
    _bounce.forward(from: 0);
  }

  /// Click activation (taskbar `_activate`, window_buttons.dart:446-483):
  /// re-entry-gated, windows → activateWindow, otherwise launchApplication.
  void _activate({bool semantic = false}) {
    // :205 — Accessible.onPressAction sends `activated` unconditionally;
    // only the pointer path is gated by `_moved` (the 10px gate flag may
    // still be set after a drag release until the next pointer down).
    if (_launching || (!semantic && _moved)) return;
    widget.onActivated?.call(widget.entryKey);
    final services = ShellServicesScope.of(context);
    final windowId = widget.windowId;
    if (widget.windowCount > 0 && windowId != null) {
      services.activateWindow(windowId);
      return;
    }
    // Parent contract: windowCount > 0 implies a windowId. Falling through
    // to launchApplication when the invariant is broken matches the source.
    final launchId = widget.launchId;
    if (launchId == null) return;
    _launching = true;
    unawaited(
      services
          .launchApplication(launchId, monitorId: widget.monitorId)
          // taskbar `_activate` catches launch failures
          // (window_buttons.dart:458-465) — never surface them here.
          .catchError((_) => false)
          .whenComplete(() => _launching = false),
    );
  }

  // ---- pointer handling (DockItem.qml:208-246) -----------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointer != null) return; // one gesture at a time
    // :201 — only Left|Right are accepted; ignore middle/stylus buttons.
    if (event.buttons & (kPrimaryButton | kSecondaryButton) == 0) return;
    _activePointer = event.pointer;
    _downPrimary = event.buttons & kPrimaryButton != 0;
    widget.onPressStarted?.call(); // :209 — on press, before any drag math
    _moved = false; // :210
    _pressPoint = event.position; // :211 (mapToItem(null) == scene coords)
    // :212-213 — grabOffset = pressPoint − icon centre.
    final box = _artworkKey.currentContext?.findRenderObject() as RenderBox?;
    final center = box != null
        ? box.localToGlobal(box.size.center(Offset.zero))
        : event.position;
    _grabOffset = _pressPoint - center;
    setState(() => _pressed = true);
    // onPressAndHold → contextRequested when no drag began (:242-245).
    _holdTimer?.cancel();
    _holdTimer = Timer(kLongPressTimeout, () {
      if (!_moved && _activePointer != null) {
        widget.onContextRequested?.call(widget.entryKey);
      }
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    // :216 — trash never drags; drag requires the left button held.
    if (widget.kind == 'trash' ||
        !_downPrimary ||
        event.buttons & kPrimaryButton == 0) {
      return;
    }
    final position = event.position; // :218
    // :219-222 — 10px hypot gate; below it the press stays a click.
    if (!_moved &&
        !dockDragGatePassed(
          position.dx - _pressPoint.dx,
          position.dy - _pressPoint.dy,
        )) {
      return;
    }
    _moved = true; // :223
    _holdTimer?.cancel();
    widget.onDragMoved?.call(
      widget.entryKey,
      position,
      _grabOffset,
      widget.iconSize,
    ); // :224
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _holdTimer?.cancel();
    _activePointer = null;
    setState(() => _pressed = false);
    if (_moved) {
      // :226-228 — a moved gesture ends as dragReleased, never a click.
      widget.onDragReleased?.call(widget.entryKey, event.position);
      return;
    }
    // :234-241 — click: right → contextRequested, left → activated.
    if (!_downPrimary) {
      widget.onContextRequested?.call(widget.entryKey);
    } else {
      _activate();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _holdTimer?.cancel();
    _activePointer = null;
    _moved = true; // :231 — blocks any trailing click
    setState(() => _pressed = false);
    widget.onDragCancelled?.call(); // :232
  }

  /// Bundled icon assets for the launcher and trash rows.
  ///
  /// The launcher uses a custom 3x3 app-grid tile (assets/icons/launcher.svg);
  /// the trash uses Pop! `user-trash`/`user-trash-full` art selected by the
  /// resolved `appId` (`dockTrashIconName`, DockService.qml:237).
  static const String _kLauncherAsset = 'assets/icons/launcher.svg';
  static const String _kTrashAsset = 'assets/icons/trash.svg';
  static const String _kTrashFullAsset = 'assets/icons/trash_full.svg';

  /// Asset paths are package-scoped: in the built shell bundle the SVGs live
  /// under `packages/kos_dock/`, so `SvgPicture.asset` must pass
  /// `package: 'kos_dock'` or the loader misses and paints nothing.
  SvgPicture _bundledGlyph(String asset) => SvgPicture.asset(
    asset,
    package: 'kos_dock',
    // Artwork raster size is the resting edge; magnification scales the
    // box on the GPU (see `build`), so the SVG is rasterized once.
    width: widget.restingIconSize,
    height: widget.restingIconSize,
    // Asset-miss fallback so a packaging slip degrades to a Material glyph
    // instead of an empty slot.
    errorBuilder: (context, error, stackTrace) =>
        Icon(Icons.apps_rounded, size: widget.restingIconSize),
  );

  /// Entry artwork.
  ///
  /// `app` entries go through `services.buildApplicationIcon`
  /// (window_buttons.dart:581-584). The Denial integration's `launcher` and
  /// `trash` rows have no application identity, so they resolve bundled SVG
  /// glyphs instead of Material symbols — the trash row is display-only
  /// (`DockService.qml:252-257` spawns the file manager through a channel the
  /// SDK does not expose). Recorded in docs/visual-deltas.md.
  Widget _artwork(BuildContext context, ShellServices services) =>
      switch (widget.kind) {
        // `_bundledGlyph` pins `width`/`height` — without them the SVG falls
        // back to its 64px viewBox and reads oversized against the
        // neighbouring app icons.
        'launcher' => _bundledGlyph(_kLauncherAsset),
        'trash' => _bundledGlyph(
          widget.appId == 'user-trash-full' ? _kTrashFullAsset : _kTrashAsset,
        ),
        _ => services.buildApplicationIcon(context, widget.appId),
      };

  // ---- build ---------------------------------------------------------------

  bool get _tooltipVisible =>
      widget.dropTarget ||
      (widget.showTooltip &&
          _containsMouse &&
          !_pressed &&
          !widget.dragged &&
          !widget.contextActive); // :175-176

  /// GPU magnification factor for the artwork box: `iconSize` is the displayed
  /// (magnified) edge while the artwork is rasterized at `restingIconSize`.
  /// Falls back to 1 when the resting edge is 0 or the ratio is non-finite.
  double get _iconScale {
    final resting = widget.restingIconSize;
    if (resting <= 0) return 1;
    final scale = widget.iconSize / resting;
    return scale.isFinite ? scale : 1;
  }

  Offset get _bounceOffset => switch (widget.edge) {
    // :112 — horizontal edge bounces the icon upwards; vertical edges bounce
    // toward the scene centre (:110-111). hidden/top share the bottom path.
    PanelEdge.left => Offset(_bounceValue.value, 0),
    PanelEdge.right => Offset(-_bounceValue.value, 0),
    _ => Offset(0, -_bounceValue.value),
  };

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    final showDot =
        widget.kind == 'app' &&
        widget.windowCount > 0 &&
        widget.showIndicators; // :181
    final horizontal =
        widget.edge != PanelEdge.left && widget.edge != PanelEdge.right;
    // Running-indicator bar (:180-189, Denial shape/colour deviation — see
    // docs/visual-deltas.md). Sized by constants, never by [restingIconSize], so
    // hover magnification cannot pulse it (:182); coloured with the
    // wallpaper-derived `colorScheme.primary` so it is not the source's
    // `onSurface` black.
    final indicator = SizedBox(
      width: horizontal ? kDockIndicatorBarLength : kDockIndicatorBarThickness,
      height: horizontal ? kDockIndicatorBarThickness : kDockIndicatorBarLength,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primary.withValues(
            alpha: dockIndicatorAlpha(focused: widget.focused), // :188
          ),
          borderRadius: BorderRadius.circular(kDockIndicatorBarRadius), // :185
        ),
      ),
    );
    // :115-116 — pressed (before drag) / contextActive / dropTarget darken.
    final shade =
        (_pressed && !_moved) || widget.contextActive || widget.dropTarget;
    return Semantics(
      button: true,
      label: widget.name, // :203-205
      onTap: () => _activate(semantic: true), // Accessible.onPressAction :205
      child: MouseRegion(
        cursor: widget._spacer
            ? services.normalCursor
            : services.linkCursor, // :202
        onEnter: (_) {
          setState(() => _containsMouse = true);
          widget.onHovered?.call(widget.entryKey); // :206
        },
        onExit: (_) {
          setState(() => _containsMouse = false);
          widget.onHoverLeft?.call(widget.entryKey); // :207
        },
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Opacity(
            opacity: widget.dragged ? 0 : 1, // :61
            // bounce translate 已内移到 Transform.scale 里（见下方内层
            // AnimatedBuilder），不再包整个 Stack——否则位移被双重施加。
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  key: _artworkKey,
                  // Displayed (magnified) edge — the layout footprint keeps
                  // matching `slot.size` exactly like before (:25).
                  width: widget.iconSize,
                  height: widget.iconSize,
                  child: Opacity(
                    // :126 — unavailable && no windows && !spacer.
                    opacity:
                        widget.available ||
                            widget.windowCount > 0 ||
                            widget._spacer
                        ? 1
                        : kDockItemUnavailableOpacity,
                    child: ExcludeSemantics(
                      // 消毛刺（P0）：图标不再用放大后的 `iconSize` 重排/
                      // 重栅格——wave 每帧改 iconSize 曾让 SVG/PNG 反复采样。
                      // 画板以 `restingIconSize` 布局/栅格一次，放大交给
                      // `Transform.scale`（bottomCenter 锚点与底部对齐的
                      // 槽位一致；medium 双线性足够平滑）。scale 非有限或
                      // resting 尺寸为 0 时回退 1。
                      child: RepaintBoundary(
                        child: Transform.scale(
                          scale: _iconScale,
                          alignment: Alignment.bottomCenter,
                          filterQuality: FilterQuality.medium,
                          // Align 松开外层 SizedBox 的 iconSize 紧约束——
                          // 内层 SizedBox 才能保持 restingIconSize 的
                          // raster 尺寸（紧约束会把画板撑回显示尺寸）。
                          // bounce translate 放进 scale 内层（源 QML 位移
                          // 随图标一起缩放，不再被放大反向稀释）。
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: AnimatedBuilder(
                              animation: _bounceValue,
                              builder: (context, child) => Transform.translate(
                                offset: _bounceOffset,
                                child: child,
                              ),
                              child: SizedBox(
                                width: widget.restingIconSize,
                                height: widget.restingIconSize,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _artwork(context, services),
                                    // pressShade (:115-124) — 90ms fade of a
                                    // 0.3 scrim instead of MultiEffect
                                    // brightness.
                                    AnimatedOpacity(
                                      opacity: shade ? 1 : 0,
                                      duration: _reduceMotion
                                          ? Duration.zero
                                          : _pressShadeDuration,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: colors.scrim.withValues(
                                            alpha: _pressShadeAlpha,
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
                ),
                // Indicator bar (:180-189) as a Stack overlay so it paints
                // *outside* the icon box, into the glass inset lane below the
                // icon. The source anchored its dot to the taller delegate box
                // (`y: height - 10`, :187); this box is the icon box, inset
                // `kDockIconBottomInset` above the band bottom, so the bar's
                // outward offset is `kDockIndicatorBottomInset -
                // kDockIconBottomInset` (= -6): 6px below/outside the icon box
                // puts the bar 3px above the band bottom. `Stack(clipBehavior:
                // Clip.none)` above lets it paint past the box.
                //
                // `Align`-free single-axis `Positioned`: left+right (or
                // top+bottom) sizes the opposite axis but leaves the bar's own
                // axis to the child, and `Center` keeps it centred along the
                // band without stretching the 10×3 (resp. 3×10) bar.
                if (showDot)
                  switch (widget.edge) {
                    PanelEdge.left => Positioned(
                      left: kDockIndicatorBottomInset - kDockIconBottomInset,
                      top: 0,
                      bottom: 0,
                      child: Center(child: indicator), // :186 transpose
                    ),
                    PanelEdge.right => Positioned(
                      right: kDockIndicatorBottomInset - kDockIconBottomInset,
                      top: 0,
                      bottom: 0,
                      child: Center(child: indicator), // :186 transpose
                    ),
                    _ => Positioned(
                      left: 0,
                      right: 0,
                      bottom: kDockIndicatorBottomInset - kDockIconBottomInset,
                      child: Center(child: indicator), // :187
                    ),
                  },
                if (_tooltipVisible) _buildTooltip(context, shell, colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Inline tooltip (delay = 0). Rendered inside the item's unclipped Stack
  /// instead of an Overlay so the component stays self-mountable; the label
  /// matches `dropTarget ? dropHint : name` (:173).
  Widget _buildTooltip(
    BuildContext context,
    ShellThemeData shell,
    ColorScheme colors,
  ) {
    final label = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          widget.dropTarget ? widget.dropHint : widget.name, // :173
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: shell.text.base.copyWith(color: colors.onInverseSurface),
        ),
      ),
    );
    return switch (widget.edge) {
      PanelEdge.left => Positioned(
        left: widget.iconSize + 8,
        top: 0,
        bottom: 0,
        child: Center(child: label),
      ),
      PanelEdge.right => Positioned(
        right: widget.iconSize + 8,
        top: 0,
        bottom: 0,
        child: Center(child: label),
      ),
      _ => Positioned(
        left: 0,
        right: 0,
        bottom: widget.iconSize + 8,
        height: 32,
        // The source tooltip sizes to its text (`implicitWidth`,
        // StyledToolTipContent.qml:17-19) instead of the slot:
        // `OverflowBox` drops the slot-width cap so a long name stays on one
        // line, centred on the icon and painting past the slot edge.
        child: OverflowBox(
          maxWidth: 480,
          maxHeight: 32,
          child: Center(child: label),
        ),
      ),
    };
  }
}
