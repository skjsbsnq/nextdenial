// Pure-Dart tests for the MPRIS matcher/gating predicates
// (lib/src/data/dock_media.dart) — no Flutter import, runnable with
// `dart test` in principle (the package still needs the Denial SDK override).

import 'package:denial_sdk/system.dart'
    show MprisPlaybackState, MprisPlaybackStatus;
import 'package:kos_dock/src/data/dock_media.dart';
import 'package:test/test.dart';

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

void main() {
  group('DockMedia.js port', () {
    test('dockMediaServiceSuffix strips the MPRIS prefix', () {
      expect(
        dockMediaServiceSuffix('org.mpris.MediaPlayer2.firefox'),
        'firefox',
      );
      expect(dockMediaServiceSuffix('something.else'), 'something.else');
      expect(dockMediaServiceSuffix(''), '');
    });

    test('matchingPlayers: identity, bus-name suffix, exact and empty', () {
      // identity match (desktopId strips a trailing .desktop)
      expect(dockMediaMatches(_player(identity: 'firefox'), 'firefox'), isTrue);
      expect(
        dockMediaMatches(_player(identity: 'firefox.desktop'), 'firefox'),
        isTrue,
      );
      // bus-name suffix match
      expect(
        dockMediaMatches(
          _player(serviceName: 'org.mpris.MediaPlayer2.firefox'),
          'firefox',
        ),
        isTrue,
      );
      // appId may itself carry the .desktop suffix
      expect(
        dockMediaMatches(_player(identity: 'firefox'), 'firefox.desktop'),
        isTrue,
      );
      // no folding: `Firefox` identity/bus does not equal appId `firefox`
      expect(dockMediaMatches(_player(identity: 'Firefox'), 'firefox'), isFalse);
      expect(
        dockMediaMatches(_player(identity: 'spotify'), 'firefox'),
        isFalse,
      );
      expect(dockMediaMatches(_player(identity: 'firefox'), ''), isFalse);
      expect(dockMediaMatches(_player(), 'firefox'), isFalse);
    });

    test('selectPlayer keeps the current member, else first (DockMedia.js:14-16)', () {
      final a = _player(identity: 'a');
      final b = _player(identity: 'b');
      expect(dockSelectPlayer(<MprisPlaybackState>[a, b], a), same(a));
      expect(dockSelectPlayer(<MprisPlaybackState>[a, b], b), same(b));
      final c = _player(identity: 'c');
      expect(dockSelectPlayer(<MprisPlaybackState>[a, b], c), same(a));
      expect(dockSelectPlayer(const <MprisPlaybackState>[], a), isNull);
      expect(dockSelectPlayer(const <MprisPlaybackState>[], null), isNull);
    });

    test('gating: available && can* (canControl approximation)', () {
      final playable = _player();
      expect(dockMediaCanGoPrevious(playable), isTrue);
      expect(dockMediaCanToggle(playable), isTrue);
      expect(dockMediaCanGoNext(playable), isTrue);

      final capped = _player(
        canGoPrevious: false,
        canGoNext: false,
        canPause: false,
        canPlay: false,
      );
      expect(dockMediaCanGoPrevious(capped), isFalse);
      expect(dockMediaCanToggle(capped), isFalse); // canPlay||canPause both false
      expect(dockMediaCanGoNext(capped), isFalse);

      // stopped players report unavailable → every control is disabled
      final stopped = _player(status: MprisPlaybackStatus.stopped);
      expect(stopped.available, isFalse);
      expect(dockMediaCanGoNext(stopped), isFalse);
      expect(dockMediaCanGoPrevious(stopped), isFalse);
      expect(dockMediaCanToggle(stopped), isFalse);

      // paused still counts as available
      final paused = _player(status: MprisPlaybackStatus.paused);
      expect(dockMediaCanToggle(paused), isTrue);

      // null player
      expect(dockMediaCanGoPrevious(null), isFalse);
      expect(dockMediaCanToggle(null), isFalse);
      expect(dockMediaCanGoNext(null), isFalse);
    });
  });
}
