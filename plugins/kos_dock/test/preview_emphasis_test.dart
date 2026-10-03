// Fake-clock port of `denial_taskbar/test/preview_emphasis_test.dart` — the
// same `runZoned(ZoneSpecification createTimer)` injection seam, wrapped in
// `package:test` so it runs under `dart test` (kos_dock test convention).

import 'dart:async';

import 'package:kos_dock/src/preview_emphasis.dart';
import 'package:test/test.dart';

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

void main() {
  group('PreviewEmphasis', () {
    test('hover delay, handoff, dismissal and disposal', () {
      var now = 0;
      final timers = <ScheduledTimer>[];
      void advance(int milliseconds) {
        now += milliseconds;
        for (final timer in List.of(timers)) {
          if (timer.deadline <= now) timer.fire();
        }
      }

      runZoned(
        () {
          final starts = <int>[];
          final releases = <int>[];
          final hover = PreviewEmphasis(
            request: (id) {
              starts.add(id);
              return () => releases.add(id);
            },
          );
          hover.enter(1);
          advance(299);
          expect(starts, isEmpty);
          hover.enter(
            1,
          ); // Remaining on the same preview does not reset the delay.
          advance(1);
          expect(starts, [1]);
          hover.leave(1);
          expect(releases, [1]);

          hover.enter(2);
          advance(150);
          hover.enter(3);
          hover.leave(2); // A late exit must not cancel the new preview.
          advance(150);
          expect(starts, [1]);
          advance(150);
          expect(starts, [1, 3]);
          hover.clear(); // Popup dismissal or dragging.
          hover.clear();
          expect(releases, [1, 3]);

          hover.enter(4);
          advance(299);
          hover.leave(4);
          advance(1);
          expect(starts, [1, 3]);
          hover.enter(5);
          advance(300);
          hover.dispose();
          expect(releases, [1, 3, 5]);
          hover.enter(6);
          advance(2000);
          expect(starts, [1, 3, 5]);

          final pending = PreviewEmphasis(
            request: (id) {
              throw StateError('Disposed pending hover fired');
            },
          );
          pending.enter(7);
          pending.dispose();
          advance(300);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = ScheduledTimer(
              now + duration.inMilliseconds,
              callback,
            );
            timers.add(timer);
            return timer;
          },
        ),
      );
    });
  });
}
