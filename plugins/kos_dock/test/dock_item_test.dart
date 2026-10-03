// Widget tests for DockItem (plugins/kos_dock/lib/src/widgets/dock_item.dart).
//
// Covers the TASK-02 acceptance checks: bounce trigger + reduce-motion skip,
// indicator dot presence/alpha, click → activateWindow / launchApplication,
// tooltip text, the 10px drag gate, and pointer cancellation.

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/dock_item.dart';
import 'package:kos_dock/src/widgets/dock_surface_math.dart'
    show kDockIconBottomInset;

/// Minimal ShellServices test double; only the members DockItem touches are
/// implemented.
final class _FakeServices implements ShellServices {
  final activated = <int>[];
  final launches = <({String id, int? monitorId})>[];
  bool launchResult = true;
  Object? launchError;

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) {
    launches.add((id: id, monitorId: monitorId));
    if (launchError != null) return Future.error(launchError!);
    return Future.value(launchResult);
  }

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      ColoredBox(
        key: ValueKey('icon:$appId'),
        color: Theme.of(context).colorScheme.primary,
      );

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

Widget _harness({
  required _FakeServices services,
  bool disableAnimations = false,
  DockItem? item,
}) {
  return ShellTheme(
    data: const ShellThemeData(),
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: ShellServicesScope(
        services: services,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(body: Center(child: item ?? const DockItem(
            entryKey: 'app:demo',
            name: 'Demo',
            appId: 'demo.desktop',
          ))),
        ),
      ),
    ),
  );
}

/// Like [_harness] but bottom-anchors the item, mirroring `_DockSlotItem`'s
/// `Align(bottomCenter)` so icon-size growth (magnification) extends upward and
/// the indicator's band-relative position stays fixed.
Widget _bottomHarness({required _FakeServices services, required DockItem item}) {
  return ShellTheme(
    data: const ShellThemeData(),
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: ShellServicesScope(
        services: services,
        child: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: item),
        ),
      ),
    ),
  );
}

/// The running-indicator bar — the only [DecoratedBox] carrying the bracket
/// radius [kDockIndicatorBarRadius] (the tooltip uses radius 4; the press shade
/// and artwork have none). Scoped under [DockItem] so it cannot over-match.
Finder _indicatorBar() => find.descendant(
  of: find.byType(DockItem),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).borderRadius ==
            BorderRadius.circular(kDockIndicatorBarRadius),
  ),
);

/// The bounce Transform directly under the AnimatedBuilder inside DockItem.
Finder _bounceTransform() => find.descendant(
  of: find.descendant(
    of: find.byType(DockItem),
    matching: find.byType(AnimatedBuilder),
  ),
  matching: find.byType(Transform),
);

Offset _bounceOffset(WidgetTester tester) {
  final transform = tester.widget<Transform>(_bounceTransform());
  return MatrixUtils.transformPoint(transform.transform, Offset.zero);
}

void main() {
  testWidgets('indicator bar shows a rounded accent bar with inactive alpha', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 1,
          windowId: 7,
        ),
      ),
    );
    final bar = tester.widget<DecoratedBox>(_indicatorBar());
    final decoration = bar.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(kDockIndicatorBarRadius));
    // Denial colour: `colorScheme.primary` (wallpaper-derived accent), at the
    // source's inactive alpha 0.8 (DockItem.qml:188) — never the source's
    // `onSurface`.
    final context = tester.element(find.byType(DockItem));
    final primary = Theme.of(context).colorScheme.primary;
    expect(decoration.color, primary.withValues(alpha: 0.8));
  });

  testWidgets('running bar renders at the fixed 10×3 size, not the icon box', (
    tester,
  ) async {
    const iconSize = 36.0;
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 1,
          windowId: 7,
          iconSize: iconSize,
          restingIconSize: iconSize,
        ),
      ),
    );
    final size = tester.getSize(_indicatorBar());
    expect(size.width, kDockIndicatorBarLength); // 10
    expect(size.height, kDockIndicatorBarThickness); // 3
    expect(size.width, lessThan(iconSize));
  });

  testWidgets('indicator bar sits below the icon in the glass inset lane', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 1,
          windowId: 7,
          iconSize: 36,
          restingIconSize: 36,
        ),
      ),
    );
    final icon = tester.getRect(find.byKey(const ValueKey('icon:demo')));
    final bar = tester.getRect(_indicatorBar());
    // Regression (user report "black dot too high, on top of the icon"): the
    // bar's bottom edge sits `kDockIconBottomInset - kDockIndicatorBottomInset`
    // (9 - 3 = 6) below the icon bottom, clear of the artwork.
    expect(bar.top, greaterThanOrEqualTo(icon.bottom - 0.5));
    expect(
      bar.bottom - icon.bottom,
      closeTo(kDockIconBottomInset - kDockIndicatorBottomInset, 0.5),
    );
    expect(bar.center.dx, closeTo(icon.center.dx, 0.5));
  });

  testWidgets('indicator bar geometry is invariant under magnification', (
    tester,
  ) async {
    // The parent anchors the item to the band bottom, so a larger `iconSize`
    // grows the artwork upward. The bar is sized by constants and positioned
    // relative to the box bottom, so its rect must not move or pulse (:182).
    Future<Rect> build(double iconSize) async {
      await tester.pumpWidget(
        _bottomHarness(
          services: _FakeServices(),
          item: DockItem(
            entryKey: 'a',
            name: 'Demo',
            appId: 'demo',
            windowCount: 1,
            windowId: 7,
            iconSize: iconSize,
            restingIconSize: 36,
          ),
        ),
      );
      return tester.getRect(_indicatorBar());
    }

    final resting = await build(36);
    final magnified = await build(54);
    expect(magnified, resting);
    expect(magnified.size.width, kDockIndicatorBarLength);
  });

  testWidgets('focused entry uses indicator alpha 1.0', (tester) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 1,
          windowId: 7,
          focused: true,
        ),
      ),
    );
    final bar = tester.widget<DecoratedBox>(_indicatorBar());
    final decoration = bar.decoration as BoxDecoration;
    expect(decoration.color!.a, closeTo(1.0, 0.01));
  });

  testWidgets('no indicator when windowCount == 0 or indicators off', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(entryKey: 'a', name: 'Demo', appId: 'demo'),
      ),
    );
    expect(_indicatorBar(), findsNothing);
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 2,
          windowId: 7,
          showIndicators: false,
        ),
      ),
    );
    expect(_indicatorBar(), findsNothing);
  });

  testWidgets('tap with a window calls activateWindow once', (tester) async {
    final services = _FakeServices();
    var callbackKey = '';
    await tester.pumpWidget(
      _harness(
        services: services,
        item: DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          windowCount: 1,
          windowId: 42,
          onActivated: (key) => callbackKey = key,
        ),
      ),
    );
    await tester.tap(find.byType(DockItem));
    expect(services.activated, [42]);
    expect(services.launches, isEmpty);
    expect(callbackKey, 'a');
  });

  testWidgets('tap without a window launches with monitorId', (tester) async {
    final services = _FakeServices();
    await tester.pumpWidget(
      _harness(
        services: services,
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          launchId: 'org.demo',
          monitorId: 3,
        ),
      ),
    );
    await tester.tap(find.byType(DockItem));
    await tester.pump();
    expect(services.activated, isEmpty);
    expect(services.launches, [(id: 'org.demo', monitorId: 3)]);
  });

  testWidgets('launching edge triggers the bounce', (tester) async {
    final services = _FakeServices();
    Widget build(bool launching) => _harness(
      services: services,
      item: DockItem(
        entryKey: 'a',
        name: 'Demo',
        appId: 'demo',
        launching: launching,
      ),
    );

    await tester.pumpWidget(build(false));
    expect(_bounceOffset(tester), Offset.zero);

    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(milliseconds: 50));
    // Rise phase: the icon is translated upward.
    expect(_bounceOffset(tester).dy, lessThan(0));

    // After the full 560ms arc the bounce is reset to 0 (DockItem.qml:103).
    await tester.pump(const Duration(seconds: 1));
    expect(_bounceOffset(tester), Offset.zero);
  });

  testWidgets('disableAnimations skips the bounce entirely', (tester) async {
    final services = _FakeServices();
    await tester.pumpWidget(
      _harness(
        services: services,
        disableAnimations: true,
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          launching: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(_bounceOffset(tester), Offset.zero);
  });

  testWidgets('tooltip shows the app name on hover when gated', (tester) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo App',
          appId: 'demo',
          showTooltip: true,
        ),
      ),
    );
    expect(find.text('Demo App'), findsNothing);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(DockItem)));
    await tester.pump();
    expect(find.text('Demo App'), findsOneWidget);
    // Press hides it (DockItem.qml:175-176 `!pointer.pressed`).
    await gesture.down(tester.getCenter(find.byType(DockItem)));
    await tester.pump();
    expect(find.text('Demo App'), findsNothing);
    await gesture.up();
  });

  testWidgets('dropTarget shows the dropHint unconditionally', (tester) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo App',
          appId: 'demo',
          dropTarget: true,
          dropHint: 'Open with Demo App',
        ),
      ),
    );
    expect(find.text('Open with Demo App'), findsOneWidget);
    expect(find.text('Demo App'), findsNothing);
  });

  testWidgets('unavailable app with no window dims to 0.45', (tester) async {
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          available: false,
        ),
      ),
    );
    final opacities = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .map((w) => w.opacity)
        .toList();
    expect(opacities, contains(0.45));
  });

  testWidgets('drag gate: <10px is a click, >=10px drags', (tester) async {
    final services = _FakeServices();
    final moved = <Offset>[];
    final released = <Offset>[];
    var pressStarted = 0;
    final item = DockItem(
      entryKey: 'a',
      name: 'Demo',
      appId: 'demo',
      launchId: 'org.demo',
      onPressStarted: () => pressStarted++,
      onDragMoved: (key, position, grabOffset, size) => moved.add(position),
      onDragReleased: (key, position) => released.add(position),
    );
    await tester.pumpWidget(_harness(services: services, item: item));

    // Small move (<10px) then release → click, no drag.
    final center = tester.getCenter(find.byType(DockItem));
    var gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    expect(moved, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(pressStarted, 1);
    expect(services.launches, isNotEmpty);

    // Large move → dragMoved/dragReleased, no extra click/launch.
    services.launches.clear();
    gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(moved.length, 2);
    await gesture.up();
    await tester.pump();
    expect(released.length, 1);
    expect(services.launches, isEmpty); // moved suppresses the click (:235)
  });

  testWidgets('hover bridges to onHovered/onHoverLeft', (tester) async {
    final hovered = <String>[];
    final left = <String>[];
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          onHovered: hovered.add,
          onHoverLeft: left.add,
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(DockItem)));
    await tester.pump();
    expect(hovered, ['a']);
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(left, ['a']);
  });

  testWidgets('launch failure is swallowed and the gate resets', (
    tester,
  ) async {
    final services = _FakeServices()..launchError = StateError('no app');
    await tester.pumpWidget(
      _harness(
        services: services,
        item: const DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          launchId: 'org.demo',
        ),
      ),
    );
    // The rejected Future must not escape as an unhandled async error
    // (taskbar `_activate` swallows it, window_buttons.dart:458-465).
    await tester.tap(find.byType(DockItem));
    await tester.pump();
    await tester.pump(); // let the catchError/whenComplete chain settle
    expect(services.launches, [(id: 'org.demo', monitorId: null)]);
    // Gate released: a second tap launches again (no stuck _launching).
    await tester.tap(find.byType(DockItem));
    await tester.pump();
    await tester.pump();
    expect(services.launches.length, 2);
  });

  testWidgets('non-left/right buttons are ignored (:201)', (tester) async {
    var pressStarted = 0;
    var contextRequests = 0;
    await tester.pumpWidget(
      _harness(
        services: _FakeServices(),
        item: DockItem(
          entryKey: 'a',
          name: 'Demo',
          appId: 'demo',
          onPressStarted: () => pressStarted++,
          onContextRequested: (_) => contextRequests++,
        ),
      ),
    );
    final center = tester.getCenter(find.byType(DockItem));
    // Middle-button press+release: neither pressStarted nor contextRequested.
    final gesture = await tester.startGesture(
      center,
      buttons: kMiddleMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(pressStarted, 0);
    expect(contextRequests, 0);
  });

  testWidgets(
    'semantic activate bypasses a stale _moved flag (:205)',
    (tester) async {
      final services = _FakeServices();
      await tester.pumpWidget(
        _harness(
          services: services,
          item: const DockItem(
            entryKey: 'a',
            name: 'Demo',
            appId: 'demo',
            windowCount: 1,
            windowId: 42,
          ),
        ),
      );
      final center = tester.getCenter(find.byType(DockItem));
      // Drag past the 10px gate and release → _moved stays true until the
      // next pointer down.
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(services.activated, isEmpty); // moved suppressed the pointer click
      // Semantics tap must still fire (Accessible.onPressAction is
      // unconditional in the source): invoke the Semantics widget's onTap
      // callback directly rather than through a pointer tap.
      final semantics = tester
          .widgetList<Semantics>(
            find.ancestor(
              of: find.byType(MouseRegion),
              matching: find.byType(Semantics),
            ),
          )
          .firstWhere((s) => s.properties.onTap != null);
      semantics.properties.onTap!();
      expect(services.activated, [42]);
    },
  );
}
