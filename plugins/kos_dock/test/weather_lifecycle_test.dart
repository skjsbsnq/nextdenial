import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/dock_weather.dart';
import 'package:kos_dock/src/data/dock_weather_io.dart';

class _Store implements DockWeatherStateStore {
  _Store(this.readResult);
  final Future<Map<String, Object?>?> readResult;
  int writes = 0;
  @override
  Future<Map<String, Object?>?> read() => readResult;
  @override
  Future<void> write(Map<String, Object?> payload) async {
    writes++;
  }
}

void main() {
  testWidgets('dispose during restore does not resurrect weather polling', (
    tester,
  ) async {
    final restored = Completer<Map<String, Object?>?>();
    var requests = 0;
    final provider = OpenMeteoDockWeatherProvider(
      stateStore: _Store(restored.future),
      httpGet: (_) async {
        requests++;
        return {};
      },
      deskCenterLocationSource: _NoLocation(),
    );
    final starting = provider.start();
    provider.dispose();
    restored.complete(null);
    await starting;
    await tester.pump();
    expect(requests, 0);
    // testWidgets also asserts that no periodic timer survives this test.
  });
  testWidgets('dispose during fetch drops the late response and timer', (
    tester,
  ) async {
    final response = Completer<Map<String, Object?>>();
    final store = _Store(Future.value(null));
    final provider = OpenMeteoDockWeatherProvider(
      stateStore: store,
      httpGet: (_) => response.future,
      deskCenterLocationSource: _NoLocation(),
    );
    final starting = provider.start();
    await tester.pump();
    provider.dispose();
    response.complete({});
    await starting;
    await tester.pump();
    expect(store.writes, 0);
  });
  testWidgets('concurrent starts share one initialization', (tester) async {
    final restored = Completer<Map<String, Object?>?>();
    var requests = 0;
    final provider = OpenMeteoDockWeatherProvider(
      stateStore: _Store(restored.future),
      httpGet: (_) async {
        requests++;
        return {};
      },
      deskCenterLocationSource: _NoLocation(),
    );
    final first = provider.start();
    final second = provider.start();
    expect(identical(first, second), isTrue);
    restored.complete(null);
    await Future.wait([first, second]);
    provider.dispose();
    expect(requests, 1);
  });
}

class _NoLocation implements DockDeskCenterLocationSource {
  @override
  Future<Map<String, Object?>?> read() async => null;
}
