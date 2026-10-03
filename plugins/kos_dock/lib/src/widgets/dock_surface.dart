/// DockSurface — the floating dock tray: glass base (`glass`) + icon row
/// (`band`) hosted inside the `kos_dock.dock` `ShellSurface` bottom strip.
///
/// Ported semantics (line anchors are into quickshell
/// `Modules/Dock/DockSurface.qml` unless noted):
/// - band width = `min(availableLength, max(96, layout.length))`
///   (`bandLength`, :119) with `availableLength = max(80, axisLength - 32)`
///   (:64); band height = `bandThickness = baseLayout.size * magnification +
///   36` (:120), a magnification head-room that paints out of the surface
///   bounds — bounds only anchor, never clip (:612-626, :769; SDK ClipRect
///   wraps the whole output in shell_surface_plane.dart:74-95).
/// - glass base sits on the band bottom: width = band width, height =
///   `restingThickness = baseLayout.size + kDockGlassPadding` (:121; Denial
///   padding 13 = 4 + 9 vs source 22), radius 20 (:816-822).
/// - `restingThickness + edgeOffset(8)` is the surface thickness, the Dart
///   mirror of `exclusiveZone` (:621) — the band never gets taller than
///   bounds; magnified icons paint above it instead (card 注意).
/// - input: `dockInputArea` publishes only the glass corridor (:750-760) plus
///   one Region per icon pointerArea (:888-892); here two `ShellInputRegion`s
///   (glass, icons) reproduce the same mask via the default
///   `ShellPointerPolicy.childBounds`, never `fullScene` — the transparent
///   band margins fall through to the desktop/taskbar (card 注意·输入穿透).
/// - pointer math: `pointerInBase = pointerAxis - (axisLength -
///   min(baseLength, availableLength))/2 + scrollOffset` (:79-81); the
///   magnification envelope animates amplitude only, 220ms easeOutCubic
///   (:97-110), with an 80ms exit debounce (`magnificationExit`, :637-644).
/// - slot/divider positions animate 220ms easeOutCubic only while
///   `!directMagnification` (:863-876, :1028-1057); while magnifying they
///   follow the wave every frame.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout/dock_magnifier.dart';
import '../statusbar/bar_clock.dart';
import '../statusbar/bar_control.dart';
import '../statusbar/bar_status.dart';
import '../statusbar/bar_tray.dart';
import '../statusbar/bar_workspace.dart';
import 'context_menu.dart';
import 'dock_item.dart';
import 'dock_spacer.dart';
import 'dock_surface_math.dart';
import 'preview_card.dart';

export '../layout/dock_magnifier.dart' show DockLayoutResult, DockSlot;
export 'dock_surface_math.dart';


/// One dock row entry consumed by [DockSurface]. Denial has no DockService
/// model yet (TASK-07 dock_store); the surface is driven by this plain data
/// list until then.
@immutable
final class DockEntry {
  const DockEntry({
    required this.key,
    required this.name,
    required this.appId,
    this.kind = 'app',
    this.launchId,
    this.windowId,
    this.windowCount = 0,
    this.focused = false,
    this.launching = false,
    this.available = true,
    this.windows = const <ApplicationWindow>[],
    this.pinned = false,
  });

  /// Stable entry identity (`entryKey`, DockItem.qml:14).
  final String key;

  /// Entry kind: `app`, `trash`, `spacer`, `small-spacer`, … (:15,:28).
  final String kind;

  /// Display name; tooltip + semantics label (:16).
  final String name;

  /// Icon identity for `services.buildApplicationIcon`.
  final String appId;

  /// Launch identity for `services.launchApplication` when there is no window.
  final String? launchId;

  /// Window to `activateWindow` on click; paired with [windowCount].
  final int? windowId;

  /// Running window count; drives the indicator dot (:23,:181).
  final int windowCount;

  /// Whether a window of this entry is focused (:20,:188).
  final bool focused;

  /// Launch acknowledgement flag; one bounce per edge (:21,:84-85).
  final bool launching;

  /// Whether the entry is launchable/available (:22,:126).
  final bool available;

  /// This entry's windows — drives the hover preview cards (TASK-04) and the
  /// context menu's checkable window list (TASK-05).
  final List<ApplicationWindow> windows;

  /// Whether the entry comes from a `dock.json` pin (`entry.pinned`,
  /// DockPreviewPopup.qml:388) — `onTogglePin` is only offered for app entries.
  final bool pinned;
}

/// The floating dock container widget: wraps [entries] in the glass tray and
/// feeds the TASK-01 magnifier with the pointer position and amplitude
/// envelope. `build()` wraps it in services/Localizations/Theme like the
/// taskbar does (`WindowsTaskbar.build`, taskbar.dart:24-61).
class DockSurface extends StatelessWidget {
  const DockSurface({
    required this.entries,
    required this.services,
    required this.monitorId,
    super.key,
    this.iconSize = kDockItemDefaultIconSize,
    this.magnification = kDockDefaultMagnification,
    this.magnificationEnabled = true,
    this.pinnedAppCount = 0,
    this.onItemHovered,
    this.onItemHoverLeft,
    this.onItemPressStarted,
    this.onItemActivated,
    this.onItemContextRequested,
    this.onItemDragMoved,
    this.onItemDragReleased,
    this.onItemDragCancelled,
    this.onItemReordered,
    this.onTogglePin,
    this.statusBarBuilder,
  });

  /// Row entries in dock order; `entry.kind` feeds the TASK-01 `kinds` list
  /// (:66-72).
  final List<DockEntry> entries;

  /// 左右状态槽构建器（kos_topbar 合并迁入：左=工作区胶囊，右=状态簇）。
  /// `null` 不渲染（widget 测试不传，`_FakeServices` 不实现状态服务）；
  /// 真实装配由 `kos_dock.dart`/`DockHost` 传入 [buildDockStatusBar]。
  final WidgetBuilder? statusBarBuilder;

  /// Shell services (icon builder, launch/activate, cursors).
  final ShellServices services;

  /// Target output for `launchApplication` (`surface.environment.output`).
  final int monitorId;

  /// Resting icon edge (`DockService.iconSize`, DockModel.js:7 default 48,
  /// clamp 32–80 :37).
  final double iconSize;

  /// Magnification scale M (`DockService.magnificationScale`, :73); clamped
  /// to 1–2 inside `layout()` (DockLayout.js:24).
  final double magnification;

  /// `DockService.magnification` toggle (:73 `? scale : 1`).
  final bool magnificationEnabled;

  /// Number of leading pinned rows; drives `sectionBoundary` (:75,:107).
  final int pinnedAppCount;

  /// `hovered(key)` (:1064) — TASK-04 consumes this for preview timing.
  final void Function(String key)? onItemHovered;

  /// `hoverLeft(key)` (:1065).
  final void Function(String key)? onItemHoverLeft;

  /// `pressStarted` (:1059-1063) — popup dismissal hook.
  final VoidCallback? onItemPressStarted;

  /// `activated(key)` (:1069+) — fires alongside DockItem's built-in
  /// activate/launch.
  final void Function(String key)? onItemActivated;

  /// `contextRequested(key)` — menu wiring belongs to TASK-05.
  final void Function(String key)? onItemContextRequested;

  /// `dragMoved(key, position, grabOffset, iconSize)` — reorder plumbing is
  /// a later card; the callback slot is wired through now.
  final DockItemDragMoved? onItemDragMoved;

  /// `dragReleased(key, position)`.
  final DockItemDragReleased? onItemDragReleased;

  /// `dragCancelled` (:1088-1091).
  final VoidCallback? onItemDragCancelled;

  /// `onReorder(fromKey, toKey)` — commit of a pinned-row drag reorder
  /// (`DockService.movePinned`). `toKey` is the entry key the drop lands on;
  /// the host applies `reorderDockPins`. `null` keeps the drag visual-only.
  final void Function(String fromKey, String toKey)? onItemReordered;

  /// Injected pin/unpin for the TASK-05 menu (`DockService.pin/unpin`
  /// :382-399) — the integration host writes `dock.json` through the
  /// TASK-07 store; `null` hides the pin row.
  final void Function(String key)? onTogglePin;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final colors = ColorScheme.fromSeed(
      seedColor: shell.accent,
      brightness: shell.brightness,
    );
    // taskbar.dart:31-61 — services + Material localizations + seeded Theme
    // so buildApplicationIcon/tooltips/menus have a Theme context.
    return ShellServicesScope(
      services: services,
      child: Localizations.override(
        context: context,
        delegates: GlobalMaterialLocalizations.delegates,
        child: Theme(
          data: ThemeData(
            useMaterial3: true,
            colorScheme: colors,
            splashFactory: NoSplash.splashFactory,
            visualDensity: VisualDensity.compact,
            tooltipTheme: const TooltipThemeData(
              waitDuration: Duration(milliseconds: 600),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 全宽玻璃条与 dock 玻璃等高：resting 由同一 resting-pass
              // layout 推出（`baseLayout.size` 可能被图标数压缩，故不能
              // 直接取 iconSize）。`layout()` 是纯函数，重复调用幂等。
              final axisLength = constraints.maxWidth;
              final avail = dockAvailableLength(axisLength);
              final mag = magnificationEnabled ? magnification : 1.0;
              final kinds = [for (final e in entries) e.kind];
              final b = dockSectionBoundary(kinds, pinnedAppCount);
              final strip = layout(
                kinds: kinds,
                preferredSize: iconSize,
                available: avail,
                magnification: mag,
                sectionSpacing: kDockSectionSpacing,
                pointer: double.nan,
                sectionBoundary: b < 0 ? const <int>[] : <int>[b],
              );
              final resting = dockRestingThickness(strip.size);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 全宽玻璃条（贯穿屏幕两端）：工作区/状态簇/dock 共用同一
                  // 条带。bottom 对齐 dock 玻璃（kDockEdgeOffset），高=resting。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: kDockEdgeOffset,
                    height: resting,
                    child: const ShellInputRegion(
                      debugLabel: 'DockStrip',
                      child: _DockStripGlass(),
                    ),
                  ),
                  // 中：dock 图标带（_DockBand 内部已按 bandLength 居中，
                  // 自带 _DockGlass 与全宽条同色同高融合）。
                  _DockBand(
                    entries: entries,
                    monitorId: monitorId,
                    iconSize: iconSize,
                    magnification: magnification,
                    magnificationEnabled: magnificationEnabled,
                    pinnedAppCount: pinnedAppCount,
                    // 有整条玻璃（statusBarBuilder 非空）时不再画 band 自带
                    // 的短玻璃，避免与 _DockStripGlass 叠成「两条」；
                    // statusBarBuilder==null（测试/独立使用）仍画默认玻璃。
                    showGlass: statusBarBuilder == null,
                    onItemHovered: onItemHovered,
                    onItemHoverLeft: onItemHoverLeft,
                    onItemPressStarted: onItemPressStarted,
                    onItemActivated: onItemActivated,
                    onItemContextRequested: onItemContextRequested,
                    onItemDragMoved: onItemDragMoved,
                    onItemDragReleased: onItemDragReleased,
                    onItemDragCancelled: onItemDragCancelled,
                    onItemReordered: onItemReordered,
                    onTogglePin: onTogglePin,
                  ),
                  if (statusBarBuilder != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: kDockEdgeOffset,
                      height: resting,
                      child: statusBarBuilder!(context),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Stateful band: owns the pointer tracker, the amplitude envelope and the
/// icons scroll controller.
class _DockBand extends StatefulWidget {
  const _DockBand({
    required this.entries,
    required this.monitorId,
    required this.iconSize,
    required this.magnification,
    required this.magnificationEnabled,
    required this.pinnedAppCount,
    this.showGlass = true,
    this.onItemHovered,
    this.onItemHoverLeft,
    this.onItemPressStarted,
    this.onItemActivated,
    this.onItemContextRequested,
    this.onItemDragMoved,
    this.onItemDragReleased,
    this.onItemDragCancelled,
    this.onItemReordered,
    this.onTogglePin,
  });

  final List<DockEntry> entries;
  final int monitorId;
  final double iconSize;
  final double magnification;
  final bool magnificationEnabled;
  final int pinnedAppCount;
  /// 是否画 band 自带的居中短玻璃（`_DockGlass`）。外层 `_DockStripGlass`
  /// 已铺整条时传 false 避免双重底（默认 true 兼容独立使用/测试）。
  final bool showGlass;
  final void Function(String key)? onItemHovered;
  final void Function(String key)? onItemHoverLeft;
  final VoidCallback? onItemPressStarted;
  final void Function(String key)? onItemActivated;
  final void Function(String key)? onItemContextRequested;
  final DockItemDragMoved? onItemDragMoved;
  final DockItemDragReleased? onItemDragReleased;
  final VoidCallback? onItemDragCancelled;
  final void Function(String fromKey, String toKey)? onItemReordered;
  final void Function(String key)? onTogglePin;

  @override
  State<_DockBand> createState() => _DockBandState();
}

class _DockBandState extends State<_DockBand>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();

  /// Amplitude envelope A (`magnificationProgress`, :97-110). Only A is
  /// animated; slot geometry is recomputed every frame (the 防追鼠标
  /// constraint, DockLayout.js:16-17,25-27).
  late final AnimationController _envelope;

  /// Pointer axis in surface coordinates (`pointerAxis`, :131); NaN = no
  /// pointer, matching the non-finite branch of DockLayout.js:50.
  ///
  /// The band's `MouseRegion` reports band-local positions, so [_bandLeft]
  /// (the band's centered surface offset) is added before use — `pointerAxis`
  /// is a scene/surface coordinate in the source (`scenePosition.x`,
  /// DockSurface.qml:169-170) and `dockPointerInBase` subtracts the same
  /// centering offset (:79-81).
  double _pointerAxis = double.nan;

  /// Surface-space x of the band's left edge from the last layout
  /// (`(axisLength - bandLength) / 2`, :766).
  double _bandLeft = 0;

  /// `magnificationActive` (:132) — set on hover, cleared by the 80ms
  /// debounce (:637-644).
  bool _magnificationActive = false;
  Timer? _magnificationExit;

  /// Hide callback of the currently-open preview/menu overlay, so a sibling
  /// can dismiss it (`DockPreviewCard.show` exclusivity, :386) and pressing an
  /// icon dismisses everything (`pressStarted`, :1059-1063).
  VoidCallback? _activePopupHide;

  /// Passed to every `DockPreviewCard.show`: closes the previous overlay.
  void _showExclusive(VoidCallback hide) {
    final previous = _activePopupHide;
    if (previous != null && !identical(previous, hide)) previous();
    _activePopupHide = hide;
  }

  void _dismissAll() {
    final hide = _activePopupHide;
    _activePopupHide = null;
    hide?.call();
  }

  /// GlobalKey on the icons viewport. `DockItem` reports scene-global positions;
  /// the icons viewport fills the band and starts at the band's left edge, so its
  /// local space is exactly the slot layout space (`slot.start` origin).
  final _iconsKey = GlobalKey();

  /// Drag-reorder session (`DockDragVisual.qml`), non-null while a pinned row is
  /// being dragged. [dragLocalPointer] is band-local; the ghost is drawn at
  /// `dragLocalPointer - dragGrabOffset - size/2`.
  String? _dragKey;
  Offset? _dragLocalPointer;
  Offset _dragGrabOffset = Offset.zero;
  double _dragIconSize = 0;

  /// Resolved landing target of the active drag: entry index (placeholder) and
  /// entry key (commit). `null` when idle or when there is no pinned block.
  int? _dropIndex;
  String? _dropKey;

  /// Latest unmagnified layout, cached so the drag handlers (outside `build`)
  /// hit-test against the same thresholds the source freezes while dragging
  /// (DockSurface.qml:412-413).
  DockLayoutResult? _lastBaseLayout;

  DockEntry? _entryFor(String key) {
    for (final entry in widget.entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// Hit-tests the drag pointer against the cached base layout: icons-local x
  /// plus the scroll offset is the base coordinate; the raw gap comes from
  /// `dockInsertionIndex` and `dockPinDropIndex` clamps it to the pinned block
  /// (`DockSurface.qml:414-431`, restricted to the pin list per the crop).
  void _resolveDrop() {
    final local = _dragLocalPointer;
    final base = _lastBaseLayout;
    final pinned = <int>[
      for (var index = 0; index < widget.entries.length; ++index)
        if (widget.entries[index].pinned) index,
    ];
    if (local == null || base == null || pinned.isEmpty) {
      _dropIndex = null;
      _dropKey = null;
      return;
    }
    final insertion = dockInsertionIndex(base.slots, local.dx + _scrollOffset);
    final target = dockPinDropIndex(
      insertion: insertion,
      start: pinned.first,
      end: pinned.last + 1,
    );
    _dropIndex = target;
    _dropKey = target == null ? null : widget.entries[target].key;
  }

  void _onDragMoved(
    String key,
    Offset position,
    Offset grabOffset,
    double size,
  ) {
    // Only pinned rows are a persistent reorder target (Denial crop, see
    // docs/visual-deltas.md); launcher/running/trash drags stay visual-only.
    final entry = _entryFor(key);
    if (entry == null || !entry.pinned) return;
    final box = _iconsKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _dragKey = key;
      _dragGrabOffset = grabOffset;
      _dragIconSize = size;
      _dragLocalPointer = box?.globalToLocal(position);
      _resolveDrop();
    });
    widget.onItemDragMoved?.call(key, position, grabOffset, size);
  }

  void _onDragReleased(String key, Offset position) {
    final target = _dragKey == key ? _dropKey : null;
    _resetDrag();
    widget.onItemDragReleased?.call(key, position);
    if (target != null && target != key) {
      widget.onItemReordered?.call(key, target);
    }
  }

  void _onDragCancelled() {
    _resetDrag();
    widget.onItemDragCancelled?.call();
  }

  void _resetDrag() {
    if (_dragKey == null) return;
    setState(() {
      _dragKey = null;
      _dragLocalPointer = null;
      _dragIconSize = 0;
      _dropIndex = null;
      _dropKey = null;
    });
  }

  /// Landing placeholder for the resolved gap slot — the source opens a
  /// provisional gap (`previewOrder`, DockSurface.qml:87-90); Denial keeps the
  /// row static and marks the target with the `DockSpacer` outline instead.
  Widget _buildDropPlaceholder(DockSlot slot, String? draggedKind) => Positioned(
    key: const ValueKey('dock-drop-placeholder'),
    left: slot.start,
    // Bottom-anchored like the icons (DockItem.qml:112).
    bottom: kDockIconBottomInset,
    width: slot.span,
    height: slot.size,
    child: Center(
      child: DockSpacer(
        dragging: true,
        small: draggedKind == 'small-spacer',
        size: slot.size,
      ),
    ),
  );

  /// Pointer-following ghost (`DockDragVisual.qml`): the dragged artwork at the
  /// drag size, positioned by the grab offset so it stays under the pointer.
  Widget _buildDragGhost(BuildContext context) {
    final size = _dragIconSize;
    final entry = _entryFor(_dragKey!);
    if (entry == null) return const SizedBox.shrink();
    final topLeft =
        _dragLocalPointer! - _dragGrabOffset - Offset(size / 2, size / 2);
    return Positioned(
      key: const ValueKey('dock-drag-ghost'),
      left: topLeft.dx,
      top: topLeft.dy,
      width: size,
      height: size,
      child: IgnorePointer(
        child: _DockDragGhost(
          entry: entry,
          size: size,
          services: ShellServicesScope.of(context),
        ),
      ),
    );
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  /// `directMagnification` (:104): reflow animations freeze while the wave is
  /// (or recently was) active so slots/dividers/band track the pointer.
  bool get _directMagnification =>
      _magnificationRequested || _envelope.value > 0;

  /// `magnificationRequested` (:91-94): magnification enabled + hover active.
  /// Drag/external-over branches do not exist yet (later cards).
  bool get _magnificationRequested =>
      widget.magnification > 1 &&
      widget.magnificationEnabled &&
      _magnificationActive;

  @override
  void initState() {
    super.initState();
    _envelope = AnimationController(
      vsync: this,
      duration: kDockReflowDuration, // :100 reflowDuration
    );
  }

  @override
  void dispose() {
    _magnificationExit?.cancel();
    _scrollController.dispose();
    _envelope.dispose();
    super.dispose();
  }

  /// Animate the envelope toward [target] (0 or 1), honoring reduce-motion
  /// (`_reduceMotion`, taskbar window_buttons.dart:375 pattern).
  void _animateEnvelope(double target) {
    if (_reduceMotion) {
      _envelope.value = target;
    } else {
      _envelope.animateTo(target, curve: Curves.easeOutCubic); // :98-103
    }
  }

  void _onPointerEnter(PointerEnterEvent event) {
    // :167-172 — entering the interactive area stops the exit debounce and
    // activates magnification.
    _magnificationExit?.cancel(); // :171 magnificationExit.stop()
    setState(() {
      _pointerAxis = event.localPosition.dx + _bandLeft;
      _magnificationActive = true; // :172
    });
    _animateEnvelope(_magnificationRequested ? 1 : 0); // :97
  }

  void _onPointerMove(PointerHoverEvent event) {
    // :699-704,:169-170 — pointerAxis follows the pointer while over the
    // interactive area; the band MouseRegion approximates that region (glass
    // + icon pointerAreas, :141-165).
    setState(() => _pointerAxis = event.localPosition.dx + _bandLeft);
  }

  void _onPointerExit(PointerExitEvent event) {
    // :173-175 + :637-644 — leaving starts the 80ms debounce instead of
    // clearing immediately; a quick re-entry cancels it. pointerAxis is
    // intentionally kept: the source never resets it (:131), so the wave
    // collapses around the last pointer position instead of snapping.
    _magnificationExit?.cancel();
    _magnificationExit = Timer(kDockMagnificationExitDelay, () {
      if (!mounted) return;
      setState(() {
        _magnificationActive = false; // :641-642
      });
      _animateEnvelope(0); // :97 — hover out 1→0
    });
  }

  /// `scrollOffset` (:77): `icons.contentX - icons.originX`, originX == 0.
  double get _scrollOffset =>
      _scrollController.hasClients ? _scrollController.offset : 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final axisLength = constraints.maxWidth; // :63 (horizontal)
        final available = dockAvailableLength(axisLength); // :64
        final effectiveMagnification = widget.magnificationEnabled
            ? widget.magnification
            : 1.0; // :73
        final kinds = [
          for (final entry in widget.entries) entry.kind,
        ]; // :66-72
        final boundary = dockSectionBoundary(kinds, widget.pinnedAppCount);
        final boundaries = boundary < 0 ? const <int>[] : <int>[boundary];
        // baseLayout (:74-76): resting pass — pointer NaN (strength is
        // irrelevant at a non-finite pointer, DockLayout.js:50).
        final baseLayout = layout(
          kinds: kinds,
          preferredSize: widget.iconSize,
          available: available,
          magnification: effectiveMagnification,
          sectionSpacing: kDockSectionSpacing,
          pointer: double.nan,
          sectionBoundary: boundaries,
        );
        // Cache the unmagnified layout for the drag hit-test (DockSurface.qml
        // freezes thresholds on the base layout, :412-413).
        _lastBaseLayout = baseLayout;
        final resting = dockRestingThickness(baseLayout.size); // :121
        final bandThickness = dockBandThickness(
          baseLayout.size,
          effectiveMagnification,
        ); // :120
        final pointerInBase = dockPointerInBase(
          pointerAxis: _pointerAxis,
          axisLength: axisLength,
          baseLength: baseLayout.baseLength,
          availableLength: available,
          scrollOffset: _scrollOffset,
        ); // :79-81
        final reflow = _reduceMotion ? Duration.zero : kDockReflowDuration;
        // Slot/divider/band animations freeze during magnification
        // (:104, :778, :864, :1029).
        final slotAnim = _directMagnification ? Duration.zero : reflow;

        return AnimatedBuilder(
          animation: _envelope,
          builder: (context, _) {
            // layout (:105-110): magnified pass recomputed every envelope
            // frame; preview reordering is a later card so kinds/order are
            // the raw model.
            final waveLayout = layout(
              kinds: kinds,
              preferredSize: baseLayout.size, // :105 — reuse base size
              available: available,
              magnification: effectiveMagnification,
              sectionSpacing: kDockSectionSpacing,
              pointer: pointerInBase,
              sectionBoundary: boundaries,
              strength: _envelope.value, // :110 — amplitude only
            );
            final bandLength = dockBandLength(
              available,
              waveLayout.length,
            ); // :119
            // Cache the band's centered surface offset so the band-local
            // MouseRegion positions below can be lifted into surface space
            // (:766); layout is `directMagnification`-frozen while the wave
            // is active, so this matches the rendered left whenever the
            // pointer position is actually consumed.
            _bandLeft = (axisLength - bandLength) / 2;
            return Stack(
              // :616 transparent surface; bounds anchor but never clip — the
              // band top may exceed the 78px surface strip (card 注意).
              clipBehavior: Clip.none,
              children: [
                // band (:762-769): centered horizontally (:766), bottom
                // edge inset by edgeOffset (:769); position/width animate
                // on reflow (:777-783) and drop to zero duration while
                // `directMagnification` (:778).
                AnimatedPositioned(
                  left: (axisLength - bandLength) / 2, // :766
                  bottom: kDockEdgeOffset, // :769
                  width: bandLength, // :767-768
                  height: bandThickness, // :765 — includes head-room
                  duration: slotAnim,
                  curve: Curves.easeOutCubic, // :780-782
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // glass (:816-822): bottom-pinned, width = band,
                      // height = restingThickness. `showGlass==false`（外层
                      // _DockStripGlass 已铺整条）时跳过，避免双重底。
                      if (widget.showGlass)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0, // :819 y = parent.height - height
                          height: resting,
                          child: const ShellInputRegion(
                            debugLabel: 'DockGlass',
                            child: _DockGlass(),
                          ),
                        ),
                      // icons viewport (:839-849): fills the band; a
                      // scrollable viewport handles layout.overflow.
                      Positioned.fill(
                        child: ShellInputRegion(
                          key: _iconsKey,
                          debugLabel: 'DockIcons',
                          child: _DockIcons(
                            entries: widget.entries,
                            baseLayout: baseLayout,
                            waveLayout: waveLayout,
                            resting: resting,
                            bandThickness: bandThickness,
                            monitorId: widget.monitorId,
                            slotAnim: slotAnim,
                            scrollController: _scrollController,
                            showPopup: _showExclusive,
                            onTogglePin: widget.onTogglePin,
                            onHovered: widget.onItemHovered,
                            onHoverLeft: widget.onItemHoverLeft,
                            onPressStarted: () {
                              // :1059-1063 — pressing any icon dismisses
                              // the open popup before the gesture is
                              // classified.
                              _dismissAll();
                              widget.onItemPressStarted?.call();
                            },
                            onActivated: widget.onItemActivated,
                            onContextRequested:
                                widget.onItemContextRequested,
                            draggedKey: _dragKey,
                            onDragMoved: _onDragMoved,
                            onDragReleased: _onDragReleased,
                            onDragCancelled: _onDragCancelled,
                          ),
                        ),
                      ),
                      // Interactive corridor (:141-165
                      // `pointerOverInteractiveArea`): the source hit-tests
                      // the glass rect ∪ each icon's `pointerArea` — a
                      // resting-thickness strip across the band — instead of
                      // the whole band. A translucent MouseRegion over that
                      // same strip keeps hover continuous while the pointer
                      // crosses icons/gaps/glass, and (unlike the old
                      // band-wide region) ignores the empty magnification
                      // head-room above, so vertical pointer travel cannot
                      // flap the envelope.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: resting,
                        child: MouseRegion(
                          hitTestBehavior: HitTestBehavior.translucent,
                          onEnter: _onPointerEnter,
                          onHover: _onPointerMove,
                          onExit: _onPointerExit,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      // Drag-reorder overlay (`DockDragVisual.qml`): the
                      // drop placeholder outline and the pointer-following
                      // ghost, painted above the row (the band Stack is
                      // Clip.none).
                      if (_dragKey != null) ...[
                        if (_dropIndex != null &&
                            _dropIndex! < waveLayout.slots.length)
                          _buildDropPlaceholder(
                            waveLayout.slots[_dropIndex!],
                            _entryFor(_dragKey!)?.kind,
                          ),
                        if (_dragLocalPointer != null)
                          _buildDragGhost(context),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Glass base material (:816-825): ShellBackdropBlur + cardColor Material,
/// radius scaled by the shell roundness, outlineVariant@0.65 1px border —
/// the denial-material port of `BlurService.backgroundColor(
/// colSurfaceContainer)` + border (card §3). The fill/blur gating follows
/// the DeskCenter card material chain (`DeskCard`): `cardColor` carries
/// `cardOpacity` so the tray matches the desktop widgets, and blur is
/// gated by `backdropBlurEnabled` (off mode paints flat).
class _DockGlass extends StatelessWidget {
  const _DockGlass();

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final colors = Theme.of(context).colorScheme;
    // :822 — source radius 20 scaled by the shell roundness setting so the
    // tray tracks the same corner scale as every other panel/card.
    final radius = BorderRadius.circular(
      shell.scaledRadius(kDockGlassRadius),
    );
    return ShellBackdropBlur(
      opacity: ShellSurfacePresentation.opacityOf(context), // taskbar.dart:163
      blur: shell.backdropBlurEnabled, // blur/glass on, off → flat fill
      separateChild: true, // taskbar.dart:165
      borderRadius: radius,
      child: Material(
        // cardColor: the widget-surface opacity (cardOpacity), matching the
        // DeskCenter cards; glass mode resolves to the glass backing.
        color: shell.cardColor(colors.surfaceContainer),
        surfaceTintColor: Colors.transparent, // taskbar.dart:76 (M3 tint off)
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          // :824-825 — outlineVariant @ 0.65, width 1.
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 全宽玻璃条材质——贯穿屏幕两端的整条底栏底（kos_topbar 合并后用户要求
/// 「dock 条延伸到两端连成一条」）。材质链与 [_DockGlass] 完全一致
/// （`ShellBackdropBlur` + `cardColor(surfaceContainer)` + `outlineVariant`
/// 1px 边），圆角用与 resting 半高匹配的胶囊圆角（`scaledRadius(999)` 封顶
/// 成 pill），让整条呈一根连续玻璃 pill 而非分段卡片。`ShellBackdropBlur`
/// 全宽模糊一次，比逐胶囊五次 blur 更省。
class _DockStripGlass extends StatelessWidget {
  const _DockStripGlass();

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final colors = Theme.of(context).colorScheme;
    // 胶囊圆角：半径 = 半高（pill），scaledRadius 跟随 shell roundness。
    final radius = BorderRadius.circular(shell.scaledRadius(999));
    return ShellBackdropBlur(
      opacity: ShellSurfacePresentation.opacityOf(context),
      blur: shell.backdropBlurEnabled,
      separateChild: true,
      borderRadius: radius,
      child: Material(
        color: shell.cardColor(colors.surfaceContainer),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// The icons Flickable (:839-849): dividers (:852-878) + slot-positioned
/// DockItems (:880-1057) inside a horizontally scrolling viewport.
class _DockIcons extends StatelessWidget {
  const _DockIcons({
    required this.entries,
    required this.baseLayout,
    required this.waveLayout,
    required this.resting,
    required this.bandThickness,
    required this.monitorId,
    required this.slotAnim,
    required this.scrollController,
    required this.showPopup,
    this.onTogglePin,
    this.onHovered,
    this.onHoverLeft,
    this.onPressStarted,
    this.onActivated,
    this.onContextRequested,
    this.draggedKey,
    this.onDragMoved,
    this.onDragReleased,
    this.onDragCancelled,
  });

  final List<DockEntry> entries;
  final DockLayoutResult baseLayout;
  final DockLayoutResult waveLayout;
  final double resting;
  final double bandThickness;
  final int monitorId;

  /// Entry key currently being dragged, so its row can be hidden (`dragged`,
  /// DockItem.qml:61).
  final String? draggedKey;

  /// `DockPreviewCard.show` exclusivity hook (band-owned).
  final void Function(VoidCallback hide) showPopup;

  /// Pin/unpin forwarded into the TASK-05 menu.
  final void Function(String key)? onTogglePin;

  /// 220ms reflow duration, or zero during `directMagnification` /
  /// reduce-motion (:863-876, :1028-1057).
  final Duration slotAnim;

  final ScrollController scrollController;
  final void Function(String key)? onHovered;
  final void Function(String key)? onHoverLeft;
  final VoidCallback? onPressStarted;
  final void Function(String key)? onActivated;
  final void Function(String key)? onContextRequested;
  final DockItemDragMoved? onDragMoved;
  final DockItemDragReleased? onDragReleased;
  final VoidCallback? onDragCancelled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, viewport) => SingleChildScrollView(
        controller: scrollController,
        scrollDirection: Axis.horizontal, // :839-843 Flickable contentWidth
        // :847 interactive:false — the content never scrolls by drag; scroll
        // position is driven programmatically (later drag auto-scroll card).
        physics: const NeverScrollableScrollPhysics(),
        // :844-846 — the scroll viewport clips overflow content only;
        // vertical paint is not clipped so magnified icons/tooltips can
        // reach into the band head-room.
        child: SizedBox(
          width: math.max(waveLayout.length, viewport.maxWidth),
          height: viewport.maxHeight,
          // Non-overflow content stays left-pinned like the Flickable (x=0);
          // the outer SizedBox only matters while the row is narrower than
          // the 96px-minimum band (:119).
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: waveLayout.length, // :842 contentWidth = layout.length
              height: viewport.maxHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Section dividers (:852-878): 2px wide, resting-20 tall,
                  // 10px below the glass top, onSurface @ 0.4, radius 1.
                  for (final divider in waveLayout.dividers)
                    _AnimatedDivider(
                      key: ValueKey('divider:$divider'),
                      divider: divider,
                      // :859-860 — glass.y + 10; glass sits at
                      // bandThickness - resting above the band bottom.
                      top: bandThickness - resting + kDockDividerInset,
                      height: resting - kDockDividerInset * 2, // :858
                      duration: slotAnim, // :863-869 — frozen while magnifying
                      color: colors.onSurface.withValues(alpha: 0.4), // :862
                    ),
                  for (var index = 0; index < entries.length; ++index)
                    _DockSlotItem(
                      key: ValueKey(entries[index].key),
                      entry: entries[index],
                      slot: waveLayout.slots[index],
                      restingIconSize: baseLayout.size, // :971
                      monitorId: monitorId,
                      duration: slotAnim,
                      // :977-987 — the tooltip yields while a preview/menu of
                      // this item is open (tracked inside _DockSlotItem).
                      showPopup: showPopup,
                      onTogglePin: onTogglePin,
                      onHovered: onHovered,
                      onHoverLeft: onHoverLeft,
                      onPressStarted: onPressStarted,
                      onActivated: onActivated,
                      onContextRequested: onContextRequested,
                      dragged: entries[index].key == draggedKey,
                      onDragMoved: onDragMoved,
                      onDragReleased: onDragReleased,
                      onDragCancelled: onDragCancelled,
                    ),
                  // Empty-dock hint (:1220-1227): the source shows "Drop apps
                  // here" — denial cut external file drags (card §4), so an
                  // apps icon in onSurfaceVariant keeps the affordance
                  // without dead copy (recorded in visual-deltas).
                  if (entries.isEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0, // centred inside the glass run
                      height: resting,
                      child: Icon(
                        Icons.apps_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
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

/// A divider that animates its x on reflow (:863-869); while
/// `directMagnification` the duration is zero so it follows the wave.
class _AnimatedDivider extends StatelessWidget {
  const _AnimatedDivider({
    required this.divider,
    required this.top,
    required this.height,
    required this.duration,
    required this.color,
    super.key,
  });

  final double divider;
  final double top;
  final double height;
  final Duration duration;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      // :859 — the divider is centered on its axis position.
      left: divider - kDockDividerWidth / 2,
      top: top,
      width: kDockDividerWidth, // :857
      height: height,
      duration: duration,
      curve: Curves.easeOutCubic, // :866-868
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1), // :861
        ),
      ),
    );
  }
}

/// One slot's DockItem with the reflow position animation (:1028-1057),
/// wrapped in the shared hover-preview / context-menu portal
/// (`DockPreviewCard`, TASK-04/05). The icon is bottom-anchored by
/// `kDockIconBottomInset` above the band bottom (DockItem.qml:112) so
/// magnification grows it upward into the band head-room; together with
/// `kDockGlassTopGap` it keeps the resting icon inside the glass.
class _DockSlotItem extends StatelessWidget {
  const _DockSlotItem({
    required this.entry,
    required this.slot,
    required this.restingIconSize,
    required this.monitorId,
    required this.duration,
    required this.showPopup,
    this.onTogglePin,
    this.onHovered,
    this.onHoverLeft,
    this.onPressStarted,
    this.onActivated,
    this.onContextRequested,
    this.dragged = false,
    this.onDragMoved,
    this.onDragReleased,
    this.onDragCancelled,
    super.key,
  });

  final DockEntry entry;
  final DockSlot slot;
  final double restingIconSize;
  final int monitorId;
  final Duration duration;

  /// Whether this row is the one being dragged (`DockItem.dragged`, :61).
  final bool dragged;

  /// `DockPreviewCard.show` exclusivity hook (band-owned).
  final void Function(VoidCallback hide) showPopup;

  /// Pin/unpin forwarded into the TASK-05 menu.
  final void Function(String key)? onTogglePin;
  final void Function(String key)? onHovered;
  final void Function(String key)? onHoverLeft;
  final VoidCallback? onPressStarted;
  final void Function(String key)? onActivated;
  final void Function(String key)? onContextRequested;
  final DockItemDragMoved? onDragMoved;
  final DockItemDragReleased? onDragReleased;
  final VoidCallback? onDragCancelled;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      // :963-968 — x = slot.start, width = slot.span (the slot footprint
      // includes the trailing gap); height = band height.
      left: slot.start,
      top: 0,
      bottom: 0,
      width: slot.span,
      duration: duration,
      curve: Curves.easeOutCubic, // :1030-1033
      child: Align(
        // DockItem.qml:110-112 — artwork x centers in the slot; y is pinned
        // kDockIconBottomInset above the delegate bottom (bounce offsets are
        // applied by DockItem's own Transform).
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: kDockIconBottomInset),
          // Spacer rows are the TASK-07 placeholder entity: invisible at rest,
          // never hovering/menu-able (`!spacer` gates, DockItem.qml:202,
          // DockSurface.qml:981-985).
          child: entry.kind == 'spacer' || entry.kind == 'small-spacer'
              ? DockSpacer(
                  small: entry.kind == 'small-spacer',
                  size: slot.size,
                )
              : DockPreviewCard(
            windows: entry.windows,
            monitorId: monitorId,
            show: showPopup,
            menuBuilder: _buildMenu,
            // :977-987 — the tooltip yields whenever a hover preview can open;
            // entries without windows keep the plain name tooltip.
            child: DockItem(
              entryKey: entry.key,
              kind: entry.kind,
              name: entry.name,
              appId: entry.appId,
              launchId: entry.launchId,
              monitorId: monitorId,
              windowId: entry.windowId,
              windowCount: entry.windowCount,
              focused: entry.focused,
              launching: entry.launching,
              available: entry.available,
              dragged: dragged, // :61
              iconSize: slot.size, // :969
              restingIconSize: restingIconSize, // :971
              showTooltip: entry.windows.isEmpty,
              onHovered: onHovered,
              onHoverLeft: onHoverLeft,
              onPressStarted: onPressStarted,
              onActivated: onActivated,
              onContextRequested: onContextRequested,
              onDragMoved: onDragMoved,
              onDragReleased: onDragReleased,
              onDragCancelled: onDragCancelled,
            ),
          ),
        ),
      ),
    );
  }

  /// TASK-05 menu content for this entry, rendered through the shared portal.
  Widget _buildMenu(
    BuildContext context,
    OverlayChildLayoutInfo layout,
    VoidCallback close,
  ) => DockContextMenu(
    layout: layout,
    onClose: close,
    monitorId: monitorId,
    kind: entry.kind,
    entryName: entry.name,
    available: entry.available,
    launchId: entry.launchId,
    windows: entry.windows,
    pinned: entry.pinned,
    onTogglePin: entry.kind == 'app' && onTogglePin != null
        ? () => onTogglePin!(entry.key)
        : null,
  );
}

/// Pointer-following drag ghost (`DockDragVisual.qml`): the dragged entry's
/// artwork at the drag size. Applications render their icon; spacers keep the
/// source's 1px outline (`DockDragVisual.qml:127-136`).
class _DockDragGhost extends StatelessWidget {
  const _DockDragGhost({
    required this.entry,
    required this.size,
    required this.services,
  });

  final DockEntry entry;
  final double size;
  final ShellServices services;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: switch (entry.kind) {
      'spacer' || 'small-spacer' => DockSpacer(
        small: entry.kind == 'small-spacer',
        dragging: true,
        size: size,
      ),
      _ => services.buildApplicationIcon(context, entry.appId),
    },
  );
}

/// Dock 底条左右状态槽装配（kos_topbar 合并迁入）。
///
/// 左=工作区胶囊，右=状态簇（托盘→WiFi→电源→控制中心→时间，时间最右，
/// 对齐 NextKde BarStatusArea 视觉顺序），dock 图标带居中。由
/// [DockSurface.statusBarBuilder] 注入；真实装配 `kos_dock.dart`/`DockHost`
/// 传入，widget 测试不传（`_FakeServices` 不实现状态服务）。
/// Dock 底条左右状态槽装配（kos_topbar 合并迁入）。
///
/// 左=工作区胶囊，右=状态簇（托盘→WiFi→电源→控制中心→时间，时间最右，
/// 对齐 NextKde BarStatusArea 视觉顺序），dock 图标带居中。由
/// [DockSurface.statusBarBuilder] 注入；真实装配 `kos_dock.dart`/`DockHost`
/// 传入，widget 测试不传（`_FakeServices` 不实现状态服务）。
///
/// 外层 `DockSurface` 已铺一条贯穿两端的全宽玻璃条（`_DockStripGlass`）并把
/// 本 builder 钉在 `bottom:kDockEdgeOffset, height:resting` 的槽位里——所以
/// 这里只负责水平排布 + 垂直居中，模块共享整根玻璃条、不再各自浮空胶囊
/// （用户要求「连成一条、取消大空隙」，对齐 NextKde 裸排玻璃观感）。各模块
/// 仍自带 InkWell hover/scale 反馈，无需独立卡片底板。
Widget buildDockStatusBar(
  BuildContext context, {
  required int monitorId,
}) {
  return Stack(
    clipBehavior: Clip.none,
    children: [
      // 左：工作区指示（裸排进整条玻璃，不另包胶囊）。accent 由 Consumer
      // watch presentationServices.accent（平填链实际用 theme.accent/
      // textSecondary，accent 仅透传接口）。
      Positioned(
        left: 10,
        top: 0,
        bottom: 0,
        child: Center(
          child: Consumer(
            builder: (context, ref, _) {
              final accent = ref.watch(
                ShellServicesScope.of(context).accent,
              );
              return WorkspaceIndicator(
                monitorId: monitorId,
                horizontal: true,
                accent: WallpaperAccent(accent),
              );
            },
          ),
        ),
      ),
      // 右：状态簇 托盘→WiFi→电源→控制中心→时间（时间最右）。间距收紧到
      // NextKde BarStatusArea 的紧凑观感（spacing 6，去掉电池百分比）。
      Positioned(
        right: 12,
        top: 0,
        bottom: 0,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              TopBarTrayStatusModule(horizontal: true),
              const TopBarNetworkStatusModule(),
              const TopBarBatteryStatusModule(),
              const TopBarControlCenterModule(),
              const TopBarClockStatusModule(),
            ],
          ),
        ),
      ),
    ],
  );
}
