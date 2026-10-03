// Widget tests for DockPreviewCard — the TASK-04 hover preview popup
// (plugins/kos_dock/lib/src/widgets/preview_card.dart).
//
// The 200ms open / 180ms close hover delays run through the injectable
// `timerFactory` seam (PreviewTimerFactory) driven by a manual FakeClock —
// the widget-level counterpart of the runZoned fake clock in
// preview_emphasis_test.dart. The same zone spec feeds an injected
// PreviewEmphasis so its 300ms dwell is covered by the fake clock too.

import 'dart:async';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/preview_emphasis.dart';
import 'package:kos_dock/src/widgets/preview_card.dart';

class ScheduledTimer implements Timer {
  ScheduledTimer(this.deadline, this.callback);
  final int deadline;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick = 1;
    callback();
  }
}

/// Manual clock behind `DockPreviewCard.timerFactory`.
final class FakeClock {
  int now = 0;
  final timers = <ScheduledTimer>[];
  Timer createTimer(Duration duration, void Function() callback) {
    final timer = ScheduledTimer(now + duration.inMilliseconds, callback);
    timers.add(timer);
    return timer;
  }

  ZoneSpecification get specification => ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) =>
        createTimer(duration, callback),
  );

  void advance(int milliseconds) {
    now += milliseconds;
    for (final timer in List.of(timers)) {
      if (timer.deadline <= now) timer.fire();
    }
  }
}

/// The preview card hosts the TASK-07 media bar, which reads `services.media`;
/// this reports "no player" so no bar renders in these tests.
final _noMedia = Provider<AsyncValue<MprisPlaybackState>>(
  (ref) => AsyncValue<MprisPlaybackState>.data(
    MprisPlaybackState.unavailable(),
  ),
);

final class _FakeServices implements ShellServices {
  final activated = <int>[];

  @override
  Provider<AsyncValue<MprisPlaybackState>> get media => _noMedia;

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) => ColoredBox(
    key: ValueKey('preview:$windowId'),
    color: const Color(0xff303030),
  );

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

const _windowA = ApplicationWindow(
  id: 11,
  appId: 'app',
  title: 'Alpha',
  active: true,
  minimized: false,
  previewSize: Size(1920, 1080), // 16:9 → 320×180
);
const _windowB = ApplicationWindow(
  id: 22,
  appId: 'app',
  title: 'Beta',
  active: false,
  minimized: false,
  previewSize: Size(800, 600), // 4:3 → 288×216
);
const _windows = [_windowA, _windowB];

const _anchor = Key('anchor');

Future<void> _pumpCard(
  WidgetTester tester, {
  required FakeClock clock,
  _FakeServices? services,
  List<ApplicationWindow> windows = _windows,
  bool dragging = false,
  bool disableAnimations = false,
  void Function(VoidCallback)? onShow,
  PreviewEmphasis? emphasis,
}) {
  return tester.pumpWidget(
    ProviderScope(
      // ShellInputRegion is a ConsumerStatefulWidget — needs a scope.
      child: ShellTheme(
        data: const ShellThemeData(),
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: MaterialApp(
            home: Scaffold(
              body: ShellServicesScope(
                services: services ?? _FakeServices(),
                child: Align(
                  // Anchor at the bottom edge like a dock icon; the card
                  // floats above it inside the nearest Overlay (MaterialApp's
                  // Navigator).
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DockPreviewCard(
                      windows: windows,
                      monitorId: 0,
                      dragging: dragging,
                      show: onShow ?? (_) {},
                      timerFactory: clock.createTimer,
                      emphasis: emphasis,
                      child: const SizedBox(
                        key: _anchor,
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Hovers the anchor with a fresh mouse pointer.
Future<TestGesture> _hoverAnchor(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byKey(_anchor)));
  await tester.pump();
  return gesture;
}

Future<void> _open(WidgetTester tester, FakeClock clock) async {
  clock.advance(200);
  await tester.pump(); // portal entry builds, open animation starts
  await tester.pump(const Duration(milliseconds: 200)); // 200ms open anim
}

void main() {
  group('DockPreviewCard', () {
    testWidgets('opens after 200ms hover, not before; cards ≤320×216', (
      tester,
    ) async {
      final clock = FakeClock();
      var showCalls = 0;
      await _pumpCard(tester, clock: clock, onShow: (_) => showCalls++);

      expect(find.text('Alpha'), findsNothing);
      await _hoverAnchor(tester);
      clock.advance(199);
      await tester.pump();
      expect(find.text('Alpha'), findsNothing); // delay not elapsed
      clock.advance(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(showCalls, 1); // widget.show(_hideImmediately) fired once

      final alpha = tester.getSize(find.byKey(const ValueKey(11)));
      expect(alpha.width, closeTo(320, 0.5)); // 16:9 caps at 320 wide
      expect(alpha.height, closeTo(180, 0.5));
      final beta = tester.getSize(find.byKey(const ValueKey(22)));
      expect(beta.width, closeTo(288, 0.5)); // 4:3 caps at 216 tall
      expect(beta.height, closeTo(216, 0.5));

      // Overlay registers its input region (childBounds, no fullScene).
      expect(
        find.byWidgetPredicate(
          (w) => w is ShellInputRegion && w.debugLabel == 'Dock window previews',
        ),
        findsOneWidget,
      );
      // Preview mode adds no full-screen outside-dismiss layer.
      expect(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.left == 0 && w.right == 0 && w.top == 0,
        ),
        findsNothing,
      );
    });

    testWidgets('leaving the anchor closes after 180ms, not before', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpCard(tester, clock: clock);
      final gesture = await _hoverAnchor(tester);
      await _open(tester, clock);
      expect(find.text('Alpha'), findsOneWidget);

      await gesture.moveTo(const Offset(10, 10)); // off anchor, off popup
      await tester.pump();
      clock.advance(179);
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget); // close delay not elapsed
      clock.advance(1);
      await tester.pump();
      await tester.pumpAndSettle(); // 180ms close anim → dismissed → hide()
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('entering the popup cancels the pending close (mouse bridge)', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpCard(tester, clock: clock);
      final gesture = await _hoverAnchor(tester);
      await _open(tester, clock);

      // Walk the pointer from the icon onto the card: the anchor's onExit
      // schedules the 180ms close and the overlay's onEnter cancels it.
      final card = tester.getCenter(find.byKey(const ValueKey(11)));
      await gesture.moveTo(card);
      await tester.pump();
      clock.advance(1000); // far past the 180ms close delay
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget); // still open

      // Leaving the popup restarts the 180ms close path.
      await gesture.moveTo(const Offset(10, 10));
      await tester.pump();
      clock.advance(180);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('tapping a card hides immediately and activates the window', (
      tester,
    ) async {
      final clock = FakeClock();
      final services = _FakeServices();
      await _pumpCard(tester, clock: clock, services: services);
      await _hoverAnchor(tester);
      await _open(tester, clock);

      await tester.tap(find.text('Alpha'), warnIfMissed: false);
      await tester.pump();
      expect(services.activated, [11]); // services.activateWindow(window.id)
      expect(find.text('Alpha'), findsNothing); // _hideImmediately
    });

    testWidgets('dragging suppresses the open path', (tester) async {
      final clock = FakeClock();
      await _pumpCard(tester, clock: clock, dragging: true);
      await _hoverAnchor(tester);
      clock.advance(1000);
      await tester.pump();
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('empty window list never opens', (tester) async {
      final clock = FakeClock();
      await _pumpCard(tester, clock: clock, windows: const []);
      await _hoverAnchor(tester);
      clock.advance(1000);
      await tester.pump();
      expect(find.byType(ShellInputRegion), findsNothing);
    });

    testWidgets('disableAnimations opens and closes instantly', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpCard(tester, clock: clock, disableAnimations: true);
      final gesture = await _hoverAnchor(tester);
      clock.advance(200);
      await tester.pump();
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget); // animation.value = 1

      await gesture.moveTo(const Offset(10, 10));
      await tester.pump();
      clock.advance(180);
      await tester.pump();
      await tester.pump();
      expect(find.text('Alpha'), findsNothing); // _hideImmediately
    });

    testWidgets('hover emphasis dwells 300ms then releases on leave', (
      tester,
    ) async {
      final clock = FakeClock();
      final emphasized = <int>[];
      final released = <int>[];
      // The injected PreviewEmphasis builds its Timer inside the fake-clock
      // zone, so its 300ms dwell rides the same manual clock.
      late final PreviewEmphasis emphasis;
      runZoned(() {
        emphasis = PreviewEmphasis(
          request: (id) {
            emphasized.add(id);
            return () => released.add(id);
          },
        );
      }, zoneSpecification: clock.specification);

      await runZoned(
        () => _pumpCard(tester, clock: clock, emphasis: emphasis),
        zoneSpecification: clock.specification,
      );
      final gesture = await _hoverAnchor(tester);
      await runZoned(
        () => _open(tester, clock),
        zoneSpecification: clock.specification,
      );

      // Enter/exit dispatch fires synchronously inside moveTo, so the whole
      // gesture runs inside the fake-clock zone.
      final card = tester.getCenter(find.byKey(const ValueKey(11)));
      await runZoned(() async {
        await gesture.moveTo(card);
        await tester.pump();
      }, zoneSpecification: clock.specification);
      clock.advance(299);
      await tester.pump();
      expect(emphasized, isEmpty); // dwell not elapsed
      clock.advance(1);
      await tester.pump();
      expect(emphasized, [11]);

      await runZoned(() async {
        await gesture.moveTo(const Offset(10, 10));
        await tester.pump();
      }, zoneSpecification: clock.specification);
      expect(released, [11]); // leave releases synchronously
    });
  });
}
