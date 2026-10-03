// Widget tests for DockContextMenu — the TASK-05 right-click menu
// (plugins/kos_dock/lib/src/widgets/context_menu.dart).
//
// The menu rides the shared DockPreviewCard portal: the card's `menuBuilder`
// seam returns a DockContextMenu; right-click / contextMenu / Shift+F10 call
// `openMenu()`. Confirm-state reset and cascade hover delays run through the
// injectable `timerFactory` driven by the same manual FakeClock as
// preview_card_test.dart.
//
// Menu items mirror DockPreviewPopup.qml:208-410 in order/visibility:
//   :208-220 title (no windows) → :228-245 window checkable rows →
//   :247-252 separator → :253-298 DesktopActions → :299-305 separator →
//   :306-316 unavailable → :320-333 Open → :334-348 Close all →
//   :349-363 Force quit (+:364-374 error) → :375-381 separator →
//   :382-399 Pin/Unpin → :400-410 Dock settings.

import 'dart:async';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/context_menu.dart';
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

/// Manual clock shared by `timerFactory` (card delays) and the menu's
/// `timerFactory` (confirm reset / cascade hover).
final class FakeClock {
  int now = 0;
  final timers = <ScheduledTimer>[];
  Timer createTimer(Duration duration, void Function() callback) {
    final timer = ScheduledTimer(now + duration.inMilliseconds, callback);
    timers.add(timer);
    return timer;
  }

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
  final launched = <String>[];

  @override
  Provider<AsyncValue<MprisPlaybackState>> get media => _noMedia;

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async {
    launched.add(id);
    return true;
  }

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      const SizedBox.shrink();

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
  previewSize: Size(1920, 1080),
);
const _windowB = ApplicationWindow(
  id: 22,
  appId: 'app',
  title: 'Beta',
  active: false,
  minimized: false,
  previewSize: Size(800, 600),
);
const _windows = [_windowA, _windowB];

const _anchor = Key('anchor');
const _menuLabel = 'Dock context menu';

Future<void> _pumpMenu(
  WidgetTester tester, {
  required FakeClock clock,
  _FakeServices? services,
  List<ApplicationWindow> windows = _windows,
  bool disableAnimations = false,
  Alignment anchorAlignment = Alignment.bottomCenter,
  DockMenuBuilder? menuBuilder,
}) {
  return tester.pumpWidget(
    ProviderScope(
      child: ShellTheme(
        data: const ShellThemeData(),
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: MaterialApp(
            home: Scaffold(
              body: ShellServicesScope(
                services: services ?? _FakeServices(),
                child: Align(
                  alignment: anchorAlignment,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8, left: 8),
                    child: DockPreviewCard(
                      windows: windows,
                      monitorId: 0,
                      show: (_) {},
                      timerFactory: clock.createTimer,
                      menuBuilder: menuBuilder,
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

DockMenuBuilder appMenu({
  required FakeClock clock,
  List<ApplicationWindow> windows = _windows,
  bool available = true,
  String? launchId = 'app.launch',
  bool? pinned = false,
  void Function(int)? onCloseWindow,
  FutureOr<bool> Function()? onForceQuit,
  VoidCallback? onTogglePin,
  VoidCallback? onOpenSettings,
}) =>
    (context, layout, close) => DockContextMenu(
      layout: layout,
      onClose: close,
      monitorId: 0,
      entryName: 'Demo App',
      available: available,
      launchId: launchId,
      windows: windows,
      pinned: pinned,
      onTogglePin: onTogglePin,
      onCloseWindow: onCloseWindow,
      onForceQuit: onForceQuit,
      onOpenSettings: onOpenSettings,
      timerFactory: clock.createTimer,
    );

Finder get _menu => find.byWidgetPredicate(
  (w) => w is ShellInputRegion && w.debugLabel == _menuLabel,
);

Future<void> _rightClick(WidgetTester tester) async {
  await tester.tap(find.byKey(_anchor), buttons: kSecondaryButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150)); // 150ms fade-in
}

void main() {
  group('DockContextMenu', () {
    testWidgets('right click opens the full app item set in source order', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(tester, clock: clock, menuBuilder: appMenu(clock: clock));

      expect(_menu, findsNothing);
      await _rightClick(tester);

      expect(_menu, findsOneWidget);
      // :228-245 checkable window rows → :340 Close all → :355 Force quit →
      // :388 Pin → :405 Dock settings; :326 Open (canLaunch).
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Open application'), findsOneWidget);
      expect(find.text('Close all windows'), findsOneWidget);
      expect(find.text('Force quit'), findsOneWidget);
      expect(find.text('Pin to Dock'), findsOneWidget);
      expect(find.text('Dock settings'), findsOneWidget);
      // Outside-dismiss full-scene layer present (:656-662).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Listener &&
              w.behavior == HitTestBehavior.opaque &&
              w.onPointerDown != null,
        ),
        findsWidgets,
      );
    });

    testWidgets('unavailable app with no windows shows title + hint', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        windows: const [],
        menuBuilder: appMenu(
          clock: clock,
          windows: const [],
          available: false,
          launchId: null,
          pinned: null,
        ),
      );
      // `openMenu()` is the same `_openMenu` the contextMenu/Shift+F10
      // bindings invoke (:525-531); sendKeyEvent can't reach the binding in
      // this harness (no real key focus on the bare Focus child).
      tester.state<DockPreviewCardState>(
        find.byType(DockPreviewCard),
      ).openMenu();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.text('Demo App'), findsOneWidget); // :208-220
      expect(
        find.text('Application is unavailable'),
        findsOneWidget,
      ); // :306-316
      expect(find.text('Open application'), findsNothing); // !canLaunch
      expect(find.text('Pin to Dock'), findsNothing); // !canChangePin
      // Dock settings stays a disabled placeholder without a host service.
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Dock settings'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('outside pointer down closes the menu', (tester) async {
      final clock = FakeClock();
      await _pumpMenu(tester, clock: clock, menuBuilder: appMenu(clock: clock));
      await _rightClick(tester);
      expect(_menu, findsOneWidget);

      await tester.tapAt(const Offset(10, 10)); // transparent full-scene layer
      await tester.pump();
      expect(_menu, findsNothing);
    });

    testWidgets('Escape closes the menu', (tester) async {
      final clock = FakeClock();
      await _pumpMenu(tester, clock: clock, menuBuilder: appMenu(clock: clock));
      await _rightClick(tester);
      expect(_menu, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_menu, findsNothing);
    });

    testWidgets(
      'Force quit is two-stage: first tap arms, timer resets, second executes',
      (tester) async {
        final clock = FakeClock();
        var quitCalls = 0;
        await _pumpMenu(
          tester,
          clock: clock,
          menuBuilder: appMenu(
            clock: clock,
            onForceQuit: () {
              quitCalls++;
              return true;
            },
          ),
        );
        await _rightClick(tester);

        await tester.tap(find.text('Force quit'));
        await tester.pump();
        expect(quitCalls, 0); // arm only
        expect(find.text('Confirm force quit?'), findsOneWidget);

        clock.advance(2999); // confirm window not elapsed
        await tester.pump();
        expect(find.text('Confirm force quit?'), findsOneWidget);
        clock.advance(1); // reset
        await tester.pump();
        expect(find.text('Force quit'), findsOneWidget);

        await tester.tap(find.text('Force quit')); // re-arm
        await tester.pump();
        await tester.tap(find.text('Confirm force quit?')); // execute
        await tester.pump();
        expect(quitCalls, 1);
        expect(_menu, findsNothing); // success dismisses (:360-362)
      },
    );

    testWidgets('failed force quit keeps the menu open with the error row', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        menuBuilder: appMenu(clock: clock, onForceQuit: () => false),
      );
      await _rightClick(tester);

      await tester.tap(find.text('Force quit'));
      await tester.pump();
      await tester.tap(find.text('Confirm force quit?'));
      await tester.pump();
      expect(_menu, findsOneWidget);
      expect(
        find.text('Unable to force quit this application.'),
        findsOneWidget,
      ); // :364-374
    });

    testWidgets('menu clamps 8px inside the output at the left edge', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        anchorAlignment: Alignment.bottomLeft,
        menuBuilder: appMenu(clock: clock),
      );
      await _rightClick(tester);

      final material = find
          .descendant(
            of: find.byType(ShellBackdropBlur),
            matching: find.byType(Material),
          )
          .first;
      final positioned = tester.widget<Positioned>(
        find.ancestor(of: material, matching: find.byType(Positioned)),
      );
      expect(positioned.left, 8); // clamped to output.left + 8
      expect(positioned.width, 244); // min(244, 800 - 16)
    });

    testWidgets('anchor at the top edge leaves no room → menu shrinks', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        anchorAlignment: Alignment.topLeft,
        menuBuilder: appMenu(clock: clock),
      );
      await _rightClick(tester);
      // maxHeight == 0 → SizedBox.shrink, no items (:636).
      expect(find.text('Dock settings'), findsNothing);
      expect(_menu, findsNothing);
    });

    testWidgets('menu shows instantly — no entrance fade', (tester) async {
      // The source popup is a plain `visible` toggle (taskbar menu: same);
      // the menu renders fully opaque on the first frame so a right-click
      // over a live preview is a single-step switch, not preview-out →
      // fade-in.
      final clock = FakeClock();
      await _pumpMenu(tester, clock: clock, menuBuilder: appMenu(clock: clock));
      await tester.tap(find.byKey(_anchor), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(); // overlay child builds

      // No Opacity wrapper anywhere inside the menu.
      expect(
        find.descendant(
          of: _menu,
          matching: find.byWidgetPredicate((w) => w is Opacity),
        ),
        findsNothing,
      );
      // And the menu content is already present.
      expect(_menu, findsOneWidget);
    });

    testWidgets('disableAnimations still shows the menu', (tester) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        disableAnimations: true,
        menuBuilder: appMenu(clock: clock),
      );
      await tester.tap(find.byKey(_anchor), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump();
      expect(_menu, findsOneWidget);
    });

    testWidgets('menu and previews are mutually exclusive on the portal', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(tester, clock: clock, menuBuilder: appMenu(clock: clock));

      // Hover → previews after the 200ms fake-clock delay.
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byKey(_anchor)));
      await tester.pump();
      clock.advance(200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey(11)), findsOneWidget); // preview card

      // Right click swaps the portal to menu mode (:431-439).
      await tester.tap(find.byKey(_anchor), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Force quit'), findsOneWidget);
      expect(find.byKey(const ValueKey(11)), findsNothing);

      // While the menu is up, hover cannot reopen previews (:331/:398).
      await gesture.moveTo(const Offset(10, 10));
      await tester.pump();
      clock.advance(500);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byKey(_anchor)));
      await tester.pump();
      clock.advance(500);
      await tester.pump();
      expect(find.byKey(const ValueKey(11)), findsNothing);
      expect(find.text('Force quit'), findsOneWidget);
    });

    testWidgets('window row activates + closes; Close all snapshots ids', (
      tester,
    ) async {
      final clock = FakeClock();
      final services = _FakeServices();
      final closed = <int>[];
      await _pumpMenu(
        tester,
        clock: clock,
        services: services,
        menuBuilder: appMenu(clock: clock, onCloseWindow: closed.add),
      );
      await _rightClick(tester);

      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(services.activated, [22]); // :240 activateWindow
      expect(_menu, findsNothing); // :241 dismissed

      await _rightClick(tester);
      await tester.tap(find.text('Close all windows'));
      await tester.pump();
      expect(closed, [11, 22]); // :343 snapshot then close each
      expect(_menu, findsNothing);
    });

    testWidgets('folder list view cascades; ancestorUrls/symlink guard', (
      tester,
    ) async {
      final clock = FakeClock();
      await _pumpMenu(
        tester,
        clock: clock,
        windows: const [],
        menuBuilder: (context, layout, close) => DockContextMenu(
          layout: layout,
          onClose: close,
          monitorId: 0,
          kind: 'folder',
          entryName: 'Docs',
          folderUrl: 'file:///docs',
          folderView: 'list',
          folderEntries: const [
            DockFolderEntry(url: 'file:///docs/a.txt', name: 'a.txt'),
            DockFolderEntry(
              url: 'file:///docs/sub',
              name: 'sub',
              isDirectory: true,
              children: [
                DockFolderEntry(url: 'file:///docs/sub/b.txt', name: 'b.txt'),
              ],
            ),
            // url == root folderUrl → ancestorUrls guard → plain row.
            DockFolderEntry(
              url: 'file:///docs',
              name: 'cycle',
              isDirectory: true,
            ),
            // isLink → never cascades (:95).
            DockFolderEntry(
              url: 'file:///docs/link',
              name: 'link',
              isDirectory: true,
              isLink: true,
            ),
          ],
          timerFactory: clock.createTimer,
        ),
      );
      await _rightClick(tester);

      // Only 'sub' qualifies for a cascade chevron (:95 guard on cycle/link).
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.text('b.txt'), findsNothing); // submenu closed

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('sub')));
      await tester.pump();
      clock.advance(200); // cascade open delay
      await tester.pump();
      expect(find.text('b.txt'), findsOneWidget); // nested portal content
      expect(
        find.text('Open in File Manager'),
        // list-section footer (:205-213) + generic folder open (:398-403)
        // + submenu footer.
        findsNWidgets(3),
      );
    });

    testWidgets('trash Empty Trash is a two-stage destructive confirm', (
      tester,
    ) async {
      final clock = FakeClock();
      var emptied = 0;
      await _pumpMenu(
        tester,
        clock: clock,
        windows: const [],
        menuBuilder: (context, layout, close) => DockContextMenu(
          layout: layout,
          onClose: close,
          monitorId: 0,
          kind: 'trash',
          entryName: 'Trash',
          onEmptyTrash: () {
            emptied++;
            return true;
          },
          timerFactory: clock.createTimer,
        ),
      );
      await _rightClick(tester);

      expect(find.text('Open Trash'), findsOneWidget); // :399
      await tester.tap(find.text('Empty Trash…')); // :406
      await tester.pump();
      expect(emptied, 0);
      // confirmEmpty heading becomes the armed label (:347).
      expect(
        find.text('Permanently delete all items in Trash?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Permanently delete all items in Trash?'));
      await tester.pump();
      expect(emptied, 1);
      expect(_menu, findsNothing);
    });
  });
}
