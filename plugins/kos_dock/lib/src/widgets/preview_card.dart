/// DockPreviewCard — the hover window-preview popup for one dock entry.
///
/// Mechanism is a 1:1 port of the taskbar `_WindowButton` preview half
/// (`denial_taskbar/lib/src/window_buttons.dart`, anchors cited inline);
/// only the dock parameters differ: open delay 200ms / close delay 180ms,
/// open animation 200ms / close 180ms (taskbar 180/120 :344-348), corner
/// radius 8, per-card cap 320×216.
///
/// The card mounts standalone: [child] is the hovered anchor (the caller
/// wraps a DockItem), the popup renders into the nearest `Overlay` through
/// `OverlayPortal.overlayChildLayoutBuilder` (:324, :518-521). The preview
/// and the TASK-05 context menu share this portal; `overlayChildBuilder`
/// dispatches on `_menu` (:520-521) — `_buildMenu` is a placeholder the menu
/// task fills. There is no full-screen outside-dismiss layer in preview mode
/// (:656-661 is menu-only).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../preview_emphasis.dart';
import 'context_menu.dart';
import 'media_bar.dart';
import 'preview_card_math.dart';

/// Creates a one-shot [Timer] — the injectable seam behind which the
/// fake-clock tests drive the 200ms open / 180ms close delays (widget-level
/// counterpart of the `runZoned(ZoneSpecification.createTimer)` pattern in
/// preview_emphasis_test.dart). The [PreviewEmphasis] dwell is covered by
/// injecting a zone-constructed instance via [DockPreviewCard.emphasis].
typedef PreviewTimerFactory = Timer Function(Duration, void Function());

/// Popup trigger and hover anchor for one dock entry's window previews.
///
/// `show` is the external exclusivity callback (:386, :434): before the
/// portal opens the first time the parent is handed `_hideImmediately` so a
/// sibling popup can dismiss this one.
class DockPreviewCard extends StatefulWidget {
  const DockPreviewCard({
    required this.child,
    required this.windows,
    required this.monitorId,
    required this.show,
    super.key,
    this.dragging = false,
    this.monitorBounds,
    this.timerFactory = Timer.new,
    this.emphasis,
    this.menuBuilder,
  });

  /// The anchor widget the card floats above (its paint transform defines
  /// the anchor rect, `_geometry` :620-627).
  final Widget child;

  /// Windows of the hovered dock entry; empty disables the hover path.
  final List<ApplicationWindow> windows;

  /// Output for `emphasizeWindow(monitorId:)`.
  final int monitorId;

  /// Whether the dock is currently dragging an icon — suppresses opening and
  /// post-frame closes an open popup (:359-367, :492-500).
  final bool dragging;

  /// Output rect the popup clamps into; `null` uses the whole overlay
  /// (:625).
  final Rect? monitorBounds;

  /// Exclusivity hook: `widget.show(_hideImmediately)` fires once before the
  /// portal opens; also reused by TASK-05 `_openMenu` (:434).
  final void Function(VoidCallback) show;

  /// Timer seam for the hover delays — defaults to `Timer.new`; tests pass a
  /// zone-intercepted or manual factory.
  final PreviewTimerFactory timerFactory;

  /// Hover-emphasis controller; injectable so the fake clock can cover its
  /// 300ms dwell through the same seam (defaults to
  /// `services.emphasizeWindow` with a `Timer.new` emphasis internally).
  final PreviewEmphasis? emphasis;

  /// TASK-05 menu builder for the `_menu` dispatch slot (:520-521) —
  /// receives the shared portal's layout info and `_closeMenu` (:441-444);
  /// typically returns a [DockContextMenu]. `null` renders nothing when
  /// `_menu` is set.
  final DockMenuBuilder? menuBuilder;

  @override
  State<DockPreviewCard> createState() => DockPreviewCardState();
}

@visibleForTesting
class DockPreviewCardState extends State<DockPreviewCard>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _focus = FocusNode();
  late final AnimationController _animation;
  late final PreviewEmphasis _emphasis;

  Timer? _timer;
  bool _menu = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context); // :375

  @override
  void initState() {
    super.initState();
    _emphasis =
        widget.emphasis ??
        PreviewEmphasis(
          request: (id) {
            // :327-339 — guard before asking the host to emphasize.
            if (!mounted ||
                widget.dragging ||
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
    _animation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200), // dock open
          reverseDuration: const Duration(milliseconds: 180), // dock close
        )..addStatusListener((status) {
          // :349-353 — hide the portal once the close animation lands.
          if (status == AnimationStatus.dismissed && mounted && !_menu) {
            _portal.hide();
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // :359-367 — surface hidden while open: cancel pending work and close on
    // the next frame (OverlayPortal must not mutate during this build).
    if (!ShellSurfacePresentation.visibleOf(context)) {
      _timer?.cancel();
      _emphasis.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ShellSurfacePresentation.visibleOf(context)) {
          _hideImmediately();
        }
      });
    }
  }

  void _openPreviews() {
    // :377-384 — all open guards in one place.
    if (!mounted ||
        widget.dragging ||
        widget.windows.isEmpty ||
        _menu ||
        !ShellSurfacePresentation.visibleOf(context)) {
      return;
    }
    if (!_portal.isShowing) {
      widget.show(_hideImmediately); // :386 — external exclusivity
      _portal.show();
    }
    if (_reduceMotion) {
      _animation.value = 1; // :389-393 — straight open
    } else {
      _animation.forward();
    }
  }

  void _enter() {
    _timer?.cancel();
    if (widget.dragging || _menu || widget.windows.isEmpty) return; // :398
    if (_portal.isShowing) {
      _openPreviews(); // :399-402 — re-entering while shown stays open
      return;
    }
    _timer = widget.timerFactory(
      const Duration(milliseconds: 200), // :403 — dock open delay
      _openPreviews,
    );
  }

  void _leave() {
    _timer?.cancel();
    if (!_menu) {
      _timer = widget.timerFactory(
        const Duration(milliseconds: 180), // :408 — dock close delay
        _hide,
      );
    }
  }

  void _hide() {
    _emphasis.clear(); // :412
    _timer?.cancel();
    if (!mounted) return;
    if (_menu || _reduceMotion) {
      _hideImmediately(); // :415-419 — straight close
    } else {
      _animation.reverse();
    }
  }

  void _hideImmediately() {
    _emphasis.clear();
    _timer?.cancel();
    if (!mounted) return;
    _portal.hide();
    _animation.value = 0;
    _menu = false; // :422-429
  }

  /// Public wrapper so the item's `contextRequested` path can open the
  /// menu without simulating a secondary tap (:575 / DockItem.qml:238).
  void openMenu() => _openMenu();

  void _openMenu() {
    // :431-439 — dragging/hidden guards, preview state reset, portal opens
    // in menu mode; preview hover stays suppressed via the `_menu` guards
    // (:331, :398, :415).
    if (!mounted ||
        widget.dragging ||
        !ShellSurfacePresentation.visibleOf(context)) {
      return;
    }
    _emphasis.clear();
    widget.show(_hideImmediately); // :434 — external exclusivity
    _timer?.cancel();
    _animation.value = 0;
    setState(() => _menu = true);
    _portal.show();
  }

  void _closeMenu() {
    // :441-444 — hide + hand focus back to the anchor.
    _hideImmediately();
    if (_focus.context != null) _focus.requestFocus();
  }

  @override
  void didUpdateWidget(covariant DockPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // :488-491 — emphasized window disappeared from the model.
    if (_emphasis.windowId != null &&
        !widget.windows.any((window) => window.id == _emphasis.windowId)) {
      _emphasis.clear();
    }
    // :492-500 — OverlayPortal must not mutate the overlay during its
    // parent's build; close on the next frame.
    if (widget.dragging || (!_menu && widget.windows.isEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            (widget.dragging || (!_menu && widget.windows.isEmpty))) {
          _hideImmediately();
        }
      });
    }
  }

  @override
  void dispose() {
    _emphasis.dispose();
    _timer?.cancel();
    _animation.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Anchor rect in overlay coordinates and the clamped output rect
  /// (:620-627).
  ({Rect anchor, Rect output}) _geometry(OverlayChildLayoutInfo layout) => (
    anchor: MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    ),
    output: (widget.monitorBounds ?? (Offset.zero & layout.overlaySize))
        .intersect(Offset.zero & layout.overlaySize),
  );

  @override
  Widget build(BuildContext context) {
    // :518-524 — portal + anchor MouseRegion; the preview/menu dispatch
    // position (:520-521) is kept for TASK-05.
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, layout) => _menu
          ? _buildMenu(context, layout)
          : _buildPreviews(context, layout),
      child: GestureDetector(
        // :575 — secondary tap opens the menu.
        onSecondaryTap: _openMenu,
        behavior: HitTestBehavior.translucent,
        child: CallbackShortcuts(
          bindings: {
            // :527-529 — keyboard menu key / Shift+F10.
            const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
            const SingleActivator(LogicalKeyboardKey.f10, shift: true):
                _openMenu,
            const SingleActivator(LogicalKeyboardKey.escape): _hide, // :530
          },
          child: Focus(
            focusNode: _focus, // :571 — restored by _closeMenu (:443)
            child: MouseRegion(
              onEnter: (_) => _enter(),
              onExit: (_) => _leave(),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }

  /// TASK-05 fills the context menu here — same dispatch slot as the
  /// taskbar's `_buildMenu` (:629+). Delegates to the injected
  /// [DockPreviewCard.menuBuilder] (typically a [DockContextMenu]); the
  /// injected `onClose` is `_closeMenu` (:441-444).
  Widget _buildMenu(BuildContext context, OverlayChildLayoutInfo layout) =>
      widget.menuBuilder?.call(context, layout, _closeMenu) ??
      const SizedBox.shrink();

  Widget _buildPreviews(BuildContext context, OverlayChildLayoutInfo layout) {
    if (widget.windows.isEmpty || widget.dragging) {
      _emphasis.clear(); // :761-764 — short circuit, no zero-size overlay
      return const SizedBox.shrink();
    }
    final geometry = _geometry(layout);
    // :766 — row budget inside the output with an 8px margin each side.
    final available = math.max(
      0.0,
      geometry.output.width - kDockPreviewMargin * 2,
    );
    // :767-770 — height budget capped at 216 above the anchor.
    final maxHeight = math.min(
      kDockPreviewMaxHeight,
      math.max(
        0.0,
        geometry.anchor.top - geometry.output.top - kDockPreviewMargin * 2,
      ),
    );
    if (available == 0 || maxHeight == 0) {
      _emphasis.clear(); // :771-774
      return const SizedBox.shrink();
    }
    final sizes = [
      for (final window in widget.windows)
        previewCardSize(
          sourceWidth: window.previewSize.width,
          sourceHeight: window.previewSize.height,
          maxWidth: math.min(kDockPreviewMaxWidth, available),
          maxHeight: maxHeight,
        ),
    ];
    final height = sizes.map((size) => size.height).reduce(math.max);
    // :779-783 — row width clamped to the budget; overflow scrolls.
    final width = math.min(
      available,
      sizes.fold(0.0, (sum, size) => sum + size.width) +
          (sizes.length - 1) * kDockPreviewGap,
    );
    // :784-787 — centered on the anchor, clamped inside the output - 8.
    final left = (geometry.anchor.center.dx - width / 2).clamp(
      geometry.output.left + kDockPreviewMargin,
      math.max(
        geometry.output.left + kDockPreviewMargin,
        geometry.output.right - kDockPreviewMargin - width,
      ),
    );
    final services = ShellServicesScope.of(context);
    return Stack(
      children: [
        Positioned(
          left: left.toDouble(),
          top: geometry.anchor.top - height - kDockPreviewMargin,
          width: width,
          height: height + kDockPreviewMargin,
          child: ShellInputRegion(
            debugLabel: 'Dock window previews',
            // :798-800 — overlay keeps the hover alive: pointer travel from
            // icon to card cancels the close timer via `_enter`.
            child: MouseRegion(
              onEnter: (_) => _enter(),
              onExit: (_) => _leave(),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): _hide,
                },
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    // :805-819 — easeOutCubic + 8px rise + 0.97→1 scale +
                    // fade, bottom-anchored.
                    final value = Curves.easeOutCubic.transform(
                      _animation.value,
                    );
                    return Transform.translate(
                      offset: Offset(0, 8 * (1 - value)),
                      child: Transform.scale(
                        scale: 0.97 + 0.03 * value,
                        alignment: Alignment.bottomCenter,
                        child: Opacity(opacity: value, child: child),
                      ),
                    );
                  },
                  child: Padding(
                    // :820-821 — the 8px bottom pad bridges icon → card so
                    // the pointer stays inside the MouseRegion corridor.
                    padding: const EdgeInsets.only(bottom: kDockPreviewMargin),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal, // :822-823
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment.end, // :825
                        children: [
                          for (final (i, window)
                              in widget.windows.indexed) ...[
                            if (i > 0)
                              const SizedBox(width: kDockPreviewGap), // :828
                            SizedBox(
                              key: ValueKey(window.id),
                              width: sizes[i].width,
                              height: sizes[i].height,
                              child: MouseRegion(
                                onEnter: (_) => _emphasis.enter(window.id),
                                onExit: (_) => _emphasis.leave(window.id),
                                child: Stack(
                                  children: [
                                    SizedBox.expand(
                                      child: _Preview(
                                        window: window,
                                        onTap: () {
                                          _hideImmediately();
                                          services.activateWindow(
                                            window.id,
                                          ); // :838-841
                                        },
                                      ),
                                    ),
                                    // TASK-07 media bar
                                    // (DockWindowCard.qml:124-172): bottom
                                    // centre, bottomMargin 4, only rendered
                                    // while a player matches the entry appId.
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 4,
                                      child: DockMediaBar(appId: window.appId),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One live-texture preview card — port of taskbar `_Preview`
/// (window_buttons.dart:860-912): dark Material, radius 8, antiAlias clip,
/// `buildWindowPreview` content, gradient title strip, ink tap → activate.
class _Preview extends StatelessWidget {
  const _Preview({required this.window, required this.onTap});
  final ApplicationWindow window;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    return Semantics(
      label: window.title,
      button: true,
      selected: window.active,
      child: Material(
        color: const Color(0xff202020),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            services.buildWindowPreview(context, window.id),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 22, 10, 8),
                  child: Text(
                    window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap, mouseCursor: services.linkCursor),
            ),
          ],
        ),
      ),
    );
  }
}
