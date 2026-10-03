// Widget tests for the TASK-07 MPRIS media bar
// (lib/src/widgets/media_bar.dart). The pure matcher/gating predicates are
// covered by `dock_media_test.dart`.

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart'
    show MprisPlaybackState, MprisPlaybackStatus;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/media_bar.dart';

MprisPlaybackState _player({
  String serviceName = 'org.mpris.MediaPlayer2.someplayer',
  String identity = '',
  MprisPlaybackStatus status = MprisPlaybackStatus.playing,
  bool canGoPrevious = true,
  bool canPlay = true,
  bool canPause = true,
  bool canGoNext = true,
}) => MprisPlaybackState(
  serviceName: serviceName,
  identity: identity,
  title: 'Track',
  artists: const <String>['Artist'],
  album: 'Album',
  artUrl: '',
  length: const Duration(minutes: 3),
  position: Duration.zero,
  observedAt: DateTime(2026),
  status: status,
  canGoNext: canGoNext,
  canGoPrevious: canGoPrevious,
  canPlay: canPlay,
  canPause: canPause,
);

final class _FakeCommands implements MediaCommands {
  int previousCalls = 0;
  int playPauseCalls = 0;
  int nextCalls = 0;

  @override
  MprisPlaybackState get current => MprisPlaybackState.unavailable();

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> playPause() async => playPauseCalls++;

  @override
  Future<void> next() async => nextCalls++;
}

Widget _wrap({required Widget child}) => ProviderScope(
  child: ShellTheme(
    data: const ShellThemeData(),
    child: MaterialApp(home: Scaffold(body: Center(child: child))),
  ),
);

Future<void> _pumpBar(
  WidgetTester tester, {
  required String appId,
  required MprisPlaybackState state,
  MediaCommands? commands,
}) {
  return tester.pumpWidget(
    _wrap(
      child: SizedBox(
        width: 320,
        height: 216,
        child: DockMediaBar(
          appId: appId,
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (ref) => AsyncValue<MprisPlaybackState>.data(state),
          ),
          mediaCommands: commands == null
              ? null
              : Provider<MediaCommands>((ref) => commands),
        ),
      ),
    ),
  );
}

/// Finder for the bar's own opaque swallow layer (InkWell adds the ones with
/// pointer callbacks).
final _hitRegion = find.descendant(
  of: find.byType(DockMediaBar),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Listener &&
        widget.behavior == HitTestBehavior.opaque &&
        widget.onPointerDown == null &&
        widget.onPointerMove == null &&
        widget.onPointerUp == null,
  ),
);

void main() {
  group('dockMediaToggleIcon', () {
    test('follows isPlaying (DockWindowCard.qml:156)', () {
      expect(dockMediaToggleIcon(_player()), Icons.pause);
      expect(
        dockMediaToggleIcon(_player(status: MprisPlaybackStatus.paused)),
        Icons.play_arrow,
      );
    });
  });

  group('DockMediaBar widget', () {
    testWidgets('renders three buttons for a matching player and plays', (
      tester,
    ) async {
      final commands = _FakeCommands();
      await _pumpBar(
        tester,
        appId: 'firefox',
        state: _player(
          serviceName: 'org.mpris.MediaPlayer2.firefox',
          identity: 'Firefox',
        ),
        commands: commands,
      );

      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsOneWidget); // playing → pause
      expect(find.byIcon(Icons.skip_next), findsOneWidget);

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(commands.playPauseCalls, 1);

      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pump();
      expect(commands.previousCalls, 1);
      expect(commands.nextCalls, 1);
    });

    testWidgets('paused player shows play_arrow', (tester) async {
      await _pumpBar(
        tester,
        appId: 'firefox',
        state: _player(
          identity: 'firefox',
          status: MprisPlaybackStatus.paused,
        ),
      );
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
    });

    testWidgets('renders nothing without a matching player', (tester) async {
      await _pumpBar(
        tester,
        appId: 'firefox',
        state: _player(identity: 'spotify'),
      );
      expect(find.byType(IconButton), findsNothing);
      expect(_hitRegion, findsNothing);
    });

    testWidgets('disabled capabilities produce disabled buttons', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        appId: 'firefox',
        state: _player(
          identity: 'firefox',
          status: MprisPlaybackStatus.paused, // play_arrow glyph
          canGoPrevious: false,
          canGoNext: false,
          canPlay: false,
          canPause: false,
        ),
      );
      IconButton buttonFor(IconData icon) => tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ),
      );
      expect(buttonFor(Icons.skip_previous).onPressed, isNull);
      expect(buttonFor(Icons.play_arrow).onPressed, isNull);
      expect(buttonFor(Icons.skip_next).onPressed, isNull);
    });

    testWidgets('bar width is buttons + 8 (DockWindowCard.qml:129)', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        appId: 'firefox',
        state: _player(identity: 'firefox'),
      );
      // 3 × controlSize 32 + 8 (4px padding each side, DockWindowCard.qml:129).
      expect(tester.getSize(_hitRegion).width, closeTo(104, 0.5));
      final row = find.descendant(
        of: find.byType(DockMediaBar),
        matching: find.byType(Row),
      );
      expect(
        tester.getSize(_hitRegion).width - tester.getSize(row).width,
        closeTo(8, 0.5),
      );
    });

    testWidgets('bar swallows taps on its padding (no click-through)', (
      tester,
    ) async {
      var backgroundTaps = 0;
      await tester.pumpWidget(
        _wrap(
          child: SizedBox(
            width: 320,
            height: 216,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundTaps++,
                    child: const ColoredBox(color: Color(0xff101010)),
                  ),
                ),
                DockMediaBar(
                  appId: 'firefox',
                  media: Provider<AsyncValue<MprisPlaybackState>>(
                    (ref) => AsyncValue<MprisPlaybackState>.data(
                      _player(identity: 'firefox'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final rect = tester.getRect(_hitRegion);
      // 2px inside the left edge — the 4px padding gap, not a button.
      await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
      await tester.pump();
      expect(backgroundTaps, 0);
    });
  });
}
